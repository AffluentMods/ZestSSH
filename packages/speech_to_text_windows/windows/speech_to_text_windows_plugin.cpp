// speech_to_text_windows 1.0.1 (pub.dev, BSD-3-Clause, see LICENSE), vendored in ZestSSH and
// changed (CHANGELOG.md):
// - A recognised phrase goes to Dart as a map ({recognizedWords, finalResult}); the Dart side
//   writes speech_to_text's JSON with dart:convert. 1.0.1 pasted the words into a JSON string
//   unescaped, so a phrase with a quote mark was not valid JSON and was dropped.
// - Every call into Dart is posted to the platform thread (PostToPlatformThread). 1.0.1 called the
//   channel from its recognition thread when the registrar has no task runner (Flutter 3.50 has
//   none), which the engine warns about.
// - Nothing is printed: 1.0.1 printed every call, status and recognised phrase to stdout.
// - The recognition thread is joined when listening stops (1.0.1 detached it with a pointer to
//   the plugin), and the destructor no longer locks m_mutex twice.
#include "speech_to_text_windows_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <sapi.h>
#include <string>
#include <utility>

namespace speech_to_text_windows {

namespace {

// The message that carries a task (a heap std::function<void()>* in LPARAM) to the platform thread.
constexpr UINT kRunTaskMessage = WM_APP + 0x51;
constexpr wchar_t kDispatchWindowClass[] = L"SpeechToTextWindowsDispatchWindow";

LRESULT CALLBACK DispatchWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kRunTaskMessage) {
    std::unique_ptr<std::function<void()>> task(
        reinterpret_cast<std::function<void()>*>(lparam));
    if (task && *task) {
      (*task)();
    }
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// The module this code is in (the plugin's DLL), for its window class.
HINSTANCE PluginModule() {
  HMODULE module = nullptr;
  GetModuleHandleExW(
      GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
      reinterpret_cast<LPCWSTR>(&DispatchWindowProc), &module);
  return module;
}

// A message-only window on the calling thread. Each engine (every window the app opens has its
// own) registers its own plugin, and with it its own window; the class is registered once.
HWND CreateDispatchWindow() {
  HINSTANCE instance = PluginModule();
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = DispatchWindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kDispatchWindowClass;
  if (!RegisterClassExW(&window_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return nullptr;
  }
  return CreateWindowExW(0, kDispatchWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                         instance, nullptr);
}

// The words of a recognition result as UTF-8 in [text]; false when SAPI gives none.
bool ResultText(ISpRecoResult* result, std::string* text) {
  LPWSTR wide = nullptr;
  HRESULT hr = result->GetText(SP_GETWHOLEPHRASE, SP_GETWHOLEPHRASE, TRUE, &wide, NULL);
  if (FAILED(hr) || !wide) {
    return false;
  }
  bool converted = false;
  int size = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
  if (size > 0) {
    text->assign(size - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, &(*text)[0], size, nullptr, nullptr);
    converted = true;
  }
  CoTaskMemFree(wide);
  return converted;
}

}  // namespace

void SpeechToTextWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "speech_to_text_windows",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<SpeechToTextWindowsPlugin>();
  plugin->m_channel = std::move(channel);
  plugin->m_registrar = registrar;

  plugin->m_channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

SpeechToTextWindowsPlugin::SpeechToTextWindowsPlugin()
  : m_cpRecognizer(nullptr)
  , m_cpRecoContext(nullptr)
  , m_cpRecoGrammar(nullptr)
  , m_cpAudio(nullptr)
  , m_initialized(false)
  , m_listening(false)
  , m_dispatchWindow(nullptr)
  , m_registrar(nullptr) {
  CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  // Made on the platform thread: RegisterWithRegistrar runs there.
  m_dispatchWindow = CreateDispatchWindow();
}

SpeechToTextWindowsPlugin::~SpeechToTextWindowsPlugin() {
  {
    std::lock_guard<std::mutex> lock(m_mutex);

    // Joins the recognition thread, so nothing posts to the window after this.
    StopLocked();

    if (m_cpRecoGrammar) {
      m_cpRecoGrammar->Release();
      m_cpRecoGrammar = nullptr;
    }
    if (m_cpRecoContext) {
      m_cpRecoContext->Release();
      m_cpRecoContext = nullptr;
    }
    if (m_cpRecognizer) {
      m_cpRecognizer->Release();
      m_cpRecognizer = nullptr;
    }
    if (m_cpAudio) {
      m_cpAudio->Release();
      m_cpAudio = nullptr;
    }
  }

  if (m_dispatchWindow) {
    // Tasks still queued would call a channel that is going away: free them without running them.
    MSG message;
    while (PeekMessageW(&message, m_dispatchWindow, kRunTaskMessage, kRunTaskMessage, PM_REMOVE)) {
      delete reinterpret_cast<std::function<void()>*>(message.lParam);
    }
    DestroyWindow(m_dispatchWindow);
    m_dispatchWindow = nullptr;
  }

  CoUninitialize();
}

void SpeechToTextWindowsPlugin::PostToPlatformThread(std::function<void()> task) {
  if (!m_dispatchWindow) {
    return;
  }
  auto* posted = new std::function<void()>(std::move(task));
  if (!PostMessageW(m_dispatchWindow, kRunTaskMessage, 0, reinterpret_cast<LPARAM>(posted))) {
    delete posted;
  }
}

void SpeechToTextWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  const std::string& method_name = method_call.method_name();

  if (method_name == "hasPermission") {
    result->Success(flutter::EncodableValue(true));
  } else if (method_name == "initialize") {
    Initialize(method_call, std::move(result));
  } else if (method_name == "listen") {
    Listen(method_call, std::move(result));
  } else if (method_name == "stop") {
    Stop(std::move(result));
  } else if (method_name == "cancel") {
    Cancel(std::move(result));
  } else if (method_name == "locales") {
    GetLocales(std::move(result));
  } else {
    result->NotImplemented();
  }
}

void SpeechToTextWindowsPlugin::Initialize(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  std::lock_guard<std::mutex> lock(m_mutex);

  if (m_initialized) {
    result->Success(flutter::EncodableValue(true));
    return;
  }

  try {
    HRESULT hr = S_OK;

    // Create a recognition engine
    hr = CoCreateInstance(CLSID_SpInprocRecognizer, NULL, CLSCTX_INPROC_SERVER,
                         IID_ISpRecognizer, (void**)&m_cpRecognizer);
    if (FAILED(hr)) {
      result->Success(flutter::EncodableValue(false));
      return;
    }

    // Create default audio input
    hr = CoCreateInstance(CLSID_SpMMAudioIn, NULL, CLSCTX_INPROC_SERVER,
                         IID_ISpAudio, (void**)&m_cpAudio);
    if (FAILED(hr)) {
      result->Success(flutter::EncodableValue(false));
      return;
    }

    // Set the audio input to our recognizer
    hr = m_cpRecognizer->SetInput(m_cpAudio, TRUE);
    if (FAILED(hr)) {
      result->Success(flutter::EncodableValue(false));
      return;
    }

    // Create a recognition context
    hr = m_cpRecognizer->CreateRecoContext(&m_cpRecoContext);
    if (FAILED(hr)) {
      result->Success(flutter::EncodableValue(false));
      return;
    }

    // Create a grammar
    hr = m_cpRecoContext->CreateGrammar(0, &m_cpRecoGrammar);
    if (FAILED(hr)) {
      result->Success(flutter::EncodableValue(false));
      return;
    }

    // Enable dictation grammar
    hr = m_cpRecoGrammar->LoadDictation(NULL, SPLO_STATIC);
    if (FAILED(hr)) {
      result->Success(flutter::EncodableValue(false));
      return;
    }

    m_initialized = true;
    result->Success(flutter::EncodableValue(true));

  } catch (...) {
    result->Success(flutter::EncodableValue(false));
  }
}

void SpeechToTextWindowsPlugin::Listen(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  std::lock_guard<std::mutex> lock(m_mutex);

  if (!m_initialized || !m_cpRecoGrammar) {
    result->Error("NOT_INITIALIZED", "Speech recognition not initialized");
    return;
  }

  if (m_listening) {
    result->Success(flutter::EncodableValue(true));
    return;
  }

  try {
    // Activate the grammar
    HRESULT hr = m_cpRecoGrammar->SetDictationState(SPRS_ACTIVE);
    if (FAILED(hr)) {
      result->Success(flutter::EncodableValue(false));
      return;
    }

    // A thread from an earlier listen has ended (StopLocked joins it); this is only a guard.
    if (m_worker.joinable()) {
      m_worker.join();
    }

    m_listening = true;
    // Posted before the thread starts, so "listening" reaches Dart before any result.
    SendStatus("listening");
    m_worker = std::thread([this]() { RecognitionLoop(); });
    result->Success(flutter::EncodableValue(true));

  } catch (...) {
    // Only the thread's start can throw here, before the result is sent.
    if (m_listening.exchange(false)) {
      m_cpRecoGrammar->SetDictationState(SPRS_INACTIVE);
      SendStatus("notListening");
    }
    result->Success(flutter::EncodableValue(false));
  }
}

void SpeechToTextWindowsPlugin::RecognitionLoop() {
  SPEVENT event;
  ULONG fetched = 0;

  while (m_listening && m_cpRecoContext) {
    HRESULT hr = m_cpRecoContext->GetEvents(1, &event, &fetched);

    if (SUCCEEDED(hr) && fetched > 0) {
      switch (event.eEventId) {
        case SPEI_RECOGNITION:
        case SPEI_HYPOTHESIS: {
          ISpRecoResult* pResult = reinterpret_cast<ISpRecoResult*>(event.lParam);
          if (pResult) {
            std::string text;
            if (ResultText(pResult, &text)) {
              SendTextRecognition(text, event.eEventId == SPEI_RECOGNITION);
            }
            pResult->Release();
          }
          break;
        }
        case SPEI_SOUND_START:
          SendStatus("soundDetected");
          break;
        case SPEI_SOUND_END:
          SendStatus("soundEnded");
          break;
      }
    }

    Sleep(50); // Small delay to prevent busy waiting
  }
}

void SpeechToTextWindowsPlugin::StopLocked() {
  bool was_listening = m_listening.exchange(false);
  if (was_listening && m_cpRecoGrammar) {
    m_cpRecoGrammar->SetDictationState(SPRS_INACTIVE);
  }
  // The thread sees m_listening false within one turn of its loop (50 ms). It never takes
  // m_mutex, so joining with it held cannot wait on this thread.
  if (m_worker.joinable()) {
    m_worker.join();
  }
  if (was_listening && m_cpRecoGrammar) {
    SendStatus("notListening");
  }
}

void SpeechToTextWindowsPlugin::Stop(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  std::lock_guard<std::mutex> lock(m_mutex);
  StopLocked();

  if (result) {
    result->Success(flutter::EncodableValue(nullptr));
  }
}

void SpeechToTextWindowsPlugin::Cancel(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  Stop(std::move(result));
}

void SpeechToTextWindowsPlugin::GetLocales(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  flutter::EncodableList locales;
  locales.push_back(flutter::EncodableValue("en-US:English (United States)"));
  locales.push_back(flutter::EncodableValue("en-GB:English (United Kingdom)"));

  result->Success(flutter::EncodableValue(locales));
}

void SpeechToTextWindowsPlugin::SendTextRecognition(const std::string& text, bool is_final) {
  if (!m_channel) {
    return;
  }
  // The words as a string value of a map: the standard codec carries them as they are, and the
  // Dart side writes speech_to_text's JSON from it (lib/speech_to_text_windows.dart).
  flutter::EncodableMap recognition;
  recognition[flutter::EncodableValue("recognizedWords")] = flutter::EncodableValue(text);
  recognition[flutter::EncodableValue("finalResult")] = flutter::EncodableValue(is_final);

  auto channel = m_channel.get();
  PostToPlatformThread([channel, recognition]() {
    channel->InvokeMethod("textRecognition",
        std::make_unique<flutter::EncodableValue>(recognition));
  });
}

void SpeechToTextWindowsPlugin::SendError(const std::string& error) {
  if (!m_channel) {
    return;
  }
  auto channel = m_channel.get();
  PostToPlatformThread([channel, error]() {
    channel->InvokeMethod("notifyError",
        std::make_unique<flutter::EncodableValue>(error));
  });
}

void SpeechToTextWindowsPlugin::SendStatus(const std::string& status) {
  if (!m_channel) {
    return;
  }
  auto channel = m_channel.get();
  PostToPlatformThread([channel, status]() {
    channel->InvokeMethod("notifyStatus",
        std::make_unique<flutter::EncodableValue>(status));
  });
}

}  // namespace speech_to_text_windows

// C API export for Flutter plugin registration
extern "C" __declspec(dllexport) void SpeechToTextWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  speech_to_text_windows::SpeechToTextWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
