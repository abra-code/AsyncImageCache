#ifndef ASYNCIMAGECACHE_CGTK_H
#define ASYNCIMAGECACHE_CGTK_H

// GTK 4 (GdkTexture for decoded images) and GLib (GChecksum, the main context), for the Linux
// engine. The oldest versions supported are GNOME 48's: GTK 4.18 and GLib 2.84. A call that needs a
// newer version compiles with the warning "is deprecated: Not available before X.Y", so it shows
// in the build even on a machine with newer libraries.
#define GLIB_VERSION_MIN_REQUIRED GLIB_VERSION_2_84
#define GLIB_VERSION_MAX_ALLOWED GLIB_VERSION_2_84
#define GDK_VERSION_MIN_REQUIRED GDK_VERSION_4_18
#define GDK_VERSION_MAX_ALLOWED GDK_VERSION_4_18

#include <gtk/gtk.h>

// GLib 2.88 declares its flags types with G_GNUC_FLAG_ENUM, and Swift then imports them as option sets whose
// members lose their C names (G_CONNECT_DEFAULT is not found). Swift code writes no flags as init(rawValue: 0),
// never Type(0) or a C name, so it builds under every GLib version.

#endif
