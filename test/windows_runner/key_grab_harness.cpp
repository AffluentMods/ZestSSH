// The Windows runner's key_grab.cpp (system keys to a full-screen remote
// screen), built on its own and driven by
// test/windows_runner/key_grab_runner_test.dart.
//
// Windows is played (key_grab::Os): a test that hooked the real keyboard of
// the PC it runs on would take its person's keys. No hook is set here.
//
//   harness.exe            runs the checks; exit code 0 where all hold

#include <windows.h>

#include <atomic>
#include <cstdio>
#include <tuple>
#include <vector>

#include "key_grab.h"

#pragma comment(lib, "user32.lib")

namespace {

int g_failures = 0;

void Check(bool ok, const char* what) {
  std::printf("%s: %s\n", ok ? "ok" : "FAILED", what);
  if (!ok) {
    ++g_failures;
  }
}

struct Played {
  std::atomic<bool> in_front{true};
  std::atomic<ULONGLONG> now{1000};
  std::atomic<bool> ctrl{false};
  std::atomic<bool> refuse_install{false};
  int installs = 0;
  int uninstalls = 0;
  std::vector<std::tuple<WPARAM, LPARAM>> posts;
};

key_grab::Os OsOf(Played* p) {
  key_grab::Os os;
  os.in_front = [p](HWND) { return p->in_front.load(); };
  os.now_ms = [p]() { return p->now.load(); };
  os.ctrl_held = [p]() { return p->ctrl.load(); };
  os.post = [p](HWND, WPARAM w, LPARAM l) { p->posts.emplace_back(w, l); };
  os.install = [p](key_grab::KeyGrab*) {
    if (p->refuse_install.load()) {
      return false;
    }
    ++p->installs;
    return true;
  };
  os.uninstall = [p]() { ++p->uninstalls; };
  return os;
}

const HWND kWindow = reinterpret_cast<HWND>(0x1234);
constexpr DWORD kAlt = LLKHF_ALTDOWN;

}  // namespace

int main() {
  using key_grab::Takes;

  Check(Takes(VK_LWIN, false, false) && Takes(VK_RWIN, false, false) && Takes(VK_APPS, false, false) &&
            Takes(VK_SNAPSHOT, false, false),
        "the Windows keys, the menu key and Print Screen are taken alone");
  Check(Takes(VK_TAB, true, false) && Takes(VK_SPACE, true, false) && Takes(VK_F4, true, false) &&
            Takes(VK_ESCAPE, true, false) && Takes(VK_ESCAPE, false, true),
        "Alt+Tab, Alt+Space, Alt+F4, Alt+Esc and Ctrl+Esc are taken");
  Check(!Takes(VK_TAB, false, false) && !Takes(VK_SPACE, false, false) && !Takes(VK_ESCAPE, false, false) &&
            !Takes('A', true, true) && !Takes(VK_MENU, false, false) && !Takes(VK_CONTROL, false, false) &&
            !Takes(VK_RETURN, true, false),
        "Tab, Space and Esc alone, letters, Alt, Ctrl and Alt+Enter are not");

  {
    Played p;
    key_grab::KeyGrab grab(OsOf(&p), nullptr);
    Check(!grab.OnKey(VK_LWIN, 0x5B, LLKHF_EXTENDED, true) && p.posts.empty(), "not started: nothing is taken");
  }

  {
    Played p;
    std::vector<std::tuple<int, int, bool, bool>> handed;
    key_grab::KeyGrab grab(OsOf(&p), [&](int vk, int scan, bool ext, bool down) { handed.emplace_back(vk, scan, ext, down); });
    Check(grab.Start(kWindow) && p.installs == 1 && grab.active(), "started: the hook is set once");
    Check(grab.OnKey(VK_LWIN, 0x5B, LLKHF_EXTENDED, true) && grab.OnKey(VK_LWIN, 0x5B, LLKHF_EXTENDED, false) &&
              p.posts.size() == 2,
          "the Windows key, pressed and let go: both taken and posted");
    Check(!grab.OnKey('A', 0x1E, 0, true) && !grab.OnKey(VK_TAB, 0x0F, 0, true) && p.posts.size() == 2,
          "a letter and Tab alone go on to Windows");
    Check(grab.OnKey(VK_TAB, 0x0F, kAlt, true) && grab.OnKey(VK_TAB, 0x0F, kAlt, false) && p.posts.size() == 4,
          "Alt+Tab: taken");
    p.ctrl = true;
    Check(grab.OnKey(VK_ESCAPE, 0x01, 0, true) && grab.OnKey(VK_ESCAPE, 0x01, 0, false), "Ctrl+Esc: taken");
    p.ctrl = false;

    for (const auto& [w, l] : p.posts) {
      grab.OnMessage(kWindow, key_grab::kKeyMessage, w, l);
    }
    Check(handed.size() == p.posts.size() && std::get<0>(handed[0]) == VK_LWIN && std::get<1>(handed[0]) == 0x5B &&
              std::get<2>(handed[0]) && std::get<3>(handed[0]) && !std::get<3>(handed[1]),
          "the window hands each on: the key, its scan code, extended, down then up");
    Check(!grab.OnMessage(kWindow, WM_KEYDOWN, VK_LWIN, 0), "other messages are not the grab's");

    p.in_front = false;
    const auto before = p.posts.size();
    Check(!grab.OnKey(VK_LWIN, 0x5B, LLKHF_EXTENDED, true) && p.posts.size() == before,
          "another program is in front: its keys are not taken");
    p.in_front = true;

    Check(grab.OnKey(VK_RWIN, 0x5C, LLKHF_EXTENDED, true), "a press taken");
    p.in_front = false;
    Check(grab.OnKey(VK_RWIN, 0x5C, LLKHF_EXTENDED, false),
          "its release is taken too, though the window is no longer in front");
    p.in_front = true;

    p.now = p.now.load() + key_grab::kRenewWithinMs + 1;
    Check(!grab.OnKey(VK_LWIN, 0x5B, LLKHF_EXTENDED, true),
          "not renewed for two seconds (the app stuck): the keys are Windows' again");
    grab.Renew();
    Check(grab.OnKey(VK_LWIN, 0x5B, LLKHF_EXTENDED, true) && grab.OnKey(VK_LWIN, 0x5B, LLKHF_EXTENDED, false),
          "renewed: taken again");

    grab.Stop();
    Check(p.uninstalls == 1 && !grab.active() && !grab.OnKey(VK_LWIN, 0x5B, LLKHF_EXTENDED, true),
          "stopped: the hook is removed and nothing is taken");
  }

  {
    Played p;
    p.refuse_install = true;
    key_grab::KeyGrab grab(OsOf(&p), nullptr);
    Check(!grab.Start(kWindow) && !grab.active(), "Windows refuses the hook: not started");
  }

  {
    Played p;
    {
      key_grab::KeyGrab grab(OsOf(&p), nullptr);
      grab.Start(kWindow);
    }
    Check(p.uninstalls == 1, "gone while grabbing: the hook is removed");
  }

  Check(!key_grab::SystemOs().in_front(nullptr), "the real Windows: no window is not in front");

  if (g_failures == 0) {
    std::printf("all hold\n");
  }
  return g_failures == 0 ? 0 : 1;
}
