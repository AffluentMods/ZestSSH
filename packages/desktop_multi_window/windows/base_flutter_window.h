//
// Created by yangbin on 2022/1/27.
//

#ifndef MULTI_WINDOW_WINDOWS_BASE_FLUTTER_WINDOW_H_
#define MULTI_WINDOW_WINDOWS_BASE_FLUTTER_WINDOW_H_

#include "window_channel.h"

class BaseFlutterWindow {

 public:

  virtual ~BaseFlutterWindow() = default;

  virtual WindowChannel *GetWindowChannel() = 0;

  void Show();

  void Hide();

  void Close();

  void SetTitle(const std::string &title);

  void SetBounds(double_t x, double_t y, double_t width, double_t height);

  void Center();

  // ZestSSH patch: the window fills the monitor it is on, without a frame,
  // or is a window again where and as it was.
  void SetFullScreen(bool full_screen);

 protected:

  virtual HWND GetWindowHandle() = 0;

 private:

  // What the window was before it filled the monitor.
  bool full_screen_ = false;
  LONG_PTR saved_style_ = 0;
  WINDOWPLACEMENT saved_placement_ = {sizeof(WINDOWPLACEMENT)};

};

#endif //MULTI_WINDOW_WINDOWS_BASE_FLUTTER_WINDOW_H_
