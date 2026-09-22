/* Process-wide settings document. Load it once, declare every setting with a
 * default, and save the complete document after a change. Arrays are repeated
 * values under one key. */
#pragma once

#include "arena.h"

#include <stdbool.h>

typedef struct cfg_entry cfg_entry;
typedef struct {
  jf_arena *arena;
  char *path;
  cfg_entry *entries;
  cfg_entry *tail;
  const char *section;
  const char *array_key;
  unsigned array_index;
} cfg;

bool cfg_load(cfg *document, jf_arena *arena, const char *path);
void cfg_section(cfg *document, const char *name);
const char *cfg_text(cfg *document, const char *key, const char *fallback);
int cfg_int(cfg *document, const char *key, int fallback);
float cfg_float(cfg *document, const char *key, float fallback);
void cfg_array(cfg *document, const char *key);
const char *cfg_array_text(cfg *document, const char *fallback);
void cfg_set_int(cfg *document, const char *key, int value);
bool cfg_save(const cfg *document);
