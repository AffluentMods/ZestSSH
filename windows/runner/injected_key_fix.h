#ifndef RUNNER_INJECTED_KEY_FIX_H_
#define RUNNER_INJECTED_KEY_FIX_H_

#include <windows.h>

// The Windows clipboard history flyout (Win+V) pastes by injecting Ctrl+V
// with SendInput and NO scan code: the key messages arrive with a scan code
// of 0. The Flutter engine derives the physical key from the scan code, so
// both the Control message and the V message map to the same unknown key
// (0x1600000000), the framework's keyboard state machine rejects the second
// one, and nothing is pasted (flutter/flutter#143997). Windows 10 delivered
// these differently, which is why it only shows on Windows 11.
//
// The repair is to give such a message the scan code the key would have had
// on a real keyboard, before the engine sees it. Real keyboards never send
// scan code 0, so nothing else is touched. Applied to the Flutter view's
// window through a subclass (see FlutterWindow).
//
// Character messages are a special case: an IME commits text as WM_CHAR
// messages with a scan code of 0 and no key press of their own, and those
// must reach the engine exactly as they are. So a character is only repaired
// when it follows an injected key press closely enough to belong to it (the
// flyout's Ctrl+V produces WM_KEYDOWN V and then WM_CHAR 0x16 within the same
// message burst); see InjectedKeyRepairer.

namespace injected_key_fix {

inline bool IsKeyMessage(UINT message) {
  switch (message) {
    case WM_KEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYDOWN:
    case WM_SYSKEYUP:
    case WM_CHAR:
    case WM_SYSCHAR:
    case WM_DEADCHAR:
    case WM_SYSDEADCHAR:
      return true;
    default:
      return false;
  }
}

inline bool IsCharMessage(UINT message) {
  return message == WM_CHAR || message == WM_SYSCHAR ||
         message == WM_DEADCHAR || message == WM_SYSDEADCHAR;
}

inline bool IsKeyDownMessage(UINT message) {
  return message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
}

// The virtual key a message is about. Key messages carry it in wparam; char
// messages carry the character instead, so ask the keyboard layout which key
// produces it (a control character such as 0x16 for Ctrl+V maps back to V).
inline UINT VirtualKeyFor(UINT message, WPARAM wparam) {
  if (!IsCharMessage(message)) {
    return static_cast<UINT>(wparam);
  }
  SHORT scan = VkKeyScanW(static_cast<WCHAR>(wparam));
  if (scan == -1) {
    return 0;
  }
  return static_cast<UINT>(LOBYTE(scan));
}

// Keys that a physical keyboard reports with the 0xE0 prefix (extended bit).
// MapVirtualKey cannot be trusted for these: for the navigation cluster it
// returns the numpad scan code without the prefix, because both keys map to
// the same virtual key.
inline bool IsExtendedVirtualKey(UINT vk) {
  switch (vk) {
    case VK_RCONTROL:
    case VK_RMENU:
    case VK_LWIN:
    case VK_RWIN:
    case VK_APPS:
    case VK_INSERT:
    case VK_DELETE:
    case VK_HOME:
    case VK_END:
    case VK_PRIOR:
    case VK_NEXT:
    case VK_LEFT:
    case VK_RIGHT:
    case VK_UP:
    case VK_DOWN:
    case VK_DIVIDE:
    case VK_NUMLOCK:
    case VK_SNAPSHOT:
      return true;
    default:
      return false;
  }
}

// Returns lparam with the scan code (bits 16-23) and the extended-key bit
// (bit 24) filled in when the scan code is 0 and the key is known; otherwise
// lparam unchanged. Stateless: the caller decides whether a character
// message is eligible (see InjectedKeyRepairer).
inline LPARAM RepairScanCode(UINT message, WPARAM wparam, LPARAM lparam) {
  if (!IsKeyMessage(message)) {
    return lparam;
  }
  if (((lparam >> 16) & 0xFF) != 0) {
    return lparam;  // A real key: leave it alone.
  }
  UINT vk = VirtualKeyFor(message, wparam);
  if (vk == 0) {
    return lparam;
  }
  // MAPVK_VK_TO_VSC_EX yields 0xE0xx for extended keys (right Ctrl/Alt,
  // arrows, Insert...). The generic VK_CONTROL/VK_SHIFT/VK_MENU map to their
  // left-hand scan codes, which is what an injected Ctrl+V means.
  UINT ex = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC_EX);
  if (ex == 0) {
    return lparam;
  }
  UINT scan = ex & 0xFF;
  bool extended = ((ex >> 8) & 0xFF) == 0xE0 || IsExtendedVirtualKey(vk);
  LPARAM repaired = lparam & ~static_cast<LPARAM>(0x01FF0000);
  repaired |= static_cast<LPARAM>(scan) << 16;
  if (extended) {
    repaired |= static_cast<LPARAM>(1) << 24;
  }
  return repaired;
}

// The repair with the one piece of state it needs: when the last injected
// key press was seen, so a scan-code-less character message is repaired only
// when it belongs to one (an injected Ctrl+V, a paste from an on-screen
// keyboard) and never when it stands alone (text committed by an IME).
class InjectedKeyRepairer {
 public:
  // Characters this long after the last injected key press are not its.
  static constexpr ULONGLONG kBurstMs = 500;

  LPARAM Repair(UINT message, WPARAM wparam, LPARAM lparam, ULONGLONG now_ms) {
    if (!IsKeyMessage(message)) {
      return lparam;
    }
    if (((lparam >> 16) & 0xFF) != 0) {
      return lparam;  // A real key: leave it alone.
    }
    if (IsCharMessage(message)) {
      bool follows_injected_press =
          last_injected_press_ms_ != 0 &&
          now_ms >= last_injected_press_ms_ &&
          now_ms - last_injected_press_ms_ <= kBurstMs;
      if (!follows_injected_press) {
        return lparam;  // An IME commit or any other stand-alone character.
      }
    }
    LPARAM repaired = RepairScanCode(message, wparam, lparam);
    if (repaired != lparam && IsKeyDownMessage(message)) {
      last_injected_press_ms_ = now_ms;
    }
    return repaired;
  }

 private:
  ULONGLONG last_injected_press_ms_ = 0;
};

}  // namespace injected_key_fix

#endif  // RUNNER_INJECTED_KEY_FIX_H_
