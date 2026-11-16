#include "pointer_hold.h"

#include <chrono>
#include <utility>

namespace pointer_hold {

namespace {

long Within(long value, long most) {
  if (value > most) {
    return most;
  }
  if (value < -most) {
    return -most;
  }
  return value;
}

// HID usage page 1 (generic desktop), usage 2 (mouse).
constexpr USHORT kUsagePageDesktop = 0x01;
constexpr USHORT kUsageMouse = 0x02;

// A place a device reports is 0 to this, across the display or the desktop.
constexpr long long kAbsoluteRange = 65535;

}  // namespace

Os SystemOs() {
  Os os;
  os.in_front = [](HWND window) {
    return window != nullptr && ::GetForegroundWindow() == window &&
           !::IsIconic(window);
  };
  os.pointer_in = [](HWND window, POINT* at) {
    POINT screen{};
    RECT area{};
    if (!::GetCursorPos(&screen) || !::GetClientRect(window, &area)) {
      return false;
    }
    POINT local = screen;
    if (!::ScreenToClient(window, &local) || !::PtInRect(&area, local)) {
      return false;
    }
    *at = screen;
    return true;
  };
  os.raw_mouse = [](HWND window, bool on) {
    RAWINPUTDEVICE device{};
    device.usUsagePage = kUsagePageDesktop;
    device.usUsage = kUsageMouse;
    // Without RIDEV_NOLEGACY: the buttons and the wheel go on reaching the
    // app as they always do, only movement is read here.
    device.dwFlags = on ? 0 : RIDEV_REMOVE;
    device.hwndTarget = on ? window : nullptr;
    return ::RegisterRawInputDevices(&device, 1, sizeof(device)) != FALSE;
  };
  os.clip = [](const RECT* rect) { return ::ClipCursor(rect) != FALSE; };
  os.show = [](bool show) { ::ShowCursor(show ? TRUE : FALSE); };
  os.now_ms = []() -> ULONGLONG {
    LARGE_INTEGER frequency{};
    LARGE_INTEGER count{};
    if (!::QueryPerformanceFrequency(&frequency) ||
        !::QueryPerformanceCounter(&count) || frequency.QuadPart <= 0) {
      return ::GetTickCount64();
    }
    const long long whole = count.QuadPart / frequency.QuadPart;
    const long long rest = count.QuadPart % frequency.QuadPart;
    return static_cast<ULONGLONG>(whole * 1000 +
                                  (rest * 1000) / frequency.QuadPart);
  };
  os.post = [](HWND window, UINT message) {
    ::PostMessageW(window, message, 0, 0);
  };
  os.timer = [](HWND window, UINT every_ms) {
    if (every_ms == 0) {
      ::KillTimer(window, kFlushTimer);
    } else {
      ::SetTimer(window, kFlushTimer, every_ms, nullptr);
    }
  };
  os.screen = [](bool whole, int* width, int* height) {
    *width = ::GetSystemMetrics(whole ? SM_CXVIRTUALSCREEN : SM_CXSCREEN);
    *height = ::GetSystemMetrics(whole ? SM_CYVIRTUALSCREEN : SM_CYSCREEN);
  };
  return os;
}

Movement MouseReader::Read(const RAWMOUSE& mouse, const Os& os) {
  if ((mouse.usFlags & MOUSE_MOVE_ABSOLUTE) == 0) {
    has_last_ = false;
    return Movement{Within(mouse.lLastX, kMostCounts),
                    Within(mouse.lLastY, kMostCounts)};
  }
  int width = 0;
  int height = 0;
  os.screen((mouse.usFlags & MOUSE_VIRTUAL_DESKTOP) != 0, &width, &height);
  if (width <= 0 || height <= 0) {
    return Movement{};
  }
  const long x = static_cast<long>(
      (static_cast<long long>(mouse.lLastX) * width) / kAbsoluteRange);
  const long y = static_cast<long>(
      (static_cast<long long>(mouse.lLastY) * height) / kAbsoluteRange);
  Movement by;
  if (has_last_) {
    by.dx = Within(x - last_x_, kMostCounts);
    by.dy = Within(y - last_y_, kMostCounts);
  }
  has_last_ = true;
  last_x_ = x;
  last_y_ = y;
  return by;
}

PointerHold::PointerHold(Os os, Moved moved, Lost lost,
                         unsigned watch_every_ms)
    : os_(std::move(os)),
      moved_(std::move(moved)),
      lost_(std::move(lost)),
      watch_every_ms_(watch_every_ms == 0 ? 1 : watch_every_ms) {}

PointerHold::~PointerHold() {
  LetGo(false);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    quit_ = true;
  }
  wake_.notify_all();
  if (watch_.joinable()) {
    watch_.join();
  }
}

bool PointerHold::Start(HWND window) {
  if (held_) {
    return window == window_;
  }
  if (window == nullptr || !os_.in_front(window)) {
    return false;
  }
  POINT at{};
  if (!os_.pointer_in(window, &at)) {
    return false;
  }
  if (!os_.raw_mouse(window, true)) {
    return false;
  }
  // The one point it is on: its buttons go on reaching what is under it
  // (the picture), and let go it is where the person left it.
  const RECT point{at.x, at.y, at.x + 1, at.y + 1};
  if (!os_.clip(&point)) {
    os_.raw_mouse(window, false);
    return false;
  }
  os_.show(false);
  hidden_ = true;
  point_ = point;
  dx_ = 0;
  dy_ = 0;
  reader_.Reset();
  last_sent_ms_ = os_.now_ms();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    held_ = true;
    freed_ = false;
    window_ = window;
    last_renew_ms_ = last_sent_ms_;
  }
  os_.timer(window, kFlushEveryMs);
  if (!watch_.joinable()) {
    watch_ = std::thread(&PointerHold::Watch, this);
  }
  return true;
}

void PointerHold::Stop() { LetGo(false); }

void PointerHold::Renew() {
  if (!held_) {
    return;
  }
  if (!os_.in_front(window_)) {
    LetGo(true);
    return;
  }
  bool freed = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    freed = freed_;
    if (!freed) {
      last_renew_ms_ = os_.now_ms();
    }
  }
  if (freed) {
    // Too late: the watch freed the pointer. This is the window's thread,
    // back: the rest is done here, and the watch's message finds nothing.
    LetGo(true);
    return;
  }
  os_.clip(&point_);
}

void PointerHold::LetGo(bool by_itself) {
  if (!held_) {
    return;
  }
  const HWND window = window_;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    held_ = false;
    freed_ = false;
    window_ = nullptr;
  }
  os_.timer(window, 0);
  os_.clip(nullptr);
  if (hidden_) {
    os_.show(true);
    hidden_ = false;
  }
  os_.raw_mouse(window, false);
  dx_ = 0;
  dy_ = 0;
  reader_.Reset();
  if (by_itself && lost_) {
    lost_();
  }
}

void PointerHold::OnMouse(const RAWMOUSE& mouse) {
  if (!held_) {
    return;
  }
  const Movement by = reader_.Read(mouse, os_);
  dx_ = Within(dx_ + by.dx, kMostWaiting);
  dy_ = Within(dy_ + by.dy, kMostWaiting);
  if (os_.now_ms() - last_sent_ms_ >= kSendEveryMs) {
    Flush();
  }
}

void PointerHold::Flush() {
  if (!held_ || (dx_ == 0 && dy_ == 0)) {
    return;
  }
  const long dx = dx_;
  const long dy = dy_;
  dx_ = 0;
  dy_ = 0;
  last_sent_ms_ = os_.now_ms();
  if (moved_) {
    moved_(dx, dy);
  }
}

bool PointerHold::OnMessage(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  if (!held_ || window != window_) {
    return false;
  }
  switch (message) {
    case WM_INPUT: {
      RAWINPUT raw{};
      UINT size = sizeof(raw);
      if (::GetRawInputData(reinterpret_cast<HRAWINPUT>(lparam), RID_INPUT,
                            &raw, &size, sizeof(RAWINPUTHEADER)) !=
              static_cast<UINT>(-1) &&
          raw.header.dwType == RIM_TYPEMOUSE) {
        OnMouse(raw.data.mouse);
      }
      // Not done with: Windows cleans up after the message itself.
      return false;
    }
    case WM_TIMER:
      if (wparam == kFlushTimer) {
        Flush();
        return true;
      }
      return false;
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) {
        LetGo(true);
      }
      return false;
    case WM_ACTIVATEAPP:
      if (wparam == FALSE) {
        LetGo(true);
      }
      return false;
    case WM_ENTERMENULOOP:
    case WM_ENTERSIZEMOVE:
    case WM_DISPLAYCHANGE:
    case WM_DESTROY:
      LetGo(true);
      return false;
    default:
      break;
  }
  if (message == kExpiredMessage) {
    bool freed = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      freed = freed_;
    }
    // A message of a hold that ended meanwhile means nothing to this one.
    if (freed) {
      LetGo(true);
    }
    return true;
  }
  return false;
}

void PointerHold::Watch() {
  std::unique_lock<std::mutex> lock(mutex_);
  while (!quit_) {
    wake_.wait_for(lock, std::chrono::milliseconds(watch_every_ms_));
    if (quit_) {
      break;
    }
    if (!held_ || freed_) {
      continue;
    }
    const ULONGLONG now = os_.now_ms();
    if (now > last_renew_ms_ && now - last_renew_ms_ > kRenewWithinMs) {
      // The app said nothing for too long. The pointer is the person's
      // again now, whatever the window's thread is doing; the message is
      // for when that thread is back.
      freed_ = true;
      os_.clip(nullptr);
      os_.post(window_, kExpiredMessage);
    }
  }
}

}  // namespace pointer_hold
