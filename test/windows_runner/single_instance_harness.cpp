// The Windows runner's single_instance.cpp, built on its own with names no
// ZestSSH uses (ZEST_SINGLE_INSTANCE_TEST), and driven by
// test/windows_runner/single_instance_runner_test.dart. Never finds, nor is
// found by, a ZestSSH that runs.
//
//   harness.exe test       runs the checks; exit code 0 where all hold
//   harness.exe window     a marked window that takes any link (the stand-in
//                          for another program's), until it is ended
//
// Found in a security review: a second
// start handed its link to any window with the mark, whoever made it.

#include <windows.h>
#include <sddl.h>

#include <cstdio>
#include <string>
#include <vector>

#include "single_instance.h"

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "advapi32.lib")

// What utils.cpp gives the runner (it needs the Flutter library).
std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  const int length = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                           utf16_string, -1, nullptr, 0,
                                           nullptr, nullptr);
  if (length <= 1) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(length - 1), '\0');
  ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string, -1,
                        utf8.data(), length, nullptr, nullptr);
  return utf8;
}

namespace {

constexpr wchar_t kTag[] = L"ZestSSH.MainWindow.Test";
int g_failures = 0;
int g_links_taken = 0;

void Check(bool ok, const char* what) {
  std::printf("%s: %s\n", ok ? "ok" : "FAILED", what);
  if (!ok) {
    ++g_failures;
  }
}

LRESULT CALLBACK TakesLinks(HWND hwnd, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  if (message == WM_COPYDATA) {
    if (single_instance::LinkFromCopyData(lparam).has_value()) {
      ++g_links_taken;
      return TRUE;
    }
    return FALSE;
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

HWND MakeMarkedWindow() {
  WNDCLASSW wc{};
  wc.lpfnWndProc = TakesLinks;
  wc.hInstance = ::GetModuleHandleW(nullptr);
  wc.lpszClassName = L"ZestSSHSingleInstanceHarness";
  ::RegisterClassW(&wc);
  HWND hwnd = ::CreateWindowExW(0, wc.lpszClassName, L"harness",
                                WS_OVERLAPPED, 0, 0, 10, 10, nullptr, nullptr,
                                wc.hInstance, nullptr);
  single_instance::MarkMainWindow(hwnd);
  return hwnd;
}

std::wstring OwnPath() {
  std::wstring path(32768, L'\0');
  const DWORD n = ::GetModuleFileNameW(nullptr, path.data(),
                                       static_cast<DWORD>(path.size()));
  path.resize(n);
  return path;
}

// Starts |exe| as "window", at low integrity where |low|.
PROCESS_INFORMATION StartWindow(const std::wstring& exe, bool low) {
  PROCESS_INFORMATION pi{};
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  std::wstring command = L"\"" + exe + L"\" window";
  if (!low) {
    ::CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE, 0,
                     nullptr, nullptr, &si, &pi);
    return pi;
  }
  HANDLE own = nullptr;
  HANDLE token = nullptr;
  PSID sid = nullptr;
  if (::OpenProcessToken(::GetCurrentProcess(),
                         TOKEN_DUPLICATE | TOKEN_QUERY |
                             TOKEN_ADJUST_DEFAULT | TOKEN_ASSIGN_PRIMARY,
                         &own) &&
      ::DuplicateTokenEx(own, 0, nullptr, SecurityImpersonation, TokenPrimary,
                         &token) &&
      ::ConvertStringSidToSidW(L"S-1-16-4096", &sid)) {
    TOKEN_MANDATORY_LABEL label{};
    label.Label.Attributes = SE_GROUP_INTEGRITY;
    label.Label.Sid = sid;
    if (::SetTokenInformation(token, TokenIntegrityLevel, &label,
                              sizeof(label) + ::GetLengthSid(sid))) {
      ::CreateProcessAsUserW(token, exe.c_str(), command.data(), nullptr,
                             nullptr, FALSE, 0, nullptr, nullptr, &si, &pi);
    }
  }
  if (sid != nullptr) ::LocalFree(sid);
  if (token != nullptr) ::CloseHandle(token);
  if (own != nullptr) ::CloseHandle(own);
  return pi;
}

struct Search {
  DWORD pid;
  bool found;
};

BOOL CALLBACK FindMarkedOf(HWND hwnd, LPARAM lparam) {
  auto* search = reinterpret_cast<Search*>(lparam);
  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid == search->pid && ::GetPropW(hwnd, kTag) != nullptr) {
    search->found = true;
    return FALSE;
  }
  return TRUE;
}

// Waits for |pid|'s marked window.
bool WaitForWindowOf(DWORD pid) {
  for (int i = 0; i < 100; ++i) {
    Search search{pid, false};
    ::EnumWindows(FindMarkedOf, reinterpret_cast<LPARAM>(&search));
    if (search.found) {
      return true;
    }
    ::Sleep(100);
  }
  return false;
}

void End(PROCESS_INFORMATION& pi) {
  if (pi.hProcess != nullptr) {
    ::TerminateProcess(pi.hProcess, 0);
    ::WaitForSingleObject(pi.hProcess, 5000);
    ::CloseHandle(pi.hProcess);
    ::CloseHandle(pi.hThread);
  }
}

// Whether a link is handed over while |pi|'s marked window is the only one.
bool HandedTo(PROCESS_INFORMATION& pi) {
  if (pi.hProcess == nullptr || !WaitForWindowOf(pi.dwProcessId)) {
    std::printf("FAILED: the stand-in window did not start\n");
    ++g_failures;
    return false;
  }
  return single_instance::HandToRunningInstance("zestssh://connect?id=t");
}

int RunChecks() {
  // This program's own window, in this process: taken.
  HWND own = MakeMarkedWindow();
  Check(single_instance::HandToRunningInstance("zestssh://connect?id=a") &&
            g_links_taken == 1,
        "a window of this very program takes the link");
  single_instance::UnmarkMainWindow(own);
  ::DestroyWindow(own);

  // Another program's marked window: passed over.
  const std::wstring self = OwnPath();
  const std::wstring other =
      self.substr(0, self.find_last_of(L'\\') + 1) + L"other.exe";
  ::CopyFileW(self.c_str(), other.c_str(), FALSE);
  PROCESS_INFORMATION foreign = StartWindow(other, false);
  Check(!HandedTo(foreign),
        "a marked window of another program is handed nothing");
  End(foreign);

  // This program at low integrity (as a sandboxed app could start it): passed over.
  PROCESS_INFORMATION low = StartWindow(self, true);
  Check(!HandedTo(low),
        "a marked window at a lower integrity level is handed nothing");
  End(low);

  // This program, another process, as it runs: taken.
  PROCESS_INFORMATION same = StartWindow(self, false);
  Check(HandedTo(same), "another running copy of this program takes the link");
  End(same);

  ::DeleteFileW(other.c_str());
  return g_failures == 0 ? 0 : 1;
}

int RunWindow() {
  MakeMarkedWindow();
  ::SetTimer(nullptr, 0, 60000, nullptr);
  MSG msg;
  while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
    if (msg.message == WM_TIMER) {
      break;
    }
    ::DispatchMessageW(&msg);
  }
  return 0;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc > 1 && std::wstring(argv[1]) == L"window") {
    return RunWindow();
  }
  if (argc > 1 && std::wstring(argv[1]) == L"test") {
    return RunChecks();
  }
  std::printf("usage: harness test | harness window\n");
  return 2;
}
