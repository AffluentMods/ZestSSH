#!/usr/bin/env bash
# The local OpenSSH servers the app's real-host tests log in to (the tests
# named *_real_host_test.dart, *_real_shell_test.dart and the certificate
# login tests). They are those of the SSH core, started by
# packages/zest_ssh_core/tool/test_sshd.sh: see there for what runs, as whom
# and on which ports, and for the variables that move them. This adds, beside
# the client key made there, an RSA key with a certificate issued by OpenSSH's
# own ssh-keygen under the test authority, which
# test/services/ssh_cert/rsa_cert_login_test.dart logs in with.
#
# And one server of the app's own: one that gives files only, as a host set
# up for SFTP alone does (ForceCommand internal-sftp, in a Match block): its
# account is the same one, signed in to with the same client key, and every
# session starts in a folder of its own ($dir/sftponly/files, with a file
# in it). A shell or a command asked of it is refused as OpenSSH refuses one
# there: "This service allows sftp connections only.", and the status 1.
# test/providers/sftp_only_real_host_test.dart logs in to it, on 127.0.0.1
# at ZESTSSH_TEST_SFTPONLY_SSHD_PORT (default 2287). It runs as the ordinary
# user, like the others, so it has no ChrootDirectory: that needs the server
# to run as root, for an account of its own and a folder root owns. What a
# client sees of it is the same.
#
#   tool/test_sshd.sh            start the servers, or start them again
#   tool/test_sshd.sh add        start those that are not running, and leave
#                                the others as they are (tests may be using them)
#   tool/test_sshd.sh sftp-only  start the server that gives files only where
#                                it is not running, and touch nothing else
#   tool/test_sshd.sh stop       stop them
#
# For Linux or WSL. The tests skip themselves when the servers are not there.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
mode="${1:-}"
dir="${ZESTSSH_TEST_SSHD_DIR:-$HOME/zestssh-sshd-test}"
sftp_only="$dir/sftponly"
sftp_only_port="${ZESTSSH_TEST_SFTPONLY_SSHD_PORT:-2287}"
sshd="$(command -v sshd || true)"
[ -n "$sshd" ] || sshd=/usr/sbin/sshd

sftp_only_running() {
  [ -f "$sftp_only/sshd.pid" ] && kill -0 "$(cat "$sftp_only/sshd.pid")" 2>/dev/null
}

stop_sftp_only() {
  if sftp_only_running; then
    kill "$(cat "$sftp_only/sshd.pid")" || true
    sleep 0.5
  fi
}

start_sftp_only() {
  if sftp_only_running; then
    if [ "$mode" = "add" ] || [ "$mode" = "sftp-only" ]; then
      echo "listening on 127.0.0.1:$sftp_only_port already (pid $(cat "$sftp_only/sshd.pid")): left as it is"
      return 0
    fi
    stop_sftp_only
  fi
  [ -x "$sshd" ] || { echo "no sshd here: install the OpenSSH server (it is not enabled by this script)"; exit 1; }
  [ -f "$dir/authorized_keys" ] || { echo "no client keys in $dir yet: run tool/test_sshd.sh first"; exit 1; }
  mkdir -p "$sftp_only/files/reports"
  chmod 700 "$sftp_only"
  [ -f "$sftp_only/host_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -f "$sftp_only/host_ed25519"
  # What the tests find in the folder a session starts in.
  printf 'hello from a host that gives files only\n' > "$sftp_only/files/hello.txt"
  cat > "$sftp_only/sshd_config" <<CFG
Port $sftp_only_port
ListenAddress 127.0.0.1
HostKey $sftp_only/host_ed25519
AuthorizedKeysFile $dir/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PidFile $sftp_only/sshd.pid
StrictModes no
LogLevel VERBOSE
Subsystem sftp internal-sftp
CFG
  # Tests log in many times in a row. (Before the Match block: what stands
  # after it is the block's.)
  if "$sshd" -t -f "$sftp_only/sshd_config" -o PerSourcePenalties=no 2>/dev/null; then
    echo "PerSourcePenalties no" >> "$sftp_only/sshd_config"
  fi
  cat >> "$sftp_only/sshd_config" <<CFG
# Files only, as a host set up for SFTP alone has it (with a ChrootDirectory
# where its server runs as root): a shell, a command or a terminal asked for
# is refused, and nothing is forwarded.
Match User $(id -un)
  ForceCommand internal-sftp -d $sftp_only/files
  AllowTcpForwarding no
  X11Forwarding no
  AllowAgentForwarding no
CFG
  "$sshd" -t -f "$sftp_only/sshd_config"
  : > "$sftp_only/sshd.log"
  "$sshd" -f "$sftp_only/sshd_config" -E "$sftp_only/sshd.log"
  sleep 1
  if sftp_only_running; then
    echo "listening on 127.0.0.1:$sftp_only_port, files only (pid $(cat "$sftp_only/sshd.pid"), log $sftp_only/sshd.log)"
  else
    echo "the server for port $sftp_only_port did not start, see $sftp_only/sshd.log"
    exit 1
  fi
}

if [ "$mode" = "sftp-only" ]; then
  start_sftp_only
  exit 0
fi

bash "$here/../packages/zest_ssh_core/tool/test_sshd.sh" "$@"
if [ "$mode" = "stop" ]; then
  stop_sftp_only
  exit 0
fi

[ -f "$dir/client_rsa" ] || ssh-keygen -q -t rsa -b 3072 -N "" -C "zestssh tests" -f "$dir/client_rsa"
# For a year, so that servers left standing do not start refusing it.
ssh-keygen -q -s "$dir/user_ca" -I rsa-openssh-issued -n "$(id -un)" -V -5m:+52w "$dir/client_rsa.pub"
echo "an RSA key with a certificate from ssh-keygen: $dir/client_rsa"
start_sftp_only
