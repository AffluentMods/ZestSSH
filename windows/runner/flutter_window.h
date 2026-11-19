#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <vector>

#include "pointer_hold.h"
#include "view_windows.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 public:
  // Subclasses a Flutter view's window so key messages injected without a
  // scan code (the Win+V clipboard history paste) reach the engine repaired.
  // Public so the detached-window callback and the view windows
  // (view_windows.cpp) can apply it to secondary views.
  static void RepairInjectedKeys(HWND flutter_view);

 private:
  static LRESULT CALLBACK InjectedKeySubclassProc(HWND hwnd, UINT message,
                                                  WPARAM wparam, LPARAM lparam,
                                                  UINT_PTR subclass_id,
                                                  DWORD_PTR ref_data);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // A link a second start of the app handed over (single_instance.h): to
  // Dart now, or kept until Dart listens.
  void OnHandedLink(const std::string& link);

  // The deep link channel (lib/services/deep_link_service.dart): Dart asks
  // getInitialLink as it starts listening, and is told onDeepLink.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      deep_link_channel_;

  // Links handed over before Dart listened (the app was starting), in order.
  std::vector<std::string> pending_links_;
  bool dart_listening_ = false;

  // Whether the first frame showed the window: before it, a link handed
  // over does not show an empty window (the first frame shows it).
  bool shown_ = false;

  // Relative mouse on a remote screen (pointer_hold.h): the channel
  // zestssh/pointer_capture (available, start, stop, renew) and its events
  // (movement as [dx, dy], and "lost" when the hold let go by itself), as
  // lib/features/screens/view/screen_pointer_hold.dart names them. Only this
  // window has it: a window desktop_multi_window opens answers "not
  // available".
  void SetUpPointerCapture();
  std::unique_ptr<pointer_hold::PointerHold> pointer_hold_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      pointer_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      pointer_events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> pointer_sink_;

  // Windows of the app's own drawn by this window's engine, a view each
  // (view_windows.h): a remote screen in a window of its own.
  std::unique_ptr<ViewWindows> view_windows_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
