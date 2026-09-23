#include "env.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_ENTRIES 24
#define MAX_NAME 48
#define MAX_VALUE 192

static struct {
    char name[MAX_NAME];
    char value[MAX_VALUE];
} entries[MAX_ENTRIES];
static size_t count;

void jf_env_add(const char *name, const char *value)
{
    if (count == MAX_ENTRIES || name[0] == '\0')
        return;
    for (size_t i = 0; i < count; i++)
        if (strcmp(entries[i].name, name) == 0)
            return;
    snprintf(entries[count].name, sizeof(entries[count].name), "%s", name);
    snprintf(entries[count].value, sizeof(entries[count].value), "%s", value);
    count++;
    fprintf(stderr, "debug.env: %s=%s\n", name, value);
}

const char *jf_env(const char *name)
{
    const char *value = getenv(name);
    if (value != NULL)
        return value;
    for (size_t i = 0; i < count; i++)
        if (strcmp(entries[i].name, name) == 0)
            return entries[i].value;
    return NULL;
}

bool jf_env_flag(const char *name) { return jf_env(name) != NULL; }
