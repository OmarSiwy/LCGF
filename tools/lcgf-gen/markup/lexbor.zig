//! The rows lexbor.c copies out of Lexbor: the same layouts as its C structs. Host only; the
//! compiler is the only thing that links Lexbor.

pub const none: u32 = 0xffff_ffff;

pub const Str = extern struct { off: u32, len: u32 };

pub const HtmlNode = extern struct {
    /// 1 element, 3 text (DOM node types).
    kind: u32,
    parent: u32,
    /// An element's qualified name, lower-case; a text node's data.
    name: Str,
    /// Byte offset of the element's `<` or of the text; `none` for implied elements.
    src: u32,
    attr_first: u32,
    attr_count: u32,
    in_template: u32,
};

pub const HtmlAttr = extern struct { name: Str, value: Str, name_src: u32, value_src: u32 };
pub const Diag = extern struct { msg: Str, src: u32 };

pub const Html = extern struct {
    nodes: ?[*]HtmlNode,
    n_nodes: u32,
    attrs: ?[*]HtmlAttr,
    n_attrs: u32,
    diags: ?[*]Diag,
    n_diags: u32,
    pool: ?[*]u8,
    pool_len: u32,
    quirks: u32,
    doctype: u32,
};

/// Values of `lxb_css_syntax_token_type_t` (css/syntax/token.h).
pub const TokenType = enum(u32) {
    undef,
    ident,
    function,
    at_keyword,
    hash,
    string,
    bad_string,
    url,
    bad_url,
    comment,
    whitespace,
    dimension,
    delim,
    unicode_range,
    number,
    percentage,
    cdo,
    cdc,
    colon,
    semicolon,
    comma,
    ls_bracket,
    rs_bracket,
    l_parenthesis,
    r_parenthesis,
    lc_bracket,
    rc_bracket,
    eof,
    _,
};

pub const CssToken = extern struct {
    type: TokenType,
    begin: u32,
    end: u32,
    /// Decoded ident, function or at-keyword name, hash, string, URL or dimension unit.
    str: Str,
    num: f64,
    is_float: u32,
    delim: u32,
};

pub const Css = extern struct {
    tokens: ?[*]CssToken,
    n_tokens: u32,
    diags: ?[*]Diag,
    n_diags: u32,
    pool: ?[*]u8,
    pool_len: u32,
};

pub extern fn lcgf_html_parse(src: [*]const u8, len: usize, out: *Html) c_int;
pub extern fn lcgf_html_free(h: *Html) void;
pub extern fn lcgf_css_tokenize(src: [*]const u8, len: usize, out: *Css) c_int;
pub extern fn lcgf_css_free(c: *Css) void;
