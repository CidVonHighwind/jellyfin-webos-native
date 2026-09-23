#include "env.h"

#include <stdio.h>
#include <string.h>

#include "../jf/store.h"

static char *trim(char *text)
{
    while (*text == ' ' || *text == '\t')
        text++;
    char *end = text + strlen(text);
    while (end > text && (end[-1] == '\n' || end[-1] == '\r' || end[-1] == ' ' || end[-1] == '\t'))
        end--;
    *end = '\0';
    return text;
}

void jf_env_init(void)
{
    char path[576];
    snprintf(path, sizeof(path), "%s/conf/debug.env", jf_store_root());
    FILE *file = fopen(path, "r");
    if (file == NULL)
        return;
    char line[256];
    while (fgets(line, sizeof(line), file) != NULL) {
        char *cursor = trim(line);
        if (cursor[0] == '\0' || cursor[0] == '#')
            continue;
        char *equals = strchr(cursor, '=');
        if (equals == NULL)
            continue;
        *equals = '\0';
        jf_env_add(trim(cursor), trim(equals + 1));
    }
    fclose(file);
}
