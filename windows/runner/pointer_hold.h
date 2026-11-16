#ifndef RUNNER_POINTER_HOLD_H_
#define RUNNER_POINTER_HOLD_H_

#include <windows.h>

#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>

// Remote screens (4.0): relative mouse, the Windows part.
//
// For a game or a 3D program on a remote screen the pointer of this computer
// is held: hidden, kept on the one point it was at, and what the mouse does
// is read as movement (raw input) and handed to the app, which sends it to
// the remote (lib/features/screens/view/screen_pointer_hold.dart, over the
// channel zestssh/pointer_capture; FlutterWindow is the channel's end here).
//
// A held pointer is a pointer the person cannot use, so the way out is the
// first thing this file is about. It lets go by itself, without the app
// asking, when:
//  - the window is no longer in front (another program, the Start menu,
//    Alt+Tab, a window of the app's own), or its menu or a move of the
//    window begins, or the displays change, or the window goes;
//  - the app has not said it is still there (Renew) for two seconds. That
//    is watched from a thread of its own, since an app that says nothing
//    is most often an app whose own thread is stuck, and a stuck thread
//    runs no timer: the watch frees the pointer itself, and the rest (the
//    pointer shown again, the app told) happens when the thread is back.
//    Windows keeps "shown or hidden" by thread, so a pointer freed this way
//    is shown again as soon as it is over anything else.
//
// What it asks of Windows goes through Os, so the whole of it is tested with
// Windows played (test/windows_runner/pointer_hold_harness.cpp): a test that
// took the real pointer of the PC it runs on would take it from its person.

namespace pointer_hold {

// The app must say it is still there this often, or the pointer is freed.
constexpr ULONGLONG kRenewWithinMs = 2000;

// Movement is handed on at most this often (a mouse reports up to 8000 times
// a second), and what is left when the mouse stops goes with the timer.
constexpr ULONGLONG kSendEveryMs = 4;
constexpr UINT kFlushEveryMs = 10;
constexpr UINT_PTR kFlushTimer = 0x5A01;

// Posted by the watch to the window: the pointer was freed, do the rest.
constexpr UINT kExpiredMessage = WM_APP + 0x5A0;

// The most one report may say, and the most that waits to be handed on: a
// report past it is a broken device, not a movement.
constexpr long kMostCounts = 1L << 20;
constexpr long kMostWaiting = 1L << 24;

// What the hold asks of Windows. The runner uses SystemOs(); a test plays it.
// now_ms, clip and post are also called from the watch's thread.
struct Os {
  // The window is the one in front, and not minimised.
  std::function<bool(HWND)> in_front;
  // Where the pointer is, in screen pixels; false where it is not over the
  // window's own area.
  std::function<bool(HWND, POINT*)> pointer_in;
  // Raw mouse input to this window on, or off.
  std::function<bool(HWND, bool)> raw_mouse;
  // The pointer kept in this rectangle; null frees it.
  std::function<bool(const RECT*)> clip;
  // The pointer shown (true) or hidden, once each way.
  std::function<void(bool)> show;
  // A clock that only goes forward, in milliseconds.
  std::function<ULONGLONG()> now_ms;
  // A message with no content posted to the window.
  std::function<void(HWND, UINT)> post;
  // The flush timer of the window every so many milliseconds; 0 ends it.
  std::function<void(HWND, UINT)> timer;
  // The size in pixels of the whole desktop (true) or the main display.
  std::function<void(bool, int*, int*)> screen;
};

// Windows itself.
Os SystemOs();

struct Movement {
  long dx = 0;
  long dy = 0;
};

// Reads one raw mouse report as movement. A mouse reports movement; a
// tablet, a virtual machine and a Remote Desktop session report a place, and
// the movement is then the way from the place before.
class MouseReader {
 public:
  Movement Read(const RAWMOUSE& mouse, const Os& os);
  void Reset() { has_last_ = false; }

 private:
  bool has_last_ = false;
  long last_x_ = 0;
  long last_y_ = 0;
};

class PointerHold {
 public:
  using Moved = std::function<void(long dx, long dy)>;
  using Lost = std::function<void()>;

  // |moved| is told movement while held, |lost| that the hold let go by
  // itself; both on the window's thread. |watch_every_ms| is how often the
  // watch looks (a test looks more often).
  PointerHold(Os os, Moved moved, Lost lost, unsigned watch_every_ms = 250);
  ~PointerHold();
  PointerHold(const PointerHold&) = delete;
  PointerHold& operator=(const PointerHold&) = delete;

  // Holds the pointer for |window| (the top level window). False, with
  // nothing changed, where the window is not in front or the pointer is not
  // over it. True where it is held already.
  bool Start(HWND window);

  // Lets go, saying nothing to the app (the app asked). Nothing where it is
  // not held.
  void Stop();

  // The app is still there. Also puts the pointer back on its point, which
  // Windows forgets at times, and lets go where the window is not in front.
  void Renew();

  bool held() const { return held_; }

  // The window's messages, before anyone else sees them. True where the
  // message was this file's own and is done with.
  bool OnMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam);

  // One raw mouse report (OnMessage calls it for WM_INPUT).
  void OnMouse(const RAWMOUSE& mouse);

  // Hands on whatever movement waits.
  void Flush();

 private:
  void LetGo(bool by_itself);
  void Watch();

  const Os os_;
  const Moved moved_;
  const Lost lost_;
  const unsigned watch_every_ms_;

  // Written on the window's thread with mutex_ held, read there freely, and
  // read by the watch with mutex_ held.
  bool held_ = false;
  HWND window_ = nullptr;
  ULONGLONG last_renew_ms_ = 0;
  // The watch freed the pointer and posted kExpiredMessage for this hold.
  bool freed_ = false;

  // The window's thread only.
  RECT point_{};
  bool hidden_ = false;
  long dx_ = 0;
  long dy_ = 0;
  ULONGLONG last_sent_ms_ = 0;
  MouseReader reader_;

  std::mutex mutex_;
  std::condition_variable wake_;
  bool quit_ = false;
  std::thread watch_;
};

}  // namespace pointer_hold

#endif  // RUNNER_POINTER_HOLD_H_
