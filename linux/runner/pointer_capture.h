#ifndef RUNNER_POINTER_CAPTURE_H_
#define RUNNER_POINTER_CAPTURE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Remote screens (4.0): relative mouse, the Linux part, on the
// channel zestssh/pointer_capture and its events
// (lib/features/screens/view/screen_pointer_hold.dart), as
// windows/runner/pointer_hold.cpp is on Windows and
// macos/Runner/PointerCaptureChannel.swift on a Mac.
//
// For a game or a 3D program on a remote screen the pointer is held, and
// how far the mouse moved is handed to the app, which sends it to the
// remote. Its buttons go on reaching the picture under it.
//
// Under X11: the pointer is hidden over the app's window and put back on the
// point it was at after every movement.
//
// Nothing is grabbed at the X server and no barrier is made there, on
// purpose: a grab or a barrier belongs to the program's connection, and a
// program that is stuck keeps it, with no way for anything else to take it
// away. Held this way, a stuck app holds nothing: it stops putting the
// pointer back, and the pointer moves again (it is hidden only while it is
// over the app's window). The price is that a very fast movement can carry
// the pointer out of the window for a moment before it is put back.
//
// Under Wayland a program cannot move the pointer, and GTK 3 does not speak
// the two protocols that hold one. The runner speaks them itself (the
// generated code under wayland/): the compositor locks the pointer to the
// window (pointer constraints) and reports the mouse's movement (relative
// pointer). The compositor ends the lock whenever the window stops being
// the one the pointer is in, whatever the app is doing, and says so; a
// compositor without both protocols makes the app answer "not available".

typedef struct _ZestPointerCapture ZestPointerCapture;

// The channel for |window|, whose Flutter view is |view|. Neither is kept
// alive by it.
ZestPointerCapture* zest_pointer_capture_new(FlBinaryMessenger* messenger,
                                             GtkWindow* window,
                                             GtkWidget* view);

// Lets go of the pointer and ends the channel.
void zest_pointer_capture_free(ZestPointerCapture* self);

#endif  // RUNNER_POINTER_CAPTURE_H_
