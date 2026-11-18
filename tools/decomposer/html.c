// Lexbor owns HTML5 tree construction. The callbacks only record source locations.
#include "parse.h"
#include <lexbor/html/html.h>
#include <lexbor/dom/interfaces/character_data.h>
#include <lexbor/dom/interfaces/document_type.h>
#include <lexbor/html/tree/error.h>
#include <lexbor/html/tokenizer/error.h>
#include <lexbor/html/interfaces/template_element.h>

static lxb_html_token_t *current;
static lxb_html_tokenizer_token_f tree_token;
static void *tree_ctx;
static const lxb_dom_document_mutation_cb_t *tree_mutation;
typedef struct { size_t name, value; } AttrPos;

static lxb_html_token_t *record_token(lxb_html_tokenizer_t *tk, lxb_html_token_t *token, void *ctx) {
    (void)ctx;
    current = token;
    lxb_html_token_t *next = tree_token(tk, token, tree_ctx);
    current = NULL;
    return next;
}

static lxb_status_t inserted(lxb_dom_node_t *node) {
    if (current && !node->user) {
        size_t pos = position(current->begin);
        if (node->type == LXB_DOM_NODE_TYPE_ELEMENT && current->tag_id == node->local_name &&
            !(current->type & LXB_HTML_TOKEN_TYPE_CLOSE)) {
            if (pos != SIZE_MAX && pos && source[pos-1] == '<') pos--;
            node->user = (void *)(uintptr_t)(pos + 1);
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
            node->user = (void *)(uintptr_t)(pos + 1);
        }
    }
    return tree_mutation && tree_mutation->inserted ? tree_mutation->inserted(node) : LXB_STATUS_OK;
}

static lxb_dom_node_t *element(lxb_dom_node_t *node) {
    lxb_dom_element_t *e = lxb_dom_interface_element(node);
    size_t n;
    const Byte *name = lxb_dom_element_qualified_name(e, &n);
    fputs("{\"kind\":\"element\",\"tag\":", stdout);
    json_string(name, n);
    const char *ns = node->ns == LXB_NS_HTML ? "html" : node->ns == LXB_NS_SVG ? "svg" :
                     node->ns == LXB_NS_MATH ? "mathml" : "other";
    printf(",\"namespace\":\"%s\"", ns);
    fputs(",\"offset\":", stdout);
    json_pos((size_t)(uintptr_t)node->user - 1);
    fputs(",\"attrs\":[", stdout);
    lxb_dom_attr_t *first = lxb_dom_element_first_attribute(e);
    for (lxb_dom_attr_t *a = first; a; a = lxb_dom_element_next_attribute(a)) {
        if (a != first) putchar(',');
        fputs("{\"name\":", stdout);
        name = lxb_dom_attr_qualified_name(a, &n);
        json_string(name, n);
        fputs(",\"value\":", stdout);
        const Byte *value = lxb_dom_attr_value(a, &n);
        json_string(value, value ? n : 0);
        const AttrPos *p = a->node.user;
        fputs(",\"offset\":", stdout);
        json_pos(p ? p->name : SIZE_MAX);
        fputs(",\"value_offset\":", stdout);
        json_pos(p ? p->value : SIZE_MAX);
        putchar('}');
    }
    fputs("],\"children\":[", stdout);
    if (node->ns == LXB_NS_HTML && node->local_name == LXB_TAG_TEMPLATE)
        return ((lxb_html_template_element_t *)node)->content->node.first_child;
    return node->first_child;
}

static void write_nodes(lxb_dom_node_t *first) {
    // Explicit traversal stack also handles template document fragments.
    typedef struct { lxb_dom_node_t *node; bool comma; } Level;
    size_t count = 1, capacity = 32;
    Level *levels = malloc(capacity * sizeof(*levels));
    if (!levels) fail("out of memory");
    levels[0] = (Level){first, false};
    while (count) {
        Level *level = &levels[count - 1];
        lxb_dom_node_t *n = level->node;
        if (!n) {
            if (--count) fputs("]}", stdout);
            continue;
        }
        level->node = n->next;
        if (n->type != LXB_DOM_NODE_TYPE_ELEMENT && n->type != LXB_DOM_NODE_TYPE_TEXT) continue;
        if (level->comma) putchar(',');
        level->comma = true;
        if (n->type == LXB_DOM_NODE_TYPE_TEXT) {
            lexbor_str_t text = lxb_dom_interface_character_data(n)->data;
            fputs("{\"kind\":\"text\",\"text\":", stdout);
            json_string(text.data, text.length);
            fputs(",\"offset\":", stdout);
            json_pos((size_t)(uintptr_t)n->user - 1);
            putchar('}');
        } else {
            lxb_dom_node_t *child = element(n);
            if (count == capacity) {
                capacity *= 2;
                levels = realloc(levels, capacity * sizeof(*levels));
                if (!levels) fail("out of memory");
            }
            levels[count++] = (Level){child, false};
        }
    }
    free(levels);
}

void parse_html(void) {
    lxb_html_document_t *doc = lxb_html_document_create();
    if (!doc || lxb_html_document_parse_chunk_begin(doc) != LXB_STATUS_OK) fail("cannot initialize HTML parser");
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
    size_t bom = source_len >= 3 && !memcmp(source, "\xef\xbb\xbf", 3) ? 3 : 0;
    if (lxb_html_document_parse_chunk(doc, source + bom, source_len - bom) != LXB_STATUS_OK ||
        lxb_html_document_parse_chunk_end(doc) != LXB_STATUS_OK) fail("HTML parse failed");
    const char *mode = dom->compat_mode == LXB_DOM_DOCUMENT_CMODE_NO_QUIRKS ? "no-quirks" :
                       dom->compat_mode == LXB_DOM_DOCUMENT_CMODE_LIMITED_QUIRKS ? "limited-quirks" : "quirks";
    printf("{\"mode\":\"%s\",\"doctype\":", mode);
    if (dom->doctype) {
        size_t n;
        const Byte *name = lxb_dom_document_type_name(dom->doctype, &n);
        fputs("{\"name\":", stdout); json_string(name, n);
        fputs(",\"public_id\":", stdout); json_string(dom->doctype->public_id.data, dom->doctype->public_id.length);
        fputs(",\"system_id\":", stdout); json_string(dom->doctype->system_id.data, dom->doctype->system_id.length);
        putchar('}');
    } else fputs("null", stdout);
    fputs(",\"nodes\":[", stdout);
    write_nodes(lxb_dom_interface_node(doc)->first_child);
    putchar(']');
    lexbor_array_obj_t *errors = tk->parse_errors;
    for (size_t i = 0; errors && i < lexbor_array_obj_length(errors); i++) {
        const lxb_html_tokenizer_error_t *e = lexbor_array_obj_get(errors, i);
        size_t n; const Byte *msg = lxb_html_tokenizer_error_to_string(e->id, &n);
        diagnostic("warning", msg, n, position(e->pos));
    }
    errors = lxb_html_parser_tree(parser)->parse_errors;
    for (size_t i = 0; errors && i < lexbor_array_obj_length(errors); i++) {
        const lxb_html_tree_error_t *e = lexbor_array_obj_get(errors, i);
        size_t n; const Byte *msg = lxb_html_tree_error_to_string(e->id, &n);
        diagnostic("warning", msg, n, position(e->begin));
    }
    dom->mutation = tree_mutation;
    lxb_html_document_destroy(doc);
}
