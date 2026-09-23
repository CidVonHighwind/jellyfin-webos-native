#include "cfg.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../platform/os.h"

struct cfg_entry {
  cfg_entry *next;
  char *section;
  char *key;
  char *value;
};

static char *trim(char *text) {
  while (*text == ' ' || *text == '\t')
    text++;
  char *end = text + strlen(text);
  while (end > text && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r'))
    *--end = '\0';
  return text;
}

static cfg_entry *append(cfg *document, char *section, char *key, char *value) {
  cfg_entry *entry = jf_arena_alloc(document->arena, sizeof(*entry));
  if (entry == NULL)
    return NULL;
  entry->next = NULL;
  entry->section = section;
  entry->key = key;
  entry->value = value;
  if (document->tail != NULL)
    document->tail->next = entry;
  else
    document->entries = entry;
  document->tail = entry;
  return entry;
}

bool cfg_load(cfg *document, jf_arena *arena, const char *path) {
  memset(document, 0, sizeof(*document));
  document->arena = arena;
  document->path = jf_arena_strdup(arena, path);
  if (document->path == NULL)
    return false;
  const int file = open(path, O_RDONLY);
  if (file < 0)
    return true;
  struct stat info;
  if (fstat(file, &info) != 0 || info.st_size < 0 ||
      info.st_size > 1024 * 1024) {
    close(file);
    return false;
  }
  char *contents = jf_arena_alloc(arena, (size_t)info.st_size + 1);
  if (contents == NULL) {
    close(file);
    return false;
  }
  size_t filled = 0;
  while (filled < (size_t)info.st_size) {
    const ssize_t read_size =
        read(file, contents + filled, (size_t)info.st_size - filled);
    if (read_size <= 0)
      break;
    filled += (size_t)read_size;
  }
  close(file);
  contents[filled] = '\0';

  char *section = "";
  for (char *line = contents; line != NULL;) {
    char *next = strchr(line, '\n');
    if (next != NULL)
      *next++ = '\0';
    char *text = trim(line);
    if (text[0] == '[') {
      char *end = strchr(text + 1, ']');
      if (end != NULL) {
        *end = '\0';
        section = trim(text + 1);
      }
    } else if (text[0] != '\0' && text[0] != ';' && text[0] != '#') {
      char *equals = strchr(text, '=');
      if (equals != NULL) {
        *equals = '\0';
        if (append(document, section, trim(text), trim(equals + 1)) == NULL)
          return false;
      }
    }
    line = next;
  }
  return true;
}

void cfg_section(cfg *document, const char *name) {
  document->section = name;
  document->array_key = NULL;
  document->array_index = 0;
}

static cfg_entry *find(const cfg *document, const char *key,
                       unsigned occurrence) {
  unsigned found = 0;
  for (cfg_entry *entry = document->entries; entry != NULL;
       entry = entry->next) {
    if (strcmp(entry->section, document->section) != 0 ||
        strcmp(entry->key, key) != 0)
      continue;
    if (found++ == occurrence)
      return entry;
  }
  return NULL;
}

static cfg_entry *add(cfg *document, const char *key, const char *value) {
  char *section_copy = jf_arena_strdup(document->arena, document->section);
  char *key_copy = jf_arena_strdup(document->arena, key);
  char *value_copy = jf_arena_strdup(document->arena, value);
  if (section_copy == NULL || key_copy == NULL || value_copy == NULL)
    return NULL;
  return append(document, section_copy, key_copy, value_copy);
}

const char *cfg_text(cfg *document, const char *key, const char *fallback) {
  cfg_entry *entry = find(document, key, 0);
  if (entry == NULL)
    entry = add(document, key, fallback);
  return entry != NULL ? entry->value : fallback;
}

int cfg_int(cfg *document, const char *key, int fallback) {
  cfg_entry *entry = find(document, key, 0);
  if (entry == NULL) {
    char value[32];
    snprintf(value, sizeof(value), "%d", fallback);
    entry = add(document, key, value);
  }
  return entry != NULL ? (int)strtol(entry->value, NULL, 10) : fallback;
}

float cfg_float(cfg *document, const char *key, float fallback) {
  cfg_entry *entry = find(document, key, 0);
  if (entry == NULL) {
    char value[48];
    snprintf(value, sizeof(value), "%g", fallback);
    entry = add(document, key, value);
  }
  return entry != NULL ? strtof(entry->value, NULL) : fallback;
}

void cfg_array(cfg *document, const char *key) {
  document->array_key = key;
  document->array_index = 0;
}

const char *cfg_array_text(cfg *document, const char *fallback) {
  if (document->array_key == NULL)
    return fallback;
  cfg_entry *entry =
      find(document, document->array_key, document->array_index++);
  if (entry == NULL)
    entry = add(document, document->array_key, fallback);
  return entry != NULL ? entry->value : fallback;
}

void cfg_set_int(cfg *document, const char *key, int value) {
  cfg_entry *entry = find(document, key, 0);
  if (entry == NULL) {
    (void)cfg_int(document, key, value);
    entry = find(document, key, 0);
  }
  if (entry != NULL) {
    char formatted[32];
    snprintf(formatted, sizeof(formatted), "%d", value);
    entry->value = jf_arena_strdup(document->arena, formatted);
  }
}

bool cfg_save(const cfg *document) {
  char temporary[600];
  const int length =
      snprintf(temporary, sizeof(temporary), "%s.tmp", document->path);
  if (length <= 0 || (size_t)length >= sizeof(temporary))
    return false;
  const int file = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (file < 0)
    return false;
  const char *section = NULL;
  bool ok = true;
  for (const cfg_entry *entry = document->entries; entry != NULL;
       entry = entry->next) {
    if (section == NULL || strcmp(section, entry->section) != 0) {
      if (jf_os_write_fmt(file, "%s[%s]\n", section != NULL ? "\n" : "",
                          entry->section) < 0) {
        ok = false;
        break;
      }
      section = entry->section;
    }
    if (jf_os_write_fmt(file, "%s=%s\n", entry->key, entry->value) < 0) {
      ok = false;
      break;
    }
  }
  if (ok && jf_os_fsync(file) != 0)
    ok = false;
  close(file);
  if (!ok || rename(temporary, document->path) != 0) {
    unlink(temporary);
    return false;
  }
  return true;
}
