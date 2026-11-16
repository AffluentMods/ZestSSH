#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "single_instance.h"
#include "utils.h"

// Forcing the discrete GPU fixes a cross-adapter black screen on some
// hybrid-GPU PCs (the app's Direct3D device lands on the wrong adapter and a
// resize rebuilds the swapchain across GPUs, which ANGLE cannot survive). But
// it also spins up the power-hungry dGPU on every laptop and writes a system
// setting, so it is a poor default and is gated OFF here. Set this to 1 (later,
// a hidden / opt-in Setting) to re-enable both the driver exports and the
// per-app registry preference below.
#define ZEST_FORCE_HIGH_PERF_GPU 0

extern "C" {
__declspec(dllexport) DWORD NvOptimusEnablement = ZEST_FORCE_HIGH_PERF_GPU;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance =
    ZEST_FORCE_HIGH_PERF_GPU;
}

#if ZEST_FORCE_HIGH_PERF_GPU
// Belt-and-braces for the export above: some desktops (an enabled iGPU that
// drives no display, with the real monitor on the discrete card) ignore the
// driver export and only honour the per-app "High performance" choice in
// Windows' Graphics settings, which is just this registry value. Write it for
// our own exe if it is not already set, so the discrete GPU is chosen on the
// NEXT launch without the user touching Settings. HKCU, no admin needed, and
// we never overwrite a value the user set themselves.
static void EnsureHighPerformanceGpuPreference() {
  wchar_t exe_path[MAX_PATH];
  DWORD len = GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return;
  }
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\DirectX\\UserGpuPreferences", 0,
                      nullptr, 0, KEY_READ | KEY_WRITE, nullptr, &key,
                      nullptr) != ERROR_SUCCESS) {
    return;
  }
  if (RegQueryValueExW(key, exe_path, nullptr, nullptr, nullptr, nullptr) !=
      ERROR_SUCCESS) {
    // GpuPreference=2 means "High performance" (the discrete GPU).
    const wchar_t* value = L"GpuPreference=2;";
    RegSetValueExW(key, exe_path, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(value),
                   static_cast<DWORD>((wcslen(value) + 1) * sizeof(wchar_t)));
  }
  RegCloseKey(key);
}
#endif  // ZEST_FORCE_HIGH_PERF_GPU

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
#if ZEST_FORCE_HIGH_PERF_GPU
  EnsureHighPerformanceGpuPreference();
#endif

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // One ZestSSH per Windows session: a second start (a zestssh:// link
  // clicked in a browser, the Start menu again) hands its link to the one
  // running, which comes to the front, and ends here. Where the running one
  // does not answer within a few seconds, this one starts as before, its
  // link with it. A terminal command (zestssh admin ...) runs on its own.
  if (!single_instance::RunsOnItsOwn(command_line_arguments) &&
      single_instance::AnotherIsRunning() &&
      single_instance::HandToRunningInstance(
          single_instance::LinkArgument(command_line_arguments))) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  bool hasParentConsole = ::AttachConsole(ATTACH_PARENT_PROCESS);
  if (!hasParentConsole && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // When running standalone (not via 'flutter run'), prevent the console
  // from intercepting Ctrl+C so it reaches the terminal emulator instead.
  // Skip this when attached to a parent console (flutter run) to keep the
  // debug connection alive.
  if (!hasParentConsole) {
    ::SetConsoleCtrlHandler(NULL, TRUE);
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"ZestSSH", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // The app has closed: what it keeps was saved before it asked for this
  // (its closing steps, then destroyAppWindow, which takes the tray icon
  // away). The process ends here. Tearing the Flutter engine down instead
  // waits for every Dart isolate to stop, the database's and the sessions'
  // among them, and a native thread that calls into one of them meanwhile
  // makes the Dart VM abort: every close of 3.2.6 left a crash report
  // (0xc0000409, FAST_FAIL_FATAL_APP_EXIT in dart::Assert::Fail under
  // DLRT_GetFfiCallbackMetadata, 28 October 2026), where 3.2.5 had crashed
  // a step earlier. Nothing is left to do that the end of the process does
  // not do.
  ::TerminateProcess(::GetCurrentProcess(), EXIT_SUCCESS);

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
