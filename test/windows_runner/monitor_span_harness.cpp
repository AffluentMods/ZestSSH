// The Windows runner's monitor_span.cpp (full screen on all monitors), built
// on its own and driven by test/windows_runner/monitor_span_runner_test.dart.
// Only what reads: the rectangle around monitors, and this PC's monitors as
// Windows lists them. No window is moved here (a test that stretched a
// window over the monitors of the PC it runs on would cover its person's
// screens).
//
//   harness.exe            runs the checks; exit code 0 where all hold

#include <windows.h>

#include <cstdio>
#include <vector>

#include "monitor_span.h"

#pragma comment(lib, "user32.lib")

namespace {

int g_failures = 0;

void Check(bool ok, const char* what) {
  std::printf("%s: %s\n", ok ? "ok" : "FAILED", what);
  if (!ok) {
    ++g_failures;
  }
}

bool Same(const RECT& a, const RECT& b) {
  return a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom;
}

}  // namespace

int main() {
  using monitor_span::Around;
  Check(Same(Around({}), RECT{0, 0, 0, 0}), "no monitors: an empty rectangle");
  Check(Same(Around({RECT{0, 0, 1920, 1080}, RECT{1920, 0, 3840, 1080}}), RECT{0, 0, 3840, 1080}),
        "two side by side: the rectangle around both");
  Check(Same(Around({RECT{0, 0, 2560, 1440}, RECT{-1920, 200, 0, 1280}}), RECT{-1920, 0, 2560, 1440}),
        "one to the left of the primary, lower and smaller: from its left edge, the primary's top to the taller's "
        "bottom");
  Check(Same(Around({RECT{0, 0, 1920, 1080}, RECT{0, -1080, 1920, 0}}), RECT{0, -1080, 1920, 1080}),
        "one above the primary: its negative top is kept");

  monitor_span::Span span;
  Check(!span.Enter(nullptr, RECT{0, 0, 10, 10}) && !span.active(), "no window: nothing is stretched");
  Check(!span.Enter(reinterpret_cast<HWND>(1), RECT{10, 10, 10, 10}) && !span.active(),
        "an empty area: nothing is stretched");
  span.Leave(nullptr);
  Check(!span.active(), "leaving when not stretched does nothing");

  const auto monitors = monitor_span::ListMonitors();
  int primaries = 0;
  bool sizes = !monitors.empty();
  for (const auto& m : monitors) {
    primaries += m.primary ? 1 : 0;
    sizes = sizes && m.rect.right > m.rect.left && m.rect.bottom > m.rect.top && m.dpi >= 72;
  }
  Check(!monitors.empty() && primaries == 1 && monitors.front().primary,
        "the real Windows: at least one monitor, one primary, listed first");
  Check(sizes, "the real Windows: each monitor has a size and a DPI");

  if (g_failures == 0) {
    std::printf("all hold\n");
  }
  return g_failures == 0 ? 0 : 1;
}
