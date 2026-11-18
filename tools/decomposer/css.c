// Preserve original selector/property/value slices so the Zig CSS layer can issue precise diagnostics.
#include "parse.h"
#include <lexbor/css/css.h>
#include <lexbor/css/declaration.h>
#include <lexbor/css/syntax/tokenizer/error.h>

static void css_error(const char *message, size_t offset) {
    diagnostic("error", (const Byte *)message, strlen(message), offset);
}

// Lexbor recovers from an unfinished block or selector at EOF. Retain its
// non-trivia token offsets so source diagnostics and ! important survive that recovery.
typedef struct { size_t offset; lxb_css_syntax_token_type_t type; bool important; } Token;
static Token *tokens;
static size_t token_count;
static size_t *at_rules;
static size_t at_count, next_at;

static size_t token_at(size_t off) {
    size_t lo = 0, hi = token_count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (tokens[mid].offset < off) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

static void scan_tokens(void) {
    lxb_css_syntax_tokenizer_t *tk = lxb_css_syntax_tokenizer_create();
    if (!tk || lxb_css_syntax_tokenizer_init(tk) != LXB_STATUS_OK) fail("cannot initialize CSS tokenizer");
    lxb_css_syntax_tokenizer_buffer_set(tk, source, source_len);
    size_t capacity = 0, depth = 0, stack_size = 0, at_size = 0;
    Token *stack = NULL;
    for (;;) {
        lxb_css_syntax_token_t *t = lxb_css_syntax_token(tk);
        if (!t) fail("CSS tokenizer failed");
        lxb_css_syntax_token_type_t type = t->type;
        if (type == LXB_CSS_SYNTAX_TOKEN__EOF) break;
        if (type != LXB_CSS_SYNTAX_TOKEN_WHITESPACE && type != LXB_CSS_SYNTAX_TOKEN_COMMENT) {
            bool important = false;
            if (type == LXB_CSS_SYNTAX_TOKEN_IDENT) {
                const lxb_css_syntax_token_ident_t *id = lxb_css_syntax_token_ident(t);
                important = id->length == 9 && lexbor_str_data_ncasecmp(id->data, (const Byte *)"important", 9);
            }
            if (token_count == capacity) {
                capacity = capacity ? capacity * 2 : 64;
                tokens = realloc(tokens, capacity * sizeof(*tokens));
                if (!tokens) fail("out of memory");
            }
            tokens[token_count++] = (Token){t->offset, type, important};
            if (type == LXB_CSS_SYNTAX_TOKEN_AT_KEYWORD && depth == 0) {
                if (at_count == at_size) {
                    at_size = at_size ? at_size * 2 : 8;
                    at_rules = realloc(at_rules, at_size * sizeof(*at_rules));
                    if (!at_rules) fail("out of memory");
                }
                at_rules[at_count++] = t->offset;
            }
            lxb_css_syntax_token_type_t close = LXB_CSS_SYNTAX_TOKEN__EOF;
            if (type == LXB_CSS_SYNTAX_TOKEN_LC_BRACKET) close = LXB_CSS_SYNTAX_TOKEN_RC_BRACKET;
            if (type == LXB_CSS_SYNTAX_TOKEN_LS_BRACKET) close = LXB_CSS_SYNTAX_TOKEN_RS_BRACKET;
            if (type == LXB_CSS_SYNTAX_TOKEN_L_PARENTHESIS || type == LXB_CSS_SYNTAX_TOKEN_FUNCTION)
                close = LXB_CSS_SYNTAX_TOKEN_R_PARENTHESIS;
            if (close != LXB_CSS_SYNTAX_TOKEN__EOF) {
                if (depth == stack_size) {
                    stack_size = stack_size ? stack_size * 2 : 8;
                    stack = realloc(stack, stack_size * sizeof(*stack));
                    if (!stack) fail("out of memory");
                }
                stack[depth++] = (Token){t->offset, close, false};
            } else if (type == LXB_CSS_SYNTAX_TOKEN_RC_BRACKET || type == LXB_CSS_SYNTAX_TOKEN_RS_BRACKET ||
                       type == LXB_CSS_SYNTAX_TOKEN_R_PARENTHESIS) {
                if (!depth || stack[depth-1].type != type) css_error("unmatched CSS closing delimiter", t->offset);
                else depth--;
            }
        }
        lxb_css_syntax_token_consume(tk);
    }
    if (depth) css_error("unclosed CSS block or function", stack[depth-1].offset);
    free(stack);
    lxb_css_syntax_tokenizer_destroy(tk);
}

static bool ws(Byte c) {
    return c == ' ' || c == '\r' || c == '\n' || c == '\t' || c == '\f';
}

static void slice(size_t begin, size_t end) {
    if (end > source_len || begin > end) fail("invalid CSS source range");
    while (begin < end && ws(source[begin])) begin++;
    while (end > begin && ws(source[end-1])) end--;
    json_string(source + begin, end - begin);
}

static void declarations(lxb_css_rule_declaration_list_t *list) {
    bool comma = false;
    for (lxb_css_rule_t *r = list ? list->first : NULL; r; r = r->next) {
        if (r->type != LXB_CSS_RULE_DECLARATION) {
            css_error("unsupported rule in declaration list", r->type == LXB_CSS_RULE_AT_RULE ? lxb_css_rule_at(r)->name_begin : SIZE_MAX);
            continue;
        }
        lxb_css_rule_declaration_t *d = lxb_css_rule_declaration(r);
        lxb_css_rule_declaration_offset_t o = d->offset;
        if (o.name_end <= o.name_begin) {
            css_error("invalid CSS declaration", o.value_begin ? o.value_begin : SIZE_MAX);
            continue;
        }
        // CSS permits whitespace/comments and ASCII case folding between ! and important.
        bool important = d->important;
        size_t end = token_at(o.value_end);
        if (!important && end >= 2 && tokens[end-1].important && tokens[end-2].offset >= o.value_begin &&
            tokens[end-2].type == LXB_CSS_SYNTAX_TOKEN_DELIM && source[tokens[end-2].offset] == '!') {
            o.value_end = tokens[end-2].offset;
            important = true;
        }
        if (comma) putchar(',');
        comma = true;
        fputs("{\"name\":", stdout);
        slice(o.name_begin, o.name_end);
        fputs(",\"value\":", stdout);
        slice(o.value_begin, o.value_end);
        printf(",\"offset\":%zu,\"value_offset\":%zu,\"important\":%s}", o.name_begin, o.value_begin, important ? "true" : "false");
    }
}

void parse_css(bool declarations_only) {
    scan_tokens();
    lxb_css_parser_t *p = lxb_css_parser_create();
    lxb_css_stylesheet_t *sheet = lxb_css_stylesheet_create(NULL);
    if (!p || !sheet || lxb_css_parser_init(p, NULL) != LXB_STATUS_OK) fail("cannot initialize CSS parser");
    if (declarations_only) {
        lxb_css_parser_memory_set(p, sheet->memory);
        lxb_css_rule_declaration_list_t *list = lxb_css_declaration_list_parse(p, source, source_len);
        if (!list) fail("cannot parse CSS declaration list");
        fputs("{\"declarations\":[", stdout);
        declarations(list);
    } else {
        if (lxb_css_stylesheet_parse(sheet, p, source, source_len) != LXB_STATUS_OK) fail("cannot parse CSS stylesheet");
        fputs("{\"rules\":[", stdout);
        bool comma = false;
        for (lxb_css_rule_t *r = lxb_css_rule_list(sheet->root)->first; r; r = r->next) {
            if (r->type != LXB_CSS_RULE_STYLE) {
                if (r->type == LXB_CSS_RULE_AT_RULE) css_error("unsupported CSS at-rule", next_at < at_count ? at_rules[next_at++] : SIZE_MAX);
                else if (r->type == LXB_CSS_RULE_BAD_STYLE) css_error("invalid CSS selector", lxb_css_rule_bad_style(r)->prelude_begin);
                else css_error("unsupported CSS rule", SIZE_MAX);
                continue;
            }
            lxb_css_rule_style_t *s = lxb_css_rule_style(r);
            size_t block = token_at(s->prelude_end);
            if (block == token_count || tokens[block].type != LXB_CSS_SYNTAX_TOKEN_LC_BRACKET)
                css_error("expected a CSS rule block", s->prelude_end);
            if (s->child && s->child->first) css_error("nested CSS rules are unsupported", s->prelude_begin);
            if (comma) putchar(',');
            comma = true;
            fputs("{\"selector\":", stdout);
            slice(s->prelude_begin, s->prelude_end);
            printf(",\"offset\":%zu,\"declarations\":[", s->prelude_begin);
            declarations(s->declarations);
            fputs("]}", stdout);
        }
    }
    putchar(']');
    lexbor_array_obj_t *errors = p->tkz->parse_errors;
    for (size_t i = 0; errors && i < lexbor_array_obj_length(errors); i++) {
        lxb_css_syntax_tokenizer_error_t *e = lexbor_array_obj_get(errors, i);
        css_error("invalid CSS token", position(e->pos));
    }
    for (size_t i = 0; p->log && i < lxb_css_log_length(p->log); i++) {
        lxb_css_log_message_t *m = lexbor_array_obj_get(&p->log->messages, i);
        if (m->type >= LXB_CSS_LOG_ERROR) diagnostic("error", m->text.data, m->text.length, SIZE_MAX);
    }
    free(tokens);
    free(at_rules);
    lxb_css_parser_destroy(p, true);
    lxb_css_stylesheet_destroy(sheet, true);
}
