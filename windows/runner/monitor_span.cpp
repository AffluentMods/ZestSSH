#include "monitor_span.h"

#include <shellscalingapi.h>

#include <algorithm>

#pragma comment(lib, "shcore.lib")

namespace monitor_span {

namespace {

BOOL CALLBACK AddMonitor(HMONITOR handle, HDC, LPRECT, LPARAM data) {
  auto* out = reinterpret_cast<std::vector<Monitor>*>(data);
  MONITORINFO info{sizeof(MONITORINFO)};
  if (!GetMonitorInfoW(handle, &info)) {
    return TRUE;
  }
  UINT dpi_x = 96, dpi_y = 96;
  if (FAILED(GetDpiForMonitor(handle, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) {
    dpi_x = 96;
  }
  out->push_back(Monitor{info.rcMonitor, dpi_x, (info.dwFlags & MONITORINFOF_PRIMARY) != 0});
  return TRUE;
}

}  // namespace

std::vector<Monitor> ListMonitors() {
  std::vector<Monitor> monitors;
  EnumDisplayMonitors(nullptr, nullptr, AddMonitor, reinterpret_cast<LPARAM>(&monitors));
  std::stable_sort(monitors.begin(), monitors.end(),
                   [](const Monitor& a, const Monitor& b) { return a.primary && !b.primary; });
  return monitors;
}

RECT Around(const std::vector<RECT>& rects) {
  if (rects.empty()) {
    return RECT{0, 0, 0, 0};
  }
  RECT around = rects.front();
  for (const RECT& r : rects) {
    around.left = (std::min)(around.left, r.left);
    around.top = (std::min)(around.top, r.top);
    around.right = (std::max)(around.right, r.right);
    around.bottom = (std::max)(around.bottom, r.bottom);
  }
  return around;
}

bool Span::Enter(HWND window, const RECT& area) {
  if (window == nullptr || area.right <= area.left || area.bottom <= area.top) {
    return false;
  }
  if (!active_) {
    style_ = GetWindowLongPtrW(window, GWL_STYLE);
    ex_style_ = GetWindowLongPtrW(window, GWL_EXSTYLE);
    placement_.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(window, &placement_);
  }
  // From a plain window: a maximised one keeps its frame where it is.
  if (IsZoomed(window)) {
    ShowWindow(window, SW_RESTORE);
  }
  const LONG_PTR frame = WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU;
  SetWindowLongPtrW(window, GWL_STYLE, (style_ & ~frame) | WS_POPUP);
  const BOOL placed = SetWindowPos(window, HWND_TOPMOST, area.left, area.top, area.right - area.left,
                                   area.bottom - area.top, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  if (!placed) {
    active_ = true;
    Leave(window);
    return false;
  }
  active_ = true;
  return true;
}

void Span::Leave(HWND window) {
  if (!active_ || window == nullptr) {
    return;
  }
  active_ = false;
  SetWindowLongPtrW(window, GWL_STYLE, style_);
  SetWindowLongPtrW(window, GWL_EXSTYLE, ex_style_);
  const HWND order = (ex_style_ & WS_EX_TOPMOST) != 0 ? HWND_TOPMOST : HWND_NOTOPMOST;
  SetWindowPos(window, order, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED);
  SetWindowPlacement(window, &placement_);
}

}  // namespace monitor_span
