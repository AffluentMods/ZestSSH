/// How far, in logical pixels, a finger may drift and still be pressing the
/// terminal rather than starting to scroll it: a press (a selection, the
/// actions sheet) is only a finger held still. Flutter's own allowance
/// (kTouchSlop, 18) let a scroll that began slowly turn into a selection.
const double kTerminalPressSlop = 8;
