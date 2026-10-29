#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* notification_channel;
  gchar* pending_notification_payload;
  gboolean notification_channel_ready;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static constexpr char kNotificationChannel[] =
    "network.noosphere.sygnature/notifications";

static void notification_method_response_cb(GObject* object,
                                            GAsyncResult* result,
                                            gpointer user_data) {
  FlMethodCall* method_call = FL_METHOD_CALL(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) response = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(object), result, &error);
  g_autoptr(FlMethodResponse) method_response = nullptr;
  if (response == nullptr) {
    method_response = FL_METHOD_RESPONSE(fl_method_error_response_new(
        "portal-error", error->message, nullptr));
  } else {
    g_autoptr(FlValue) value = fl_value_new_bool(TRUE);
    method_response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  }
  fl_method_call_respond(method_call, method_response, nullptr);
  g_object_unref(method_call);
}

static void notification_method_call_cb(FlMethodChannel* channel,
                                        FlMethodCall* method_call,
                                        gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "initialize") == 0) {
    self->notification_channel_ready = TRUE;
    g_autoptr(FlValue) pending = self->pending_notification_payload == nullptr
        ? fl_value_new_null()
        : fl_value_new_string(self->pending_notification_payload);
    g_clear_pointer(&self->pending_notification_payload, g_free);
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(pending));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  if (g_strcmp0(method, "show") != 0) {
    fl_method_call_respond_not_implemented(method_call, nullptr);
    return;
  }

  FlValue* arguments = fl_method_call_get_args(method_call);
  FlValue* id = arguments == nullptr
                    ? nullptr
                    : fl_value_lookup_string(arguments, "id");
  FlValue* title = arguments == nullptr
                       ? nullptr
                       : fl_value_lookup_string(arguments, "title");
  FlValue* body = arguments == nullptr
                      ? nullptr
                      : fl_value_lookup_string(arguments, "body");
  FlValue* payload = arguments == nullptr
                         ? nullptr
                         : fl_value_lookup_string(arguments, "payload");
  if (arguments == nullptr ||
      fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP || id == nullptr ||
      title == nullptr || body == nullptr || payload == nullptr ||
      fl_value_get_type(id) != FL_VALUE_TYPE_INT ||
      fl_value_get_type(title) != FL_VALUE_TYPE_STRING ||
      fl_value_get_type(body) != FL_VALUE_TYPE_STRING ||
      fl_value_get_type(payload) != FL_VALUE_TYPE_STRING) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_error_response_new(
            "bad-arguments", "Invalid notification details", nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  GDBusConnection* connection =
      g_application_get_dbus_connection(G_APPLICATION(self));
  if (connection == nullptr) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_error_response_new(
            "portal-unavailable", "No session D-Bus connection", nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  GVariantBuilder notification;
  g_variant_builder_init(&notification, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&notification, "{sv}", "title",
                        g_variant_new_string(fl_value_get_string(title)));
  g_variant_builder_add(&notification, "{sv}", "body",
                        g_variant_new_string(fl_value_get_string(body)));
  g_variant_builder_add(&notification, "{sv}", "sound",
                        g_variant_new_string("silent"));
  g_variant_builder_add(
      &notification, "{sv}", "default-action",
      g_variant_new_string("app.open-notification"));
  g_variant_builder_add(
      &notification, "{sv}", "default-action-target",
      g_variant_new_string(fl_value_get_string(payload)));
  g_autofree gchar* notification_id =
      g_strdup_printf("%" G_GINT64_FORMAT, fl_value_get_int(id));
  g_dbus_connection_call(
      connection, "org.freedesktop.portal.Desktop",
      "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Notification",
      "AddNotification",
      g_variant_new("(s@a{sv})", notification_id,
                    g_variant_builder_end(&notification)),
      nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
      notification_method_response_cb, g_object_ref(method_call));
}

static void notification_action_cb(GSimpleAction* action,
                                   GVariant* parameter,
                                   gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* payload = g_variant_get_string(parameter, nullptr);
  if (self->notification_channel_ready &&
      self->notification_channel != nullptr) {
    g_autoptr(FlValue) value = fl_value_new_string(payload);
    fl_method_channel_invoke_method(self->notification_channel,
                                    "notificationResponse", value, nullptr,
                                    nullptr, nullptr);
  } else {
    g_free(self->pending_notification_payload);
    self->pending_notification_payload = g_strdup(payload);
  }
  g_application_activate(G_APPLICATION(self));
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

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
    gtk_header_bar_set_title(header_bar, "Sygnature");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Sygnature");
  }

  gtk_window_set_default_size(window, 1280, 720);
  gtk_window_set_icon_name(window, APPLICATION_ID);
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable != nullptr) {
    g_autofree gchar* directory = g_path_get_dirname(executable);
    g_autofree gchar* icon_path =
        g_build_filename(directory, "data", "app-icon.png", nullptr);
    gtk_window_set_icon_from_file(window, icon_path, nullptr);
  }

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
  self->notification_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      kNotificationChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->notification_channel, notification_method_call_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  if (g_strv_length(*arguments) == 2 &&
      g_strcmp0((*arguments)[1], "--gapplication-service") == 0) {
    return G_APPLICATION_CLASS(my_application_parent_class)
        ->local_command_line(application, arguments, exit_status);
  }
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return FALSE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);

  g_autoptr(GSimpleAction) notification_action = g_simple_action_new(
      "open-notification", G_VARIANT_TYPE_STRING);
  g_signal_connect(notification_action, "activate",
                   G_CALLBACK(notification_action_cb), application);
  g_action_map_add_action(G_ACTION_MAP(application),
                          G_ACTION(notification_action));
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
  g_clear_object(&self->notification_channel);
  g_clear_pointer(&self->pending_notification_payload, g_free);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE |
                                         G_APPLICATION_HANDLES_OPEN,
                                     nullptr));
}
