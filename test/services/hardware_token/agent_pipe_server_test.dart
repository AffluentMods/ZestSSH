import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/hardware_token/os_ssh_agent.dart';
import 'package:zestssh/services/hardware_token/windows_pipe_ffi.dart';

/// Who may serve the SSH agent's pipe on Windows (found in a
/// security review): any account of a computer may create
/// `\\.\pipe\openssh-ssh-agent` while no agent holds it, and the app gave a
/// private key to whatever answered. Decided by who Windows says serves it,
/// with stand-in identities here (a computer with one account cannot serve a
/// pipe as another; windows_agent_pipe_test.dart reads the real ones).
void main() {
  const me = 'S-1-5-21-1111111111-2222222222-3333333333-1001';
  const someoneElse = 'S-1-5-21-1111111111-2222222222-3333333333-1002';
  const localService = 'S-1-5-19';
  const administrators = 'S-1-5-32-544';

  AgentPipeServer verdict({String? own = me, String? process, String? owner}) =>
      agentPipeServerVerdict(PipeServerIdentity(ownUser: own, serverProcessUser: process, pipeOwner: owner));

  group('the serving process, where Windows names its user', () {
    test("LocalSystem's (the OpenSSH Authentication Agent) is used", () {
      expect(kLocalSystemSid, 'S-1-5-18');
      expect(verdict(process: kLocalSystemSid), AgentPipeServer.trusted);
      expect(verdict(process: kLocalSystemSid, owner: kLocalSystemSid), AgentPipeServer.trusted);
    });

    test("the person's own (1Password, Bitwarden) is used", () {
      expect(verdict(process: me), AgentPipeServer.trusted);
      expect(verdict(process: me, owner: me), AgentPipeServer.trusted);
    });

    test("another account's is refused, whoever owns the pipe", () {
      expect(verdict(process: someoneElse), AgentPipeServer.otherAccount);
      expect(verdict(process: localService), AgentPipeServer.otherAccount, reason: 'a service account');
      expect(verdict(process: administrators), AgentPipeServer.otherAccount);
      expect(verdict(process: someoneElse, owner: kLocalSystemSid), AgentPipeServer.otherAccount,
          reason: 'the process that answers decides, where it is known');
      expect(verdict(process: someoneElse, owner: me), AgentPipeServer.otherAccount);
    });
  });

  group("the pipe's owner, where the process cannot be asked", () {
    test('SYSTEM, as the OpenSSH agent owns its pipe, is used', () {
      expect(verdict(owner: kLocalSystemSid), AgentPipeServer.trusted);
    });

    test("another account's is refused", () {
      expect(verdict(owner: someoneElse), AgentPipeServer.otherAccount);
      expect(verdict(owner: localService), AgentPipeServer.otherAccount);
    });

    test('Administrators, which owns what an elevated program makes and is not how the agent makes its pipe, is refused',
        () {
      expect(verdict(owner: administrators), AgentPipeServer.otherAccount);
    });

    test("the person's own is not enough: their programs can be asked, so one that cannot is another's", () {
      expect(verdict(owner: me), AgentPipeServer.unconfirmed);
    });
  });

  test('what Windows would not say is refused', () {
    expect(verdict(), AgentPipeServer.unconfirmed, reason: 'neither the process nor the owner');
    expect(verdict(own: null, process: kLocalSystemSid), AgentPipeServer.unconfirmed, reason: 'not even who we are');
    expect(verdict(own: '', process: ''), AgentPipeServer.unconfirmed);
    expect(verdict(own: null, owner: kLocalSystemSid), AgentPipeServer.unconfirmed);
  });

  test('a refusal says which, names no account, and is the agent failure callers already handle', () {
    final other = AgentPipeNotYours(AgentPipeServer.otherAccount);
    final unknown = AgentPipeNotYours(AgentPipeServer.unconfirmed);
    expect(other, isA<OsAgentException>());
    expect(other.typeName, 'AgentPipeNotYours');
    expect(other.message, contains('another account'));
    expect(unknown.message, contains('did not say'));
    for (final e in [other, unknown]) {
      expect(e.message, contains('Nothing was sent'));
      expect(e.message, isNot(contains('S-1-')));
    }
  });
}
