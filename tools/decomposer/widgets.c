// Explicit widget fragments use the HTML tokenizer and balanced component tags.
// Standard HTML always goes through Lexbor's unmodified HTML5 tree builder.
#include "parse.h"
#include <lexbor/html/html.h>
#include <lexbor/html/tag.h>
#include <lexbor/html/tokenizer/error.h>

typedef struct { lxb_tag_id_t tag; size_t pos; bool comma; } Parent;
typedef struct { Parent *stack; size_t count, capacity; } Fragment;

static void widget_error(const char *message, size_t pos) {
    diagnostic("error", (const Byte *)message, strlen(message), pos);
}

static lxb_html_token_t *accept(lxb_html_tokenizer_t *tk, lxb_html_token_t *t, void *ctx) {
    Fragment *f = ctx;
    size_t pos = position(t->begin);
    if (t->tag_id == LXB_TAG__END_OF_FILE || t->tag_id == LXB_TAG__EM_COMMENT) return t;
    if (t->tag_id == LXB_TAG__EM_DOCTYPE) {
        widget_error("unexpected doctype in widget fragment", pos);
        return t;
    }
    if (t->type & LXB_HTML_TOKEN_TYPE_CLOSE) {
        if (f->count == 1 || f->stack[f->count-1].tag != t->tag_id)
            widget_error("closing widget does not match the open widget", pos);
        else { fputs("]}", stdout); f->count--; }
        return t;
    }
    if (f->stack[f->count-1].comma) putchar(',');
    f->stack[f->count-1].comma = true;
    if (t->tag_id == LXB_TAG__TEXT) {
        fputs("{\"kind\":\"text\",\"text\":", stdout);
        json_string(t->text_start, (size_t)(t->text_end - t->text_start));
        fputs(",\"offset\":", stdout); json_pos(pos); putchar('}');
        return t;
    }
    if (pos != SIZE_MAX && pos && source[pos-1] == '<') pos--;
    size_t n;
    const Byte *name = lxb_tag_name_by_id(t->tag_id, &n);
    fputs("{\"kind\":\"element\",\"namespace\":\"widget\",\"tag\":", stdout);
    json_string(name, n);
    fputs(",\"offset\":", stdout); json_pos(pos);
    fputs(",\"attrs\":[", stdout);
    for (lxb_html_token_attr_t *a = t->attr_first; a; a = a->next) {
        if (a != t->attr_first) putchar(',');
        fputs("{\"name\":", stdout);
        name = lxb_html_token_attr_name(a, &n);
        json_string(name, n);
        fputs(",\"value\":", stdout); json_string(a->value, a->value_size);
        fputs(",\"offset\":", stdout); json_pos(position(a->name_begin));
        fputs(",\"value_offset\":", stdout); json_pos(position(a->value_begin));
        putchar('}');
    }
    fputs("],\"children\":[", stdout);
    if ((t->type & LXB_HTML_TOKEN_TYPE_CLOSE_SELF) || (t->tag_id != LXB_TAG_COL && lxb_html_tag_is_void(t->tag_id))) {
        fputs("]}", stdout);
        return t;
    }
    if (f->count == f->capacity) {
        f->capacity *= 2;
        f->stack = realloc(f->stack, f->capacity * sizeof(*f->stack));
        if (!f->stack) fail("out of memory");
    }
    f->stack[f->count++] = (Parent){ t->tag_id, pos, false };
    lxb_html_tokenizer_set_state_by_tag(tk, false, t->tag_id, LXB_NS_HTML);
    return t;
}

void parse_widgets(void) {
    Fragment f = { .count = 1, .capacity = 16 };
    f.stack = calloc(f.capacity, sizeof(*f.stack));
    lxb_html_tokenizer_t *tk = lxb_html_tokenizer_create();
    if (!f.stack || !tk || lxb_html_tokenizer_init(tk) != LXB_STATUS_OK) fail("cannot initialize widget tokenizer");
    lxb_html_tokenizer_callback_token_done_set(tk, accept, &f);
    fputs("{\"mode\":\"widgets\",\"doctype\":null,\"nodes\":[", stdout);
    size_t bom = source_len >= 3 && !memcmp(source, "\xef\xbb\xbf", 3) ? 3 : 0;
    if (lxb_html_tokenizer_begin(tk) != LXB_STATUS_OK || lxb_html_tokenizer_chunk(tk, source + bom, source_len - bom) != LXB_STATUS_OK ||
        lxb_html_tokenizer_end(tk) != LXB_STATUS_OK) fail("widget tokenization failed");
    while (f.count > 1) {
        widget_error("unclosed widget element", f.stack[--f.count].pos);
        fputs("]}", stdout);
    }
    putchar(']');
    for (size_t i = 0; tk->parse_errors && i < lexbor_array_obj_length(tk->parse_errors); i++) {
        const lxb_html_tokenizer_error_t *e = lexbor_array_obj_get(tk->parse_errors, i);
        size_t n; const Byte *msg = lxb_html_tokenizer_error_to_string(e->id, &n);
        diagnostic("error", msg, n, position(e->pos));
    }
    lxb_html_tokenizer_destroy(tk);
    free(f.stack);
}
