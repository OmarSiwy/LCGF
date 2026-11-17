/* Probe: lexbor HTML tree with source lines + CSS stylesheet/tokens. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lexbor/html/html.h>
#include <lexbor/html/parser.h>
#include <lexbor/css/css.h>
#include <lexbor/html/tree/error.h>

static const char *src_begin, *src_end;
static size_t cur_off = (size_t)-1;            /* offset of token being processed */
static lxb_html_tokenizer_token_f orig_cb;
static void *orig_ctx;
static const lxb_dom_document_mutation_cb_t *orig_mut;
static lxb_dom_document_mutation_cb_t my_mut;

static lxb_html_token_t *wrap_cb(lxb_html_tokenizer_t *tkz, lxb_html_token_t *tok, void *ctx) {
    const char *b = (const char *)tok->begin;
    cur_off = (b >= src_begin && b <= src_end) ? (size_t)(b - src_begin) : (size_t)-1;
    return orig_cb(tkz, tok, ctx);
}
/* lexbor 3.0 DOM "inserted" mutation hook: stamp the source offset of the token
 * whose tree-construction step inserted the node (node->user is free for apps). */
static lxb_status_t on_inserted(lxb_dom_node_t *n) {
    if (n->user == NULL && cur_off != (size_t)-1) n->user = (void *)(cur_off + 1);  /* 0 = unknown */
    return orig_mut && orig_mut->inserted ? orig_mut->inserted(n) : LXB_STATUS_OK;
}
static void line_col(size_t off, int *l, int *c) {
    *l = 1; *c = 1;
    for (size_t i = 0; i < off; i++) { if (src_begin[i] == '\n') { (*l)++; *c = 1; } else (*c)++; }
}
static void dump(lxb_dom_node_t *n, int depth) {
    for (; n; n = n->next) {
        size_t u = (size_t)n->user; int l = 0, c = 0;
        if (u) line_col(u - 1, &l, &c);
        printf("%*s", depth * 2, "");
        if (n->type == LXB_DOM_NODE_TYPE_ELEMENT) {
            size_t len; const lxb_char_t *nm = lxb_dom_element_qualified_name(lxb_dom_interface_element(n), &len);
            printf("<%.*s>", (int)len, nm);
            for (lxb_dom_attr_t *a = lxb_dom_element_first_attribute(lxb_dom_interface_element(n)); a; a = lxb_dom_element_next_attribute(a)) {
                size_t kl, vl; const lxb_char_t *k = lxb_dom_attr_qualified_name(a, &kl); const lxb_char_t *v = lxb_dom_attr_value(a, &vl);
                printf(" %.*s=\"%.*s\"", (int)kl, k, (int)vl, v ? (const char *)v : "");
            }
        } else if (n->type == LXB_DOM_NODE_TYPE_TEXT) {
            size_t len; const lxb_char_t *t = lxb_dom_node_text_content(n, &len);
            printf("#text \"");
            for (size_t i = 0; i < len; i++) putchar(t[i] == '\n' ? '~' : t[i]);
            printf("\"");
        } else printf("#node type=%d", n->type);
        if (u) printf("   @%d:%d", l, c); else printf("   @?");
        printf("\n");
        dump(n->first_child, depth + 1);
    }
}
/* Tokenizer-only mode: no HTML tree-construction rules, every tag survives. */
static lxb_html_token_t *tok_only(lxb_html_tokenizer_t *tkz, lxb_html_token_t *t, void *ctx) {
    if (t->tag_id == LXB_TAG__END_OF_FILE || t->begin == NULL) { printf("EOF\n"); return t; }
    int l, c; line_col((const char *)t->begin - src_begin, &l, &c);
    if (t->tag_id == LXB_TAG__TEXT) {
        printf("@%d:%d TEXT \"", l, c);
        for (const lxb_char_t *p = t->begin; p < t->end; p++) putchar(*p == '\n' ? '~' : *p);
        printf("\"\n"); return t;
    }
    if (t->tag_id == LXB_TAG_STYLE && !(t->type & LXB_HTML_TOKEN_TYPE_CLOSE)) {
        lxb_html_tokenizer_set_state_by_tag(tkz, false, LXB_TAG_STYLE, LXB_NS_HTML);
    }
    size_t nl; const lxb_char_t *nm = lxb_tag_name_by_id(t->tag_id, &nl);
    printf("@%d:%d %s%.*s%s", l, c, (t->type & LXB_HTML_TOKEN_TYPE_CLOSE) ? "</" : "<", (int)nl, nm,
           (t->type & LXB_HTML_TOKEN_TYPE_CLOSE_SELF) ? "/>" : ">");
    for (lxb_html_token_attr_t *a = t->attr_first; a; a = a->next) {
        int al, ac; line_col((const char *)a->name_begin - src_begin, &al, &ac);
        printf(" %.*s=\"%.*s\"@%d:%d", (int)(a->name_end - a->name_begin), a->name_begin, (int)a->value_size, a->value ? (const char *)a->value : "", al, ac);
    }
    printf("\n"); return t;
}
static const char *css_src;
static void line_col_css(size_t off, int *l, int *c) {
    *l = 1; *c = 1;
    for (size_t i = 0; i < off; i++) { if (css_src[i] == '\n') { (*l)++; *c = 1; } else (*c)++; }
}
static char *slurp(const char *p, size_t *len) {
    FILE *f = fopen(p, "rb"); fseek(f, 0, SEEK_END); *len = ftell(f); rewind(f);
    char *b = malloc(*len + 1); fread(b, 1, *len, f); b[*len] = 0; fclose(f); return b;
}
static lxb_status_t out(const lxb_char_t *d, size_t l, void *ctx) { printf("%.*s", (int)l, d); return LXB_STATUS_OK; }

int main(int argc, char **argv) {
    size_t hl, cl; char *html = slurp(argv[1], &hl), *css = slurp(argv[2], &cl);
    src_begin = html; src_end = html + hl; css_src = css;

    lxb_html_document_t *doc = lxb_html_document_create();
    lxb_dom_document_t *dd = lxb_dom_interface_document(doc);
    orig_mut = dd->mutation; if (orig_mut) my_mut = *orig_mut; my_mut.inserted = on_inserted; dd->mutation = &my_mut;
    if (lxb_html_document_parse_chunk_begin(doc) != LXB_STATUS_OK) return 1;
    lxb_html_tokenizer_t *tkz = lxb_html_parser_tokenizer((lxb_html_parser_t *)dd->parser);
    orig_cb = tkz->callback_token_done; orig_ctx = tkz->callback_token_ctx;
    lxb_html_tokenizer_callback_token_done_set(tkz, wrap_cb, orig_ctx);
    lxb_html_document_parse_chunk(doc, (const lxb_char_t *)html, hl);
    lxb_html_document_parse_chunk_end(doc);
    printf("== HTML tree (document parse) ==\n");
    dump(lxb_dom_interface_node(doc)->first_child, 0);

    printf("\n== HTML tree errors ==\n");
    lexbor_array_obj_t *perr = lxb_html_parser_tree((lxb_html_parser_t *)dd->parser)->parse_errors;
    printf("tree parse errors: %zu\n", perr ? lexbor_array_obj_length(perr) : 0);
    for (size_t i = 0; perr && i < lexbor_array_obj_length(perr); i++) {
        lxb_html_tree_error_t *e = lexbor_array_obj_get(perr, i); size_t el; int l = 0, c = 0;
        if (e->begin >= (const lxb_char_t *)src_begin && e->begin <= (const lxb_char_t *)src_end) line_col((const char *)e->begin - src_begin, &l, &c);
        printf("  @%d:%d %s\n", l, c, (const char *)lxb_html_tree_error_to_string(e->id, &el));
    }

    printf("\n== HTML tokenizer only ==\n");
    lxb_html_tokenizer_t *tk = lxb_html_tokenizer_create(); lxb_html_tokenizer_init(tk);
    lxb_html_tokenizer_callback_token_done_set(tk, tok_only, NULL);
    lxb_html_tokenizer_begin(tk); lxb_html_tokenizer_chunk(tk, (const lxb_char_t *)html, hl); lxb_html_tokenizer_end(tk);

    printf("\n== CSS stylesheet (lxb_css_stylesheet_parse + serialize) ==\n");
    lxb_css_parser_t *cp = lxb_css_parser_create(); lxb_css_parser_init(cp, NULL);
    lxb_css_stylesheet_t *sst = lxb_css_stylesheet_create(NULL);
    lxb_status_t st = lxb_css_stylesheet_parse(sst, cp, (const lxb_char_t *)css, cl);
    printf("status=%d\n", st);
    lxb_css_rule_serialize(sst->root, out, NULL); printf("\n");
    printf("-- per rule --\n");
    lxb_css_rule_list_t *list = lxb_css_rule_list(sst->root);
    for (lxb_css_rule_t *r = list->first; r; r = r->next) {
        if (r->type != LXB_CSS_RULE_STYLE) continue;
        lxb_css_rule_style_t *s = lxb_css_rule_style(r);
        { int l, c; line_col_css(s->prelude_begin, &l, &c);
          printf("selector @%d:%d [prelude %zu..%zu]: ", l, c, s->prelude_begin, s->prelude_end); }
        lxb_css_selector_serialize_list(s->selector, out, NULL); printf("\n");
        for (lxb_css_rule_t *d = s->declarations->first; d; d = d->next) {
            lxb_css_rule_declaration_t *decl = lxb_css_rule_declaration(d);
            { int l, c; line_col_css(decl->offset.name_begin, &l, &c);
              printf("  decl @%d:%d [name %zu..%zu value %zu..%zu] type=%zu: ", l, c, decl->offset.name_begin, decl->offset.name_end, decl->offset.value_begin, decl->offset.value_end, (size_t)decl->type); } lxb_css_rule_declaration_serialize(decl, out, NULL); printf("\n");
        }
    }

    printf("\n== CSS raw tokens with offsets ==\n");
    lxb_css_syntax_tokenizer_t *ct = lxb_css_syntax_tokenizer_create(); lxb_css_syntax_tokenizer_init(ct);
    lxb_css_syntax_tokenizer_buffer_set(ct, (const lxb_char_t *)css, cl);
    for (;;) {
        lxb_css_syntax_token_t *t = lxb_css_syntax_token(ct);
        lxb_css_syntax_token_type_t ty = lxb_css_syntax_token_type(t);
        if (ty == LXB_CSS_SYNTAX_TOKEN__EOF) break;
        if (ty != LXB_CSS_SYNTAX_TOKEN_WHITESPACE) {
            lxb_css_syntax_token_base_t *b = lxb_css_syntax_token_base(t);
            printf("[%s off=%zu] %.*s\n", lxb_css_syntax_token_type_name_by_id(ty), (size_t)t->offset, (int)b->length, b->begin);
        }
        lxb_css_syntax_token_consume(ct);
    }
    return 0;
}
