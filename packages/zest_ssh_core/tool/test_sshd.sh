#!/usr/bin/env bash
# Starts the seven local OpenSSH servers the integration tests of this package
# log in to (test/kex/pq_kex_interop_test.dart, test/kex/rekey_interop_test.dart,
# test/src/ssh_waiters_test.dart, test/src/ssh_agent_refused_test.dart,
# test/src/ssh_keepalive_test.dart, test/src/sftp/sftp_real_server_test.dart,
# test/src/ssh_server_text_test.dart, test/src/ssh_exit_status_test.dart,
# test/src/ssh_forward_local_test.dart).
#
# They run as the ordinary user, on the loopback address only, each with a
# host key of its own, and take six client keys made here: one that may do
# what the account may, one that is given no terminal and no agent
# forwarding, one that is given everything but agent forwarding, one that
# runs one command whatever is asked for, which prints a word and ends at
# once, one that may open no connection on to another host, and an RSA key.
# Password login is off.
# The first also trusts a certificate authority made here (user_ca), for
# tests that log in with a certificate. Nothing system-wide is touched,
# enabled or installed. For Linux or WSL with OpenSSH 9.9 or newer (older
# servers do not have the post-quantum exchanges).
#
#   tool/test_sshd.sh          start them, or start them again
#   tool/test_sshd.sh add      start those that are not running, and leave
#                              the others as they are (tests may be using them)
#   tool/test_sshd.sh stop     stop them
#
# ZESTSSH_TEST_SSHD_DIR         where the keys, configs and logs go
#                               (default ~/zestssh-sshd-test)
# ZESTSSH_TEST_SSHD_PORT        the server the tests log in to (default 2299)
# ZESTSSH_TEST_REKEY_SSHD_PORT  a second one with "RekeyLimit 1M", which asks
#                               for new keys every megabyte, and with SFTP
#                               (default 2297). The first has no SFTP, for
#                               the tests of a server that has none.
# ZESTSSH_TEST_BANNER_SSHD_PORT a third one, whose notice before sign-in is
#                               in an older encoding, with a byte in it that
#                               is no UTF-8 (default 2295)
# ZESTSSH_TEST_ONETRY_SSHD_PORT a fourth one with "MaxAuthTries 1", which
#                               ends the connection, saying why, at the
#                               first key it does not know (default 2293)
# ZESTSSH_TEST_SHA512_SSHD_PORT a fifth one, which takes from an RSA key
#                               only signatures with SHA-512, as a server
#                               that is set up strictly does (default 2291)
# ZESTSSH_TEST_SHA1_SSHD_PORT   a sixth one, which takes from an RSA key
#                               only the first kind of signature, with
#                               SHA-1, as a server older than OpenSSH 7.2
#                               does (default 2285)
# ZESTSSH_TEST_GCM_SSHD_PORT    a seventh one, whose only ciphers are the
#                               two AES-GCM ones, as a server that is set
#                               up strictly may have it (default 2289)
#
# The tests find the servers by the same variables, and skip themselves when
# the servers are not there.
set -eu

dir="${ZESTSSH_TEST_SSHD_DIR:-$HOME/zestssh-sshd-test}"
port="${ZESTSSH_TEST_SSHD_PORT:-2299}"
rekey_port="${ZESTSSH_TEST_REKEY_SSHD_PORT:-2297}"
banner_port="${ZESTSSH_TEST_BANNER_SSHD_PORT:-2295}"
onetry_port="${ZESTSSH_TEST_ONETRY_SSHD_PORT:-2293}"
sha512_port="${ZESTSSH_TEST_SHA512_SSHD_PORT:-2291}"
sha1_port="${ZESTSSH_TEST_SHA1_SSHD_PORT:-2285}"
gcm_port="${ZESTSSH_TEST_GCM_SSHD_PORT:-2289}"
mode="${1:-}"
sshd="$(command -v sshd || true)"
[ -n "$sshd" ] || sshd=/usr/sbin/sshd
[ -x "$sshd" ] || { echo "no sshd here: install the OpenSSH server (it is not enabled by this script)"; exit 1; }

running() {
  # $1: the folder of one server
  [ -f "$1/sshd.pid" ] && kill -0 "$(cat "$1/sshd.pid")" 2>/dev/null
}

stop_one() {
  # $1: the folder of one server
  if running "$1"; then
    kill "$(cat "$1/sshd.pid")" || true
    sleep 0.5
  fi
}

start_one() {
  # $1: its folder, $2: its port, $3 and $4: lines of its own for the config
  if [ "$mode" = "add" ] && running "$1"; then
    echo "listening on 127.0.0.1:$2 already (pid $(cat "$1/sshd.pid")): left as it is"
    return 0
  fi
  mkdir -p "$1"
  chmod 700 "$1"
  [ -f "$1/host_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -f "$1/host_ed25519"
  cat > "$1/sshd_config" <<CFG
Port $2
ListenAddress 127.0.0.1
HostKey $1/host_ed25519
AuthorizedKeysFile $dir/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PidFile $1/sshd.pid
StrictModes no
LogLevel VERBOSE
# The exchanges a current server no longer offers by itself, for the tests of
# the older ones this library still speaks.
KexAlgorithms +diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha256,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521
$3
${4:-}
CFG
  # Tests log in many times in a row, and some are refused on purpose.
  if "$sshd" -t -f "$1/sshd_config" -o PerSourcePenalties=no 2>/dev/null; then
    echo "PerSourcePenalties no" >> "$1/sshd_config"
  fi
  "$sshd" -t -f "$1/sshd_config"
  : > "$1/sshd.log"
  "$sshd" -f "$1/sshd_config" -E "$1/sshd.log"
  sleep 1
  if [ -f "$1/sshd.pid" ] && kill -0 "$(cat "$1/sshd.pid")" 2>/dev/null; then
    echo "listening on 127.0.0.1:$2 (pid $(cat "$1/sshd.pid"), log $1/sshd.log)"
  else
    echo "the server for port $2 did not start, see $1/sshd.log"
    exit 1
  fi
}

if [ "$mode" != "add" ]; then
  stop_one "$dir"
  stop_one "$dir/rekey"
  stop_one "$dir/banner"
  stop_one "$dir/onetry"
  stop_one "$dir/sha512"
  stop_one "$dir/sha1"
  stop_one "$dir/gcm"
fi
if [ "$mode" = "stop" ]; then
  echo "stopped"
  exit 0
fi

mkdir -p "$dir"
chmod 700 "$dir"
[ -f "$dir/client_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "zest_ssh_core tests" -f "$dir/client_ed25519"
if [ ! -f "$dir/authorized_keys" ] || ! grep -qF "$(cut -d' ' -f2 "$dir/client_ed25519.pub")" "$dir/authorized_keys"; then
  cat "$dir/client_ed25519.pub" >> "$dir/authorized_keys"
fi
# A second client key, which the server gives no terminal and no agent
# forwarding: for the tests of what the client does when a server refuses
# those (test/src/ssh_waiters_test.dart).
[ -f "$dir/client_restricted_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "zest_ssh_core tests, restricted" -f "$dir/client_restricted_ed25519"
if ! grep -qF "$(cut -d' ' -f2 "$dir/client_restricted_ed25519.pub")" "$dir/authorized_keys"; then
  echo "no-pty,no-agent-forwarding $(cat "$dir/client_restricted_ed25519.pub")" >> "$dir/authorized_keys"
fi
# And a third, which the server gives everything but agent forwarding: for
# the tests of a session that goes on without it.
[ -f "$dir/client_noagent_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "zest_ssh_core tests, no agent forwarding" -f "$dir/client_noagent_ed25519"
if ! grep -qF "$(cut -d' ' -f2 "$dir/client_noagent_ed25519.pub")" "$dir/authorized_keys"; then
  echo "no-agent-forwarding $(cat "$dir/client_noagent_ed25519.pub")" >> "$dir/authorized_keys"
fi
# And a fourth, which runs one command whatever is asked for, a shell too:
# it prints a word and ends at once, with a status of its own. For the tests
# of a program that has ended by the time the server's yes to it is read
# (test/src/ssh_exit_status_test.dart).
[ -f "$dir/client_forced_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "zest_ssh_core tests, one command" -f "$dir/client_forced_ed25519"
if ! grep -qF "$(cut -d' ' -f2 "$dir/client_forced_ed25519.pub")" "$dir/authorized_keys"; then
  echo "command=\"echo forced; exit 7\" $(cat "$dir/client_forced_ed25519.pub")" >> "$dir/authorized_keys"
fi
# And a fifth, which may open no connection on to another host: for the
# tests of a server that will not pass a connection on, as a jump host is
# asked to (test/src/ssh_forward_local_test.dart).
[ -f "$dir/client_noforward_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "zest_ssh_core tests, no forwarding" -f "$dir/client_noforward_ed25519"
if ! grep -qF "$(cut -d' ' -f2 "$dir/client_noforward_ed25519.pub")" "$dir/authorized_keys"; then
  echo "no-port-forwarding $(cat "$dir/client_noforward_ed25519.pub")" >> "$dir/authorized_keys"
fi
# And an RSA key, which signs in three ways (RFC 8332), each of which a
# server takes or refuses: for the tests of which way a client picks for a
# server (test/src/ssh_rsa_signature_kind_test.dart).
[ -f "$dir/client_bare_rsa" ] || ssh-keygen -q -t rsa -b 3072 -N "" -C "zest_ssh_core tests, RSA" -f "$dir/client_bare_rsa"
if ! grep -qF "$(cut -d' ' -f2 "$dir/client_bare_rsa.pub")" "$dir/authorized_keys"; then
  cat "$dir/client_bare_rsa.pub" >> "$dir/authorized_keys"
fi
chmod 600 "$dir/authorized_keys"
[ -f "$dir/user_ca" ] || ssh-keygen -q -t ed25519 -N "" -C "zest_ssh_core test authority" -f "$dir/user_ca"

start_one "$dir" "$port" "TrustedUserCAKeys $dir/user_ca.pub"
start_one "$dir/rekey" "$rekey_port" "RekeyLimit 1M" "Subsystem sftp internal-sftp"
# The third server's notice: "Zugang nur fuer Befugte." with its u with two
# dots as ISO 8859-1 writes it, the single byte 0xFC (octal 374), which is
# no UTF-8.
mkdir -p "$dir/banner"
printf 'Zugang nur f\374r Befugte.\n' > "$dir/banner/issue"
start_one "$dir/banner" "$banner_port" "Banner $dir/banner/issue"
# The fourth server allows one failed sign-in: a key it does not know is the
# end of the connection, with the server's reason for it.
start_one "$dir/onetry" "$onetry_port" "MaxAuthTries 1"
# The fifth and the sixth server each take one kind of signature from an RSA
# key: the fifth the one with SHA-512, the sixth the first one, with SHA-1
# ("ssh-rsa"). Both also trust the certificate authority, for the same with
# a certificate.
start_one "$dir/sha512" "$sha512_port" "PubkeyAcceptedAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-512-cert-v01@openssh.com" "TrustedUserCAKeys $dir/user_ca.pub"
start_one "$dir/sha1" "$sha1_port" "PubkeyAcceptedAlgorithms ssh-ed25519,ssh-rsa,ssh-rsa-cert-v01@openssh.com" "TrustedUserCAKeys $dir/user_ca.pub"
# The seventh server has the two AES-GCM ciphers and no other: a client that
# does not offer them has nothing in common with it.
start_one "$dir/gcm" "$gcm_port" "Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com"
echo "log in as $(id -un) with the key $dir/client_ed25519"
