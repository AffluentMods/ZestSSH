// The Windows runner's pointer_hold.cpp (relative mouse on a remote screen),
// built on its own and driven by
// test/windows_runner/pointer_hold_runner_test.dart.
//
// Windows is played (pointer_hold::Os): a test that held the real pointer of
// the PC it runs on would take it from the person at that PC. The one check
// against the real Windows is that a window which is not in front is refused
// and the pointer left as it was.
//
//   harness.exe            runs the checks; exit code 0 where all hold

#include <windows.h>

#include <atomic>
#include <climits>
#include <cstdio>
#include <mutex>
#include <string>
#include <vector>

#include "pointer_hold.h"

#pragma comment(lib, "user32.lib")

namespace {

int g_failures = 0;

void Check(bool ok, const char* what) {
  std::printf("%s: %s\n", ok ? "ok" : "FAILED", what);
  if (!ok) {
    ++g_failures;
  }
}

// Windows, played. Everything the watch's thread may touch is atomic or
// behind the mutex.
struct Played {
  std::atomic<bool> in_front{true};
  std::atomic<bool> pointer_in{true};
  std::atomic<bool> raw_ok{true};
  std::atomic<bool> clip_ok{true};
  POINT at{640, 360};
  std::atomic<ULONGLONG> now{1000};
  int width = 1920;
  int height = 1080;
  int whole_width = 3840;
  int whole_height = 1080;

  std::atomic<int> raw_on{0};
  std::atomic<int> raw_off{0};
  std::atomic<int> clips{0};
  std::atomic<int> frees{0};
  std::atomic<bool> clipped{false};
  std::atomic<int> hides{0};
  std::atomic<int> shows{0};
  std::atomic<int> expired_posts{0};
  std::atomic<UINT> timer_every{0};
  std::mutex mutex;
  RECT rect{};

  pointer_hold::Os Os() {
    pointer_hold::Os os;
    os.in_front = [this](HWND) { return in_front.load(); };
    os.pointer_in = [this](HWND, POINT* out) {
      if (!pointer_in.load()) {
        return false;
      }
      *out = at;
      return true;
    };
    os.raw_mouse = [this](HWND, bool on) {
      if (!raw_ok.load()) {
        return false;
      }
      if (on) {
        ++raw_on;
      } else {
        ++raw_off;
      }
      return true;
    };
    os.clip = [this](const RECT* r) {
      if (r == nullptr) {
        ++frees;
        clipped = false;
        return true;
      }
      if (!clip_ok.load()) {
        return false;
      }
      std::lock_guard<std::mutex> lock(mutex);
      rect = *r;
      ++clips;
      clipped = true;
      return true;
    };
    os.show = [this](bool show) {
      if (show) {
        ++shows;
      } else {
        ++hides;
      }
    };
    os.now_ms = [this]() { return now.load(); };
    os.post = [this](HWND, UINT message) {
      if (message == pointer_hold::kExpiredMessage) {
        ++expired_posts;
      }
    };
    os.timer = [this](HWND, UINT every) { timer_every = every; };
    os.screen = [this](bool whole, int* w, int* h) {
      *w = whole ? whole_width : width;
      *h = whole ? whole_height : height;
    };
    return os;
  }
};

struct Heard {
  std::vector<pointer_hold::Movement> moves;
  int lost = 0;
};

const HWND kWindow = reinterpret_cast<HWND>(static_cast<INT_PTR>(0x1234));
const HWND kOther = reinterpret_cast<HWND>(static_cast<INT_PTR>(0x4321));

RAWMOUSE Moved(long dx, long dy) {
  RAWMOUSE mouse{};
  mouse.usFlags = MOUSE_MOVE_RELATIVE;
  mouse.lLastX = dx;
  mouse.lLastY = dy;
  return mouse;
}

RAWMOUSE At(long x, long y, bool whole) {
  RAWMOUSE mouse{};
  mouse.usFlags = static_cast<USHORT>(MOUSE_MOVE_ABSOLUTE |
                                      (whole ? MOUSE_VIRTUAL_DESKTOP : 0));
  mouse.lLastX = x;
  mouse.lLastY = y;
  return mouse;
}

// Waits, at most a few seconds, for what the watch's thread is to do.
template <typename F>
bool Soon(F done) {
  for (int i = 0; i < 400; ++i) {
    if (done()) {
      return true;
    }
    ::Sleep(10);
  }
  return done();
}

void Refused() {
  {
    Played windows;
    windows.in_front = false;
    pointer_hold::PointerHold hold(windows.Os(), nullptr, nullptr, 5);
    Check(!hold.Start(kWindow) && !hold.held() && windows.raw_on == 0 &&
              windows.clips == 0 && windows.hides == 0,
          "a window that is not in front is refused, and nothing is touched");
    Check(!hold.Start(nullptr), "no window is refused");
  }
  {
    Played windows;
    windows.pointer_in = false;
    pointer_hold::PointerHold hold(windows.Os(), nullptr, nullptr, 5);
    Check(!hold.Start(kWindow) && windows.raw_on == 0 && windows.clips == 0 &&
              windows.hides == 0,
          "a pointer that is not over the window is not taken");
  }
  {
    Played windows;
    windows.raw_ok = false;
    pointer_hold::PointerHold hold(windows.Os(), nullptr, nullptr, 5);
    Check(!hold.Start(kWindow) && windows.clips == 0 && windows.hides == 0,
          "where raw input cannot be had the pointer is left alone");
  }
  {
    Played windows;
    windows.clip_ok = false;
    pointer_hold::PointerHold hold(windows.Os(), nullptr, nullptr, 5);
    Check(!hold.Start(kWindow) && windows.raw_on == 1 &&
              windows.raw_off == 1 && windows.hides == 0 && !hold.held(),
          "where the pointer cannot be kept raw input is given back and "
          "nothing is hidden");
  }
}

void HeldAndLetGo() {
  Played windows;
  Heard heard;
  pointer_hold::PointerHold hold(
      windows.Os(),
      [&](long dx, long dy) {
        heard.moves.push_back(pointer_hold::Movement{dx, dy});
      },
      [&]() { ++heard.lost; }, 5);
  Check(hold.Start(kWindow) && hold.held(), "held");
  bool one_point = false;
  {
    std::lock_guard<std::mutex> lock(windows.mutex);
    one_point = windows.rect.left == 640 && windows.rect.top == 360 &&
                windows.rect.right == 641 && windows.rect.bottom == 361;
  }
  Check(one_point && windows.clipped,
        "the pointer is kept on the one point it was at");
  Check(windows.hides == 1 && windows.shows == 0 && windows.raw_on == 1 &&
            windows.timer_every == pointer_hold::kFlushEveryMs,
        "hidden once, raw input on, the flush timer running");
  Check(hold.Start(kWindow) && windows.hides == 1 && windows.raw_on == 1,
        "held already: not taken a second time");
  Check(!hold.Start(kOther) && hold.held(),
        "another window cannot take a pointer that is held");

  // Movement: summed, handed on at most every few milliseconds, the rest
  // with the timer.
  windows.now += pointer_hold::kSendEveryMs;
  hold.OnMouse(Moved(3, -2));
  Check(heard.moves.size() == 1 && heard.moves[0].dx == 3 &&
            heard.moves[0].dy == -2,
        "movement is handed on");
  hold.OnMouse(Moved(5, 5));
  hold.OnMouse(Moved(-1, 2));
  Check(heard.moves.size() == 1, "not more often than every 4 ms");
  Check(hold.OnMessage(kWindow, WM_TIMER, pointer_hold::kFlushTimer, 0) &&
            heard.moves.size() == 2 && heard.moves[1].dx == 4 &&
            heard.moves[1].dy == 7,
        "what waited goes with the timer, summed");
  Check(hold.OnMessage(kWindow, WM_TIMER, pointer_hold::kFlushTimer, 0) &&
            heard.moves.size() == 2,
        "a timer with nothing waiting hands on nothing");
  Check(!hold.OnMessage(kWindow, WM_TIMER, 77, 0),
        "another timer of the window is not this file's");
  Check(!hold.OnMessage(kOther, WM_ACTIVATE, WA_INACTIVE, 0) && hold.held(),
        "another window's messages mean nothing");

  // A report past all reason is cut, and so is what waits.
  windows.now += pointer_hold::kSendEveryMs;
  hold.OnMouse(Moved(LONG_MAX, LONG_MIN));
  Check(heard.moves.back().dx == pointer_hold::kMostCounts &&
            heard.moves.back().dy == -pointer_hold::kMostCounts,
        "a report past all reason is cut");
  for (int i = 0; i < 64; ++i) {
    hold.OnMouse(Moved(pointer_hold::kMostCounts, 0));
  }
  hold.Flush();
  Check(heard.moves.back().dx == pointer_hold::kMostWaiting,
        "and so is what waits to be handed on");

  // The app is still there: the pointer is put back on its point.
  const int clips_before = windows.clips;
  hold.Renew();
  Check(windows.clips == clips_before + 1 && hold.held(),
        "renewed: the pointer is put back on its point");

  // The app lets go.
  const size_t moves_before = heard.moves.size();
  hold.OnMouse(Moved(9, 9));
  hold.Stop();
  Check(!hold.held() && !windows.clipped && windows.shows == 1 &&
            windows.raw_off == 1 && windows.timer_every == 0,
        "let go: freed, shown once, raw input off, the timer ended");
  Check(heard.lost == 0, "the app asked: it is not told");
  Check(heard.moves.size() == moves_before,
        "movement that waited is not handed on after");
  hold.OnMouse(Moved(4, 4));
  hold.Flush();
  hold.Stop();
  hold.Renew();
  Check(heard.moves.size() == moves_before && windows.shows == 1 &&
            windows.raw_off == 1,
        "not held: movement, renewing and letting go again are nothing");

  // Held again after: the same again, with nothing left over.
  Check(hold.Start(kWindow) && windows.hides == 2, "held again");
  windows.now += pointer_hold::kSendEveryMs;
  hold.OnMouse(Moved(1, 1));
  Check(heard.moves.back().dx == 1 && heard.moves.back().dy == 1,
        "nothing of the hold before is left");
}

void APlaceIsRead() {
  Played windows;
  Heard heard;
  pointer_hold::PointerHold hold(
      windows.Os(),
      [&](long dx, long dy) {
        heard.moves.push_back(pointer_hold::Movement{dx, dy});
      },
      nullptr, 5);
  hold.Start(kWindow);
  // A tablet, a virtual machine, a Remote Desktop session: a place, 0 to
  // 65535 across the main display (1920 wide here).
  windows.now += pointer_hold::kSendEveryMs;
  hold.OnMouse(At(32768, 32768, false));
  Check(heard.moves.empty(), "the first place is no movement");
  windows.now += pointer_hold::kSendEveryMs;
  hold.OnMouse(At(32768 + 3413, 32768, false));
  Check(heard.moves.size() == 1 && heard.moves[0].dx == 100 &&
            heard.moves[0].dy == 0,
        "a place after it is the way from the place before, in pixels");
  // Across the whole desktop (3840 wide here), the same step is twice as far.
  windows.now += pointer_hold::kSendEveryMs;
  hold.OnMouse(At(32768 + 3413 + 3413, 32768, true));
  windows.now += pointer_hold::kSendEveryMs;
  hold.OnMouse(At(32768 + 3413 + 3413 + 3413, 32768 - 6068, true));
  Check(heard.moves.back().dx == 200 && heard.moves.back().dy == -100,
        "a place across the whole desktop is measured by the whole desktop");
  // A mouse after a place: its movement as it is, and the place forgotten.
  windows.now += pointer_hold::kSendEveryMs;
  hold.OnMouse(Moved(-7, 7));
  Check(heard.moves.back().dx == -7 && heard.moves.back().dy == 7,
        "a mouse after it moves as a mouse");
  const size_t before = heard.moves.size();
  windows.now += pointer_hold::kSendEveryMs;
  hold.OnMouse(At(100, 100, false));
  Check(heard.moves.size() == before,
        "and the next place is a first place again");
}

void LetsGoByItself() {
  struct Way {
    const char* what;
    UINT message;
    WPARAM wparam;
    bool lets_go;
  };
  const Way ways[] = {
      {"the window is no longer the active one: let go", WM_ACTIVATE,
       WA_INACTIVE, true},
      {"another program is in front: let go", WM_ACTIVATEAPP, FALSE, true},
      {"the window's menu opens: let go", WM_ENTERMENULOOP, 0, true},
      {"the window is moved or sized: let go", WM_ENTERSIZEMOVE, 0, true},
      {"the displays change: let go", WM_DISPLAYCHANGE, 0, true},
      {"the window goes: let go", WM_DESTROY, 0, true},
      {"the window becoming the active one is no reason to let go",
       WM_ACTIVATE, WA_ACTIVE, false},
      {"the app coming to the front is no reason to let go", WM_ACTIVATEAPP,
       TRUE, false},
      {"a key is no reason to let go", WM_KEYDOWN, VK_ESCAPE, false},
  };
  for (const Way& way : ways) {
    Played windows;
    Heard heard;
    pointer_hold::PointerHold hold(windows.Os(), nullptr,
                                   [&]() { ++heard.lost; }, 5);
    hold.Start(kWindow);
    const bool done = hold.OnMessage(kWindow, way.message, way.wparam, 0);
    const bool let_go = !hold.held() && !windows.clipped &&
                        windows.shows == 1 && windows.raw_off == 1 &&
                        heard.lost == 1;
    const bool kept = hold.held() && windows.clipped && windows.shows == 0 &&
                      heard.lost == 0;
    Check(!done && (way.lets_go ? let_go : kept), way.what);
    // Said once: the same message again says nothing more.
    hold.OnMessage(kWindow, way.message, way.wparam, 0);
    Check(heard.lost == (way.lets_go ? 1 : 0),
          way.lets_go ? "  and the app is told once"
                      : "  and the app is told nothing");
  }
  {
    Played windows;
    Heard heard;
    pointer_hold::PointerHold hold(windows.Os(), nullptr,
                                   [&]() { ++heard.lost; }, 5);
    hold.Start(kWindow);
    windows.in_front = false;
    hold.Renew();
    Check(!hold.held() && !windows.clipped && windows.shows == 1 &&
              heard.lost == 1,
          "renewed while the window is not in front: let go, and the app "
          "is told");
  }
}

void TheWatch() {
  Played windows;
  Heard heard;
  pointer_hold::PointerHold hold(windows.Os(), nullptr,
                                 [&]() { ++heard.lost; }, 5);
  hold.Start(kWindow);

  // Renewed in time, again and again: it stays held.
  for (int i = 0; i < 6; ++i) {
    windows.now += pointer_hold::kRenewWithinMs - 100;
    hold.Renew();
    ::Sleep(20);
  }
  Check(hold.held() && windows.clipped && windows.expired_posts == 0,
        "renewed in time it stays held, however long");

  // The app says nothing, and the window's thread (this one) does nothing:
  // the watch frees the pointer by itself.
  windows.now += pointer_hold::kRenewWithinMs + 1;
  const bool freed = Soon([&] { return !windows.clipped.load(); });
  Check(freed && windows.expired_posts == 1,
        "not renewed for two seconds: the watch frees the pointer itself, "
        "with the window's thread doing nothing, and posts its message");
  ::Sleep(60);
  Check(windows.expired_posts == 1 && windows.frees == 1,
        "once, not again and again");
  Check(hold.held() && windows.shows == 0 && heard.lost == 0,
        "the rest waits for the window's thread");

  // The thread is back and takes the message.
  Check(hold.OnMessage(kWindow, pointer_hold::kExpiredMessage, 0, 0),
        "the watch's message is this file's own");
  Check(!hold.held() && windows.shows == 1 && windows.raw_off == 1 &&
            windows.timer_every == 0 && heard.lost == 1,
        "then the pointer is shown, raw input is off and the app is told");

  // A message of that hold arriving during the next one means nothing.
  windows.now += 10;
  Check(hold.Start(kWindow), "held again after it");
  hold.OnMessage(kWindow, pointer_hold::kExpiredMessage, 0, 0);
  Check(hold.held() && heard.lost == 1,
        "a late message of the hold before does not end this one");

  // The app comes back late and renews before the message: the release is
  // finished there.
  windows.now += pointer_hold::kRenewWithinMs + 1;
  Soon([&] { return windows.expired_posts.load() == 2; });
  hold.Renew();
  Check(!hold.held() && heard.lost == 2 && windows.shows == 2 &&
            !windows.clipped,
        "a renewal that comes too late finishes the release, and does not "
        "take the pointer back");
}

void GoneWhileHeld() {
  Played windows;
  Heard heard;
  {
    pointer_hold::PointerHold hold(windows.Os(), nullptr,
                                   [&]() { ++heard.lost; }, 5);
    hold.Start(kWindow);
  }
  Check(!windows.clipped && windows.shows == 1 && windows.raw_off == 1 &&
            windows.timer_every == 0 && heard.lost == 0,
        "gone while held: everything is given back");
}

// The real Windows: a window that is not in front (it is never shown) is
// refused, and the pointer of this PC is as it was.
void TheRealWindowsRefuses() {
  const HWND window = ::CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 10, 10,
                                        HWND_MESSAGE, nullptr,
                                        ::GetModuleHandleW(nullptr), nullptr);
  RECT before{};
  ::GetClipCursor(&before);
  CURSORINFO shown_before{};
  shown_before.cbSize = sizeof(shown_before);
  ::GetCursorInfo(&shown_before);
  bool started = true;
  {
    pointer_hold::PointerHold hold(pointer_hold::SystemOs(), nullptr, nullptr);
    started = window != nullptr && hold.Start(window);
    hold.Renew();
    hold.Stop();
  }
  RECT after{};
  ::GetClipCursor(&after);
  CURSORINFO shown_after{};
  shown_after.cbSize = sizeof(shown_after);
  ::GetCursorInfo(&shown_after);
  Check(window != nullptr && !started && ::EqualRect(&before, &after) &&
            shown_before.flags == shown_after.flags,
        "the real Windows: a window that is not in front is refused and "
        "the pointer of this PC is as it was");
  const ULONGLONG a = pointer_hold::SystemOs().now_ms();
  ::Sleep(30);
  const ULONGLONG b = pointer_hold::SystemOs().now_ms();
  Check(b > a && b - a >= 20 && b - a < 2000,
        "the real clock goes forward in milliseconds");
  if (window != nullptr) {
    ::DestroyWindow(window);
  }
}

}  // namespace

int main() {
  Refused();
  HeldAndLetGo();
  APlaceIsRead();
  LetsGoByItself();
  TheWatch();
  GoneWhileHeld();
  TheRealWindowsRefuses();
  std::printf(g_failures == 0 ? "all hold\n" : "%d FAILED\n", g_failures);
  return g_failures == 0 ? 0 : 1;
}
