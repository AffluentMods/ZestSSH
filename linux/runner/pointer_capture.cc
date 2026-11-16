#include "pointer_capture.h"

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#if defined(GDK_WINDOWING_WAYLAND) && defined(ZEST_WAYLAND_POINTER)
#include <gdk/gdkwayland.h>
#include "wayland/pointer-constraints-unstable-v1-client-protocol.h"
#include "wayland/relative-pointer-unstable-v1-client-protocol.h"
#define ZEST_HAS_WAYLAND 1
#endif

#include <math.h>
#include <string.h>

namespace {

const char kMethods[] = "zestssh/pointer_capture";
const char kEvents[] = "zestssh/pointer_capture/events";

// The app must renew this often, or the pointer is let go.
const gint64 kRenewWithinUs = 2 * G_USEC_PER_SEC;

// Movement is handed on at most this often; what is left when the mouse
// stops goes with the tick.
const gint64 kSendEveryUs = 4000;
const guint kTickMs = 10;

// The pointer put back on its point is seen as one more movement, to that
// point. If it has not been seen this long after asking, the pointer could
// not be moved (an X server inside a Wayland session): go on without it.
const gint64 kPutBackWithinUs = 100000;

// The most that waits to be handed on.
const gdouble kMostWaiting = 16777216.0;

#ifdef ZEST_HAS_WAYLAND
// How long the compositor has to say the pointer is locked before the
// app is told it could not be held.
const guint kLockWithinMs = 500;
#endif

}  // namespace

struct _ZestPointerCapture {
  GtkWindow* window;
  GtkWidget* view;
  FlMethodChannel* methods;
  FlEventChannel* events;
  gboolean listening;

  gboolean held;
  // The point the pointer is kept on, in the screen's own coordinates.
  GdkScreen* screen;
  gint anchor_x;
  gint anchor_y;
  // Where the pointer was at the movement before.
  gdouble last_x;
  gdouble last_y;
  // The pointer was asked back to its point and that movement has not come.
  gboolean put_back_asked;
  gint64 put_back_at_us;
  // Movement that waits to be handed on, in the screen's pixels.
  gdouble dx;
  gdouble dy;
  gint64 last_sent_us;
  gint64 last_renew_us;
  guint tick_id;
  gulong active_handler;
  GdkCursor* blank;

#ifdef ZEST_HAS_WAYLAND
  // Wayland: the two protocols as the compositor offers them, the lock
  // and the movement of a hold, and a start that waits for the
  // compositor's answer.
  struct wl_registry* registry;
  struct zwp_pointer_constraints_v1* constraints;
  struct zwp_relative_pointer_manager_v1* relative_manager;
  struct zwp_locked_pointer_v1* locked;
  struct zwp_relative_pointer_v1* relative;
  gboolean wayland_hold;
  FlMethodCall* starting;
  guint start_timeout;
#endif
};

namespace {

// The one channel of the process: the tap below sees every event of the app.
ZestPointerCapture* g_capture = nullptr;

GdkDevice* pointer_of(ZestPointerCapture* self) {
  if (self->window == nullptr) {
    return nullptr;
  }
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(self->window));
  GdkSeat* seat = gdk_display_get_default_seat(display);
  return seat == nullptr ? nullptr : gdk_seat_get_pointer(seat);
}

#ifdef ZEST_HAS_WAYLAND
gboolean on_wayland(ZestPointerCapture* self) {
  return self->window != nullptr &&
         GDK_IS_WAYLAND_DISPLAY(gtk_widget_get_display(GTK_WIDGET(self->window)));
}
#endif

gboolean on_x11(ZestPointerCapture* self) {
#ifdef GDK_WINDOWING_X11
  return self->window != nullptr &&
         GDK_IS_X11_DISPLAY(gtk_widget_get_display(GTK_WIDGET(self->window)));
#else
  return FALSE;
#endif
}

gboolean can_hold(ZestPointerCapture* self) {
  if (self->window == nullptr || self->view == nullptr) {
    return FALSE;
  }
#ifdef ZEST_HAS_WAYLAND
  // Only a compositor that offers both protocols.
  if (on_wayland(self)) {
    return self->constraints != nullptr && self->relative_manager != nullptr;
  }
#endif
  return on_x11(self);
}

void send(ZestPointerCapture* self, FlValue* value) {
  if (self->listening && self->events != nullptr) {
    fl_event_channel_send(self->events, value, nullptr, nullptr);
  }
}

void flush(ZestPointerCapture* self) {
  if (!self->held) {
    return;
  }
  // Whole counts go; the part of a count that is left waits for the next.
  const gdouble whole_x = trunc(self->dx);
  const gdouble whole_y = trunc(self->dy);
  if (whole_x == 0 && whole_y == 0) {
    return;
  }
  self->dx -= whole_x;
  self->dy -= whole_y;
  self->last_sent_us = g_get_monotonic_time();
  g_autoptr(FlValue) by = fl_value_new_list();
  fl_value_append_take(by, fl_value_new_int(static_cast<gint64>(whole_x)));
  fl_value_append_take(by, fl_value_new_int(static_cast<gint64>(whole_y)));
  send(self, by);
}

void put_back(ZestPointerCapture* self) {
  GdkDevice* pointer = pointer_of(self);
  if (pointer == nullptr || self->screen == nullptr) {
    return;
  }
  gdk_device_warp(pointer, self->screen, self->anchor_x, self->anchor_y);
  self->put_back_asked = TRUE;
  self->put_back_at_us = g_get_monotonic_time();
}

#ifdef ZEST_HAS_WAYLAND
// The lock and the movement of a Wayland hold, given back to the compositor.
void wayland_release(ZestPointerCapture* self) {
  if (self->relative != nullptr) {
    zwp_relative_pointer_v1_destroy(self->relative);
    self->relative = nullptr;
  }
  if (self->locked != nullptr) {
    zwp_locked_pointer_v1_destroy(self->locked);
    self->locked = nullptr;
  }
  self->wayland_hold = FALSE;
}
#endif

void let_go(ZestPointerCapture* self, gboolean by_itself) {
  if (!self->held) {
    return;
  }
  self->held = FALSE;
  if (self->tick_id != 0) {
    g_source_remove(self->tick_id);
    self->tick_id = 0;
  }
  gboolean was_wayland = FALSE;
#ifdef ZEST_HAS_WAYLAND
  was_wayland = self->wayland_hold;
  if (was_wayland) {
    // The compositor unlocks it where it was locked.
    wayland_release(self);
  }
#endif
  // Where the person left it, and seen again.
  GdkDevice* pointer = pointer_of(self);
  if (!was_wayland && pointer != nullptr && self->screen != nullptr) {
    gdk_device_warp(pointer, self->screen, self->anchor_x, self->anchor_y);
  }
  if (self->view != nullptr) {
    GdkWindow* window = gtk_widget_get_window(self->view);
    if (window != nullptr) {
      gdk_window_set_cursor(window, nullptr);
    }
  }
  self->put_back_asked = FALSE;
  self->dx = 0;
  self->dy = 0;
  if (by_itself) {
    g_autoptr(FlValue) lost = fl_value_new_string("lost");
    send(self, lost);
  }
}

// The pointer is at this place of the screen now.
void moved(ZestPointerCapture* self, gdouble x_root, gdouble y_root) {
  const gint64 now = g_get_monotonic_time();
  if (self->put_back_asked) {
    if (x_root == self->anchor_x && y_root == self->anchor_y) {
      // The pointer put back: that way is not the mouse's.
      self->put_back_asked = FALSE;
      self->last_x = x_root;
      self->last_y = y_root;
      return;
    }
    if (now - self->put_back_at_us > kPutBackWithinUs) {
      self->put_back_asked = FALSE;
    }
  }
  const gdouble by_x = x_root - self->last_x;
  const gdouble by_y = y_root - self->last_y;
  self->last_x = x_root;
  self->last_y = y_root;
  if (by_x == 0 && by_y == 0) {
    return;
  }
  gint scale = 1;
  if (self->view != nullptr) {
    scale = gtk_widget_get_scale_factor(self->view);
  }
  self->dx = CLAMP(self->dx + by_x * scale, -kMostWaiting, kMostWaiting);
  self->dy = CLAMP(self->dy + by_y * scale, -kMostWaiting, kMostWaiting);
  // Back on its point, unless that was asked for and has not happened yet
  // (movements on their way meanwhile are counted from the one before).
  if (!self->put_back_asked) {
    put_back(self);
  }
  if (now - self->last_sent_us >= kSendEveryUs) {
    flush(self);
  }
}

gboolean tick_cb(gpointer user_data) {
  ZestPointerCapture* self = static_cast<ZestPointerCapture*>(user_data);
  if (!self->held) {
    self->tick_id = 0;
    return G_SOURCE_REMOVE;
  }
  if (g_get_monotonic_time() - self->last_renew_us > kRenewWithinUs) {
    // The app said nothing for too long.
    self->tick_id = 0;
    let_go(self, TRUE);
    return G_SOURCE_REMOVE;
  }
  flush(self);
  return G_SOURCE_CONTINUE;
}

gboolean start(ZestPointerCapture* self) {
  if (self->held) {
    return TRUE;
  }
  if (!on_x11(self) || !can_hold(self) || !gtk_window_is_active(self->window)) {
    return FALSE;
  }
  GdkWindow* window = gtk_widget_get_window(self->view);
  GdkDevice* pointer = pointer_of(self);
  if (window == nullptr || pointer == nullptr) {
    return FALSE;
  }
  // Only a pointer that is over the view: its buttons must go on reaching
  // the picture.
  gint in_x = 0;
  gint in_y = 0;
  gdk_window_get_device_position(window, pointer, &in_x, &in_y, nullptr);
  if (in_x < 0 || in_y < 0 || in_x >= gdk_window_get_width(window) ||
      in_y >= gdk_window_get_height(window)) {
    return FALSE;
  }
  GdkScreen* screen = nullptr;
  gint x = 0;
  gint y = 0;
  gdk_device_get_position(pointer, &screen, &x, &y);
  if (screen == nullptr) {
    return FALSE;
  }
  if (self->blank == nullptr) {
    self->blank = gdk_cursor_new_for_display(
        gtk_widget_get_display(GTK_WIDGET(self->window)), GDK_BLANK_CURSOR);
  }
  gdk_window_set_cursor(window, self->blank);
  const gint64 now = g_get_monotonic_time();
  self->screen = screen;
  self->anchor_x = x;
  self->anchor_y = y;
  self->last_x = x;
  self->last_y = y;
  self->put_back_asked = FALSE;
  self->dx = 0;
  self->dy = 0;
  self->last_sent_us = now;
  self->last_renew_us = now;
  self->held = TRUE;
  self->tick_id = g_timeout_add(kTickMs, tick_cb, self);
  return TRUE;
}

#ifdef ZEST_HAS_WAYLAND
// Answers the start that waits for the compositor.
void finish_start(ZestPointerCapture* self, gboolean held) {
  if (self->start_timeout != 0) {
    g_source_remove(self->start_timeout);
    self->start_timeout = 0;
  }
  FlMethodCall* call = self->starting;
  self->starting = nullptr;
  if (call != nullptr) {
    g_autoptr(FlValue) answer = fl_value_new_bool(held);
    fl_method_call_respond_success(call, answer, nullptr);
    g_object_unref(call);
  }
}

void locked_cb(void* data, struct zwp_locked_pointer_v1* locked) {
  ZestPointerCapture* self = static_cast<ZestPointerCapture*>(data);
  if (self->starting == nullptr || self->held) {
    return;
  }
  const gint64 now = g_get_monotonic_time();
  self->dx = 0;
  self->dy = 0;
  self->last_sent_us = now;
  self->last_renew_us = now;
  self->put_back_asked = FALSE;
  self->screen = nullptr;
  self->wayland_hold = TRUE;
  self->held = TRUE;
  self->tick_id = g_timeout_add(kTickMs, tick_cb, self);
  finish_start(self, TRUE);
}

void unlocked_cb(void* data, struct zwp_locked_pointer_v1* locked) {
  ZestPointerCapture* self = static_cast<ZestPointerCapture*>(data);
  // The compositor ended the lock (it was asked for once: it does not
  // come back by itself).
  if (self->starting != nullptr) {
    wayland_release(self);
    finish_start(self, FALSE);
    return;
  }
  let_go(self, TRUE);
}

const struct zwp_locked_pointer_v1_listener kLockedListener = {locked_cb, unlocked_cb};

void relative_motion_cb(void* data, struct zwp_relative_pointer_v1* relative,
                        uint32_t time_hi, uint32_t time_lo, wl_fixed_t dx,
                        wl_fixed_t dy, wl_fixed_t dx_unaccelerated,
                        wl_fixed_t dy_unaccelerated) {
  ZestPointerCapture* self = static_cast<ZestPointerCapture*>(data);
  if (!self->held || !self->wayland_hold) {
    return;
  }
  // The mouse's own movement, before the pointer's acceleration.
  self->dx = CLAMP(self->dx + wl_fixed_to_double(dx_unaccelerated), -kMostWaiting, kMostWaiting);
  self->dy = CLAMP(self->dy + wl_fixed_to_double(dy_unaccelerated), -kMostWaiting, kMostWaiting);
  if (g_get_monotonic_time() - self->last_sent_us >= kSendEveryUs) {
    flush(self);
  }
}

const struct zwp_relative_pointer_v1_listener kRelativeListener = {relative_motion_cb};

gboolean start_timeout_cb(gpointer user_data) {
  ZestPointerCapture* self = static_cast<ZestPointerCapture*>(user_data);
  self->start_timeout = 0;
  // The compositor did not lock it in time: not held.
  wayland_release(self);
  finish_start(self, FALSE);
  return G_SOURCE_REMOVE;
}

// Asks the compositor to lock the pointer to the window; [call] is
// answered when it says it has, or that it will not.
void start_wayland(ZestPointerCapture* self, FlMethodCall* call) {
  auto answer = [call](gboolean held) {
    g_autoptr(FlValue) value = fl_value_new_bool(held);
    fl_method_call_respond_success(call, value, nullptr);
  };
  if (self->held) {
    answer(TRUE);
    return;
  }
  // One lock at a time: a second one on the same window is an error the
  // compositor ends the app for.
  if (self->starting != nullptr || self->locked != nullptr || !can_hold(self) ||
      !gtk_window_is_active(self->window)) {
    answer(FALSE);
    return;
  }
  GdkWindow* window = gtk_widget_get_window(self->view);
  GdkDevice* pointer = pointer_of(self);
  if (window == nullptr || pointer == nullptr) {
    answer(FALSE);
    return;
  }
  gint in_x = 0;
  gint in_y = 0;
  gdk_window_get_device_position(window, pointer, &in_x, &in_y, nullptr);
  if (in_x < 0 || in_y < 0 || in_x >= gdk_window_get_width(window) ||
      in_y >= gdk_window_get_height(window)) {
    answer(FALSE);
    return;
  }
  struct wl_surface* surface = gdk_wayland_window_get_wl_surface(gdk_window_get_toplevel(window));
  struct wl_pointer* wl_pointer = gdk_wayland_device_get_wl_pointer(pointer);
  if (surface == nullptr || wl_pointer == nullptr) {
    answer(FALSE);
    return;
  }
  if (self->blank == nullptr) {
    self->blank = gdk_cursor_new_for_display(
        gtk_widget_get_display(GTK_WIDGET(self->window)), GDK_BLANK_CURSOR);
  }
  gdk_window_set_cursor(window, self->blank);
  self->locked = zwp_pointer_constraints_v1_lock_pointer(
      self->constraints, surface, wl_pointer, nullptr,
      ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT);
  zwp_locked_pointer_v1_add_listener(self->locked, &kLockedListener, self);
  self->relative = zwp_relative_pointer_manager_v1_get_relative_pointer(
      self->relative_manager, wl_pointer);
  zwp_relative_pointer_v1_add_listener(self->relative, &kRelativeListener, self);
  self->starting = FL_METHOD_CALL(g_object_ref(call));
  self->start_timeout = g_timeout_add(kLockWithinMs, start_timeout_cb, self);
}

// The compositor's list of what it offers: the two protocols are kept.
void registry_global_cb(void* data, struct wl_registry* registry, uint32_t name,
                        const char* interface, uint32_t version) {
  ZestPointerCapture* self = static_cast<ZestPointerCapture*>(data);
  if (self->constraints == nullptr &&
      strcmp(interface, zwp_pointer_constraints_v1_interface.name) == 0) {
    self->constraints = static_cast<struct zwp_pointer_constraints_v1*>(
        wl_registry_bind(registry, name, &zwp_pointer_constraints_v1_interface, 1));
  } else if (self->relative_manager == nullptr &&
             strcmp(interface, zwp_relative_pointer_manager_v1_interface.name) == 0) {
    self->relative_manager = static_cast<struct zwp_relative_pointer_manager_v1*>(
        wl_registry_bind(registry, name, &zwp_relative_pointer_manager_v1_interface, 1));
  }
}

void registry_global_remove_cb(void* data, struct wl_registry* registry, uint32_t name) {}

const struct wl_registry_listener kRegistryListener = {registry_global_cb, registry_global_remove_cb};
#endif  // ZEST_HAS_WAYLAND

void renew(ZestPointerCapture* self) {
  if (!self->held) {
    return;
  }
  if (self->window == nullptr || !gtk_window_is_active(self->window)) {
    let_go(self, TRUE);
    return;
  }
  self->last_renew_us = g_get_monotonic_time();
}

// Every event of the app passes here on its way to GTK. A held pointer
// reads its movement from them and lets go when the window loses the
// keyboard; nothing is kept from GTK.
void event_tap(GdkEvent* event, gpointer user_data) {
  ZestPointerCapture* self = g_capture;
  if (self != nullptr && self->held) {
    switch (event->type) {
      // (Under Wayland the compositor reports the movement; the pointer
      // itself does not move while it is locked.)
      case GDK_MOTION_NOTIFY:
        if (self->screen != nullptr) {
          moved(self, event->motion.x_root, event->motion.y_root);
        }
        break;
      case GDK_LEAVE_NOTIFY:
        // Out of the window in one fast movement: counted, and put back.
        if (self->screen != nullptr && event->crossing.mode == GDK_CROSSING_NORMAL) {
          moved(self, event->crossing.x_root, event->crossing.y_root);
        }
        break;
      case GDK_FOCUS_CHANGE:
        if (!event->focus_change.in) {
          let_go(self, TRUE);
        }
        break;
      case GDK_WINDOW_STATE:
        if ((event->window_state.new_window_state &
             GDK_WINDOW_STATE_ICONIFIED) != 0) {
          let_go(self, TRUE);
        }
        break;
      default:
        break;
    }
  }
  gtk_main_do_event(event);
}

void active_changed_cb(GObject* object, GParamSpec* spec, gpointer user_data) {
  ZestPointerCapture* self = static_cast<ZestPointerCapture*>(user_data);
  if (self->held && self->window != nullptr &&
      !gtk_window_is_active(self->window)) {
    let_go(self, TRUE);
  }
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                    gpointer user_data) {
  ZestPointerCapture* self = static_cast<ZestPointerCapture*>(user_data);
  const gchar* name = fl_method_call_get_name(call);
  if (strcmp(name, "available") == 0) {
    g_autoptr(FlValue) can = fl_value_new_bool(can_hold(self));
    fl_method_call_respond_success(call, can, nullptr);
  } else if (strcmp(name, "start") == 0) {
#ifdef ZEST_HAS_WAYLAND
    // Under Wayland the compositor answers a moment later.
    if (on_wayland(self)) {
      start_wayland(self, call);
      return;
    }
#endif
    g_autoptr(FlValue) started = fl_value_new_bool(start(self));
    fl_method_call_respond_success(call, started, nullptr);
  } else if (strcmp(name, "stop") == 0) {
    let_go(self, FALSE);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (strcmp(name, "renew") == 0) {
    renew(self);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

FlMethodErrorResponse* listen_cb(FlEventChannel* channel, FlValue* args,
                                 gpointer user_data) {
  ZestPointerCapture* self = static_cast<ZestPointerCapture*>(user_data);
  self->listening = TRUE;
  return nullptr;
}

FlMethodErrorResponse* cancel_cb(FlEventChannel* channel, FlValue* args,
                                 gpointer user_data) {
  ZestPointerCapture* self = static_cast<ZestPointerCapture*>(user_data);
  // Nobody listens any more (the app let go, or its code started over): a
  // pointer nobody listens to is not held.
  let_go(self, FALSE);
  self->listening = FALSE;
  return nullptr;
}

}  // namespace

ZestPointerCapture* zest_pointer_capture_new(FlBinaryMessenger* messenger,
                                             GtkWindow* window,
                                             GtkWidget* view) {
  ZestPointerCapture* self = g_new0(ZestPointerCapture, 1);
  self->window = window;
  self->view = view;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->window));
  g_object_add_weak_pointer(G_OBJECT(view),
                            reinterpret_cast<gpointer*>(&self->view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->methods =
      fl_method_channel_new(messenger, kMethods, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->methods, method_call_cb,
                                            self, nullptr);
  self->events =
      fl_event_channel_new(messenger, kEvents, FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(self->events, listen_cb, cancel_cb,
                                       self, nullptr);

  self->active_handler = g_signal_connect(
      window, "notify::is-active", G_CALLBACK(active_changed_cb), self);

#ifdef ZEST_HAS_WAYLAND
  // Under Wayland: what the compositor offers, heard as the main loop runs
  // (long before anyone turns relative mouse on).
  if (on_wayland(self)) {
    struct wl_display* display =
        gdk_wayland_display_get_wl_display(gtk_widget_get_display(GTK_WIDGET(window)));
    if (display != nullptr) {
      self->registry = wl_display_get_registry(display);
      wl_registry_add_listener(self->registry, &kRegistryListener, self);
    }
  }
#endif

  // One tap for the process, in front of GTK's own handling of events.
  g_capture = self;
  gdk_event_handler_set(event_tap, nullptr, nullptr);
  return self;
}

void zest_pointer_capture_free(ZestPointerCapture* self) {
  if (self == nullptr) {
    return;
  }
  let_go(self, FALSE);
#ifdef ZEST_HAS_WAYLAND
  // A start still waiting is answered, and what was bound is given back.
  wayland_release(self);
  finish_start(self, FALSE);
  if (self->relative_manager != nullptr) {
    zwp_relative_pointer_manager_v1_destroy(self->relative_manager);
  }
  if (self->constraints != nullptr) {
    zwp_pointer_constraints_v1_destroy(self->constraints);
  }
  if (self->registry != nullptr) {
    wl_registry_destroy(self->registry);
  }
#endif
  if (g_capture == self) {
    g_capture = nullptr;
    gdk_event_handler_set(reinterpret_cast<GdkEventFunc>(gtk_main_do_event),
                          nullptr, nullptr);
  }
  if (self->window != nullptr) {
    if (self->active_handler != 0) {
      g_signal_handler_disconnect(self->window, self->active_handler);
    }
    g_object_remove_weak_pointer(G_OBJECT(self->window),
                                 reinterpret_cast<gpointer*>(&self->window));
  }
  if (self->view != nullptr) {
    g_object_remove_weak_pointer(G_OBJECT(self->view),
                                 reinterpret_cast<gpointer*>(&self->view));
  }
  g_clear_object(&self->methods);
  g_clear_object(&self->events);
  g_clear_object(&self->blank);
  g_free(self);
}
