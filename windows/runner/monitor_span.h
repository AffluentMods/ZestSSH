#ifndef RUNNER_MONITOR_SPAN_H_
#define RUNNER_MONITOR_SPAN_H_

#include <windows.h>

#include <vector>

// Remote screens (4.1): full screen on all monitors, the Windows part.
//
// An RDP screen in full screen can take every monitor of this PC: the remote
// is asked for one display per monitor, each the monitor's size and place
// (lib/features/screens/desktop/screen_span.dart), and the window covers them
// all. Windows' own full screen (and window_manager's) covers one monitor, so
// this part lists the monitors in their real pixels and stretches the window,
// borderless and on top, over the rectangle around those asked for; leaving
// puts back its style, its place and whether it was maximised.
//
// Over the channel zestssh/monitor_span: monitors, span, unspan.

namespace monitor_span {

struct Monitor {
  RECT rect;  // in physical pixels, on the virtual desktop
  UINT dpi;   // its effective DPI (96 = 100%)
  bool primary;
};

// This PC's monitors, the primary one first.
std::vector<Monitor> ListMonitors();

// The rectangle around [rects].
RECT Around(const std::vector<RECT>& rects);

class Span {
 public:
  // Stretches [window] over [area], borderless and on top. False where the
  // area is empty or Windows refused.
  bool Enter(HWND window, const RECT& area);

  // Puts the window back as it was. Nothing where it was not stretched.
  void Leave(HWND window);

  bool active() const { return active_; }

 private:
  bool active_ = false;
  LONG_PTR style_ = 0;
  LONG_PTR ex_style_ = 0;
  WINDOWPLACEMENT placement_{sizeof(WINDOWPLACEMENT)};
};

}  // namespace monitor_span

#endif  // RUNNER_MONITOR_SPAN_H_
