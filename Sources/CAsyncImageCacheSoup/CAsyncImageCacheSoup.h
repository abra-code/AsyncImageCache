#ifndef ASYNCIMAGECACHE_CSOUP_H
#define ASYNCIMAGECACHE_CSOUP_H

// libsoup 3, for loading http and https URLs on Linux. The oldest version supported is GNOME 48's,
// 3.6; a call that needs a newer one compiles with a deprecation warning.
#define SOUP_VERSION_MIN_REQUIRED SOUP_VERSION_3_6
#define SOUP_VERSION_MAX_ALLOWED SOUP_VERSION_3_6

#include <libsoup/soup.h>

#endif
