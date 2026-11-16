/// For an editor's Save: the value to write for a field, given the item as
/// the editor read it ([loaded]) and as it is now ([now]), both stamped by
/// [changedAt]. Where the item did not change meanwhile (or either is not
/// known), what the form holds. Where it did (a sync wrote it), a field whose
/// form value is still the one the editor read takes the item's value now; a
/// field the person changed keeps theirs.
///
/// An editor left open wrote its whole form over what a sync brought in, and
/// the old values then won on every device (the
/// host editor has its own, keptFromSync).
T Function<T>(T form, T Function(R item) of) keptSince<R>(R? loaded, R? now, DateTime? Function(R item) changedAt) {
  final moved = loaded != null && now != null && changedAt(now) != changedAt(loaded);
  return <T>(T form, T Function(R item) of) => moved && form == of(loaded) ? of(now) : form;
}
