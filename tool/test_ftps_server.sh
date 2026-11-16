#!/usr/bin/env bash
# The local FTPS server the app's FTPS integration test logs in to
# (test/native/ftps_integration_test.dart): vsftpd, as the 3.4 spike ran it,
# at its TLS defaults,
# which REQUIRE TLS session reuse on every data connection (require_ssl_reuse
# unset = YES) and a TLS close at the end of an upload (strict_ssl_read_eof):
# the two things a client on dart:io alone cannot do. Two instances, with a
# self-signed certificate made for the run (a made-up name):
#
#   explicit (AUTH TLS)  port 4021, passive ports 41000-41049
#   implicit (TLS first) port 4990, passive ports 41050-41099
#
# Plain FTP is refused by both (force_local_logins_ssl and
# force_local_data_ssl default to YES with ssl_enable).
#
# For WSL (Ubuntu) or Linux, AS ROOT, since vsftpd signs in local accounts
# through PAM: from Windows,
#
#   wsl -u root bash tool/test_ftps_server.sh          start (installs vsftpd)
#   wsl -u root bash tool/test_ftps_server.sh stop     stop, and remove
#                                                      everything it added
#
# then, on Windows, with WSL's own address (`wsl hostname -I`, the first
# one), NOT 127.0.0.1: WSL's localhost relay cuts the end off uploads now and
# then (vsftpd: "DATA connection terminated without SSL shutdown", a 426),
# which is the relay's, not the client's (checked 6 Nov 2026: 0 of 11 runs
# failed on WSL's address, 6 of 12 on 127.0.0.1):
#
#   ZESTSSH_TEST_FTPS_HOST=172.x.y.z flutter test --no-pub \
#     --dart-define=ZEST_ORCHARDS=true test/native/ftps_integration_test.dart
#   (cd packages/zest_native && ZESTSSH_TEST_FTPS_HOST=172.x.y.z \
#     dart test test/ftps_server_test.dart)
#
# The account is zestftps with the password Zest-Ftps-Test-2026 (a test
# account in WSL only; stop deletes it). Each instance runs as a transient
# systemd unit (zestftps-*). No package service is started by the install,
# so nothing ever listens on port 21.
set -euo pipefail
D=/etc/zestftps
L=/var/log/zestftps
USER_NAME=zestftps
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" != 0 ]; then
  echo "Run as root: wsl -u root bash tool/test_ftps_server.sh" >&2
  exit 2
fi

if [ "${1:-}" = stop ]; then
  systemctl stop 'zestftps-*' 2>/dev/null || true
  systemctl reset-failed 'zestftps-*' 2>/dev/null || true
  # vsftpd and ssl-cert only when this script installed them.
  if [ -f "$D/installed-by-zestftps" ]; then
    apt-get purge -y -qq vsftpd ssl-cert > /dev/null || true
  fi
  userdel -r "$USER_NAME" 2>/dev/null || true
  rm -f "/var/mail/$USER_NAME"
  rm -rf "$D" "$L" /usr/sbin/policy-rc.d
  echo "units left: $(systemctl list-units --all 'zestftps-*' --no-legend | wc -l)"
  echo "listening on 4021 or 4990: $(ss -ltn | grep -cE ':(4021|4990) ' || true)"
  exit 0
fi

mkdir -p "$D" "$L" /var/run/vsftpd/empty
if ! command -v vsftpd > /dev/null && [ ! -x /usr/sbin/vsftpd ]; then
  # No package service starts during the install (no plain FTP on port 21, ever).
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
  chmod +x /usr/sbin/policy-rc.d
  trap 'rm -f /usr/sbin/policy-rc.d' EXIT
  apt-get update -qq
  apt-get install -y -qq vsftpd > /dev/null
  touch "$D/installed-by-zestftps"
  rm -f /usr/sbin/policy-rc.d
fi
systemctl stop vsftpd 2>/dev/null || true
systemctl disable vsftpd 2>/dev/null || true
systemctl stop 'zestftps-*' 2>/dev/null || true
systemctl reset-failed 'zestftps-*' 2>/dev/null || true

openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=ftps-test.example.test" \
  -keyout "$D/key.pem" -out "$D/cert.pem" 2>/dev/null
chmod 600 "$D"/*.pem

id "$USER_NAME" > /dev/null 2>&1 || useradd -m -s /bin/bash "$USER_NAME"
echo "$USER_NAME:Zest-Ftps-Test-2026" | chpasswd
chmod 755 "/home/$USER_NAME"

vs() { # name port pasv_min pasv_max implicit
  cat > "$D/vsftpd-$1.conf" <<EOF
listen=YES
listen_ipv6=NO
listen_port=$2
background=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
pasv_enable=YES
pasv_min_port=$3
pasv_max_port=$4
ssl_enable=YES
rsa_cert_file=$D/cert.pem
rsa_private_key_file=$D/key.pem
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
xferlog_enable=YES
vsftpd_log_file=$L/vsftpd-$1.log
log_ftp_protocol=YES
EOF
  [ "$5" = yes ] && echo "implicit_ssl=YES" >> "$D/vsftpd-$1.conf"
  systemd-run --quiet --unit="zestftps-vsftpd-$1" /usr/sbin/vsftpd "$D/vsftpd-$1.conf"
}
vs explicit 4021 41000 41049 no
vs implicit 4990 41050 41099 yes
sleep 1
ss -ltn | grep -E ':(4021|4990) ' || { echo "vsftpd did not start: see journalctl -u 'zestftps-*'" >&2; exit 1; }
echo "FTPS test server up on $(hostname -I | cut -d" " -f1): explicit 4021, implicit 4990 (user $USER_NAME)"
