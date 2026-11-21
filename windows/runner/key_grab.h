#ifndef RUNNER_KEY_GRAB_H_
#define RUNNER_KEY_GRAB_H_

#include <windows.h>

#include <atomic>
#include <functional>
#include <set>
#include <thread>

// Remote screens (4.1): system keys go to the remote in full screen, the
// Windows part.
//
// Some keys never reach a window: Windows acts on them first (the Windows
// key opens Start, Alt+Tab switches programs, Ctrl+Esc, Alt+Esc, Alt+Space
// opens the window's menu, Alt+F4 closes the window, Print Screen takes a
// picture, the menu key). In full screen on a remote screen they are the
// remote's, as in Windows' own Remote Desktop app. A low-level keyboard hook
// takes those keys, and only those, and hands them to the app over the
// channel zestssh/key_grab (lib/features/screens/view/screen_key_grab.dart),
// which sends them to the remote.
//
// A hook sees the keys of every program, so what it takes is narrow and its
// way out comes first. A key is taken only while all of these hold:
//  - the app asked for it (full screen, the picture has the keyboard,
//    Settings on), and has said it is still there (Renew) within two
//    seconds: an app whose own thread is stuck says nothing, and the keys
//    are Windows' again;
//  - this window is the one in front and is not minimised, checked on every
//    key, so another program never loses a key to it.
// A key whose press was taken has its release taken too, so neither side
// sees one without the other. Ctrl+Alt+Del and Windows+L are Windows' alone:
// no hook sees them.
//
// The hook lives on a thread of its own with its own message loop, so a busy
// app never slows the keyboard of the rest of the PC: the hook decides on
// that thread and posts what it took to the window.
//
// What it asks of Windows goes through Os, so it is tested with Windows
// played (test/windows_runner/key_grab_harness.cpp): a test that hooked the
// real keyboard of the PC it runs on would take its person's keys.

namespace key_grab {

// The app must say it is still there this often, or nothing is taken.
constexpr ULONGLONG kRenewWithinMs = 2000;

// Posted to the window with a key the hook took: wparam = MAKEWPARAM(vk,
// down), lparam = MAKELPARAM(scan code, extended).
constexpr UINT kKeyMessage = WM_APP + 0x5B0;

// Whether Windows would act on [vk] itself, with Alt or Ctrl held as said:
// the keys taken.
bool Takes(DWORD vk, bool alt_held, bool ctrl_held);

class KeyGrab;

// What the grab asks of Windows. The runner uses SystemOs(); a test plays it.
// in_front, now_ms, ctrl_held and post are called from the hook's thread.
struct Os {
  // The window is the one in front, and not minimised.
  std::function<bool(HWND)> in_front;
  std::function<ULONGLONG()> now_ms;
  // Ctrl is held down now.
  std::function<bool()> ctrl_held;
  std::function<void(HWND, WPARAM, LPARAM)> post;
  // Starts the hook (on a thread of its own) for [grab]; false where Windows
  // refused it.
  std::function<bool(KeyGrab*)> install;
  // Removes the hook and ends its thread.
  std::function<void()> uninstall;
};

// Windows itself.
Os SystemOs();

class KeyGrab {
 public:
  // [on_key] is called on the window's thread with each key taken: its
  // virtual key, scan code, whether it is an extended key, and down or up.
  KeyGrab(Os os, std::function<void(int vk, int scan, bool extended, bool down)> on_key);
  ~KeyGrab();

  KeyGrab(const KeyGrab&) = delete;
  KeyGrab& operator=(const KeyGrab&) = delete;

  // Takes the system keys for [window] from now. False where the hook could
  // not be set.
  bool Start(HWND window);

  // Takes nothing from now, and removes the hook.
  void Stop();

  // The app is still there.
  void Renew();

  bool active() const { return active_.load(); }

  // The hook's question, on its thread, for a key that is not injected:
  // true where the key is taken (posted to the window, and kept from
  // everything else). [flags] are the hook's (LLKHF_*).
  bool OnKey(DWORD vk, DWORD scan, DWORD flags, bool down);

  // The window's messages: true for a key the hook took, handed on.
  bool OnMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam);

 private:
  bool Live() const;

  Os os_;
  std::function<void(int, int, bool, bool)> on_key_;
  std::atomic<bool> active_{false};
  std::atomic<HWND> window_{nullptr};
  std::atomic<ULONGLONG> renewed_{0};
  bool installed_ = false;
  // Keys whose press was taken (the hook's thread only).
  std::set<DWORD> taken_;
};

}  // namespace key_grab

#endif  // RUNNER_KEY_GRAB_H_
