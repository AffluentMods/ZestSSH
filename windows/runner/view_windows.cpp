#include "view_windows.h"

#include <flutter/standard_method_codec.h>

#include <string>

#include "flutter_window.h"
#include "resource.h"

// The view controller API for a view of a running engine: exported by
// flutter_windows.dll (flutter_windows_internal.h in the engine), not yet in
// the public header the app builds against.
extern "C" {
typedef struct {
  int width;
  int height;
} FlutterDesktopViewControllerProperties;

FLUTTER_EXPORT FlutterDesktopViewControllerRef
FlutterDesktopEngineCreateViewController(
    FlutterDesktopEngineRef engine,
    const FlutterDesktopViewControllerProperties* properties);
}

namespace {

constexpr char kChannel[] = "zestssh/view_windows";
constexpr wchar_t kWindowClass[] = L"ZESTSSH_VIEW_WINDOW";

// The one manager of the process (the main window makes it), for the
// window procedure to find.
ViewWindows* g_view_windows = nullptr;

// The C API's handle of the main window's view controller, held privately
// by the C++ wrapper: read through an explicit instantiation, which the
// language exempts from access checks.
template <typename Tag, typename Tag::type Member>
struct Reader {
  friend typename Tag::type Get(Tag) { return Member; }
};
struct ControllerHandle {
  using type = FlutterDesktopViewControllerRef flutter::FlutterViewController::*;
  friend type Get(ControllerHandle);
};
template struct Reader<ControllerHandle, &flutter::FlutterViewController::controller_>;

FlutterDesktopViewControllerRef RawController(
    flutter::FlutterViewController* controller) {
  return controller->*Get(ControllerHandle());
}

const flutter::EncodableValue* Arg(const flutter::EncodableMap& map,
                                   const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

int IntArg(const flutter::EncodableMap& map, const char* key, int otherwise) {
  const flutter::EncodableValue* v = Arg(map, key);
  if (v == nullptr) return otherwise;
  if (const int32_t* i = std::get_if<int32_t>(v)) return *i;
  if (const int64_t* l = std::get_if<int64_t>(v)) return static_cast<int>(*l);
  if (const double* d = std::get_if<double>(v)) return static_cast<int>(*d);
  return otherwise;
}

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                              static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      out.data(), n);
  return out;
}

void RegisterClassOnce() {
  static bool registered = false;
  if (registered) return;
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.lpszClassName = kWindowClass;
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.hInstance = GetModuleHandle(nullptr);
  // The app's own icon in the title bar and the taskbar (a window of the
  // plugin's had the system's default one).
  wc.hIcon = LoadIcon(wc.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
  wc.hIconSm = wc.hIcon;
  wc.hbrBackground = CreateSolidBrush(RGB(0x0A, 0x0A, 0x0A));
  wc.lpfnWndProc = ViewWindows::WndProcThunk;
  RegisterClassExW(&wc);
  registered = true;
}

}  // namespace

ViewWindows::ViewWindows(flutter::FlutterViewController* main_controller) {
  engine_ = FlutterDesktopViewControllerGetEngine(RawController(main_controller));
  g_view_windows = this;
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      main_controller->engine()->messenger(), kChannel,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { OnCall(call, std::move(result)); });
}

ViewWindows::~ViewWindows() {
  channel_ = nullptr;
  while (!windows_.empty()) {
    Close(windows_.begin()->first);
  }
  g_view_windows = nullptr;
}

LRESULT CALLBACK ViewWindows::WndProcThunk(HWND hwnd, UINT message,
                                           WPARAM wparam, LPARAM lparam) {
  const int id = static_cast<int>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (g_view_windows != nullptr && id != 0) {
    auto it = g_view_windows->windows_.find(id);
    if (it != g_view_windows->windows_.end() && it->second.top == hwnd) {
      return g_view_windows->Handle(id, it->second, hwnd, message, wparam,
                                    lparam);
    }
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT ViewWindows::Handle(int id, Window& w, HWND hwnd, UINT message,
                            WPARAM wparam, LPARAM lparam) {
  // Not given to the plugins' top-level window handlers
  // (FlutterDesktopViewControllerHandleTopLevelWindowProc): those are the
  // main window's (window_manager's close, frame, minimum size, focus and
  // DPI), and none of them asks which window a message is for, so this
  // window's close ran the main window's and its frame lost its title bar.
  // The view's own window takes its size, focus and DPI messages itself.
  switch (message) {
    case WM_SIZE: {
      RECT rect;
      GetClientRect(hwnd, &rect);
      if (w.child != nullptr) {
        MoveWindow(w.child, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }
    case WM_ACTIVATE:
      if (w.child != nullptr && LOWORD(wparam) != WA_INACTIVE) {
        SetFocus(w.child);
      }
      return 0;
    case WM_DPICHANGED: {
      auto* suggested = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(hwnd, nullptr, suggested->left, suggested->top,
                   suggested->right - suggested->left,
                   suggested->bottom - suggested->top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    case WM_CLOSE:
      // Dart takes the view out of what it draws, then asks close: the
      // window is not destroyed under a view still being drawn.
      if (channel_) {
        flutter::EncodableMap args{
            {flutter::EncodableValue("id"), flutter::EncodableValue(id)}};
        channel_->InvokeMethod(
            "closeRequested",
            std::make_unique<flutter::EncodableValue>(std::move(args)));
      }
      return 0;
    default:
      break;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

bool ViewWindows::Open(int width, int height, int* id_out,
                       int64_t* view_id_out) {
  if (engine_ == nullptr) return false;
  RegisterClassOnce();
  const int id = next_id_++;
  HWND top = CreateWindowExW(0, kWindowClass, L"ZestSSH", WS_OVERLAPPEDWINDOW,
                             CW_USEDEFAULT, CW_USEDEFAULT, width, height,
                             nullptr, nullptr, GetModuleHandle(nullptr),
                             nullptr);
  if (top == nullptr) return false;
  SetWindowLongPtr(top, GWLP_USERDATA, static_cast<LONG_PTR>(id));
  RECT client;
  GetClientRect(top, &client);
  FlutterDesktopViewControllerProperties props{client.right - client.left,
                                                client.bottom - client.top};
  FlutterDesktopViewControllerRef controller =
      FlutterDesktopEngineCreateViewController(engine_, &props);
  if (controller == nullptr) {
    DestroyWindow(top);
    return false;
  }
  HWND child = FlutterDesktopViewGetHWND(
      FlutterDesktopViewControllerGetView(controller));
  SetParent(child, top);
  SetWindowLongPtr(child, GWL_STYLE,
                   (GetWindowLongPtr(child, GWL_STYLE) | WS_CHILD | WS_VISIBLE) &
                       ~WS_POPUP);
  MoveWindow(child, 0, 0, client.right - client.left,
             client.bottom - client.top, TRUE);
  // Win+V's clipboard history paste, as in the main window's view.
  FlutterWindow::RepairInjectedKeys(child);
  Window w;
  w.top = top;
  w.child = child;
  w.controller = controller;
  windows_[id] = w;
  *id_out = id;
  *view_id_out = FlutterDesktopViewControllerGetViewId(controller);
  return true;
}

void ViewWindows::Close(int id) {
  auto it = windows_.find(id);
  if (it == windows_.end()) return;
  Window w = it->second;
  windows_.erase(it);
  // The view first (it goes from the engine with its own window), then the
  // window that held it.
  if (w.controller != nullptr) {
    FlutterDesktopViewControllerDestroy(w.controller);
  }
  if (w.top != nullptr) {
    DestroyWindow(w.top);
  }
}

void ViewWindows::SetFullScreen(Window& w, bool on) {
  if (on == w.full_screen) return;
  HWND hwnd = w.top;
  if (on) {
    w.style_before = GetWindowLong(hwnd, GWL_STYLE);
    w.placement_before.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(hwnd, &w.placement_before);
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
    SetWindowLong(hwnd, GWL_STYLE, w.style_before & ~WS_OVERLAPPEDWINDOW);
    SetWindowPos(hwnd, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
                 monitor.rcMonitor.right - monitor.rcMonitor.left,
                 monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    SetWindowLong(hwnd, GWL_STYLE, w.style_before);
    SetWindowPlacement(hwnd, &w.placement_before);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                     SWP_FRAMECHANGED);
  }
  w.full_screen = on;
}

void ViewWindows::OnCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  static const flutter::EncodableMap kEmpty;
  const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableMap& args = map != nullptr ? *map : kEmpty;

  if (method == "open") {
    int id = 0;
    int64_t view_id = 0;
    if (!Open(IntArg(args, "width", 1100), IntArg(args, "height", 720), &id,
              &view_id)) {
      result->Error("open-failed", "The window could not be opened");
      return;
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("id"), flutter::EncodableValue(id)},
        {flutter::EncodableValue("viewId"), flutter::EncodableValue(view_id)},
    }));
    return;
  }
  if (method == "ids") {
    flutter::EncodableList ids;
    for (const auto& entry : windows_) {
      ids.push_back(flutter::EncodableValue(entry.first));
    }
    result->Success(flutter::EncodableValue(ids));
    return;
  }
  const int id = IntArg(args, "id", 0);
  auto it = windows_.find(id);
  if (method == "close") {
    Close(id);
    result->Success();
    return;
  }
  if (it == windows_.end()) {
    result->Error("no-window", "No such window");
    return;
  }
  Window& w = it->second;
  if (method == "place") {
    const flutter::EncodableValue* title = Arg(args, "title");
    if (title != nullptr) {
      if (const std::string* s = std::get_if<std::string>(title)) {
        SetWindowTextW(w.top, Wide(*s).c_str());
      }
    }
    // Logical pixels as Dart gives them, made the monitor's own.
    UINT dpi = GetDpiForWindow(w.top);
    const double scale = dpi / 96.0;
    SetWindowPos(w.top, nullptr,
                 static_cast<int>(IntArg(args, "x", 0) * scale),
                 static_cast<int>(IntArg(args, "y", 0) * scale),
                 static_cast<int>(IntArg(args, "width", 1100) * scale),
                 static_cast<int>(IntArg(args, "height", 720) * scale),
                 SWP_NOZORDER);
    ShowWindow(w.top, SW_SHOWNORMAL);
    SetForegroundWindow(w.top);
    result->Success();
  } else if (method == "focus") {
    if (IsIconic(w.top)) ShowWindow(w.top, SW_RESTORE);
    ShowWindow(w.top, SW_SHOW);
    SetForegroundWindow(w.top);
    result->Success();
  } else if (method == "fullScreen") {
    const flutter::EncodableValue* on = Arg(args, "on");
    const bool* b = on != nullptr ? std::get_if<bool>(on) : nullptr;
    SetFullScreen(w, b != nullptr && *b);
    result->Success();
  } else {
    result->NotImplemented();
  }
}
