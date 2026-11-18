#ifndef DECOMPOSER_PARSE_H
#define DECOMPOSER_PARSE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char Byte;
extern const Byte *source;
extern size_t source_len;

void fail(const char *message);
void json_string(const Byte *data, size_t length);
void json_pos(size_t pos);
size_t position(const Byte *p);
void diagnostic(const char *severity, const Byte *message, size_t length, size_t pos);
void write_diagnostics(void);
void parse_html(void);
void parse_widgets(void);
void parse_css(bool declarations_only);

#endif
