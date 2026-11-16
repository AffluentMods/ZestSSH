#include "flutter_window.h"

#include <commctrl.h>

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "injected_key_fix.h"
#include "single_instance.h"
#include <desktop_multi_window/desktop_multi_window_plugin.h>

namespace {
constexpr UINT_PTR kInjectedKeySubclassId = 1;

// The deep link channel's name, as DeepLinkService names it.
constexpr char kDeepLinkChannel[] = "com.affluentlabs.zestssh/deeplink";

// Links kept before Dart listens: a few, as Dart keeps (a page firing links
// by the hundred gets no more answered than these).
constexpr size_t kMaxPendingLinks = 8;

// Relative mouse's channels, as screen_pointer_hold.dart names them.
constexpr char kPointerCaptureChannel[] = "zestssh/pointer_capture";
constexpr char kPointerCaptureEvents[] = "zestssh/pointer_capture/events";
}  // namespace

LRESULT CALLBACK FlutterWindow::InjectedKeySubclassProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR ref_data) {
  // One repairer for the process: every Flutter view's messages arrive on
  // the UI thread, and the burst state (was there an injected key press
  // just now) is the same question whichever view is focused.
  static injected_key_fix::InjectedKeyRepairer repairer;
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(hwnd, &FlutterWindow::InjectedKeySubclassProc,
                         subclass_id);
  }
  return DefSubclassProc(
      hwnd, message, wparam,
      repairer.Repair(message, wparam, lparam, GetTickCount64()));
}

void FlutterWindow::RepairInjectedKeys(HWND flutter_view) {
  if (flutter_view == nullptr) {
    return;
  }
  SetWindowSubclass(flutter_view, &FlutterWindow::InjectedKeySubclassProc,
                    kInjectedKeySubclassId, 0);
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

// The window torn down while this object is whole. Quitting through
// windowManager.destroy() only posts WM_QUIT: the message loop in main.cpp
// ends with the window still open, and this object goes out of scope. With an
// empty destructor the flutter_controller_ member was then deleted by its own
// destructor, which keeps the pointer set while it deletes; deleting it
// destroys Flutter's child window, Windows sends this window a message, and
// MessageHandler handed it to the controller being deleted: a null read in
// flutter_windows.dll (0xc0000005, then 0xc000041d) on every exit, and a crash
// dump written each time (found 28 October 2026). Destroy() runs OnDestroy,
// which clears the pointer before the controller goes, then destroys the
// window.
FlutterWindow::~FlutterWindow() { Destroy(); }

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // The main window, for a second start to find and hand its link to. Only
  // this one: windows desktop_multi_window opens have their own class and
  // engines, and no deep link channel.
  single_instance::MarkMainWindow(GetHandle());
  deep_link_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kDeepLinkChannel,
          &flutter::StandardMethodCodec::GetInstance());
  deep_link_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "getInitialLink") {
          // The link this start was opened with comes to Dart on its
          // command line (lib/main.dart); none here. Dart listens from now
          // on: what was handed over meanwhile goes to it now.
          dart_listening_ = true;
          result->Success();
          std::vector<std::string> pending;
          pending.swap(pending_links_);
          for (const auto& link : pending) {
            OnHandedLink(link);
          }
          return;
        }
        result->NotImplemented();
      });

  SetUpPointerCapture();

  // Register plugin re-initialization for secondary (detached) windows.
  // desktop_multi_window creates child windows with their own Flutter engines;
  // this callback ensures those engines get all plugins registered.
  DesktopMultiWindowSetWindowCreatedCallback(
      [](void *flutter_view_controller) {
        auto *controller =
            reinterpret_cast<flutter::FlutterViewController *>(
                flutter_view_controller);
        RegisterPlugins(controller->engine());
        // Detached terminal windows paste too.
        FlutterWindow::RepairInjectedKeys(
            controller->view()->GetNativeWindow());
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Keyboard messages go to the view window, not to this one, so the
  // clipboard-history repair has to sit on the view.
  RepairInjectedKeys(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->shown_ = true;
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnHandedLink(const std::string& link) {
  if (dart_listening_ && deep_link_channel_) {
    deep_link_channel_->InvokeMethod(
        "onDeepLink", std::make_unique<flutter::EncodableValue>(link));
  } else if (pending_links_.size() < kMaxPendingLinks) {
    pending_links_.push_back(link);
  }
}

void FlutterWindow::SetUpPointerCapture() {
  using flutter::EncodableList;
  using flutter::EncodableValue;

  pointer_hold_ = std::make_unique<pointer_hold::PointerHold>(
      pointer_hold::SystemOs(),
      [this](long dx, long dy) {
        if (pointer_sink_) {
          pointer_sink_->Success(EncodableValue(EncodableList{
              EncodableValue(static_cast<int32_t>(dx)),
              EncodableValue(static_cast<int32_t>(dy)),
          }));
        }
      },
      [this]() {
        if (pointer_sink_) {
          pointer_sink_->Success(EncodableValue(std::string("lost")));
        }
      });

  pointer_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      flutter_controller_->engine()->messenger(), kPointerCaptureChannel,
      &flutter::StandardMethodCodec::GetInstance());
  pointer_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const std::string& method = call.method_name();
        if (method == "available") {
          result->Success(EncodableValue(true));
        } else if (method == "start") {
          result->Success(EncodableValue(
              pointer_hold_ != nullptr && pointer_hold_->Start(GetHandle())));
        } else if (method == "stop") {
          if (pointer_hold_) {
            pointer_hold_->Stop();
          }
          result->Success();
        } else if (method == "renew") {
          if (pointer_hold_) {
            pointer_hold_->Renew();
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  pointer_events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      flutter_controller_->engine()->messenger(), kPointerCaptureEvents,
      &flutter::StandardMethodCodec::GetInstance());
  pointer_events_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [this](const EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            pointer_sink_ = std::move(events);
            return nullptr;
          },
          [this](const EncodableValue* arguments)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            // Nobody listens any more (the app let go, or its code started
            // over): a pointer nobody listens to is not held.
            if (pointer_hold_) {
              pointer_hold_->Stop();
            }
            pointer_sink_ = nullptr;
            return nullptr;
          }));
}

void FlutterWindow::OnDestroy() {
  single_instance::UnmarkMainWindow(GetHandle());
  // The pointer first: given back before anything it reports to is gone.
  pointer_hold_ = nullptr;
  pointer_sink_ = nullptr;
  pointer_events_ = nullptr;
  pointer_channel_ = nullptr;
  deep_link_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // A second start of the app handing over its link (single_instance.h):
  // this window to the front, and the link to Dart.
  if (message == WM_COPYDATA) {
    if (std::optional<std::string> link =
            single_instance::LinkFromCopyData(lparam)) {
      if (shown_) {
        single_instance::BringToFront(hwnd);
      }
      if (!link->empty()) {
        OnHandedLink(*link);
      }
      return TRUE;
    }
  }

  // A held pointer (relative mouse) sees the window's messages first: the
  // mouse's raw movement, and every reason to give the pointer back.
  if (pointer_hold_ &&
      pointer_hold_->OnMessage(hwnd, message, wparam, lparam)) {
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
