import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart' show SecretBoxAuthenticationError, SecretBoxPaddingError;
import 'package:drift/drift.dart' show CouldNotRollBackException, DriftWrappedException, InvalidDataException;
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException, FirebaseAuthMultiFactorException;
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http show ClientException;
import 'package:pointycastle/api.dart' show InvalidCipherTextException;
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show AuthorizationErrorCode, SignInWithAppleAuthorizationException, SignInWithAppleException;
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:xml/xml.dart' show XmlParserException;
import 'package:zest_ssh_core/zest_ssh_core.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show OrchardServerException, StaleCrateKey;
import 'package:zestssh/features/password_managers/password_manager_requests.dart'
    show PasswordRefMissing, PasswordRefNotAllowed;
import 'package:zestssh/features/teams/account_key_service.dart' show AccountKeysConflict;
import 'package:zestssh/services/hardware_token/os_agent_key_pair.dart' show AgentSignInAborted;
import 'package:zestssh/services/ssh_auth_prompts.dart' show SignInTimedOut;
import 'package:zestssh/services/ssh_service.dart' show HostKeyNotAccepted, HostKeyRefusal;
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/type_name.dart';

/// What kind of thing an error is, as a line says it that may not carry the
/// error's own words (3.0; the SSH core's audit, the app's half of what it
/// found of names).
///
/// Such a line asked the program for the name of the error's type
/// (`runtimeType`). A build made for release has its names obfuscated and
/// has another name for nearly every type, so the line said "(aB)" in every
/// released app. Now the name is spelled out: here for what the language
/// and the packages throw, and by the error itself where it is one of the
/// app's or of the SSH core.
void main() {
  /// Each with the name it is to be said by.
  void named(List<(Object, String)> things) {
    for (final (thing, name) in things) {
      expect(errorKind(thing), name, reason: '$thing');
    }
  }

  test('what a network, a file and a program throw, a kind made from another by its own name', () {
    named([
      (const HandshakeException('no'), 'HandshakeException'),
      (const CertificateException('no'), 'CertificateException'),
      (const TlsException('no'), 'TlsException'),
      (const SocketException('Connection refused'), 'SocketException'),
      (const RedirectException('too many', []), 'RedirectException'),
      (const HttpException('no'), 'HttpException'),
      (const WebSocketException('no'), 'WebSocketException'),
      (const PathAccessException('a.txt', OSError('denied', 5)), 'PathAccessException'),
      (const PathExistsException('a.txt', OSError('there', 17)), 'PathExistsException'),
      (const PathNotFoundException('a.txt', OSError('gone', 2)), 'PathNotFoundException'),
      (const FileSystemException('no', 'a.txt'), 'FileSystemException'),
      (const ProcessException('op', ['item', 'get']), 'ProcessException'),
      (const SignalException('no'), 'SignalException'),
      (const StdinException('no'), 'StdinException'),
      (const StdoutException('no'), 'StdoutException'),
      (http.ClientException('no'), 'ClientException'),
    ]);
  });

  test('what a plugin, the database and the libraries for encryption and for accounts throw', () {
    named([
      (MissingPluginException('no'), 'MissingPluginException'),
      (PlatformException(code: 'channel-error'), 'PlatformException'),
      (SqliteException(1, 'no'), 'SqliteException'),
      (DriftWrappedException(message: 'no'), 'DriftWrappedException'),
      (CouldNotRollBackException(StateError('a'), StackTrace.empty, StateError('b')), 'CouldNotRollBackException'),
      (InvalidDataException('no'), 'InvalidDataException'),
      (SecretBoxAuthenticationError(), 'SecretBoxAuthenticationError'),
      (SecretBoxPaddingError(), 'SecretBoxPaddingError'),
      (InvalidCipherTextException('no'), 'InvalidCipherTextException'),
      (_SecondStepNeeded(), 'FirebaseAuthMultiFactorException'),
      (FirebaseAuthException(code: 'user-not-found'), 'FirebaseAuthException'),
      (FirebaseException(plugin: 'core'), 'FirebaseException'),
      (
        const SignInWithAppleAuthorizationException(code: AuthorizationErrorCode.canceled, message: 'no'),
        'SignInWithAppleAuthorizationException',
      ),
      (_AppleSaidNo(), 'SignInWithAppleException'),
      // (One of these is a FormatException as well, and is said as what it is first.)
      (XmlParserException('no'), 'XmlException'),
    ]);
  });

  test('the language\'s own, a kind made from another by its own name', () {
    named([
      (TimeoutException('no', const Duration(seconds: 10)), 'TimeoutException'),
      (const FormatException('no'), 'FormatException'),
      (IsolateSpawnException('no'), 'IsolateSpawnException'),
      (RemoteError('no', ''), 'RemoteError'),
      (JsonCyclicError(const <Object>[]), 'JsonCyclicError'),
      (JsonUnsupportedObjectError(Object()), 'JsonUnsupportedObjectError'),
      // (A FlutterError is an AssertionError as well.)
      (FlutterError('no'), 'FlutterError'),
      (AssertionError('no'), 'AssertionError'),
      (TypeError(), 'TypeError'),
      (IndexError.withLength(3, 2), 'IndexError'),
      (RangeError('no'), 'RangeError'),
      (ArgumentError('no'), 'ArgumentError'),
      (NoSuchMethodError.withInvocation(Object(), Invocation.method(#gone, const [])), 'NoSuchMethodError'),
      (UnimplementedError('no'), 'UnimplementedError'),
      (UnsupportedError('no'), 'UnsupportedError'),
      (StateError('no'), 'StateError'),
      (ConcurrentModificationError(), 'ConcurrentModificationError'),
      (const OutOfMemoryError(), 'OutOfMemoryError'),
      (const StackOverflowError(), 'StackOverflowError'),
    ]);
  });

  test('a cast that fails is a TypeError, where the program has a name of its own for it', () {
    // (What the program calls it starts with an underscore here, and is something else in a released build.)
    Object? thrown;
    try {
      final Object list = <int>[];
      list as Map<String, dynamic>;
    } catch (e) {
      thrown = e;
    }
    expect(errorKind(thrown!), 'TypeError');
    expect('${thrown.runtimeType}', isNot('TypeError'));
  });

  test('what the SSH core throws: by the name each spells out, and those that spell none out by theirs', () {
    named([
      (SSHAuthFailError('All authentication methods failed'), 'SSHAuthFailError'),
      (SSHAuthAbortError('Connection closed before authentication'), 'SSHAuthAbortError'),
      (SSHHandshakeError('No matching cipher algorithm'), 'SSHHandshakeError'),
      (SSHKeyDecryptError('Invalid passphrase'), 'SSHKeyDecryptError'),
      (SSHConnectionRefusedException(host: '192.0.2.10', port: 22), 'SSHConnectionRefusedException'),
      (SSHMacMismatchException(), 'SSHMacMismatchException'),
      (SSHInternalError('a state that cannot be'), 'SSHInternalError'),
      (SSHChannelOpenError(2, 'Connection refused'), 'SSHChannelOpenError'),
      (SSHSocketError(const SocketException('Connection reset by peer')), 'SSHSocketError'),
      (const SSHHostKeyVerifyError('no'), 'SSHHostKeyVerifyError'),
      (const SSHHttpException('no'), 'SSHHttpException'),
      (const SSHDecompressionBombException(9, 4), 'SSHDecompressionBombException'),
      (SftpAbortError('no'), 'SftpAbortError'),
      (SftpNotSftpError('Welcome'), 'SftpNotSftpError'),
      (SftpStatusError(2, 'No such file'), 'SftpStatusError'),
      (SftpExtensionUnsupportedError('statvfs@openssh.com'), 'SftpExtensionUnsupportedError'),
      (SftpExtensionVersionMismatchError('statvfs@openssh.com', '3'), 'SftpExtensionVersionMismatchError'),
      (_OtherExtension(), 'SftpExtensionError'),
      (SftpError('no'), 'SftpError'),
    ]);
  });

  test('what the app makes of one of the SSH core\'s errors keeps the name of what it was made from, which is how '
      'it prints itself', () {
    final key = HostKeyNotAccepted(HostKeyRefusal.declinedNew, host: '192.0.2.10', port: 22);
    expect(errorKind(key), 'SSHHostkeyError');
    expect('$key', startsWith('SSHHostkeyError('));
    final agent = AgentSignInAborted.keyNotLoaded();
    expect(errorKind(agent), 'SSHAuthAbortError');
    expect('$agent', startsWith('SSHAuthAbortError('));
  });

  test('what the app throws says its own name, a kind made from another its own too', () {
    named([
      (const OrchardServerException(403, 'forbidden'), 'OrchardServerException'),
      (const StaleCrateKey(4), 'StaleCrateKey'),
      // (It is a TimeoutException as well.)
      (SignInTimedOut(const Duration(seconds: 15)), 'SignInTimedOut'),
      (_Named(), 'a name it spells out'),
      // (Made from one of the app's with nothing spelled out: the name of what it was made from.)
      (_FromNamed(), 'a name it spells out'),
    ]);
    expect(const OrchardServerException(403, 'forbidden'), isA<HasTypeName>());
  });

  test('the three that wrote no text of their own say their name, where they printed what the program calls them', () {
    expect('${const PasswordRefMissing()}', 'PasswordRefMissing');
    expect('${const PasswordRefNotAllowed()}', 'PasswordRefNotAllowed');
    expect('${const AccountKeysConflict(null)}', 'AccountKeysConflict');
    named([
      (const PasswordRefMissing(), 'PasswordRefMissing'),
      (const PasswordRefNotAllowed(), 'PasswordRefNotAllowed'),
      (const AccountKeysConflict(null), 'AccountKeysConflict'),
    ]);
  });

  test('what is none of the kinds known is named as the widest kind it is, and never by what the program calls it',
      () {
    named([
      (Exception('no'), 'Exception'),
      (_OddException(), 'Exception'),
      (_OddError(), 'Error'),
      ('a string that was thrown', 'Object'),
      (42, 'Object'),
    ]);
  });

  test('nothing of the error\'s own words is in what it is named by', () {
    const secret = 'hunter2-not-a-real-one';
    for (final thing in <Object>[
      const SocketException(secret),
      const FormatException(secret, secret),
      SSHAuthFailError(secret),
      StateError(secret),
      Exception(secret),
      PlatformException(code: secret, message: secret),
      secret,
    ]) {
      expect(errorKind(thing), isNot(contains('hunter2')), reason: '${thing.runtimeType}');
    }
  });
}

class _Named implements Exception, HasTypeName {
  @override
  String get typeName => 'a name it spells out';
}

class _FromNamed extends _Named {}

class _OddException implements Exception {}

class _OddError extends Error {}

class _OtherExtension implements SftpExtensionError {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SecondStepNeeded implements FirebaseAuthMultiFactorException {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppleSaidNo implements SignInWithAppleException {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
