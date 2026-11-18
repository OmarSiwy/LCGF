// The host parser reads one source and produces a JSON tree for the Zig emitter.
#include "parse.h"

const Byte *source;
size_t source_len;

void fail(const char *message) {
    fprintf(stderr, "decomposer-parse: %s\n", message);
    exit(EXIT_FAILURE);
}

void json_string(const Byte *data, size_t length) {
    putchar('"');
    for (size_t i = 0; i < length; i++) {
        unsigned c = data[i];
        if (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c < 32) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}

size_t position(const Byte *p) {
    uintptr_t loc = (uintptr_t)p, base = (uintptr_t)source;
    return loc >= base && loc - base <= source_len ? loc - base : SIZE_MAX;
}

void json_pos(size_t pos) {
    if (pos == SIZE_MAX) fputs("null", stdout);
    else printf("%zu", pos);
}

typedef struct { const char *severity; Byte *message; size_t length, pos; } Diagnostic;
static Diagnostic *issues;
static size_t count, capacity;

void diagnostic(const char *severity, const Byte *message, size_t length, size_t pos) {
    if (count == capacity) {
        capacity = capacity ? capacity * 2 : 8;
        issues = realloc(issues, capacity * sizeof(*issues));
        if (!issues) fail("out of memory");
    }
    Byte *copy = malloc(length + 1);
    if (!copy) fail("out of memory");
    memcpy(copy, message, length);
    issues[count++] = (Diagnostic){severity, copy, length, pos};
}

void write_diagnostics(void) {
    fputs(",\"diagnostics\":[", stdout);
    for (size_t i = 0; i < count; i++) {
        if (i) putchar(',');
        printf("{\"severity\":\"%s\",\"message\":", issues[i].severity);
        json_string(issues[i].message, issues[i].length);
        fputs(",\"offset\":", stdout);
        json_pos(issues[i].pos);
        putchar('}');
        free(issues[i].message);
    }
    free(issues);
    fputs("]}\n", stdout);
}

// JSON strings require UTF-8, so report a bad source byte before emitting JSON.
static void check_utf8(void) {
    for (size_t i = 0; i < source_len;) {
        unsigned c = source[i++];
        if (c < 128) continue;
        size_t extra = c < 0xe0 ? 1 : c < 0xf0 ? 2 : 3;
        if (c >= 0xc2 && c <= 0xf4 && source_len - i >= extra) {
            bool ok = !(c == 0xe0 && source[i] < 0xa0) && !(c == 0xed && source[i] >= 0xa0)
                   && !(c == 0xf0 && source[i] < 0x90) && !(c == 0xf4 && source[i] >= 0x90);
            for (size_t k = 0; k < extra; k++) ok &= (source[i+k] & 0xc0) == 0x80;
            if (ok) { i += extra; continue; }
        }
        fprintf(stderr, "decomposer-parse: invalid UTF-8 at byte %zu\n", i - 1);
        exit(EXIT_FAILURE);
    }
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3 || (strcmp(argv[1], "html") && strcmp(argv[1], "widgets") && strcmp(argv[1], "css") && strcmp(argv[1], "declarations")))
        fail("usage: decomposer-parse html|widgets|css|declarations [FILE|-]");
    FILE *file = argc == 3 && strcmp(argv[2], "-") ? fopen(argv[2], "rb") : stdin;
    if (!file) { perror(argv[2]); return EXIT_FAILURE; }
    size_t size = 8192;
    Byte *data = malloc(size);
    if (!data) fail("out of memory");
    for (;;) {
        source_len += fread(data + source_len, 1, size - source_len, file);
        if (ferror(file)) fail("cannot read input");
        if (source_len < size) break;
        if (size > SIZE_MAX / 2) fail("source too large");
        size *= 2;
        data = realloc(data, size);
        if (!data) fail("out of memory");
    }
    if (file != stdin) fclose(file);
    data[source_len] = 0;
    source = data;
    check_utf8();
    if (!strcmp(argv[1], "html")) parse_html();
    else if (!strcmp(argv[1], "widgets")) parse_widgets();
    else {
        // Ignore a leading UTF-8 BOM without shifting CSS source offsets.
        if (source_len >= 3 && !memcmp(data, "\xef\xbb\xbf", 3)) memset(data, ' ', 3);
        parse_css(!strcmp(argv[1], "declarations"));
    }
    write_diagnostics();
    free(data);
    return ferror(stdout) ? EXIT_FAILURE : EXIT_SUCCESS;
}
