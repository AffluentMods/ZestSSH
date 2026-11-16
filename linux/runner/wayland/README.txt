The four files here are generated, not written: the client side of two
Wayland protocols the runner speaks for relative mouse (pointer_capture.cc),
which GTK 3 does not speak itself.

  pointer-constraints-unstable-v1   the pointer locked to the window
  relative-pointer-unstable-v1      the mouse's movement as movement

Made with wayland-scanner 1.24.0 from wayland-protocols 1.47 (Ubuntu), on
15 November 2026:

  wayland-scanner client-header <xml> <name>-client-protocol.h
  wayland-scanner private-code  <xml> <name>-protocol.c

with <xml> under /usr/share/wayland-protocols/unstable/pointer-constraints/
and .../unstable/relative-pointer/. They are checked in so that no build of
the app (deb, rpm, Flatpak, Snap) needs wayland-scanner or wayland-protocols.
Each carries its protocol's own licence (MIT) at its top; keep it there. To
make them again, run the two commands and replace the files whole.
