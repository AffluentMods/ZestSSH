#ifndef RUNNER_VIEW_WINDOWS_H_
#define RUNNER_VIEW_WINDOWS_H_

#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter_windows.h>
#include <windows.h>

#include <map>
#include <memory>

// Windows of the app's own drawn by the main window's engine, each a view of
// it (a remote screen in a window of its own, 4.0). A second engine in the
// process, as desktop_multi_window opens, shares ANGLE's one Direct3D device
// with the first, and the two engines' threads drawing at once crashed in the
// graphics driver: one engine, drawing every window, never does.
//
// The channel zestssh/view_windows (lib/features/screens/window/view_windows.dart):
//   open {width, height}            -> {id, viewId}: a hidden window with a new view
//   place {id, x, y, width, height, title}: where it is and its title; shown
//   focus {id}, close {id}, fullScreen {id, on}, ids -> [id]
// and to Dart: closeRequested {id} when its person closes the window (Dart
// takes the view out of its tree, then asks close).
class ViewWindows {
 public:
  // For the engine of [main_controller], its messages on that engine.
  explicit ViewWindows(flutter::FlutterViewController* main_controller);
  ~ViewWindows();

  ViewWindows(const ViewWindows&) = delete;
  ViewWindows& operator=(const ViewWindows&) = delete;

  // The window procedure of every such window (registered with its class).
  static LRESULT CALLBACK WndProcThunk(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  struct Window {
    HWND top = nullptr;
    HWND child = nullptr;
    FlutterDesktopViewControllerRef controller = nullptr;
    // Full screen: the style and the place it had before.
    bool full_screen = false;
    LONG style_before = 0;
    WINDOWPLACEMENT placement_before{};
  };

  LRESULT Handle(int id, Window& w, HWND hwnd, UINT message, WPARAM wparam,
                 LPARAM lparam);

  void OnCall(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                  result);
  bool Open(int width, int height, int* id_out, int64_t* view_id_out);
  void Close(int id);
  void SetFullScreen(Window& w, bool on);

  FlutterDesktopEngineRef engine_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::map<int, Window> windows_;
  int next_id_ = 1000;
};

#endif  // RUNNER_VIEW_WINDOWS_H_
