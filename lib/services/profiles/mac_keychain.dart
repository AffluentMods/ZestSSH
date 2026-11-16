import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:zestssh/utils/type_name.dart';

/// macOS did not let ZestSSH use one of its own keychain items (3.3.2). The app's
/// items are in the legacy keychain, and the Mac app was signed ad hoc until
/// 3.4.0 (a Developer ID signature since), so to macOS each update of those was a
/// new app, as a build signed another way still is: a read of an item an older
/// build made brings up its
/// question ("ZestSSH wants to use your confidential information stored in
/// flutter_secure_storage_service"), and this is the answer that was not yes. Allow
/// covers one read; Always Allow, with the Mac's login password, stays.
///
/// A [PlatformException] still, as the plugin's own was: whatever took that takes
/// this. Nothing here ever makes a new key for one that could not be read.
class KeychainAccessDenied extends PlatformException implements Exception, HasTypeName {
  KeychainAccessDenied(this.status, {this.asked = true})
      : super(code: 'Unexpected security result code', message: 'Code: $status', details: status);

  /// What macOS answered ([statuses]).
  final int status;

  /// False where macOS was not asked this time: it said no to the same item
  /// earlier in this run, and nobody has chosen Try again since ([KeychainDenials]).
  final bool asked;

  /// The answers that mean macOS did not let the app in: the person chose Deny or
  /// closed the question (errSecUserCanceled, -128), the password was not taken
  /// (errSecAuthFailed, -25293), macOS could not ask at all (errSecInteractionNotAllowed,
  /// -25308: the Mac locked, or no window to ask in), or the build may not use the
  /// keychain it names (errSecMissingEntitlement, -34018).
  static const statuses = {-128, -25293, -25308, -34018};

  /// The status of [error] where it is one of [statuses], and null otherwise. The
  /// plugin says it as `details`, and in its message as `Code: -128, Message: ...`.
  static int? statusOf(Object error) {
    if (error is KeychainAccessDenied) return error.status;
    if (error is! PlatformException) return null;
    final details = error.details;
    final status = details is int ? details : int.tryParse(RegExp(r'Code: (-?\d+)').firstMatch(error.message ?? '')?.group(1) ?? '');
    return statuses.contains(status) ? status : null;
  }

  @override
  String toString() => 'KeychainAccessDenied($status${asked ? '' : ', not asked again'})';

  @override
  String get typeName => 'KeychainAccessDenied';
}

/// What macOS said no to in this run ([KeychainAccessDenied]), by the item's name.
/// Such an item fails at once and macOS is not asked about it again, until the
/// person chooses Try again ([tryAgain]) or the app starts again: work nobody asked
/// for (sync, the sweep after a pull, a team's rounds) waits meanwhile, and never
/// brings the question up again by itself. Listened to by what says so on screen.
class KeychainDenials extends ChangeNotifier {
  final _denied = <String, int>{};
  KeychainAccessDenied? _last;

  /// Whether macOS said no to anything in this run since the last Try again.
  bool get any => _denied.isNotEmpty;

  /// The newest of them, for the details a person can copy.
  KeychainAccessDenied? get last => _last;

  int? _statusOf(String name) => _denied[name];

  void _note(String name, KeychainAccessDenied denied) {
    _denied[name] = denied.status;
    _last = denied;
    notifyListeners();
  }

  /// The person chose Try again: macOS is asked about each of them again.
  void tryAgain() {
    if (_denied.isEmpty) return;
    _denied.clear();
    _last = null;
    notifyListeners();
  }
}

/// The keychain on a Mac, over the plugin: all but [readAll] and [deleteAll] are
/// the plugin's own, but for what macOS said no to ([denials]).
///
/// The app uses the legacy keychain (it carries no keychain access group),
/// and there the plugin's readAll, a query for every item with its data, fails
/// with errSecParam (-50) on every Mac. So does everything that lists what is kept:
/// the clean-ups, the seal's sweeps, the move to profiles. The same query for the
/// items' names alone works (macos/Runner/KeychainNames.swift), and each is then
/// read on its own.
class MacKeychain extends FlutterSecureStoragePlatform {
  MacKeychain(this._plugin, {KeychainDenials? denials}) : denials = denials ?? KeychainDenials();

  static const channel = MethodChannel('zestssh/keychain_names');

  final FlutterSecureStoragePlatform _plugin;

  /// What macOS said no to in this run.
  final KeychainDenials denials;

  /// The names kept, with nothing read: this asks nothing of anyone, where a read
  /// may, for each item, with a new build's signature.
  Future<List<String>> names(Map<String, String> options) async =>
      await channel.invokeListMethod<String>('names', {'options': options}) ?? const [];

  /// [call] on the item [key], unless macOS said no to it in this run: then it fails
  /// at once, and nobody is asked again. A no from macOS is said as
  /// [KeychainAccessDenied], and kept.
  Future<T> _asking<T>(String key, Future<T> Function() call) async {
    final before = denials._statusOf(key);
    if (before != null) throw KeychainAccessDenied(before, asked: false);
    try {
      return await call();
    } on PlatformException catch (e) {
      final status = KeychainAccessDenied.statusOf(e);
      if (status == null) rethrow;
      final denied = e is KeychainAccessDenied ? e : KeychainAccessDenied(status);
      denials._note(key, denied);
      throw denied;
    }
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async {
    final out = <String, String>{};
    for (final name in await names(options)) {
      final value = await read(key: name, options: options);
      // One that went between the list and its read is simply not there.
      if (value != null) out[name] = value;
    }
    return out;
  }

  /// One by one too: the legacy keychain's delete of a query takes what it matches
  /// first, and the plugin's goes through the same kind of query.
  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    for (final name in await names(options)) {
      await delete(key: name, options: options);
    }
  }

  /// Whether it is there asks for no value, and macOS asks nothing for it.
  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) =>
      _plugin.containsKey(key: key, options: options);

  @override
  Future<void> delete({required String key, required Map<String, String> options}) =>
      _asking(key, () => _plugin.delete(key: key, options: options));

  @override
  Future<String?> read({required String key, required Map<String, String> options}) =>
      _asking(key, () => _plugin.read(key: key, options: options));

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) =>
      _asking(key, () => _plugin.write(key: key, value: value, options: options));
}
