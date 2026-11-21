#include "key_grab.h"

#include <condition_variable>
#include <mutex>

namespace key_grab {

bool Takes(DWORD vk, bool alt_held, bool ctrl_held) {
  switch (vk) {
    case VK_LWIN:
    case VK_RWIN:
    case VK_APPS:
    case VK_SNAPSHOT:
      return true;
    case VK_TAB:    // Alt+Tab
    case VK_SPACE:  // Alt+Space, the window's menu
    case VK_F4:     // Alt+F4
      return alt_held;
    case VK_ESCAPE:  // Alt+Esc, Ctrl+Esc, Ctrl+Shift+Esc
      return alt_held || ctrl_held;
    default:
      return false;
  }
}

namespace {

// The grab the one hook answers for (one window, one grab at a time).
std::atomic<KeyGrab*> g_owner{nullptr};

LRESULT CALLBACK HookProc(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HC_ACTION) {
    KeyGrab* owner = g_owner.load();
    const auto* k = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lparam);
    // (What another program types for its person is not ours to take.)
    if (owner != nullptr && (k->flags & LLKHF_INJECTED) == 0) {
      const bool down = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
      if (owner->OnKey(k->vkCode, k->scanCode, k->flags, down)) {
        return 1;
      }
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

// The hook's thread: set the hook, run its message loop until told to end,
// remove the hook.
struct HookThread {
  std::thread thread;
  DWORD id = 0;
  std::mutex mutex;
  std::condition_variable ready_cv;
  bool ready = false;
  bool hooked = false;
};

HookThread* g_thread = nullptr;

bool InstallHook(KeyGrab* grab) {
  if (g_thread != nullptr) {
    g_owner.store(grab);
    return true;
  }
  auto* t = new HookThread();
  g_owner.store(grab);
  t->thread = std::thread([t]() {
    MSG msg;
    // A message queue for this thread before anyone posts to it.
    PeekMessageW(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
    HHOOK hook = SetWindowsHookExW(WH_KEYBOARD_LL, HookProc, GetModuleHandleW(nullptr), 0);
    {
      std::lock_guard<std::mutex> lock(t->mutex);
      t->id = GetCurrentThreadId();
      t->hooked = hook != nullptr;
      t->ready = true;
    }
    t->ready_cv.notify_all();
    if (hook == nullptr) {
      return;
    }
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
    UnhookWindowsHookEx(hook);
  });
  bool hooked;
  {
    std::unique_lock<std::mutex> lock(t->mutex);
    t->ready_cv.wait(lock, [t]() { return t->ready; });
    hooked = t->hooked;
  }
  if (!hooked) {
    t->thread.join();
    delete t;
    g_owner.store(nullptr);
    return false;
  }
  g_thread = t;
  return true;
}

void UninstallHook() {
  g_owner.store(nullptr);
  HookThread* t = g_thread;
  g_thread = nullptr;
  if (t == nullptr) {
    return;
  }
  PostThreadMessageW(t->id, WM_QUIT, 0, 0);
  t->thread.join();
  delete t;
}

}  // namespace

Os SystemOs() {
  Os os;
  os.in_front = [](HWND window) {
    return window != nullptr && GetForegroundWindow() == window && !IsIconic(window);
  };
  os.now_ms = []() { return GetTickCount64(); };
  os.ctrl_held = []() { return (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0; };
  os.post = [](HWND window, WPARAM wparam, LPARAM lparam) {
    PostMessageW(window, kKeyMessage, wparam, lparam);
  };
  os.install = [](KeyGrab* grab) { return InstallHook(grab); };
  os.uninstall = []() { UninstallHook(); };
  return os;
}

KeyGrab::KeyGrab(Os os, std::function<void(int, int, bool, bool)> on_key)
    : os_(std::move(os)), on_key_(std::move(on_key)) {}

KeyGrab::~KeyGrab() { Stop(); }

bool KeyGrab::Start(HWND window) {
  // (Whether the window is in front is asked on every key, not here.)
  if (window == nullptr) {
    return false;
  }
  window_.store(window);
  renewed_.store(os_.now_ms());
  if (!installed_) {
    if (!os_.install(this)) {
      window_.store(nullptr);
      return false;
    }
    installed_ = true;
  }
  active_.store(true);
  return true;
}

void KeyGrab::Stop() {
  active_.store(false);
  if (installed_) {
    // (The hook's thread ends here, so taken_ is no longer touched by it.)
    os_.uninstall();
    installed_ = false;
  }
  taken_.clear();
  window_.store(nullptr);
}

void KeyGrab::Renew() { renewed_.store(os_.now_ms()); }

bool KeyGrab::Live() const {
  if (!active_.load()) {
    return false;
  }
  if (os_.now_ms() - renewed_.load() > kRenewWithinMs) {
    return false;
  }
  return os_.in_front(window_.load());
}

bool KeyGrab::OnKey(DWORD vk, DWORD scan, DWORD flags, bool down) {
  const HWND window = window_.load();
  const WPARAM wparam = MAKEWPARAM(static_cast<WORD>(vk), down ? 1 : 0);
  const LPARAM lparam = MAKELPARAM(static_cast<WORD>(scan), (flags & LLKHF_EXTENDED) != 0 ? 1 : 0);
  if (!down && taken_.erase(vk) > 0) {
    // Its press was taken: so is its release, whatever holds now.
    if (window != nullptr) {
      os_.post(window, wparam, lparam);
    }
    return true;
  }
  if (!down || !Live()) {
    return false;
  }
  if (!Takes(vk, (flags & LLKHF_ALTDOWN) != 0, os_.ctrl_held())) {
    return false;
  }
  taken_.insert(vk);
  os_.post(window, wparam, lparam);
  return true;
}

bool KeyGrab::OnMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message != kKeyMessage) {
    return false;
  }
  if (on_key_ && window == window_.load()) {
    on_key_(LOWORD(wparam), LOWORD(lparam), HIWORD(lparam) != 0, HIWORD(wparam) != 0);
  }
  return true;
}

}  // namespace key_grab
