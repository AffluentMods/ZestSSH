/// Reject trivially guessable PINs at setup: a single repeated digit (0000,
/// 111111) or a run of consecutive ascending/descending digits (1234, 4321,
/// 23456). These dominate any shoulder-surfer's or offline attacker's first
/// guesses, and the PIN wraps the vault DB key. Extracted from the setup screen
/// so it is unit-testable.
bool isTrivialPin(String pin) {
  if (pin.isEmpty) return false;
  if (pin.split('').toSet().length == 1) return true; // all same digit
  var asc = true, desc = true;
  for (var i = 1; i < pin.length; i++) {
    final d = pin.codeUnitAt(i) - pin.codeUnitAt(i - 1);
    if (d != 1) asc = false;
    if (d != -1) desc = false;
  }
  return asc || desc;
}
