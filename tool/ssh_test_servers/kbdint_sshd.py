"""A scripted SSH server for testing keyboard-interactive (2FA) sign-in.

Run it, then the Dart test test/services/ssh_keyboard_interactive_real_test.dart
talks to it (the test skips itself when this is not running):

    python tool/ssh_test_servers/kbdint_sshd.py

Needs paramiko (pip install paramiko). Listens on 127.0.0.1:2298 unless
ZESTSSH_TEST_KBDINT_PORT says otherwise, and writes one JSON line per answer
it receives to ZESTSSH_TEST_KBDINT_LOG (default: kbdint-sshd.jsonl in the
system temp folder), so a test can check exactly what reached the server.

The username picks the scenario. The right password is "pw", the right code
"123456":

  pwotp   round 1 "Password:", round 2 "Verification code:"
  both    one round asking "Password:" and "Verification code:" together
  keyotp  any public key is a partial success, then "Verification code:"
  push    a message with nothing to answer, then 20 s of silence (a push
          approval), then success
  retry   "Password:" until it is right, at most three times
  echo    an echoed "Passcode or option (1-2):" that must be answered "1"

Test only: it accepts anything else about the connection and never opens a
real shell.
"""
import json
import os
import socket
import sys
import tempfile
import threading
import time

import paramiko

PORT = int(os.environ.get("ZESTSSH_TEST_KBDINT_PORT", "2298"))
LOG = os.environ.get("ZESTSSH_TEST_KBDINT_LOG",
                     os.path.join(tempfile.gettempdir(), "kbdint-sshd.jsonl"))
HOST_KEY = paramiko.ECDSAKey.generate()
_log_lock = threading.Lock()


def log(entry):
    with _log_lock:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")


def query(name="", instructions="", *prompts):
    return paramiko.InteractiveQuery(name, instructions, *prompts)


class Scenario(paramiko.ServerInterface):
    def __init__(self):
        self.user = None
        self.round = 0
        self.key_ok = False

    # Methods offered to the client.
    def get_allowed_auths(self, username):
        if username == "keyotp" and not self.key_ok:
            return "publickey"
        return "keyboard-interactive"

    def check_auth_password(self, username, password):
        log({"user": username, "method": "password"})
        return paramiko.AUTH_FAILED

    def check_auth_none(self, username):
        return paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        if username == "keyotp":
            self.key_ok = True
            return paramiko.AUTH_PARTIALLY_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_auth_interactive(self, username, submethods):
        self.user = username
        self.round = 0
        if username in ("pwotp", "retry"):
            return query("", "", ("Password: ", False))
        if username == "both":
            return query("", "", ("Password: ", False),
                         ("Verification code: ", False))
        if username == "keyotp":
            if not self.key_ok:
                return paramiko.AUTH_FAILED
            return query("", "", ("Verification code: ", False))
        if username == "push":
            return query("Duo two-factor",
                         "Pushed a login request to your phone.")
        if username == "echo":
            return query("", "Choose 1 for a push or 2 for a call.",
                         ("Passcode or option (1-2): ", True))
        return paramiko.AUTH_FAILED

    def check_auth_interactive_response(self, responses):
        user, rnd = self.user, self.round
        self.round += 1
        log({"user": user, "round": rnd, "responses": list(responses)})
        ok, fail = paramiko.AUTH_SUCCESSFUL, paramiko.AUTH_FAILED
        if user == "pwotp":
            if rnd == 0:
                if list(responses) == ["pw"]:
                    return query("", "", ("Verification code: ", False))
                return fail
            return ok if list(responses) == ["123456"] else fail
        if user == "both":
            return ok if list(responses) == ["pw", "123456"] else fail
        if user == "keyotp":
            return ok if list(responses) == ["123456"] else fail
        if user == "push":
            if list(responses):
                return fail
            time.sleep(20)
            return ok
        if user == "retry":
            if list(responses) == ["pw"]:
                return ok
            if rnd < 2:
                return query("", "Wrong password, try again.",
                             ("Password: ", False))
            return fail
        if user == "echo":
            return ok if list(responses) == ["1"] else fail
        return fail

    def check_channel_request(self, kind, chanid):
        if kind == "session":
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


def serve(conn):
    transport = paramiko.Transport(conn)
    transport.add_server_key(HOST_KEY)
    try:
        transport.start_server(server=Scenario())
        channel = transport.accept(60)
        if channel is not None:
            channel.close()
        while transport.is_active():
            time.sleep(0.2)
    except Exception as e:  # noqa: BLE001 - a test server logs and moves on
        log({"error": repr(e)})
    finally:
        transport.close()


def main():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", PORT))
    listener.listen(16)
    print("kbdint test sshd on 127.0.0.1:%d, log %s" % (PORT, LOG), flush=True)
    while True:
        conn, _ = listener.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
