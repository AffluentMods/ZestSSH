import 'package:flutter/scheduler.dart';

/// Runs [callback] once the next frame is drawn, and asks for that frame.
///
/// A post-frame callback alone waits for whatever frame comes next, and where
/// it is registered from a timer, a stream, a future, a provider's listener,
/// a tray menu or the system (no setState and no input in the same turn) no
/// frame may come until the mouse moves. A computer's status bar used to tick
/// once a second for as long as the window lived and so brought one; it ticks
/// only while it counts something now, and the
/// Hosts page's Switch to session was found waiting. Where the callback is
/// registered while a frame is being built (build, initState) the frame in
/// progress runs it, and a plain addPostFrameCallback is enough.
void afterNextFrame(FrameCallback callback) {
  final scheduler = SchedulerBinding.instance;
  scheduler.addPostFrameCallback(callback);
  scheduler.scheduleFrame();
}
