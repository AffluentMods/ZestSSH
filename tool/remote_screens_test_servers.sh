#!/usr/bin/env bash
# The remote screen test servers for ZestSSH 4.0 (RDP, VNC, X11), for the remote
# screen work and its tests. For WSL (Ubuntu) or Linux, AS ROOT: from Windows,
#
#   wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh start
#   wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh start vencrypt
#   wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh start x264
#   wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh start x11
#   wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh status
#   wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh restart-vnc
#   wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh stop
#   wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh purge
#
# start installs what is missing (apt, no package service is started or left
# enabled), makes the test account and its password the first time, and starts:
#
#   RDP   xrdp 0.10 + xorgxrdp, an Xfce desktop    TCP 13389, TLS only
#         (security_layer=tls; xrdp offers no NLA/CredSSP, so a client sends
#         the password inside TLS, in the Client Info PDU; NLA is tested
#         against Windows), its own self-signed certificate
#         (CN=zestscreens-rdp.example.test), X displays from :40
#   VNC   TigerVNC Xvnc, display :31, 1280x800     TCP 15931 and the Unix
#         socket /run/zestscreens/vnc.sock (mode 0600, the test account's),
#         VncAuth with its own 8 character password; xterm and xeyes on it
#   VNC   with "start vencrypt", also a second Xvnc, display :32, 1024x768,
#   TLS   TCP 15932, VeNCrypt only: X509Vnc (the same VNC password) and
#         X509Plain (the test account and its password, through PAM service
#         zestscreens-vnc), its own self-signed certificate
#         (CN=zestscreens-vnc.example.test, kept in /etc/zestscreens)
#   RDP   with "start x264", also xrdp 0.10.2 built from its release tarball
#   H.264 with --enable-x264 (x264 is GPL: a test server only, never linked into
#         ZestSSH) and xorgxrdp 0.10.3 built against it, its own sesman and X
#         displays from :60, TCP 13390, TLS only, the same certificate; installed
#         under /opt/zestscreens/xrdp-x264 (configuration and X modules in there
#         too, nothing in /etc or /usr), built once (about 1 minute here). Its
#         gfx.toml asks for H.264 first, then RemoteFX (Progressive)
#   SSH   OpenSSH sshd of its own                  TCP 2240, password login for
#         the test account only, TCP and Unix socket forwarding on, X11
#         forwarding on (X11DisplayOffset 50, X11UseLocalhost yes)
#   X11   xeyes, xclock, xterm and xdpyinfo for the X11 forwarding test
#   X11   with "start x11", also a stand-in for the CLIENT's own X server (as
#   local VcXsrv or XQuartz would be): TigerVNC Xvnc :41, 1280x800, taking X
#         clients on TCP 6041 (all addresses: WSL's NAT network and the
#         localhost relay reach it from this PC only) with MIT-MAGIC-COOKIE-1
#         access control (a random cookie, kept in /etc/zestscreens/x11-local
#         as ZS_X11_COOKIE=<hex>, root only), its SECURITY extension on, and
#         viewed through the VNC socket /run/zestscreens/x11-local.sock (the
#         same VNC password); an xclock on it stands for the user's own window
#
# The account is "alex" with a password made by start (random, 20
# characters). It is kept ONLY in /etc/zestscreens/env (root:root, mode 0600),
# as ZS_USER, ZS_PASSWORD and ZS_VNC_PASSWORD lines; read it with
#   wsl -d Ubuntu -u root cat /etc/zestscreens/env
# purge deletes the account and that file; stop keeps both.
#
# How a test connects. Use WSL's own address (`wsl hostname -I`, the first
# one), not 127.0.0.1: WSL's localhost relay cut connections in the FTPS spike.
# WSL's NAT network is reachable from this PC only.
#
#   Direct          RDP  <wsl-ip>:13389       VNC  <wsl-ip>:15931
#   Through SSH     (what the app does by default; the servers are the same)
#     RDP over a local forward:  ssh -p 2240 -L 33389:127.0.0.1:13389 alex@<wsl-ip>
#                                then connect to 127.0.0.1:33389
#     VNC over a local forward:  ssh -p 2240 -L 35931:127.0.0.1:15931 alex@<wsl-ip>
#     VNC on the Unix socket:    ssh -p 2240 -L 35932:/run/zestscreens/vnc.sock alex@<wsl-ip>
#                                (OpenSSH 6.7+; the app opens a direct-streamlocal
#                                channel to the same path, no local port)
#     X11 forwarding:            ssh -X -p 2240 alex@<wsl-ip> xeyes
#                                (needs an X server on the client: VcXsrv on
#                                Windows; inside WSL, WSLg's :0 answers)
#
# The RDP probe in packages/zest_native/rust (examples/rdp_probe.rs, feature
# "rdp") reads ZS_RDP_HOST, ZS_RDP_PORT, ZS_USER and ZS_PASSWORD.
#
# WSLg mounts /tmp/.X11-unix read-only; each X server here runs in a systemd
# unit with a private writable /tmp/.X11-unix (TemporaryFileSystem), and X
# programs reach it through Linux's abstract socket, so WSLg is left as it is.
# Everything runs as transient systemd units named zestscreens-*.
set -euo pipefail

D=/etc/zestscreens
R=/run/zestscreens
L=/var/log/zestscreens
ENV_FILE=$D/env
# A made-up user (the fixtures' Alex): the spike used another name; `purge` it with the old
# script, or `userdel -r` it, if that account is still in the WSL distribution.
TEST_USER=alex
RDP_PORT=13389
VNC_DISPLAY=31
VNC_PORT=15931
VNC_SOCK=$R/vnc.sock
SSH_PORT=2240
X11_OFFSET=50
XRDP_OFFSET=40
PACKAGES=(xrdp xorgxrdp xfce4-session xfwm4 xfce4-panel xfdesktop4 xfce4-settings dbus-x11
  tigervnc-standalone-server tigervnc-tools x11-apps x11-utils xterm xauth openssh-server openssl xclip)
VNC_TLS_DISPLAY=32
# start x11: the client's X server stand-in.
X11_LOCAL_DISPLAY=41
X11_LOCAL_SOCK=$R/x11-local.sock
X11_LOCAL_ENV=$D/x11-local
VNC_TLS_PORT=15932
PAM_SERVICE=zestscreens-vnc
# start x264: xrdp built with x264 (H.264 in the graphics pipeline), beside the packaged one.
X264_PORT=13390
X264_OFFSET=60
X264_VERSION=0.10.2
X264_SHA256=6e2b4fb719fbd74a42c1008afc670e5e2940c8cbf3d8977e78c8451f7d267b62
X264_PREFIX=/opt/zestscreens/xrdp-x264
X264_SRC=/opt/zestscreens/src
# Its own socket folder: xrdp 0.10 always asks for sesman at <socket folder>/sesman.socket (a
# ListenPort that is not a number is ignored), so a second sesman needs a folder of its own.
X264_SOCKETS=/run/zestscreens-x264
# xorgxrdp built against that xrdp (Ubuntu's 0.10.2 was built against xrdp 0.10.1's headers and
# stops the X server: "expected xrdp client_info version 20230425, got 20241118"), and 0.10.3, the
# one released with xrdp 0.10.2: 0.10.2 has no NV12 BT.709 full-range capture, which xrdp 0.10.2 asks
# for in the graphics pipeline ("rdpCapture3: unimplemented color conversion": all-zero pictures).
X264_XORGXRDP_VERSION=0.10.3
X264_XORGXRDP_SHA256=9d425a5774c7ef79c5f3caf5bbe238f4f8e04f4e182e948cfdb3d7b76b6abcd4
X264_BUILD_DEPS=(libx264-dev libpam0g-dev libjpeg-dev nasm libxkbfile-dev libssl-dev libx11-dev
  libxfixes-dev libxrandr-dev xserver-xorg-dev build-essential pkg-config curl)
UNITS=(zestscreens-sesman zestscreens-xrdp zestscreens-xvnc zestscreens-vnc-apps zestscreens-sshd
  zestscreens-xvnc-tls zestscreens-sesman-x264 zestscreens-xrdp-x264 zestscreens-x11-local
  zestscreens-x11-local-apps)
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" != 0 ]; then
  echo "Run as root: wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh ${1:-start}" >&2
  exit 2
fi

unit_state() { systemctl is-active "$1.service" 2>/dev/null || true; }

listening() { ss -ltnH "( sport = :$1 )" | grep -q . && echo yes || echo no; }

stop_units() {
  for u in "${UNITS[@]}"; do
    systemctl stop "$u.service" 2>/dev/null || true
    systemctl reset-failed "$u.service" 2>/dev/null || true
  done
  # Sessions sesman started outlive it when their unit is gone: end them too.
  if id "$TEST_USER" > /dev/null 2>&1; then
    pkill -u "$TEST_USER" 2>/dev/null || true
  fi
  rm -rf "$R" "$X264_SOCKETS"
}

status() {
  echo "units:"
  for u in "${UNITS[@]}"; do printf '  %-24s %s\n' "$u" "$(unit_state "$u")"; done
  echo "listening:"
  printf '  RDP  tcp %-6s %s\n' "$RDP_PORT" "$(listening "$RDP_PORT")"
  printf '  VNC  tcp %-6s %s\n' "$VNC_PORT" "$(listening "$VNC_PORT")"
  printf '  VNC  tcp %-6s %s (VeNCrypt; with "start vencrypt")\n' "$VNC_TLS_PORT" "$(listening "$VNC_TLS_PORT")"
  printf '  RDP  tcp %-6s %s (xrdp %s with x264; with "start x264")\n' "$X264_PORT" "$(listening "$X264_PORT")" "$X264_VERSION"
  if [ -f "$D/vnc-cert.pem" ]; then
    echo "  VeNCrypt certificate SHA-256: $(openssl x509 -in "$D/vnc-cert.pem" -outform DER | sha256sum | cut -d' ' -f1)"
  fi
  printf '  SSH  tcp %-6s %s\n' "$SSH_PORT" "$(listening "$SSH_PORT")"
  printf '  X11  tcp %-6s %s (the client X server stand-in :%s; with "start x11")\n' \
    "$((6000 + X11_LOCAL_DISPLAY))" "$(listening "$((6000 + X11_LOCAL_DISPLAY))")" "$X11_LOCAL_DISPLAY"
  if [ -S "$VNC_SOCK" ]; then
    echo "  VNC  unix $VNC_SOCK yes ($(stat -c '%U %a' "$VNC_SOCK"))"
  else
    echo "  VNC  unix $VNC_SOCK no"
  fi
  echo "address: $(hostname -I | awk '{print $1}')"
  if [ -f "$ENV_FILE" ]; then
    echo "account: $TEST_USER, password in $ENV_FILE ($(stat -c '%U:%G %a' "$ENV_FILE"))"
  else
    echo "account: not made yet (start makes it)"
  fi
}

# The two X programs on the VNC display (xeyes follows the pointer, so moving it draws).
start_vnc_apps() {
  systemd-run --quiet --unit=zestscreens-vnc-apps --uid="$TEST_USER" --gid="$TEST_USER" \
    -E DISPLAY=":$VNC_DISPLAY" -E HOME="$1" \
    -p StandardOutput=append:$L/vnc-apps.out -p StandardError=append:$L/vnc-apps.out \
    /bin/sh -c 'xterm -geometry 80x24+20+20 & exec xeyes -geometry 240x180+700+40'
}

case "${1:-start}" in
  status)
    status
    exit 0
    ;;
  restart-vnc)
    # The VNC server restarted under its viewers (test/native/vnc_integration_test.dart): Xvnc :31
    # stops (every viewer is closed by it) and starts again, with its X programs.
    systemctl is-active --quiet zestscreens-xvnc.service || { echo "Xvnc is not running: start first" >&2; exit 1; }
    systemctl stop zestscreens-vnc-apps.service 2> /dev/null || true
    systemctl reset-failed zestscreens-vnc-apps.service 2> /dev/null || true
    systemctl restart zestscreens-xvnc.service
    for _ in $(seq 1 50); do
      [ -S "$VNC_SOCK" ] && [ "$(listening "$VNC_PORT")" = yes ] && break
      sleep 0.1
    done
    start_vnc_apps "$(getent passwd "$TEST_USER" | cut -d: -f6)"
    [ -S "$VNC_SOCK" ] && [ "$(listening "$VNC_PORT")" = yes ] || { echo "Xvnc did not come back: see $L/xvnc.out" >&2; exit 1; }
    echo "Xvnc :$VNC_DISPLAY restarted"
    exit 0
    ;;
  stop)
    stop_units
    status
    exit 0
    ;;
  purge)
    stop_units
    if id "$TEST_USER" > /dev/null 2>&1; then userdel -r "$TEST_USER" 2> /dev/null || true; fi
    rm -f "/var/mail/$TEST_USER"
    if [ -f "$D/installed-packages" ]; then
      # shellcheck disable=SC2046
      apt-get purge -y -qq $(sort -u "$D/installed-packages") > /dev/null || true
    fi
    for s in xrdp xrdp-sesman; do systemctl reset-failed "$s" 2> /dev/null || true; done
    rm -rf "$D" "$L" /usr/sbin/policy-rc.d "/etc/pam.d/$PAM_SERVICE" /opt/zestscreens
    status
    exit 0
    ;;
  start) ;;
  *)
    echo "usage: $0 start [vencrypt|x264|x11]|status|restart-vnc|stop|purge" >&2
    exit 2
    ;;
esac

mkdir -p "$D" "$L"
chmod 700 "$D"

# Packages: what is missing, with no package service started while installing.
missing=()
for p in "${PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2> /dev/null | grep -q 'ok installed' || missing+=("$p")
done
if [ "${#missing[@]}" -gt 0 ]; then
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
  chmod +x /usr/sbin/policy-rc.d
  trap 'rm -f /usr/sbin/policy-rc.d' EXIT
  dpkg-query -W -f='${Package}\n' | sort > "$D/packages-before"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${missing[@]}" > /dev/null
  # Every package this install added, its dependencies too: purge removes exactly these.
  dpkg-query -W -f='${Package}\n' | sort | comm -13 "$D/packages-before" - >> "$D/installed-packages"
  rm -f "$D/packages-before"
  rm -f /usr/sbin/policy-rc.d
fi
# The packages' own services stay off: these servers run as zestscreens-* units only.
for s in xrdp xrdp-sesman; do
  systemctl stop "$s" 2> /dev/null || true
  systemctl disable "$s" 2> /dev/null || true
done

# The test account and its passwords, made once, kept in the root-only env file.
if [ ! -f "$ENV_FILE" ]; then
  pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
  vncpw="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-8)"
  umask 077
  printf 'ZS_USER=%s\nZS_PASSWORD=%s\nZS_VNC_PASSWORD=%s\n' "$TEST_USER" "$pw" "$vncpw" > "$ENV_FILE"
  umask 022
fi
chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"
# The account is this script's own (TEST_USER), whose password is set below. A file an
# earlier version wrote may name another: whatever read the user from it then signed in
# as an account that does not exist, and only ever saw the sign-in screen (found on 15
# November 2026). The line is put right every time.
if [ "$(sed -n 's/^ZS_USER=//p' "$ENV_FILE")" != "$TEST_USER" ]; then
  if grep -q '^ZS_USER=' "$ENV_FILE"; then
    sed -i "s/^ZS_USER=.*/ZS_USER=$TEST_USER/" "$ENV_FILE"
  else
    printf 'ZS_USER=%s\n' "$TEST_USER" >> "$ENV_FILE"
  fi
fi
ZS_PASSWORD="$(sed -n 's/^ZS_PASSWORD=//p' "$ENV_FILE")"
ZS_VNC_PASSWORD="$(sed -n 's/^ZS_VNC_PASSWORD=//p' "$ENV_FILE")"
if ! id "$TEST_USER" > /dev/null 2>&1; then
  useradd -m -s /bin/bash "$TEST_USER"
fi
printf '%s:%s\n' "$TEST_USER" "$ZS_PASSWORD" | chpasswd
H="$(getent passwd "$TEST_USER" | cut -d: -f6)"
# The desktop xrdp's session starts (/etc/X11/Xsession runs ~/.xsession). On X only: under WSL,
# GTK would otherwise find WSLg's Wayland compositor and open the panel on the Windows desktop.
printf '%s\n' 'unset WAYLAND_DISPLAY' 'export GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb XDG_SESSION_TYPE=x11' \
  'exec startxfce4' > "$H/.xsession"
chown "$TEST_USER:$TEST_USER" "$H/.xsession"
install -d -o "$TEST_USER" -g "$TEST_USER" -m 700 "$H/.zestscreens"
printf '%s\n' "$ZS_VNC_PASSWORD" | vncpasswd -f > "$H/.zestscreens/vncpasswd"
chown "$TEST_USER:$TEST_USER" "$H/.zestscreens/vncpasswd"
chmod 600 "$H/.zestscreens/vncpasswd"

# Start clean.
stop_units
install -d -o "$TEST_USER" -g "$TEST_USER" -m 700 "$R"

# RDP: the certificate, then copies of the package's configuration with our port, TLS only,
# our certificate and X displays from :40.
if [ ! -f "$D/rdp-cert.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=zestscreens-rdp.example.test" \
    -keyout "$D/rdp-key.pem" -out "$D/rdp-cert.pem" 2> /dev/null
  chmod 600 "$D/rdp-key.pem"
fi
mkdir -p "$D/xrdp"
cp -a /etc/xrdp/. "$D/xrdp/"
# Only the first port= line ([Globals]); the session sections have their own (port=-1).
sed -i \
  -e "0,/^port=.*/s||port=tcp://:$RDP_PORT|" \
  -e "s|^security_layer=.*|security_layer=tls|" \
  -e "s|^certificate=.*|certificate=$D/rdp-cert.pem|" \
  -e "s|^key_file=.*|key_file=$D/rdp-key.pem|" \
  "$D/xrdp/xrdp.ini"
sed -i -e "s|^X11DisplayOffset=.*|X11DisplayOffset=$XRDP_OFFSET|" "$D/xrdp/sesman.ini"
systemd-run --quiet --unit=zestscreens-sesman \
  -p TemporaryFileSystem=/tmp/.X11-unix:mode=1777 \
  -p StandardOutput=append:$L/sesman.out -p StandardError=append:$L/sesman.out \
  /usr/sbin/xrdp-sesman --nodaemon --config "$D/xrdp/sesman.ini"
systemd-run --quiet --unit=zestscreens-xrdp \
  -p StandardOutput=append:$L/xrdp.out -p StandardError=append:$L/xrdp.out \
  /usr/sbin/xrdp --nodaemon --config "$D/xrdp/xrdp.ini"

# VNC: Xvnc on TCP and on a Unix socket, as the test account, with two X programs on it.
systemd-run --quiet --unit=zestscreens-xvnc --uid="$TEST_USER" --gid="$TEST_USER" \
  -p TemporaryFileSystem=/tmp/.X11-unix:mode=1777 \
  -p StandardOutput=append:$L/xvnc.out -p StandardError=append:$L/xvnc.out \
  /usr/bin/Xvnc ":$VNC_DISPLAY" -geometry 1280x800 -depth 24 -desktop zestscreens-vnc \
  -rfbport "$VNC_PORT" -localhost=0 -rfbunixpath "$VNC_SOCK" -rfbunixmode 0600 \
  -SecurityTypes VncAuth -PasswordFile "$H/.zestscreens/vncpasswd" -AlwaysShared -nolisten tcp
for _ in $(seq 1 50); do [ -S "$VNC_SOCK" ] && break; sleep 0.1; done
start_vnc_apps "$H"

# VNC with VeNCrypt (start vencrypt): a second Xvnc that offers only X509Vnc and X509Plain, with a
# self-signed certificate of its own; X509Plain checks the test account's password through PAM.
if [ "${2:-}" = vencrypt ]; then
  if [ ! -f "$D/vnc-cert.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=zestscreens-vnc.example.test" \
      -keyout "$D/vnc-key.pem" -out "$D/vnc-cert.pem" 2> /dev/null
    chmod 600 "$D/vnc-key.pem"
  fi
  # Xvnc runs as the test account and reads its key: a copy the account owns, in its home.
  install -o "$TEST_USER" -g "$TEST_USER" -m 600 "$D/vnc-key.pem" "$H/.zestscreens/vnc-key.pem"
  install -o "$TEST_USER" -g "$TEST_USER" -m 644 "$D/vnc-cert.pem" "$H/.zestscreens/vnc-cert.pem"
  printf '%s\n' '@include common-auth' '@include common-account' > "/etc/pam.d/$PAM_SERVICE"
  systemd-run --quiet --unit=zestscreens-xvnc-tls --uid="$TEST_USER" --gid="$TEST_USER" \
    -p TemporaryFileSystem=/tmp/.X11-unix:mode=1777 \
    -p StandardOutput=append:$L/xvnc-tls.out -p StandardError=append:$L/xvnc-tls.out \
    /usr/bin/Xvnc ":$VNC_TLS_DISPLAY" -geometry 1024x768 -depth 24 -desktop zestscreens-vnc-tls \
    -rfbport "$VNC_TLS_PORT" -localhost=0 -SecurityTypes X509Vnc,X509Plain \
    -X509Cert "$H/.zestscreens/vnc-cert.pem" -X509Key "$H/.zestscreens/vnc-key.pem" \
    -PasswordFile "$H/.zestscreens/vncpasswd" -PlainUsers "$TEST_USER" -pam_service "$PAM_SERVICE" \
    -AlwaysShared -nolisten tcp
fi

# The client's X server stand-in (start x11): Xvnc :41 taking X clients on TCP with a cookie, as
# VcXsrv or XQuartz would on the user's computer; the forwarded windows are seen through its VNC
# socket. The cookie is made once and kept root only; Xvnc reads it from an auth file the test
# account owns.
if [ "${2:-}" = x11 ]; then
  if [ ! -f "$X11_LOCAL_ENV" ]; then
    umask 077
    printf 'ZS_X11_COOKIE=%s
' "$(openssl rand -hex 16)" > "$X11_LOCAL_ENV"
    umask 022
  fi
  chmod 600 "$X11_LOCAL_ENV"
  x11_cookie="$(sed -n 's/^ZS_X11_COOKIE=//p' "$X11_LOCAL_ENV")"
  rm -f "$H/.zestscreens/x11-local.auth"
  runuser -u "$TEST_USER" -- sh -c 'umask 077; xauth -q -f "$1" add ":$2" MIT-MAGIC-COOKIE-1 "$3"' sh     "$H/.zestscreens/x11-local.auth" "$X11_LOCAL_DISPLAY" "$x11_cookie"
  systemd-run --quiet --unit=zestscreens-x11-local --uid="$TEST_USER" --gid="$TEST_USER"     -p TemporaryFileSystem=/tmp/.X11-unix:mode=1777     -p StandardOutput=append:$L/x11-local.out -p StandardError=append:$L/x11-local.out     /usr/bin/Xvnc ":$X11_LOCAL_DISPLAY" -geometry 1280x800 -depth 24 -desktop zestscreens-x11-local     -rfbport -1 -rfbunixpath "$X11_LOCAL_SOCK" -rfbunixmode 0600     -SecurityTypes VncAuth -PasswordFile "$H/.zestscreens/vncpasswd" -AlwaysShared     -auth "$H/.zestscreens/x11-local.auth" -listen tcp
  for _ in $(seq 1 50); do [ -S "$X11_LOCAL_SOCK" ] && break; sleep 0.1; done
  systemd-run --quiet --unit=zestscreens-x11-local-apps --uid="$TEST_USER" --gid="$TEST_USER"     -E DISPLAY=":$X11_LOCAL_DISPLAY" -E XAUTHORITY="$H/.zestscreens/x11-local.auth" -E HOME="$H"     -p StandardOutput=append:$L/x11-local-apps.out -p StandardError=append:$L/x11-local-apps.out     /usr/bin/xclock -geometry 200x200+1060+20 -update 1
fi

# RDP with H.264 (start x264): xrdp 0.10.2 from its release tarball, built once with x264 (0.10.1,
# Ubuntu's version, has no H.264 encoder at all: its tarball has only the #ifdefs). Everything goes
# under $X264_PREFIX, its configuration too (--sysconfdir: with the default, `make install` writes
# over the package's files in /etc/xrdp, /etc/default, /etc/init.d and /etc/pam.d). Its own sesman
# (displays from :60, its own socket folder) with Ubuntu's xorgxrdp 0.10.2, which has the H.264
# capture.
build_xrdp_x264() {
  if [ -x "$X264_PREFIX/sbin/xrdp" ] && [ -f "$X264_PREFIX/etc/xrdp/gfx.toml" ] \
    && "$X264_PREFIX/sbin/xrdp" --version 2>&1 | grep -qx "xrdp $X264_VERSION" \
    && ldd "$X264_PREFIX/sbin/xrdp" | grep -q 'libx264\.so' \
    && grep -q "$X264_SOCKETS" "$X264_PREFIX/sbin/xrdp-sesman" \
    && grep -qx "$X264_XORGXRDP_VERSION" "$X264_PREFIX/xorg/VERSION" 2> /dev/null; then
    return 0
  fi
  local missing=() p started
  started=$(date +%s)
  for p in "${X264_BUILD_DEPS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2> /dev/null | grep -q 'ok installed' || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    dpkg-query -W -f='${Package}\n' | sort > "$D/packages-before"
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}" > /dev/null
    dpkg-query -W -f='${Package}\n' | sort | comm -13 "$D/packages-before" - >> "$D/installed-packages"
    rm -f "$D/packages-before"
  fi
  mkdir -p "$X264_SRC"
  local tarball="$X264_SRC/xrdp-$X264_VERSION.tar.gz"
  [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
    "https://github.com/neutrinolabs/xrdp/releases/download/v$X264_VERSION/xrdp-$X264_VERSION.tar.gz"
  echo "$X264_SHA256  $tarball" | sha256sum -c --quiet - || { echo "xrdp tarball checksum mismatch" >&2; return 1; }
  local xtarball="$X264_SRC/xorgxrdp-$X264_XORGXRDP_VERSION.tar.gz"
  # GitHub's download host answered 504 for this one on 8 Nov 2026; `gh release download
  # v$X264_XORGXRDP_VERSION -R neutrinolabs/xorgxrdp` (through the API) fetched it, copied into $X264_SRC.
  [ -f "$xtarball" ] || curl -fsSL --retry 3 --retry-all-errors -o "$xtarball" \
    "https://github.com/neutrinolabs/xorgxrdp/releases/download/v$X264_XORGXRDP_VERSION/xorgxrdp-$X264_XORGXRDP_VERSION.tar.gz"
  echo "$X264_XORGXRDP_SHA256  $xtarball" | sha256sum -c --quiet - || { echo "xorgxrdp tarball checksum mismatch" >&2; return 1; }
  rm -rf "$X264_SRC/xrdp-$X264_VERSION"
  tar xzf "$tarball" -C "$X264_SRC"
  (
    cd "$X264_SRC/xrdp-$X264_VERSION"
    # --enable-strict-locations, or configure sets sysconfdir to /etc whatever is passed.
    ./configure --prefix="$X264_PREFIX" --enable-strict-locations --sysconfdir="$X264_PREFIX/etc" \
      --localstatedir="$X264_PREFIX/var" --with-pamconfdir="$X264_PREFIX/etc/pam.d" \
      --enable-x264 --enable-rfxcodec --enable-jpeg --enable-pam --enable-pam-config=debian \
      --with-socketdir="$X264_SOCKETS" > "$L/x264-configure.log" 2>&1
    grep -q "sysconfdir *$X264_PREFIX/etc" "$L/x264-configure.log"
    make -j"$(nproc)" > "$L/x264-make.log" 2>&1
    # Installed into a staging folder first: only the prefix may be in it.
    rm -rf "$X264_SRC/stage"
    make install DESTDIR="$X264_SRC/stage" > "$L/x264-install.log" 2>&1
  ) || { echo "the xrdp x264 build failed: see $L/x264-*.log" >&2; return 1; }
  local outside
  outside="$(cd "$X264_SRC/stage" && find . -mindepth 1 -maxdepth 3 | grep -v -x -e . -e ./opt -e ./opt/zestscreens \
    -e "./opt/zestscreens/xrdp-x264" -e "\./opt/zestscreens/xrdp-x264/.*" || true)"
  if [ -n "$outside" ]; then
    echo "the xrdp x264 install would write outside $X264_PREFIX: $outside" >&2
    return 1
  fi
  rm -rf "$X264_PREFIX"
  cp -a "$X264_SRC/stage$X264_PREFIX" "$X264_PREFIX"
  rm -rf "$X264_SRC/stage"
  # xorgxrdp against the xrdp just built (its headers through xrdp.pc), staged, then its X modules
  # and xorg.conf copied under the prefix (the X server gets -modulepath and -config for them).
  rm -rf "$X264_SRC/xorgxrdp-$X264_XORGXRDP_VERSION" "$X264_SRC/stage-xorgxrdp"
  tar xzf "$xtarball" -C "$X264_SRC"
  (
    cd "$X264_SRC/xorgxrdp-$X264_XORGXRDP_VERSION"
    PKG_CONFIG_PATH="$X264_PREFIX/lib/pkgconfig" ./configure > "$L/x264-xorgxrdp-configure.log" 2>&1
    make -j"$(nproc)" > "$L/x264-xorgxrdp-make.log" 2>&1
    make install DESTDIR="$X264_SRC/stage-xorgxrdp" > "$L/x264-xorgxrdp-install.log" 2>&1
  ) || { echo "the xorgxrdp build failed: see $L/x264-xorgxrdp-*.log" >&2; return 1; }
  local xs="$X264_SRC/stage-xorgxrdp" m="$X264_PREFIX/xorg/modules"
  install -d "$m/drivers" "$m/input" "$X264_PREFIX/etc/X11/xrdp"
  install -m 644 "$xs/usr/lib/xorg/modules/libxorgxrdp.so" "$m/"
  install -m 644 "$xs/usr/lib/xorg/modules/drivers/xrdpdev_drv.so" "$m/drivers/"
  install -m 644 "$xs/usr/lib/xorg/modules/input/xrdpkeyb_drv.so" "$xs/usr/lib/xorg/modules/input/xrdpmouse_drv.so" "$m/input/"
  install -m 644 "$xs/etc/X11/xrdp/xorg.conf" "$X264_PREFIX/etc/X11/xrdp/xorg.conf"
  echo "$X264_XORGXRDP_VERSION" > "$X264_PREFIX/xorg/VERSION"
  rm -rf "$xs"
  echo "xrdp $X264_VERSION with x264 built in $(( $(date +%s) - started )) s"
}
if [ "${2:-}" = x264 ]; then
  build_xrdp_x264
  XC=$X264_PREFIX/etc/xrdp
  # The package's copies were made from /etc/xrdp above; these are the build's own.
  sed -i \
    -e "0,/^port=.*/s||port=tcp://:$X264_PORT|" \
    -e "s|^security_layer=.*|security_layer=tls|" \
    -e "s|^certificate=.*|certificate=$D/rdp-cert.pem|" \
    -e "s|^key_file=.*|key_file=$D/rdp-key.pem|" \
    "$XC/xrdp.ini"
  sed -i -e "s|^X11DisplayOffset=.*|X11DisplayOffset=$X264_OFFSET|" "$XC/sesman.ini"
  # The X server with our xorgxrdp: its xorg.conf and modules first (Xorg runs as the user, not
  # elevated, so an absolute -config and -modulepath are taken).
  if grep -q '^param=xrdp/xorg.conf$' "$XC/sesman.ini"; then
    sed -i -e "s|^param=xrdp/xorg.conf\$|param=$X264_PREFIX/etc/X11/xrdp/xorg.conf\nparam=-modulepath\nparam=$X264_PREFIX/xorg/modules,/usr/lib/xorg/modules|" \
      "$XC/sesman.ini"
  fi
  install -d -m 755 "$X264_SOCKETS" "$X264_PREFIX/var/log" "$X264_PREFIX/var/run"
  systemd-run --quiet --unit=zestscreens-sesman-x264 \
    -p TemporaryFileSystem=/tmp/.X11-unix:mode=1777 \
    -p StandardOutput=append:$L/sesman-x264.out -p StandardError=append:$L/sesman-x264.out \
    "$X264_PREFIX/sbin/xrdp-sesman" --nodaemon --config "$XC/sesman.ini"
  systemd-run --quiet --unit=zestscreens-xrdp-x264 \
    -p StandardOutput=append:$L/xrdp-x264.out -p StandardError=append:$L/xrdp-x264.out \
    "$X264_PREFIX/sbin/xrdp" --nodaemon --config "$XC/xrdp.ini"
fi

# SSH: an sshd of its own for the test account, with forwarding and X11 forwarding on.
[ -f "$D/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$D/ssh_host_ed25519_key"
cat > "$D/sshd_config" << EOF
Port $SSH_PORT
ListenAddress 0.0.0.0
HostKey $D/ssh_host_ed25519_key
PidFile $R/sshd.pid
UsePAM yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $TEST_USER
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
X11Forwarding yes
X11DisplayOffset $X11_OFFSET
X11UseLocalhost yes
XAuthLocation /usr/bin/xauth
Subsystem sftp internal-sftp
EOF
mkdir -p /run/sshd
/usr/sbin/sshd -t -f "$D/sshd_config"
systemd-run --quiet --unit=zestscreens-sshd \
  -p StandardOutput=append:$L/sshd.out -p StandardError=append:$L/sshd.out \
  /usr/sbin/sshd -D -e -f "$D/sshd_config"

# Each answers.
ok=1
for _ in $(seq 1 50); do
  [ "$(listening "$RDP_PORT")" = yes ] && [ "$(listening "$VNC_PORT")" = yes ] \
    && [ "$(listening "$SSH_PORT")" = yes ] && [ -S "$VNC_SOCK" ] && break
  sleep 0.2
done
[ "$(listening "$RDP_PORT")" = yes ] || { echo "RDP is not listening: see $L/xrdp.out" >&2; ok=0; }
[ "$(listening "$VNC_PORT")" = yes ] || { echo "VNC is not listening: see $L/xvnc.out" >&2; ok=0; }
[ -S "$VNC_SOCK" ] || { echo "no VNC socket at $VNC_SOCK: see $L/xvnc.out" >&2; ok=0; }
[ "$(listening "$SSH_PORT")" = yes ] || { echo "sshd is not listening: see $L/sshd.out" >&2; ok=0; }
if [ "${2:-}" = vencrypt ]; then
  for _ in $(seq 1 25); do [ "$(listening "$VNC_TLS_PORT")" = yes ] && break; sleep 0.2; done
  [ "$(listening "$VNC_TLS_PORT")" = yes ] || { echo "VeNCrypt VNC is not listening: see $L/xvnc-tls.out" >&2; ok=0; }
fi
if [ "${2:-}" = x11 ]; then
  for _ in $(seq 1 25); do [ "$(listening "$((6000 + X11_LOCAL_DISPLAY))")" = yes ] && break; sleep 0.2; done
  [ "$(listening "$((6000 + X11_LOCAL_DISPLAY))")" = yes ] || { echo "the X server stand-in is not listening: see $L/x11-local.out" >&2; ok=0; }
  [ -S "$X11_LOCAL_SOCK" ] || { echo "no VNC socket at $X11_LOCAL_SOCK: see $L/x11-local.out" >&2; ok=0; }
fi
if [ "${2:-}" = x264 ]; then
  for _ in $(seq 1 25); do [ "$(listening "$X264_PORT")" = yes ] && break; sleep 0.2; done
  [ "$(listening "$X264_PORT")" = yes ] || { echo "RDP (x264) is not listening: see $L/xrdp-x264.out" >&2; ok=0; }
fi
# The VNC server says hello (RFB 003.008) on both ways in.
banner_tcp="$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$VNC_PORT; head -c 12 <&3" 2> /dev/null || true)"
echo "VNC tcp says: ${banner_tcp:-nothing}"
[ "${banner_tcp:0:3}" = RFB ] || ok=0
if command -v python3 > /dev/null; then
  banner_unix="$(timeout 3 python3 -c "import socket,sys;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);print(s.recv(12).decode().strip())" "$VNC_SOCK" 2> /dev/null || true)"
  echo "VNC unix says: ${banner_unix:-nothing}"
  [ "${banner_unix:0:3}" = RFB ] || ok=0
fi
# An X program can draw on the VNC display.
if runuser -u "$TEST_USER" -- env DISPLAY=":$VNC_DISPLAY" xdpyinfo > /dev/null 2>&1; then
  echo "X display :$VNC_DISPLAY answers xdpyinfo"
else
  echo "X display :$VNC_DISPLAY does not answer xdpyinfo" >&2
  ok=0
fi
status
echo "password for $TEST_USER: kept in $ENV_FILE (root only)"
[ "$ok" = 1 ] || exit 1
