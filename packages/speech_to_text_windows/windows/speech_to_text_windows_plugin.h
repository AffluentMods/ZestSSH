// speech_to_text_windows 1.0.1 (pub.dev, BSD-3-Clause, see LICENSE), vendored in ZestSSH and
// changed: calls into Dart are posted to the platform thread through a message-only window, the
// recognition thread is joined when listening stops, results go to Dart as a map, and nothing is
// printed. CHANGELOG.md lists the changes.
#ifndef FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <sapi.h>
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>

namespace speech_to_text_windows {

class SpeechToTextWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  SpeechToTextWindowsPlugin();
  virtual ~SpeechToTextWindowsPlugin();

  SpeechToTextWindowsPlugin(const SpeechToTextWindowsPlugin&) = delete;
  SpeechToTextWindowsPlugin& operator=(const SpeechToTextWindowsPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Initialize(const flutter::MethodCall<flutter::EncodableValue> &method_call,
                 std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Listen(const flutter::MethodCall<flutter::EncodableValue> &method_call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Stop(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Cancel(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void GetLocales(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Stops listening and joins the recognition thread. The caller holds m_mutex.
  void StopLocked();
  // The recognition thread: reads SAPI's events until listening stops.
  void RecognitionLoop();

  void SendTextRecognition(const std::string& text, bool is_final = false);
  void SendError(const std::string& error);
  void SendStatus(const std::string& status);

  // Runs [task] on the platform thread: posted to m_dispatchWindow, whose window procedure runs
  // it. Safe from any thread while the plugin lives (the destructor joins the recognition thread
  // before it destroys the window).
  void PostToPlatformThread(std::function<void()> task);

  // SAPI Speech Recognition objects
  ISpRecognizer* m_cpRecognizer;
  ISpRecoContext* m_cpRecoContext;
  ISpRecoGrammar* m_cpRecoGrammar;
  ISpAudio* m_cpAudio;

  std::mutex m_mutex;
  bool m_initialized;
  std::atomic<bool> m_listening;
  std::thread m_worker;

  // A message-only window made on the platform thread (the plugin is made there), so a message
  // posted to it from any thread is handled on the platform thread.
  HWND m_dispatchWindow;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> m_channel;
  flutter::PluginRegistrarWindows* m_registrar;
};

}  // namespace speech_to_text_windows

// C API for Flutter plugin registration
extern "C" __declspec(dllexport) void SpeechToTextWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#endif  // FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_
