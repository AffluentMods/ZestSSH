#include "include/desktop_multi_window/desktop_multi_window_plugin.h"
#include "multi_window_plugin_internal.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <map>
#include <memory>

#include "multi_window_manager.h"

namespace {

class DesktopMultiWindowPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  DesktopMultiWindowPlugin();

  ~DesktopMultiWindowPlugin() override;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

// static
void DesktopMultiWindowPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "mixin.one/flutter_multi_window",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<DesktopMultiWindowPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

DesktopMultiWindowPlugin::DesktopMultiWindowPlugin() = default;

DesktopMultiWindowPlugin::~DesktopMultiWindowPlugin() = default;

void DesktopMultiWindowPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "createWindow") {
    auto args = std::get_if<std::string>(method_call.arguments());
    auto window_id = MultiWindowManager::Instance()->Create(args != nullptr ? *args : "");
    result->Success(flutter::EncodableValue(window_id));
    return;
  } else if (method_call.method_name() == "show") {
    auto window_id = method_call.arguments()->LongValue();
    MultiWindowManager::Instance()->Show(window_id);
    result->Success();
    return;
  } else if (method_call.method_name() == "hide") {
    auto window_id = method_call.arguments()->LongValue();
    MultiWindowManager::Instance()->Hide(window_id);
    result->Success();
    return;
  } else if (method_call.method_name() == "close") {
    auto window_id = method_call.arguments()->LongValue();
    MultiWindowManager::Instance()->Close(window_id);
    result->Success();
    return;
  } else if (method_call.method_name() == "setFrame") {
    auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id = arguments->at(flutter::EncodableValue("windowId")).LongValue();
    auto left = std::get<double_t>(arguments->at(flutter::EncodableValue("left")));
    auto top = std::get<double_t>(arguments->at(flutter::EncodableValue("top")));
    auto width = std::get<double_t>(arguments->at(flutter::EncodableValue("width")));
    auto height = std::get<double_t>(arguments->at(flutter::EncodableValue("height")));
    MultiWindowManager::Instance()->SetFrame(window_id, left, top, width, height);
    result->Success();
    return;
  } else if (method_call.method_name() == "center") {
    auto window_id = method_call.arguments()->LongValue();
    MultiWindowManager::Instance()->Center(window_id);
    result->Success();
    return;
  } else if (method_call.method_name() == "setTitle") {
    auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id = arguments->at(flutter::EncodableValue("windowId")).LongValue();
    auto title = std::get<std::string>(arguments->at(flutter::EncodableValue("title")));
    MultiWindowManager::Instance()->SetTitle(window_id, title);
    result->Success();
    return;
  } else if (method_call.method_name() == "setFullScreen") {
    auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (arguments == nullptr) {
      result->Error("bad_arguments", "setFullScreen takes a map");
      return;
    }
    auto id = arguments->find(flutter::EncodableValue("windowId"));
    auto full = arguments->find(flutter::EncodableValue("fullScreen"));
    if (id == arguments->end() || full == arguments->end() || !std::holds_alternative<bool>(full->second)) {
      result->Error("bad_arguments", "setFullScreen takes windowId and fullScreen");
      return;
    }
    MultiWindowManager::Instance()->SetFullScreen(id->second.LongValue(), std::get<bool>(full->second));
    result->Success();
    return;
  } else if (method_call.method_name() == "getAllSubWindowIds") {
    auto window_ids = MultiWindowManager::Instance()->GetAllSubWindowIds();
    result->Success(window_ids);
    return;
  }
  result->NotImplemented();
}

}  // namespace

void DesktopMultiWindowPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {

  InternalMultiWindowPluginRegisterWithRegistrar(registrar);

  // ZestSSH patch: only attach the MAIN window once.
  //
  // This public registrar is what the app's generated RegisterPlugins() calls,
  // and the app runs RegisterPlugins() for every SUB-window engine too (via
  // DesktopMultiWindowSetWindowCreatedCallback), so that the sub-windows get
  // every other plugin. Upstream unconditionally builds a WindowChannel(id 0)
  // here and hands it to AttachFlutterMainWindow, which early-returns when
  // window 0 already exists and discards the channel. Its constructor had
  // already re-bound "mixin.one/flutter_multi_window_channel" on the
  // sub-window's engine, and its destructor then set that binding to nullptr,
  // killing the sub-window's REAL inter-window channel (registered moments
  // earlier in FlutterWindow's constructor). Every child->main invokeMethod
  // then failed with MissingPluginException, so a popped-out editor could not
  // even fetch its file and a detached terminal could not send input.
  // Checking BEFORE creating the channel avoids the throwaway object entirely.
  if (MultiWindowManager::Instance()->HasMainWindow()) {
    return;
  }

  // Attach MainWindow for
  auto hwnd = FlutterDesktopViewGetHWND(FlutterDesktopPluginRegistrarGetView(registrar));
  auto channel = WindowChannel::RegisterWithRegistrar(registrar, 0);
  MultiWindowManager::Instance()->AttachFlutterMainWindow(GetAncestor(hwnd, GA_ROOT),
                                                          std::move(channel));
}

void InternalMultiWindowPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  DesktopMultiWindowPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
