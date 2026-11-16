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
import 'package:http/http.dart' as http show ClientException;
import 'package:pointycastle/api.dart' show InvalidCipherTextException;
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show SignInWithAppleAuthorizationException, SignInWithAppleException;
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:xml/xml.dart' show XmlException;
import 'package:zest_native/ftps.dart' show FtpsException;
import 'package:zest_ssh_core/zest_ssh_core.dart'
    show
        SSHChannelOpenError,
        SSHDecompressionBombException,
        SSHException,
        SSHHostKeyVerifyError,
        SSHHttpException,
        SSHInternalError,
        SSHMessageError,
        SSHSocketError,
        SftpAbortError,
        SftpError,
        SftpExtensionError,
        SftpExtensionUnsupportedError,
        SftpExtensionVersionMismatchError,
        SftpNotSftpError,
        SftpStatusError;
import 'package:zestssh/utils/type_name.dart';

/// What kind of thing [error] is: the name its type has in code, and no
/// more of it. For a line that may not carry the error's own words (a log
/// line that is kept for an error's details, a sentence that is shown),
/// since those can hold a name, an address or something secret.
///
/// The name is never asked of the program (`runtimeType`): a build made for
/// release has another name for nearly every type, the language's own among
/// them (a program built that way called a SocketException "Zj" and a
/// TimeoutException "sb"; a FormatException kept its name), and such a line
/// said that name there. It is spelled out: by the error itself where it is
/// one of the app's ([HasTypeName]) or of the SSH core, and here for what
/// the language and the packages throw. Nothing is read from the error's
/// text either.
///
/// What is none of the kinds known here is named as the widest kind it is:
/// "Exception", "Error", or "Object" for a thing that is thrown and is
/// neither.
String errorKind(Object error) => switch (error) {
      // The app's own, and the SSH core's: each spells its name out.
      HasTypeName(:final typeName) => typeName,
      // FTPS (3.4), from the native library's package.
      FtpsException(:final typeName) => typeName,
      SSHMessageError(:final typeName) => typeName,
      SSHException(:final typeName) => typeName,
      SSHInternalError() => 'SSHInternalError',
      SSHChannelOpenError() => 'SSHChannelOpenError',
      SSHSocketError() => 'SSHSocketError',
      SSHHostKeyVerifyError() => 'SSHHostKeyVerifyError',
      SSHHttpException() => 'SSHHttpException',
      SSHDecompressionBombException() => 'SSHDecompressionBombException',
      SftpAbortError() => 'SftpAbortError',
      SftpNotSftpError() => 'SftpNotSftpError',
      SftpStatusError() => 'SftpStatusError',
      SftpExtensionUnsupportedError() => 'SftpExtensionUnsupportedError',
      SftpExtensionVersionMismatchError() => 'SftpExtensionVersionMismatchError',
      SftpExtensionError() => 'SftpExtensionError',
      SftpError() => 'SftpError',

      // A network, a file, a program (dart:io). A kind made from another comes before it.
      HandshakeException() => 'HandshakeException',
      CertificateException() => 'CertificateException',
      TlsException() => 'TlsException',
      SocketException() => 'SocketException',
      RedirectException() => 'RedirectException',
      HttpException() => 'HttpException',
      WebSocketException() => 'WebSocketException',
      PathAccessException() => 'PathAccessException',
      PathExistsException() => 'PathExistsException',
      PathNotFoundException() => 'PathNotFoundException',
      FileSystemException() => 'FileSystemException',
      ProcessException() => 'ProcessException',
      SignalException() => 'SignalException',
      StdinException() => 'StdinException',
      StdoutException() => 'StdoutException',
      http.ClientException() => 'ClientException',

      // What a plugin, the database and the libraries for encryption and for accounts throw.
      MissingPluginException() => 'MissingPluginException',
      PlatformException() => 'PlatformException',
      SqliteException() => 'SqliteException',
      DriftWrappedException() => 'DriftWrappedException',
      CouldNotRollBackException() => 'CouldNotRollBackException',
      InvalidDataException() => 'InvalidDataException',
      SecretBoxAuthenticationError() => 'SecretBoxAuthenticationError',
      SecretBoxPaddingError() => 'SecretBoxPaddingError',
      InvalidCipherTextException() => 'InvalidCipherTextException',
      FirebaseAuthMultiFactorException() => 'FirebaseAuthMultiFactorException',
      FirebaseAuthException() => 'FirebaseAuthException',
      FirebaseException() => 'FirebaseException',
      SignInWithAppleAuthorizationException() => 'SignInWithAppleAuthorizationException',
      SignInWithAppleException() => 'SignInWithAppleException',
      XmlException() => 'XmlException',

      // The language's own (dart:async, dart:convert, dart:isolate, dart:core).
      TimeoutException() => 'TimeoutException',
      FormatException() => 'FormatException',
      IsolateSpawnException() => 'IsolateSpawnException',
      RemoteError() => 'RemoteError',
      JsonCyclicError() => 'JsonCyclicError',
      JsonUnsupportedObjectError() => 'JsonUnsupportedObjectError',
      FlutterError() => 'FlutterError',
      AssertionError() => 'AssertionError',
      TypeError() => 'TypeError',
      IndexError() => 'IndexError',
      RangeError() => 'RangeError',
      ArgumentError() => 'ArgumentError',
      NoSuchMethodError() => 'NoSuchMethodError',
      UnimplementedError() => 'UnimplementedError',
      UnsupportedError() => 'UnsupportedError',
      StateError() => 'StateError',
      ConcurrentModificationError() => 'ConcurrentModificationError',
      OutOfMemoryError() => 'OutOfMemoryError',
      StackOverflowError() => 'StackOverflowError',
      Exception() => 'Exception',
      Error() => 'Error',
      _ => 'Object',
    };
