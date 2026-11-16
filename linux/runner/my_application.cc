#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <string.h>

#include "flutter/generated_plugin_registrant.h"
#include "pointer_capture.h"

// The deep link channel's name, as lib/services/deep_link_service.dart has it.
static const char kDeepLinkChannel[] = "com.affluentlabs.zestssh/deeplink";

// Links kept before Dart listens: a few, as Dart keeps.
static const guint kMaxEarlyLinks = 8;

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;

  // One ZestSSH per session (GApplication, over D-Bus): a second start (a
  // zestssh:// link opened, the menu again) hands its link to this one,
  // whose window comes to the front, and ends. The window, and the links
  // handed over before Dart listened (the app was starting).
  GtkWindow* window;
  FlMethodChannel* deep_link_channel;
  GPtrArray* early_links;
  gboolean dart_listening;

  // Relative mouse on a remote screen (pointer_capture.h): this window's
  // pointer held, and given back.
  ZestPointerCapture* pointer_capture;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static gboolean is_zestssh_link(const gchar* text) {
  return text != nullptr && g_ascii_strncasecmp(text, "zestssh://", 10) == 0;
}

// The link to Dart now, or kept until it listens.
static void hand_link_to_dart(MyApplication* self, const gchar* link) {
  if (self->dart_listening && self->deep_link_channel != nullptr) {
    g_autoptr(FlValue) value = fl_value_new_string(link);
    fl_method_channel_invoke_method(self->deep_link_channel, "onDeepLink",
                                    value, nullptr, nullptr, nullptr);
  } else if (self->early_links->len < kMaxEarlyLinks) {
    g_ptr_array_add(self->early_links, g_strdup(link));
  }
}

static void deep_link_call_cb(FlMethodChannel* channel,
                              FlMethodCall* method_call, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (strcmp(fl_method_call_get_name(method_call), "getInitialLink") != 0) {
    fl_method_call_respond_not_implemented(method_call, nullptr);
    return;
  }
  // The link this start was opened with comes to Dart on its command line
  // (lib/main.dart); none here. Dart listens from now on: what was handed
  // over meanwhile goes to it now.
  self->dart_listening = TRUE;
  g_autoptr(FlValue) none = fl_value_new_null();
  fl_method_call_respond_success(method_call, none, nullptr);
  g_autoptr(GPtrArray) early = self->early_links;
  self->early_links = g_ptr_array_new_with_free_func(g_free);
  for (guint i = 0; i < early->len; i++) {
    hand_link_to_dart(self, static_cast<const gchar*>(g_ptr_array_index(early, i)));
  }
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  // Started again while it runs: the window there is brought to the front
  // (from the tray too), no second one.
  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->window));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "zestssh");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "zestssh");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->deep_link_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      kDeepLinkChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->deep_link_channel,
                                            deep_link_call_cb, self, nullptr);

  self->pointer_capture = zest_pointer_capture_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), window,
      GTK_WIDGET(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::open: a second start handed over its link.
static void my_application_open(GApplication* application, GFile** files,
                                gint n_files, const gchar* hint) {
  MyApplication* self = MY_APPLICATION(application);
  my_application_activate(application);
  for (gint i = 0; i < n_files; i++) {
    g_autofree gchar* uri = g_file_get_uri(files[i]);
    // Only a zestssh:// link goes on (to Dart, which reads it as strictly
    // as any opened link).
    if (is_zestssh_link(uri)) {
      hand_link_to_dart(self, uri);
    }
  }
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  // A command from a terminal (zestssh admin ...) runs on its own, as ever.
  gchar** args = self->dart_entrypoint_arguments;
  if (args[0] != nullptr && strcmp(args[0], "admin") == 0) {
    g_application_set_flags(application,
                            static_cast<GApplicationFlags>(
                                g_application_get_flags(application) |
                                G_APPLICATION_NON_UNIQUE));
  }

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  // Another ZestSSH runs in this session: it gets the link (or is just
  // brought to the front), and this start ends.
  if (g_application_get_is_remote(application)) {
    const gchar* link = nullptr;
    for (gchar** a = args; *a != nullptr; a++) {
      if (is_zestssh_link(*a)) {
        link = *a;
        break;
      }
    }
    if (link != nullptr) {
      GFile* files[1] = {g_file_new_for_uri(link)};
      g_application_open(application, files, 1, "");
      g_object_unref(files[0]);
    } else {
      g_application_activate(application);
    }
    *exit_status = 0;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  // The pointer first: given back before the channels go.
  g_clear_pointer(&self->pointer_capture, zest_pointer_capture_free);
  g_clear_object(&self->deep_link_channel);
  g_clear_pointer(&self->early_links, g_ptr_array_unref);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->early_links = g_ptr_array_new_with_free_func(g_free);
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_OPEN, nullptr));
}
