/// Something of the app's that is thrown says what its type is called in
/// code, spelled out.
///
/// The app writes no log to disk, sends none anywhere, and collects no
/// crash reports. What it knows of a failure is what the person copies from
/// an error's details. A line there that may not carry an error's own words
/// (they can hold a name, an address or something secret) says what kind of
/// error it was, and it asked the program for the name of the type
/// (`runtimeType`). A build made for release has its names obfuscated: it
/// has another name for nearly every type, so such a line said "(aB)" in
/// every released app and the right name in every test.
///
/// So each kind spells its name out, as the errors of the SSH core do
/// (`typeName` there too), and [errorKind] reads it. A test holds every
/// class of the app that is thrown to it
/// (test/utils/thrown_types_named_test.dart).
abstract interface class HasTypeName {
  /// What this type is called in code. A class made from another spells out
  /// its own.
  String get typeName;
}
