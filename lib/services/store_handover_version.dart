/// Which version of ZestSSH from the Microsoft Store is installed, which
/// version the website's copy is, and whether the Store's copy may take the
/// website copy's data.
///
/// Why: the website's copy can be a version ahead of the Store's (a release is
/// on zestssh.com before the Store has certified it). A website 3.3 that has
/// already moved its data into per-account profiles, handing over to a Store
/// copy still on 3.2.7, would open that copy on data it cannot read. So the
/// website's copy hands over only to a Store copy of at least its own version
/// (store_handover_start.dart), and the website installer opens the Store's
/// copy instead of installing only on the same rule (installer/zestssh_setup.iss).
/// The Store's copy keeps the same rule from its side: it takes over only a
/// website copy of at most its own version, and hands its start to a newer one.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zestssh/services/store_handover.dart';
import 'package:zestssh/services/update_check_service.dart'
    show compareVersions;
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/utils/windows_programs.dart';

/// The Store's copy's version could be read neither from Windows nor from
/// PowerShell.
class StoreVersionUnreadable implements Exception, HasTypeName {
  const StoreVersionUnreadable(this.message);
  final String message;

  @override
  String get typeName => 'StoreVersionUnreadable';

  @override
  String toString() => 'StoreVersionUnreadable: $message';
}

/// The website copy's version could not be read from its program.
class ProgramVersionUnreadable implements Exception, HasTypeName {
  const ProgramVersionUnreadable(this.message);
  final String message;

  @override
  String get typeName => 'ProgramVersionUnreadable';

  @override
  String toString() => 'ProgramVersionUnreadable: $message';
}

/// A version the comparison believes: dotted numbers, an optional `+build`.
final _readable = RegExp(r'^\d+(\.\d+)*(\+\w+)?$');

/// Whether the Store's copy, at [storeVersion], may take the data of the
/// website's copy, at [websiteVersion]: it is at least as new. The one rule
/// for both copies: the website's copy hands over only where it holds, and the
/// Store's copy takes over only where it holds (and hands its start to the
/// website's copy where it does not). Compared as dotted numbers
/// ([compareVersions]), so 3.10 is newer than 3.9, a missing part is 0 and a
/// `+build` part is left out: the Store package's version is the pubspec's
/// with its build number dropped and a 0 added (3.2.7+299 is 3.2.7.0 there;
/// the msix tool), so the same release is the same version on both sides.
/// Throws a [FormatException] where either is not a version: what cannot be
/// read is never taken as older or newer.
bool storeCopyMayTakeOver({
  required String storeVersion,
  required String websiteVersion,
}) {
  for (final v in [storeVersion, websiteVersion]) {
    if (!_readable.hasMatch(v.trim())) {
      throw FormatException('Not a version', v);
    }
  }
  return compareVersions(storeVersion.trim(), websiteVersion.trim()) >= 0;
}

/// The version in a package's full name, `Name_Version_Arch_ResourceId_PublisherId`
/// (AffluentLabs.ZestSSH_3.2.7.0_x64__a13075jvne08e); null where it holds none.
String? packageVersionOf(String fullName) {
  final parts = fullName.trim().split('_');
  if (parts.length != 5) return null;
  return RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(parts[1]) ? parts[1] : null;
}

/// The highest version among a family's installed packages (a family can hold
/// more than one for a moment, during an update); null where none has one.
String? highestPackageVersion(Iterable<String> fullNames) {
  String? best;
  for (final name in fullNames) {
    final v = packageVersionOf(name);
    if (v != null && (best == null || compareVersions(v, best) > 0)) best = v;
  }
  return best;
}

/// The version of ZestSSH from the Microsoft Store installed for this Windows
/// account; null where none is. Asks Windows itself first
/// ([packageFullNamesByFamily]), and PowerShell's Get-AppxPackage where that
/// call is not there or fails. Throws [StoreVersionUnreadable] where neither
/// answers.
Future<String?> installedStoreCopyVersion({
  String family = StoreHandover.packageFamily,
}) async {
  Object? first;
  try {
    return highestPackageVersion(packageFullNamesByFamily(family));
  } catch (e) {
    first = e;
  }
  try {
    return highestPackageVersion(await packageFullNamesByPowerShell(family));
  } catch (e) {
    throw StoreVersionUnreadable(
      'GetPackagesByPackageFamily: $first; Get-AppxPackage: $e',
    );
  }
}

const _errorSuccess = 0;
const _errorInsufficientBuffer = 122;

typedef _GetPackagesNative =
    Int32 Function(
      Pointer<Utf16> family,
      Pointer<Uint32> count,
      Pointer<Pointer<Utf16>> fullNames,
      Pointer<Uint32> bufferLength,
      Pointer<Uint16> buffer,
    );
typedef _GetPackagesDart =
    int Function(
      Pointer<Utf16> family,
      Pointer<Uint32> count,
      Pointer<Pointer<Utf16>> fullNames,
      Pointer<Uint32> bufferLength,
      Pointer<Uint16> buffer,
    );

/// The full names of a package family's packages installed for this Windows
/// account, from kernel32's GetPackagesByPackageFamily (appmodel.h, Windows 8
/// on; it answers an unpackaged program too): an empty list where none is.
/// Throws an [OSError] where Windows answers with an error.
List<String> packageFullNamesByFamily(String family) {
  final getPackages = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<_GetPackagesNative, _GetPackagesDart>(
        'GetPackagesByPackageFamily',
      );
  final name = family.toNativeUtf16();
  final count = calloc<Uint32>();
  final length = calloc<Uint32>();
  try {
    // Asked with no room first: Windows says how many there are and how much
    // room their names take.
    var code = getPackages(name, count, nullptr, length, nullptr);
    // A package installed between the two calls needs more room: asked again.
    for (var i = 0; i < 3; i++) {
      if (code == _errorSuccess && count.value == 0) return const [];
      if (code != _errorInsufficientBuffer && code != _errorSuccess) break;
      final names = calloc<Pointer<Utf16>>(count.value);
      final buffer = calloc<Uint16>(length.value);
      try {
        code = getPackages(name, count, names, length, buffer);
        if (code == _errorSuccess) {
          return [
            for (var n = 0; n < count.value; n++) names[n].toDartString(),
          ];
        }
      } finally {
        calloc.free(names);
        calloc.free(buffer);
      }
    }
    throw OSError('GetPackagesByPackageFamily', code);
  } finally {
    calloc.free(name);
    calloc.free(count);
    calloc.free(length);
  }
}

/// The same from Windows PowerShell 5.1 (whose Appx module has Get-AppxPackage),
/// by its full path: one full name a line, none where nothing is installed.
/// [family] goes into a PowerShell command, so only a family name's own
/// letters are taken (a name, an underscore, the 13 letters of a publisher id).
/// A PowerShell that has not answered in 20 seconds is ended, and this throws
/// a [TimeoutException].
Future<List<String>> packageFullNamesByPowerShell(String family) async {
  if (!RegExp(r'^[A-Za-z0-9.\-]+_[a-z0-9]{13}$').hasMatch(family)) {
    throw ArgumentError.value(family, 'family', 'Not a package family name');
  }
  final packageName = family.split('_').first;
  final result = await runEndedAfter(windowsPowerShell, [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    'Get-AppxPackage -Name $packageName -ErrorAction Stop | '
        'Where-Object PackageFamilyName -eq $family | '
        r'ForEach-Object { $_.PackageFullName }',
  ], const Duration(seconds: 20));
  if (result.exitCode != 0) {
    throw ProcessException(
      windowsPowerShell,
      const ['Get-AppxPackage'],
      'exit code ${result.exitCode}',
      result.exitCode,
    );
  }
  return [
    for (final line in '${result.stdout}'.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
}

/// Runs [exe] with [arguments] as [Process.run] does, but ends it where it has
/// not finished within [limit], and throws a [TimeoutException]: a program
/// left running after the wait was given up on stayed for as long as it
/// hung. [started] is told its process id, in tests.
@visibleForTesting
Future<ProcessResult> runEndedAfter(
  String exe,
  List<String> arguments,
  Duration limit, {
  void Function(int pid)? started,
}) async {
  final process = await Process.start(exe, arguments);
  started?.call(process.pid);
  final out = process.stdout.transform(systemEncoding.decoder).join();
  final err = process.stderr.transform(systemEncoding.decoder).join();
  final int code;
  try {
    code = await process.exitCode.timeout(limit);
  } on TimeoutException {
    process.kill();
    // Its pipes close as it ends: nothing is left waiting on them.
    unawaited(out.then<void>((_) {}, onError: (_) {}));
    unawaited(err.then<void>((_) {}, onError: (_) {}));
    rethrow;
  }
  return ProcessResult(process.pid, code, await out, await err);
}

const _appModelErrorNoPackage = 15700;

typedef _CurrentPackageNative =
    Int32 Function(Pointer<Uint32> length, Pointer<Utf16> fullName);
typedef _CurrentPackageDart =
    int Function(Pointer<Uint32> length, Pointer<Utf16> fullName);

/// The full name of the package this process runs as, from kernel32's
/// GetCurrentPackageFullName (appmodel.h, Windows 8 on); null where it runs as
/// none (a program installed from the website). Throws an [OSError] where
/// Windows answers with another error.
String? currentPackageFullName() {
  final current = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<_CurrentPackageNative, _CurrentPackageDart>(
        'GetCurrentPackageFullName',
      );
  final length = calloc<Uint32>();
  try {
    var code = current(length, nullptr);
    if (code == _appModelErrorNoPackage) return null;
    for (var i = 0; i < 3 && code == _errorInsufficientBuffer; i++) {
      final name = calloc<Uint16>(length.value + 1);
      try {
        code = current(length, name.cast());
        if (code == _errorSuccess) return name.cast<Utf16>().toDartString();
      } finally {
        calloc.free(name);
      }
    }
    throw OSError('GetCurrentPackageFullName', code);
  } finally {
    calloc.free(length);
  }
}

/// The Store copy's own version, as Windows knows its package: the field the
/// website's copy reads it from ([installedStoreCopyVersion]). Read from the
/// same place on both sides, the two copies never disagree about which is
/// newer, whatever the
/// program's own version says: a package versioned apart from the pubspec
/// would have them hand the start to each other for ever. Throws
/// [StoreVersionUnreadable] where this process runs as no package, or its
/// name holds no version.
String storeCopyOwnVersion({String? Function()? fullName}) {
  final name = (fullName ?? currentPackageFullName)();
  final version = name == null ? null : packageVersionOf(name);
  if (version == null) {
    throw StoreVersionUnreadable(
      name == null ? 'This process runs as no package' : 'No version in its package name',
    );
  }
  return version;
}

/// Whether this process runs as a Microsoft Store package: it has a package
/// identity, or its program is in the folder Windows installs packages in
/// (WindowsApps). [executable] and [fullName] stand in for this process's, in
/// tests.
bool runsAsPackage({String? executable, String? Function()? fullName}) {
  final exe = executable ?? Platform.resolvedExecutable;
  if (RegExp(r'[\\/]WindowsApps[\\/]', caseSensitive: false).hasMatch(exe)) {
    return true;
  }
  try {
    return (fullName ?? currentPackageFullName)() != null;
  } catch (_) {
    // Windows did not say: its folder said no.
    return false;
  }
}

typedef _VersionSizeNative =
    Uint32 Function(Pointer<Utf16> file, Pointer<Uint32> handle);
typedef _VersionSizeDart =
    int Function(Pointer<Utf16> file, Pointer<Uint32> handle);
typedef _VersionInfoNative =
    Int32 Function(
      Pointer<Utf16> file,
      Uint32 handle,
      Uint32 length,
      Pointer<Uint8> data,
    );
typedef _VersionInfoDart =
    int Function(
      Pointer<Utf16> file,
      int handle,
      int length,
      Pointer<Uint8> data,
    );
typedef _VersionQueryNative =
    Int32 Function(
      Pointer<Uint8> block,
      Pointer<Utf16> subBlock,
      Pointer<Pointer<Void>> value,
      Pointer<Uint32> length,
    );
typedef _VersionQueryDart =
    int Function(
      Pointer<Uint8> block,
      Pointer<Utf16> subBlock,
      Pointer<Pointer<Void>> value,
      Pointer<Uint32> length,
    );

/// The product version written into the program at [exe], from its version
/// resource (version.dll's GetFileVersionInfoW and VerQueryValueW):
/// windows/runner/Runner.rc writes the pubspec's version there with its build
/// (3.2.7+299), in every build since the first commit (1.3.4).
///
/// Why this field: it is the one
/// each copy reads its own version from (package_info_plus, which keeps the
/// part before the +). The Store's copy reads the website copy's version just
/// as that copy reads it itself, so the two never disagree about which of them
/// is newer, and neither hands its start to the other and back.
///
/// Throws [ProgramVersionUnreadable] where the file is not there, holds no
/// version, or cannot be read.
String programProductVersion(String exe) {
  final version = DynamicLibrary.open('version.dll');
  final sizeOf = version.lookupFunction<_VersionSizeNative, _VersionSizeDart>(
    'GetFileVersionInfoSizeW',
  );
  final readInfo = version
      .lookupFunction<_VersionInfoNative, _VersionInfoDart>(
        'GetFileVersionInfoW',
      );
  final query = version.lookupFunction<_VersionQueryNative, _VersionQueryDart>(
    'VerQueryValueW',
  );
  final path = exe.toNativeUtf16();
  final handle = calloc<Uint32>();
  final value = calloc<Pointer<Void>>();
  final length = calloc<Uint32>();
  Pointer<Uint8> block = nullptr;
  try {
    final size = sizeOf(path, handle);
    if (size == 0) {
      throw ProgramVersionUnreadable('No version in $exe');
    }
    block = calloc<Uint8>(size);
    if (readInfo(path, 0, size, block) == 0) {
      throw ProgramVersionUnreadable('The version of $exe was not read');
    }
    bool ask(String subBlock) {
      final sub = subBlock.toNativeUtf16();
      try {
        return query(block, sub, value, length) != 0 &&
            value.value != nullptr &&
            length.value > 0;
      } finally {
        calloc.free(sub);
      }
    }

    // Its languages as the program lists them (Runner.rc: 0x409, 1252), then
    // that one and Unicode's, as other programs are written.
    final languages = <String>[];
    if (ask(r'\VarFileInfo\Translation')) {
      final pairs = value.value.cast<Uint16>();
      for (var i = 0; i + 1 < length.value ~/ 2; i += 2) {
        languages.add(
          pairs[i].toRadixString(16).padLeft(4, '0') +
              pairs[i + 1].toRadixString(16).padLeft(4, '0'),
        );
      }
    }
    for (final language in [...languages, '040904e4', '040904b0']) {
      if (!ask('\\StringFileInfo\\$language\\ProductVersion')) continue;
      // A string's length is in characters, its ending 0 among them.
      final text = value.value.cast<Utf16>().toDartString(length: length.value);
      final end = text.indexOf('\u0000');
      final product = (end < 0 ? text : text.substring(0, end)).trim();
      if (product.isNotEmpty) return product;
    }
    throw ProgramVersionUnreadable('No product version in $exe');
  } finally {
    calloc.free(path);
    calloc.free(handle);
    calloc.free(value);
    calloc.free(length);
    if (block != nullptr) calloc.free(block);
  }
}
