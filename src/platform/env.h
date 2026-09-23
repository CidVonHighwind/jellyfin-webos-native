/* Debug switches, from the environment or from a file the platform provides.
 *
 * SAM launches an app with an environment of its own making and no way to add to it, so on
 * the TV the switches are read from conf/debug.env instead - one KEY=VALUE per line. The
 * environment still wins where it has a value, so a hand-started run can override the file.
 */
#pragma once

#include <stdbool.h>

/* Loads whatever the platform keeps its overrides in. Call once, after the store root is
 * known: that is where the file lives. */
void jf_env_init(void);

/* The environment first, then what jf_env_init loaded. NULL when set in neither. */
const char *jf_env(const char *name);

/* Set in either, whatever the value. */
bool jf_env_flag(const char *name);

/* For jf_env_init: record one override. Ignored once full or if the key is already held. */
void jf_env_add(const char *name, const char *value);
