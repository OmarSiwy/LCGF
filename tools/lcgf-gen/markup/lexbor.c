// The only C in the markup compiler: it walks Lexbor's structures and copies what the compiler
// reads into flat rows (lexbor.zig declares the same layouts). Lexbor owns HTML5 tree
// construction and CSS tokenization; everything after that is Zig. Ported from
// 141d297d:tools/decomposer/html.c, which recorded source positions the same way.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <lexbor/html/html.h>
#include <lexbor/dom/interfaces/character_data.h>
#include <lexbor/html/tree/error.h>
#include <lexbor/html/tokenizer/error.h>
#include <lexbor/html/interfaces/template_element.h>
#include <lexbor/css/css.h>
#include <lexbor/css/syntax/tokenizer/error.h>

#define NONE 0xffffffffu

typedef struct { uint32_t off, len; } lcgf_str;
typedef struct {
    uint32_t kind; // 1 element, 3 text
    uint32_t parent;
    lcgf_str name; // element: qualified name; text: its data
    uint32_t src;  // byte offset of '<' or of the text, NONE if unknown
    uint32_t attr_first, attr_count;
    uint32_t in_template; // inside a <template>'s content
} lcgf_html_node;
typedef struct { lcgf_str name, value; uint32_t name_src, value_src; } lcgf_html_attr;
typedef struct { lcgf_str msg; uint32_t src; } lcgf_diag;
typedef struct {
    lcgf_html_node *nodes; uint32_t n_nodes;
    lcgf_html_attr *attrs; uint32_t n_attrs;
    lcgf_diag *diags; uint32_t n_diags;
    uint8_t *pool; uint32_t pool_len;
    uint32_t quirks, doctype;
} lcgf_html;
typedef struct {
    uint32_t type, begin, end; // end: one past the token's last source byte
    lcgf_str str;              // decoded name, string or unit
    double num;
    uint32_t is_float, delim;
} lcgf_css_token;
typedef struct {
    lcgf_css_token *tokens; uint32_t n_tokens;
    lcgf_diag *diags; uint32_t n_diags;
    uint8_t *pool; uint32_t pool_len;
} lcgf_css;

static void *grow(void **p, uint32_t *n, uint32_t *cap, size_t size) {
    if (*n == *cap) {
        *cap = *cap ? *cap * 2 : 64;
        void *q = realloc(*p, (size_t)*cap * size);
        if (!q) return NULL;
        *p = q;
    }
    return (char *)*p + (size_t)(*n)++ * size;
}

typedef struct { uint8_t *data; uint32_t len, cap; } Pool;

static lcgf_str pool_add(Pool *pool, const lxb_char_t *data, size_t len) {
    lcgf_str s = {pool->len, (uint32_t)len};
    if (pool->len + len > pool->cap) {
        uint32_t cap = pool->cap ? pool->cap : 1024;
        while (cap < pool->len + len) cap *= 2;
        uint8_t *q = realloc(pool->data, cap);
        if (!q) return (lcgf_str){NONE, 0};
        pool->data = q;
        pool->cap = cap;
    }
    if (len) memcpy(pool->data + pool->len, data, len);
    pool->len += (uint32_t)len;
    return s;
}

// ---- HTML ---------------------------------------------------------------------------------------

static const lxb_char_t *source;
static size_t source_len;
static lxb_html_token_t *current;
static lxb_html_tokenizer_token_f tree_token;
static void *tree_ctx;
static const lxb_dom_document_mutation_cb_t *tree_mutation;
typedef struct { uint32_t name, value; } AttrPos;

static uint32_t position(const lxb_char_t *p) {
    uintptr_t loc = (uintptr_t)p, base = (uintptr_t)source;
    return p && loc >= base && loc - base <= source_len ? (uint32_t)(loc - base) : NONE;
}

static lxb_html_token_t *record_token(lxb_html_tokenizer_t *tk, lxb_html_token_t *token, void *ctx) {
    (void)ctx;
    current = token;
    lxb_html_token_t *next = tree_token(tk, token, tree_ctx);
    current = NULL;
    return next;
}

// Stamps each node with the offset of the token that created it (+1, so 0 means none).
static lxb_status_t inserted(lxb_dom_node_t *node) {
    if (current && !node->user) {
        uint32_t pos = position(current->begin);
        if (node->type == LXB_DOM_NODE_TYPE_ELEMENT && current->tag_id == node->local_name &&
            !(current->type & LXB_HTML_TOKEN_TYPE_CLOSE)) {
            if (pos != NONE && pos && source[pos - 1] == '<') pos--;
            node->user = (void *)(uintptr_t)((uint64_t)pos + 1);
            lxb_dom_attr_t *a = lxb_dom_element_first_attribute(lxb_dom_interface_element(node));
            for (lxb_html_token_attr_t *t = current->attr_first; t && a; t = t->next) {
                if (a->node.local_name != t->name->attr_id) continue;
                AttrPos *p = lexbor_mraw_alloc(node->owner_document->mraw, sizeof(*p));
                if (!p) return LXB_STATUS_ERROR_MEMORY_ALLOCATION;
                *p = (AttrPos){position(t->name_begin), position(t->value_begin)};
                a->node.user = p;
                a = lxb_dom_element_next_attribute(a);
            }
        } else if (node->type == LXB_DOM_NODE_TYPE_TEXT && current->tag_id == LXB_TAG__TEXT) {
            node->user = (void *)(uintptr_t)((uint64_t)pos + 1);
        }
    }
    return tree_mutation && tree_mutation->inserted ? tree_mutation->inserted(node) : LXB_STATUS_OK;
}

static uint32_t stamp(lxb_dom_node_t *n) {
    return n->user ? (uint32_t)((uintptr_t)n->user - 1) : NONE;
}

typedef struct { lxb_dom_node_t *node; uint32_t parent, in_template; } Level;

static int walk(lcgf_html *out, Pool *pool, lxb_dom_node_t *first) {
    uint32_t cap_nodes = 0, cap_attrs = 0, depth = 1, cap_levels = 32;
    Level *levels = malloc(cap_levels * sizeof(*levels));
    if (!levels) return 1;
    levels[0] = (Level){first, NONE, 0};
    while (depth) {
        Level *level = &levels[depth - 1];
        lxb_dom_node_t *n = level->node;
        if (!n) { depth--; continue; }
        level->node = n->next;
        if (n->type != LXB_DOM_NODE_TYPE_ELEMENT && n->type != LXB_DOM_NODE_TYPE_TEXT) continue;
        uint32_t index = out->n_nodes;
        lcgf_html_node *row = grow((void **)&out->nodes, &out->n_nodes, &cap_nodes, sizeof(*row));
        if (!row) return 1;
        *row = (lcgf_html_node){(uint32_t)n->type, level->parent, {0, 0}, stamp(n), out->n_attrs, 0, level->in_template};
        if (n->type == LXB_DOM_NODE_TYPE_TEXT) {
            lexbor_str_t text = lxb_dom_interface_character_data(n)->data;
            row->name = pool_add(pool, text.data, text.length);
            continue;
        }
        lxb_dom_element_t *e = lxb_dom_interface_element(n);
        size_t len;
        const lxb_char_t *name = lxb_dom_element_qualified_name(e, &len);
        row->name = pool_add(pool, name, len);
        for (lxb_dom_attr_t *a = lxb_dom_element_first_attribute(e); a; a = lxb_dom_element_next_attribute(a)) {
            lcgf_html_attr *at = grow((void **)&out->attrs, &out->n_attrs, &cap_attrs, sizeof(*at));
            if (!at) return 1;
            const AttrPos *p = a->node.user;
            name = lxb_dom_attr_qualified_name(a, &len);
            at->name = pool_add(pool, name, len);
            const lxb_char_t *value = lxb_dom_attr_value(a, &len);
            at->value = pool_add(pool, value, value ? len : 0);
            at->name_src = p ? p->name : NONE;
            at->value_src = p ? p->value : NONE;
            out->nodes[index].attr_count++;
        }
        lxb_dom_node_t *child = n->first_child;
        uint32_t in_template = level->in_template;
        if (n->ns == LXB_NS_HTML && n->local_name == LXB_TAG_TEMPLATE) {
            child = ((lxb_html_template_element_t *)n)->content->node.first_child;
            in_template = 1;
        }
        if (depth == cap_levels) {
            cap_levels *= 2;
            Level *q = realloc(levels, cap_levels * sizeof(*levels));
            if (!q) return 1;
            levels = q;
        }
        levels[depth++] = (Level){child, index, in_template};
    }
    free(levels);
    return 0;
}

static int diag(lcgf_html *out, uint32_t *cap, Pool *pool, const lxb_char_t *msg, size_t len, uint32_t src) {
    lcgf_diag *d = grow((void **)&out->diags, &out->n_diags, cap, sizeof(*d));
    if (!d) return 1;
    *d = (lcgf_diag){pool_add(pool, msg, len), src};
    return 0;
}

int lcgf_html_parse(const uint8_t *src, size_t len, lcgf_html *out) {
    memset(out, 0, sizeof(*out));
    source = src;
    source_len = len;
    lxb_html_document_t *doc = lxb_html_document_create();
    if (!doc || lxb_html_document_parse_chunk_begin(doc) != LXB_STATUS_OK) return 1;
    lxb_dom_document_t *dom = lxb_dom_interface_document(doc);
    lxb_html_parser_t *parser = (lxb_html_parser_t *)dom->parser;
    lxb_html_tokenizer_t *tk = lxb_html_parser_tokenizer(parser);
    tree_token = tk->callback_token_done;
    tree_ctx = tk->callback_token_ctx;
    tree_mutation = dom->mutation;
    lxb_dom_document_mutation_cb_t callbacks = {0};
    if (tree_mutation) callbacks = *tree_mutation;
    callbacks.inserted = inserted;
    dom->mutation = &callbacks;
    lxb_html_tokenizer_callback_token_done_set(tk, record_token, NULL);
    if (lxb_html_document_parse_chunk(doc, src, len) != LXB_STATUS_OK ||
        lxb_html_document_parse_chunk_end(doc) != LXB_STATUS_OK) return 1;
    out->quirks = dom->compat_mode != LXB_DOM_DOCUMENT_CMODE_NO_QUIRKS;
    out->doctype = dom->doctype != NULL;
    Pool pool = {0};
    int failed = walk(out, &pool, lxb_dom_interface_node(doc)->first_child);
    uint32_t cap = 0;
    lexbor_array_obj_t *errors = tk->parse_errors;
    for (size_t i = 0; !failed && errors && i < lexbor_array_obj_length(errors); i++) {
        const lxb_html_tokenizer_error_t *e = lexbor_array_obj_get(errors, i);
        size_t n;
        const lxb_char_t *msg = lxb_html_tokenizer_error_to_string(e->id, &n);
        failed = diag(out, &cap, &pool, msg, n, position(e->pos));
    }
    errors = lxb_html_parser_tree(parser)->parse_errors;
    for (size_t i = 0; !failed && errors && i < lexbor_array_obj_length(errors); i++) {
        const lxb_html_tree_error_t *e = lexbor_array_obj_get(errors, i);
        size_t n;
        const lxb_char_t *msg = lxb_html_tree_error_to_string(e->id, &n);
        failed = diag(out, &cap, &pool, msg, n, position(e->begin));
    }
    out->pool = pool.data;
    out->pool_len = pool.len;
    dom->mutation = tree_mutation;
    lxb_html_document_destroy(doc);
    return failed;
}

void lcgf_html_free(lcgf_html *h) {
    free(h->nodes);
    free(h->attrs);
    free(h->diags);
    free(h->pool);
}

// ---- CSS ----------------------------------------------------------------------------------------

int lcgf_css_tokenize(const uint8_t *src, size_t len, lcgf_css *out) {
    memset(out, 0, sizeof(*out));
    source = src;
    source_len = len;
    lxb_css_syntax_tokenizer_t *tk = lxb_css_syntax_tokenizer_create();
    if (!tk || lxb_css_syntax_tokenizer_init(tk) != LXB_STATUS_OK) return 1;
    lxb_css_syntax_tokenizer_buffer_set(tk, src, len);
    Pool pool = {0};
    uint32_t cap = 0, cap_diags = 0;
    int failed = 0;
    for (;;) {
        lxb_css_syntax_token_t *t = lxb_css_syntax_token(tk);
        if (!t) { failed = 1; break; }
        if (t->type == LXB_CSS_SYNTAX_TOKEN__EOF) break;
        if (t->type != LXB_CSS_SYNTAX_TOKEN_COMMENT) {
            lcgf_css_token *row = grow((void **)&out->tokens, &out->n_tokens, &cap, sizeof(*row));
            if (!row) { failed = 1; break; }
            uint32_t begin = (uint32_t)t->offset;
            *row = (lcgf_css_token){(uint32_t)t->type, begin, begin + (uint32_t)t->types.base.length, {0, 0}, 0, 0, 0};
            switch (t->type) {
            case LXB_CSS_SYNTAX_TOKEN_IDENT: case LXB_CSS_SYNTAX_TOKEN_FUNCTION:
            case LXB_CSS_SYNTAX_TOKEN_AT_KEYWORD: case LXB_CSS_SYNTAX_TOKEN_HASH:
            case LXB_CSS_SYNTAX_TOKEN_STRING: case LXB_CSS_SYNTAX_TOKEN_URL:
                row->str = pool_add(&pool, t->types.string.data, t->types.string.length);
                break;
            case LXB_CSS_SYNTAX_TOKEN_DIMENSION:
                row->num = t->types.dimension.num.num;
                row->is_float = t->types.dimension.num.is_float;
                row->str = pool_add(&pool, t->types.dimension.str.data, t->types.dimension.str.length);
                break;
            case LXB_CSS_SYNTAX_TOKEN_NUMBER: case LXB_CSS_SYNTAX_TOKEN_PERCENTAGE:
                row->num = t->types.number.num;
                row->is_float = t->types.number.is_float;
                break;
            case LXB_CSS_SYNTAX_TOKEN_DELIM:
                row->delim = t->types.delim.character;
                break;
            default: break;
            }
        }
        lxb_css_syntax_token_consume(tk);
    }
    lexbor_array_obj_t *errors = tk->parse_errors;
    for (size_t i = 0; !failed && errors && i < lexbor_array_obj_length(errors); i++) {
        const lxb_css_syntax_tokenizer_error_t *e = lexbor_array_obj_get(errors, i);
        lcgf_diag *d = grow((void **)&out->diags, &out->n_diags, &cap_diags, sizeof(*d));
        if (!d) { failed = 1; break; }
        static const char msg[] = "invalid CSS token";
        *d = (lcgf_diag){pool_add(&pool, (const lxb_char_t *)msg, sizeof(msg) - 1), position(e->pos)};
    }
    out->pool = pool.data;
    out->pool_len = pool.len;
    lxb_css_syntax_tokenizer_destroy(tk);
    return failed;
}

void lcgf_css_free(lcgf_css *c) {
    free(c->tokens);
    free(c->diags);
    free(c->pool);
}
