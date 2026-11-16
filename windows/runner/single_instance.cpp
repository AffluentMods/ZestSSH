#include "single_instance.h"

#include <appmodel.h>

#include <cwchar>

#include "utils.h"

#pragma comment(lib, "advapi32.lib")

namespace single_instance {

namespace {

// A debug build (flutter run) is its own app beside an installed ZestSSH:
// it neither hands its start to the installed one nor takes the installed
// one's links. The runner's own test (test/windows_runner) uses names no
// ZestSSH uses, so it never finds, or is found by, one that runs.
#if defined(ZEST_SINGLE_INSTANCE_TEST)
constexpr wchar_t kMutexName[] = L"Local\\ZestSSH.SingleInstance.Test";
constexpr wchar_t kWindowTag[] = L"ZestSSH.MainWindow.Test";
#elif defined(_DEBUG)
constexpr wchar_t kMutexName[] = L"Local\\ZestSSH.SingleInstance.Debug";
constexpr wchar_t kWindowTag[] = L"ZestSSH.MainWindow.Debug";
#else
constexpr wchar_t kMutexName[] = L"Local\\ZestSSH.SingleInstance";
constexpr wchar_t kWindowTag[] = L"ZestSSH.MainWindow";
#endif

constexpr char kScheme[] = "zestssh://";

// How long a second start looks for the running one's window, and how long
// it waits for that window to take the link.
constexpr int kFindTries = 50;
constexpr DWORD kFindPauseMs = 100;
constexpr UINT kSendTimeoutMs = 5000;

// ZestSSH from the Microsoft Store: its package's family name
// (lib/services/store_handover.dart, StoreHandover.packageFamily).
constexpr wchar_t kStorePackageFamily[] = L"AffluentLabs.ZestSSH_a13075jvne08e";

// ZestSSH from zestssh.com: its installer's uninstall entry (the AppId of
// installer/zestssh_setup.iss; StoreHandover.uninstallKey) and program.
constexpr wchar_t kUninstallKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    L"{F47AC10B-58CC-4372-A567-0E02B2C3D479}_is1";
constexpr wchar_t kProgramName[] = L"zestssh.exe";

HANDLE g_mutex = nullptr;

bool StartsWithScheme(const std::string& s) {
  const size_t n = sizeof(kScheme) - 1;
  if (s.size() < n) {
    return false;
  }
  for (size_t i = 0; i < n; ++i) {
    char c = s[i];
    if (c >= 'A' && c <= 'Z') {
      c = static_cast<char>(c - 'A' + 'a');
    }
    if (c != kScheme[i]) {
      return false;
    }
  }
  return true;
}

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
      static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring utf16(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                        static_cast<int>(utf8.size()), utf16.data(), length);
  return utf16;
}

bool SamePath(const std::wstring& a, const std::wstring& b) {
  return !a.empty() && !b.empty() &&
         ::CompareStringOrdinal(a.c_str(), static_cast<int>(a.size()),
                                b.c_str(), static_cast<int>(b.size()),
                                TRUE) == CSTR_EQUAL;
}

// The full path of |process|'s program, as Windows names it; empty where it
// cannot be read.
std::wstring ImageOf(HANDLE process) {
  std::wstring path(32768, L'\0');
  DWORD size = static_cast<DWORD>(path.size());
  if (!::QueryFullProcessImageNameW(process, 0, path.data(), &size)) {
    return std::wstring();
  }
  path.resize(size);
  return path;
}

// |process|'s integrity level (its mandatory label's RID); false where it
// cannot be read, or the process runs in an AppContainer (a sandboxed app).
bool IntegrityOf(HANDLE process, DWORD* level) {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(process, TOKEN_QUERY, &token)) {
    return false;
  }
  bool read = false;
  DWORD container = 0;
  DWORD size = 0;
  if (::GetTokenInformation(token, TokenIsAppContainer, &container,
                            sizeof(container), &size) &&
      container == 0) {
    ::GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &size);
    if (size > 0) {
      std::vector<BYTE> buffer(size);
      auto* label = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(buffer.data());
      if (::GetTokenInformation(token, TokenIntegrityLevel, label, size,
                                &size) &&
          ::IsValidSid(label->Label.Sid)) {
        const UCHAR count = *::GetSidSubAuthorityCount(label->Label.Sid);
        if (count > 0) {
          *level = *::GetSidSubAuthority(label->Label.Sid, count - 1);
          read = true;
        }
      }
    }
  }
  ::CloseHandle(token);
  return read;
}

// Whether |process| runs as ZestSSH from the Microsoft Store: its package
// family is the Store copy's.
bool IsStoreCopy(HANDLE process) {
  wchar_t family[PACKAGE_FAMILY_NAME_MAX_LENGTH + 1] = {};
  UINT32 length = PACKAGE_FAMILY_NAME_MAX_LENGTH + 1;
  return ::GetPackageFamilyName(process, &length, family) == ERROR_SUCCESS &&
         ::CompareStringOrdinal(family, -1, kStorePackageFamily, -1, TRUE) ==
             CSTR_EQUAL;
}

// [folder]\zestssh.exe, without a doubled separator.
std::wstring ProgramIn(std::wstring folder) {
  while (!folder.empty() && (folder.back() == L'\\' || folder.back() == L'/')) {
    folder.pop_back();
  }
  return folder.empty() ? std::wstring() : folder + L"\\" + kProgramName;
}

std::wstring RegistryText(HKEY root, DWORD view, const wchar_t* value) {
  DWORD bytes = 0;
  const DWORD flags = RRF_RT_REG_SZ | view;
  if (::RegGetValueW(root, kUninstallKey, value, flags, nullptr, nullptr,
                     &bytes) != ERROR_SUCCESS ||
      bytes < sizeof(wchar_t)) {
    return std::wstring();
  }
  std::wstring text(bytes / sizeof(wchar_t), L'\0');
  if (::RegGetValueW(root, kUninstallKey, value, flags, nullptr, text.data(),
                     &bytes) != ERROR_SUCCESS) {
    return std::wstring();
  }
  text.resize(::wcsnlen(text.c_str(), text.size()));
  return text;
}

std::wstring Environment(const wchar_t* name) {
  wchar_t value[MAX_PATH * 2] = {};
  const DWORD n = ::GetEnvironmentVariableW(name, value, MAX_PATH * 2);
  return n == 0 || n >= MAX_PATH * 2 ? std::wstring() : std::wstring(value, n);
}

// Where ZestSSH from zestssh.com's program is: the folder its uninstall entry
// names, for this Windows account or for all of them, else its installer's
// default folders (StoreHandover.websiteCopy, the same order).
std::vector<std::wstring> WebsitePrograms() {
  std::vector<std::wstring> programs;
  const struct {
    HKEY root;
    DWORD view;
  } entries[] = {{HKEY_CURRENT_USER, 0},
                 {HKEY_LOCAL_MACHINE, RRF_SUBKEY_WOW6464KEY},
                 {HKEY_LOCAL_MACHINE, RRF_SUBKEY_WOW6432KEY}};
  for (const auto& entry : entries) {
    for (const wchar_t* value : {L"InstallLocation", L"Inno Setup: App Path"}) {
      const std::wstring program =
          ProgramIn(RegistryText(entry.root, entry.view, value));
      if (!program.empty()) {
        programs.push_back(program);
      }
    }
  }
  const std::wstring local = Environment(L"LOCALAPPDATA");
  if (!local.empty()) {
    programs.push_back(ProgramIn(local + L"\\Programs\\ZestSSH"));
  }
  const std::wstring program_files = Environment(L"ProgramFiles");
  if (!program_files.empty()) {
    programs.push_back(ProgramIn(program_files + L"\\ZestSSH"));
  }
  return programs;
}

// Whether |hwnd| belongs to a ZestSSH this start may hand its link to (found
// in a security review): a window anyone on
// the desktop can make carries the mark as well, and a sandboxed app's would
// take every link the browser opens. Its process runs this very program, or
// ZestSSH from the Microsoft Store, or ZestSSH from zestssh.com where its
// installer put it (the two hand their start to each other:
// lib/services/store_handover_start.dart); at no lower an integrity level
// than this one, and in no AppContainer. Where any of it cannot be read, it
// is not handed anything.
bool IsZestSsh(HWND hwnd) {
  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0) {
    return false;
  }
  if (pid == ::GetCurrentProcessId()) {
    return true;
  }
  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) {
    return false;
  }
  bool ours = false;
  DWORD theirs = 0;
  DWORD mine = 0;
  const std::wstring image = ImageOf(process);
  if (!image.empty() && IntegrityOf(process, &theirs) &&
      IntegrityOf(::GetCurrentProcess(), &mine) && theirs >= mine) {
    if (SamePath(image, ImageOf(::GetCurrentProcess()))) {
      ours = true;
    } else {
      const size_t slash = image.find_last_of(L"\\/");
      const std::wstring name =
          slash == std::wstring::npos ? image : image.substr(slash + 1);
      if (SamePath(name, kProgramName)) {
        if (IsStoreCopy(process)) {
          ours = true;
        } else {
          for (const auto& program : WebsitePrograms()) {
            if (SamePath(image, program)) {
              ours = true;
              break;
            }
          }
        }
      }
    }
  }
  ::CloseHandle(process);
  return ours;
}

BOOL CALLBACK FindTagged(HWND hwnd, LPARAM found) {
  // A marked window that is not a ZestSSH's is passed over, and the search
  // goes on: it cannot hide the real one.
  if (::GetPropW(hwnd, kWindowTag) != nullptr && IsZestSsh(hwnd)) {
    *reinterpret_cast<HWND*>(found) = hwnd;
    return FALSE;
  }
  return TRUE;
}

HWND FindMainWindow() {
  HWND found = nullptr;
  ::EnumWindows(FindTagged, reinterpret_cast<LPARAM>(&found));
  return found;
}

}  // namespace

bool RunsOnItsOwn(const std::vector<std::string>& args) {
  return !args.empty() && args.front() == "admin";
}

std::string LinkArgument(const std::vector<std::string>& args) {
  for (const auto& arg : args) {
    if (StartsWithScheme(arg)) {
      return arg;
    }
  }
  return std::string();
}

bool AnotherIsRunning() {
  g_mutex = ::CreateMutexW(nullptr, FALSE, kMutexName);
  // A mutex that could not be made at all (no rights to it): this one runs.
  return g_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS;
}

bool HandToRunningInstance(const std::string& link) {
  std::wstring wide = Utf16FromUtf8(link);
  if (wide.size() > kMaxLinkChars) {
    wide.clear();
  }
  HWND target = nullptr;
  for (int i = 0; i < kFindTries; ++i) {
    target = FindMainWindow();
    if (target != nullptr) {
      break;
    }
    ::Sleep(kFindPauseMs);
  }
  if (target == nullptr) {
    return false;
  }
  // This start came from the person (a click in the browser), so it may
  // bring a window to the front; it passes that on to the running one.
  DWORD pid = 0;
  ::GetWindowThreadProcessId(target, &pid);
  if (pid != 0) {
    ::AllowSetForegroundWindow(pid);
  }
  COPYDATASTRUCT data{};
  data.dwData = kLinkCopyDataId;
  data.cbData = static_cast<DWORD>((wide.size() + 1) * sizeof(wchar_t));
  data.lpData = const_cast<wchar_t*>(wide.c_str());
  DWORD_PTR answer = 0;
  const LRESULT sent = ::SendMessageTimeoutW(
      target, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
      SMTO_ABORTIFHUNG | SMTO_BLOCK, kSendTimeoutMs, &answer);
  return sent != 0 && answer == TRUE;
}

void MarkMainWindow(HWND hwnd) {
  if (hwnd != nullptr) {
    ::SetPropW(hwnd, kWindowTag, reinterpret_cast<HANDLE>(1));
  }
}

void UnmarkMainWindow(HWND hwnd) {
  if (hwnd != nullptr) {
    ::RemovePropW(hwnd, kWindowTag);
  }
}

std::optional<std::string> LinkFromCopyData(LPARAM lparam) {
  const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
  if (data == nullptr || data->dwData != kLinkCopyDataId) {
    return std::nullopt;
  }
  if (data->cbData % sizeof(wchar_t) != 0 ||
      data->cbData > (kMaxLinkChars + 1) * sizeof(wchar_t)) {
    return std::nullopt;
  }
  const size_t units = data->cbData / sizeof(wchar_t);
  if (units == 0 || data->lpData == nullptr) {
    return std::string();
  }
  const auto* text = static_cast<const wchar_t*>(data->lpData);
  // Up to its terminator, never past what was sent.
  const std::wstring wide(text, ::wcsnlen(text, units));
  if (wide.empty()) {
    return std::string();
  }
  std::string link = Utf8FromUtf16(wide.c_str());
  // Only a zestssh:// link goes on (to Dart, which reads it as strictly as
  // any opened link); anything else only shows the window.
  if (!StartsWithScheme(link)) {
    return std::string();
  }
  return link;
}

void BringToFront(HWND hwnd) {
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else if (!::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  ::SetForegroundWindow(hwnd);
}

}  // namespace single_instance
