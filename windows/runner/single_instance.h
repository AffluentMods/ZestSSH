#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <optional>
#include <string>
#include <vector>

// One ZestSSH per Windows session. A second start (a zestssh:// link opened
// in a browser starts zestssh.exe with the link as its argument, as the
// protocol is registered: installer/zestssh_setup.iss, pubspec.yaml's
// msix_config) hands its link to the ZestSSH already running, brings that
// window to the front and ends; the running one gives the link to Dart on
// the deep link channel (flutter_window.cpp), as an opened link on a phone.
// Windows that desktop_multi_window opens are made inside the running
// process and never pass through here.
namespace single_instance {

// WM_COPYDATA's dwData for a link handed over by a second start ('ZEST').
constexpr ULONG_PTR kLinkCopyDataId = 0x5A455354;

// The longest link handed over, in UTF-16 code units: a share link's cap
// (ConnectionShareUrlService.maxLinkChars). A longer one is not handed over;
// the window is still brought to the front.
constexpr size_t kMaxLinkChars = 12 * 1024;

// Whether this start runs on its own whatever else runs: a command from a
// terminal (`zestssh admin ...`, the setup file) does its work and ends.
bool RunsOnItsOwn(const std::vector<std::string>& args);

// The first zestssh:// link among |args| (the scheme in any case), or empty.
std::string LinkArgument(const std::vector<std::string>& args);

// Claims this session's ZestSSH mutex (held until the process ends). True
// when another ZestSSH of this session holds it already.
bool AnotherIsRunning();

// Hands |link| (empty: none, just show it) to the running ZestSSH's main
// window and lets it come to the front. Waits up to five seconds for that
// window (the running one may be starting). True when it took the link.
bool HandToRunningInstance(const std::string& link);

// Marks |hwnd| as this ZestSSH's main window, for a second start to find
// ([HandToRunningInstance]); [UnmarkMainWindow] before it is destroyed.
void MarkMainWindow(HWND hwnd);
void UnmarkMainWindow(HWND hwnd);

// What a WM_COPYDATA (its |lparam|) from a second start carries: the link
// in UTF-8, or an empty string for none (just show the window). nullopt
// when the message is not one of ours, or is malformed.
std::optional<std::string> LinkFromCopyData(LPARAM lparam);

// Shows |hwnd| (restored from minimised, or from the tray where it was
// hidden) and brings it to the front.
void BringToFront(HWND hwnd);

}  // namespace single_instance

#endif  // RUNNER_SINGLE_INSTANCE_H_
