//! `ui!` and `include_ui!`: a UI spec run through `lcgf-gen` while the crate compiles.
//!
//! `ui!` writes the spec in Rust tokens and turns it into the `.zon` spec lcgf-gen reads
//! (src/abi/zon.zig). `include_ui!` names a `.zon` file. Either way lcgf-gen runs the same `plan`
//! the Zig compiler runs, and its Rust output becomes a module: `pub mod <name> { State,
//! Widget, TABLES, BYTES, Ui }`. lcgf-gen is `$LCGF_GEN`, or `$LCGF_PREFIX/bin/lcgf-gen`.
//!
//! ```ignore
//! lcgf::ui! {
//!     state Mixer { title: &'static str = "Mixer", muted: bool = false, volume: f32 = 0.5 }
//!     col(pad: 8, gap: 4, fill: theme(panel)) {
//!         label(title)
//!         row(size: (fill, fit), gap: 8, cross: center) {
//!             checkbox(id: mute, bind: muted, text: title)
//!             slider(id: volume, bind: volume)
//!         }
//!     }
//! }
//! ```
//!
//! Fields are `&'static str`, `bool`, `f32`, `u32` (a list's count) or `u8` (a choice's
//! selector); `spring level: f32 = 0.5` springs a slider's field. Besides `row` and `col` (which
//! take `when: field`), nodes are `list(count: f, max: n) { template }`, `choice(select: f) {
//! alternatives }`, `custom(id: name, data: n)` (a node the host draws), `label(field)`,
//! `text("Volume {.1} dB", field, ...)` (fields written into a format: `{}`, `{.N}` for an f32),
//! `button(id:, text:)`, `checkbox(id:, bind:, text:)` and `slider(id:, bind:)`.
//!
//! Styles: `size: (w, h)` with `fit`, `fill`, `px(n)`, `pct(f)`, `grow(f)`; `pad: n` or
//! `pad: (l, t, r, b)`; `gap`, `radius`, `border`, `opacity`; `main`/`cross: start|center|end`;
//! `clip: true`; `fill`/`border_color: rgb(r, g, b)`, `rgba(r, g, b, a)` or `theme(token)`.

use proc_macro::{Delimiter, TokenStream, TokenTree};
use std::fmt::Write as _;
use std::path::PathBuf;
use std::process::Command;

#[proc_macro]
pub fn ui(input: TokenStream) -> TokenStream {
    match dsl_to_zon(input) {
        Ok((name, zon)) => generate(&name, &zon),
        Err(e) => compile_error(&e),
    }
}

/// `include_ui!("toolbar.zon")`: a spec from a file, relative to `$LCGF_SPECS` when set, else
/// to the crate's manifest directory. `include_ui!("ui/page.html")` takes an HTML page and its
/// CSS instead (docs/guide/markup.md, "C++ and Rust"). `include_ui!("card.zon", static)` (or a
/// page in the static subset, `include_ui!("ui/card.html", static)`) makes a static UI:
/// the comptime pipeline's tables (`lcgf::StaticUi`: folded layout, paint templates) for a
/// spec whose structure never changes (`lcgf-gen --static`); its frame, `lcgf_ui_<name>_frame`,
/// comes from `lcgf_build::static_ui` in the crate's build script.
#[proc_macro]
pub fn include_ui(input: TokenStream) -> TokenStream {
    let tokens: Vec<TokenTree> = input.into_iter().collect();
    let Some(TokenTree::Literal(lit)) = tokens.first() else {
        return compile_error("include_ui! takes a string literal path");
    };
    let static_ = match &tokens[1..] {
        [] => false,
        [TokenTree::Punct(p), TokenTree::Ident(i)]
            if p.as_char() == ',' && i.to_string() == "static" =>
        {
            true
        }
        _ => {
            return compile_error("include_ui!(\"spec.zon\") or include_ui!(\"spec.zon\", static)");
        }
    };
    let raw = lit.to_string();
    let path = raw.trim_matches('"');
    let base = std::env::var("LCGF_SPECS")
        .or_else(|_| std::env::var("CARGO_MANIFEST_DIR"))
        .unwrap_or_default();
    let full = PathBuf::from(base).join(path);
    if path.ends_with(".html") {
        return include_html(&full, static_);
    }
    let zon = match std::fs::read_to_string(&full) {
        Ok(z) => z,
        Err(e) => return compile_error(&format!("include_ui!: {}: {e}", full.display())),
    };
    let name = zon
        .split(".name = \"")
        .nth(1)
        .and_then(|s| s.split('"').next())
        .unwrap_or("ui")
        .to_string();
    let mut out = generate_as(&name, &zon, static_);
    // rustc tracks a file `include_bytes!` reads, so an edit to the spec rebuilds the crate; a
    // proc macro's own reads are not tracked.
    let track = format!(
        "const _: &[u8] = include_bytes!({:?});",
        full.display().to_string()
    );
    out.extend(track.parse::<TokenStream>().unwrap());
    out
}

/// `include_shader!("textured.wgsl")`: a WGSL shader as `pub mod textured { Shader, Group0, .. }`.
/// lcgf-gen reflects its bind groups, as lcgf_render.gpu does in Zig, and embeds its code for
/// every back end: the WGSL (wgpu), naga's SPIR-V (Vulkan), naga's GLSL ES per entry point
/// (GL ES), naga's MSL with its slots (Metal) and naga's HLSL with its samplers registered (D3D12). naga is `$LCGF_NAGA`, or `naga` on PATH. A
/// back end reads only its own code, and an associated const nobody reads is not in the binary.
/// The path is relative to `$LCGF_SHADERS` when set, else to the crate's manifest directory.
/// `include_shader!("textured.wgsl", msl = "gen/textured.metal", hlsl = "gen/textured.hlsl")`
/// takes translations made already, from the same directory, instead of naga's.
#[proc_macro]
pub fn include_shader(input: TokenStream) -> TokenStream {
    let tokens: Vec<TokenTree> = input.into_iter().collect();
    let Some(TokenTree::Literal(lit)) = tokens.first() else {
        return compile_error("include_shader! takes a string literal path");
    };
    // Optional `, msl = "f"` and `, hlsl = "f"`: translations made already, used instead of naga's.
    let (mut msl_arg, mut hlsl_arg) = (None, None);
    let mut rest = &tokens[1..];
    while let [
        TokenTree::Punct(c),
        TokenTree::Ident(k),
        TokenTree::Punct(e),
        TokenTree::Literal(v),
        tail @ ..,
    ] = rest
    {
        if c.as_char() != ',' || e.as_char() != '=' {
            break;
        }
        let v = Some(v.to_string().trim_matches('"').to_string());
        match k.to_string().as_str() {
            "msl" => msl_arg = v,
            "hlsl" => hlsl_arg = v,
            _ => {
                return compile_error(
                    "include_shader!: the options are msl = \"f\" and hlsl = \"f\"",
                );
            }
        }
        rest = tail;
    }
    if !rest.is_empty() {
        return compile_error(
            "include_shader!(\"s.wgsl\" [, msl = \"s.metal\"] [, hlsl = \"s.hlsl\"])",
        );
    }
    let raw = lit.to_string();
    let path = raw.trim_matches('"');
    let base = std::env::var("LCGF_SHADERS")
        .or_else(|_| std::env::var("CARGO_MANIFEST_DIR"))
        .unwrap_or_default();
    let wgsl = PathBuf::from(&base).join(path);
    let name = wgsl
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("shader")
        .to_string();
    let Ok(gen_path) = lcgf_gen() else {
        return compile_error(
            "set LCGF_GEN or LCGF_PREFIX (an installed `zig build abi`) to find lcgf-gen",
        );
    };
    let dir = std::env::temp_dir().join(format!("lcgf-macros-{}-{name}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let naga = std::env::var("LCGF_NAGA").unwrap_or_else(|_| "naga".into());
    let run = |cmd: &mut Command, what: &str| -> Result<Vec<u8>, TokenStream> {
        match cmd.output() {
            Ok(o) if o.status.success() => Ok(o.stdout),
            Ok(o) => Err(compile_error(&format!(
                "{what}: {}",
                String::from_utf8_lossy(&o.stderr)
            ))),
            Err(e) => Err(compile_error(&format!("lcgf: running {what}: {e}"))),
        }
    };
    let spv = dir.join(format!("{name}.spv"));
    let mut code_args: Vec<std::ffi::OsString> = vec!["--spirv".into(), spv.clone().into()];
    if let Err(e) = run(
        Command::new(&naga).arg(&wgsl).arg(&spv),
        &format!("naga {}", wgsl.display()),
    ) {
        return e;
    }
    let entries = match run(
        Command::new(&gen_path)
            .arg("--wgsl")
            .arg(&wgsl)
            .arg("--entry-points"),
        "lcgf-gen --entry-points",
    ) {
        Ok(o) => String::from_utf8_lossy(&o).into_owned(),
        Err(e) => return e,
    };
    for line in entries.lines() {
        let f: Vec<&str> = line.split(' ').collect();
        let [entry, stage, profile, ext] = f[..] else {
            continue;
        };
        let glsl = dir.join(format!("{name}.{entry}.{ext}"));
        let mut cmd = Command::new(&naga);
        cmd.args([
            "--profile",
            profile,
            "--shader-stage",
            stage,
            "--entry-point",
            entry,
        ])
        .arg(&wgsl)
        .arg(&glsl);
        if let Err(e) = run(&mut cmd, &format!("naga {} ({entry})", wgsl.display())) {
            return e;
        }
        code_args.push("--glsl".into());
        let mut a = std::ffi::OsString::from(format!("{entry}="));
        a.push(glsl.as_os_str());
        code_args.push(a);
    }
    let msl = match msl_arg {
        Some(m) => PathBuf::from(&base).join(m),
        None => {
            let m = dir.join(format!("{name}.metal"));
            if let Err(e) = run(
                Command::new(&naga).arg(&wgsl).arg(&m),
                &format!("naga {} (MSL)", wgsl.display()),
            ) {
                return e;
            }
            m
        }
    };
    code_args.push("--msl".into());
    code_args.push(msl.into());
    let hlsl = match hlsl_arg {
        Some(h) => PathBuf::from(&base).join(h),
        None => {
            let h = dir.join(format!("{name}.hlsl"));
            if let Err(e) = run(
                Command::new(&naga).arg(&wgsl).arg(&h),
                &format!("naga {} (HLSL)", wgsl.display()),
            ) {
                return e;
            }
            h
        }
    };
    code_args.push("--hlsl".into());
    code_args.push(hlsl.into());
    let out = run(
        Command::new(&gen_path)
            .arg("--wgsl")
            .arg(&wgsl)
            .args(&code_args)
            .args(["--name", &name, "--lang", "rust"]),
        "lcgf-gen",
    );
    let _ = std::fs::remove_dir_all(&dir);
    let code = match out {
        Ok(o) => String::from_utf8_lossy(&o).into_owned(),
        Err(e) => return e,
    };
    format!("#[allow(dead_code, clippy::all)] pub mod {name} {{ {code} }}")
        .parse()
        .unwrap()
}

/// `include_ui!("page.html")`: the page and its CSS lowered by lcgf-gen to the `.zon` the seam
/// reads, then generated as that `.zon` would be. lcgf-gen's errors (GNU format, at the HTML or
/// CSS line) become the `compile_error!`; every file of its depfile is tracked. `static_`: a
/// page in the static subset, as a static UI (`lcgf-gen page.html --static`).
fn include_html(html: &std::path::Path, static_: bool) -> TokenStream {
    let Ok(gen_path) = lcgf_gen() else {
        return compile_error(
            "set LCGF_GEN or LCGF_PREFIX (an installed `zig build abi`) to find lcgf-gen",
        );
    };
    let stem = html.file_stem().and_then(|s| s.to_str()).unwrap_or("ui");
    let dir = std::env::temp_dir().join(format!("lcgf-macros-{}-{stem}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let (zon_path, dep_path) = (
        dir.join(format!("{stem}.zon")),
        dir.join(format!("{stem}.d")),
    );
    let mut cmd = Command::new(&gen_path);
    cmd.arg(html);
    if static_ {
        cmd.arg("--static");
    }
    let out = cmd
        .args(["--lang", "zon", "-o"])
        .arg(&zon_path)
        .arg("--depfile")
        .arg(&dep_path)
        .output();
    let zon = std::fs::read_to_string(&zon_path);
    let deps = std::fs::read_to_string(&dep_path).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&dir);
    match out {
        Ok(o) if o.status.success() => {}
        Ok(o) => return compile_error(String::from_utf8_lossy(&o.stderr).trim_end()),
        Err(e) => return compile_error(&format!("lcgf: running {}: {e}", gen_path.display())),
    }
    let Ok(zon) = zon else {
        return compile_error(&format!("lcgf-gen wrote no spec for {}", html.display()));
    };
    let name = zon
        .split(".name = \"")
        .nth(1)
        .and_then(|s| s.split('"').next())
        .unwrap_or("ui")
        .to_string();
    let mut out = generate_as(&name, &zon, static_);
    // The depfile is `out: dep dep ...`, spaces in a path escaped.
    let list = deps
        .split_once(": ")
        .map_or("", |d| d.1)
        .replace("\\ ", "\0");
    for dep in list.split_whitespace() {
        let track = format!(
            "const _: &[u8] = include_bytes!({:?});",
            dep.replace('\0', " ")
        );
        out.extend(track.parse::<TokenStream>().unwrap());
    }
    out
}

fn lcgf_gen() -> Result<PathBuf, std::env::VarError> {
    std::env::var("LCGF_GEN").map(PathBuf::from).or_else(|_| {
        std::env::var("LCGF_PREFIX").map(|p| PathBuf::from(p).join("bin").join("lcgf-gen"))
    })
}

fn compile_error(msg: &str) -> TokenStream {
    format!("::core::compile_error!({msg:?});").parse().unwrap()
}

/// Runs lcgf-gen on `zon` and wraps its Rust output in `pub mod name`.
fn generate(name: &str, zon: &str) -> TokenStream {
    generate_as(name, zon, false)
}

fn generate_as(name: &str, zon: &str, static_: bool) -> TokenStream {
    let Ok(gen_path) = lcgf_gen() else {
        return compile_error(
            "set LCGF_GEN or LCGF_PREFIX (an installed `zig build abi`) to find lcgf-gen",
        );
    };
    let dir = std::env::temp_dir().join(format!("lcgf-macros-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let spec = dir.join(format!("{name}.zon"));
    if let Err(e) = std::fs::write(&spec, zon) {
        return compile_error(&format!("lcgf: writing {}: {e}", spec.display()));
    }
    let mut cmd = Command::new(&gen_path);
    cmd.arg(&spec);
    if static_ {
        cmd.arg("--static");
    }
    let out = cmd.args(["--lang", "rust"]).output();
    let _ = std::fs::remove_file(&spec);
    let out = match out {
        Ok(o) => o,
        Err(e) => return compile_error(&format!("lcgf: running {}: {e}", gen_path.display())),
    };
    if !out.status.success() {
        return compile_error(&format!(
            "lcgf-gen: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    let code = String::from_utf8_lossy(&out.stdout);
    format!("#[allow(non_upper_case_globals, dead_code, clippy::all)] pub mod {name} {{ {code} }}")
        .parse()
        .unwrap()
}

// ---- the DSL -----------------------------------------------------------------------------------

type Res<T> = Result<T, String>;

struct Toks {
    t: Vec<TokenTree>,
    i: usize,
}

impl Toks {
    fn new(s: TokenStream) -> Self {
        Self {
            t: s.into_iter().collect(),
            i: 0,
        }
    }
    fn peek(&self) -> Option<&TokenTree> {
        self.t.get(self.i)
    }
    fn next(&mut self) -> Option<TokenTree> {
        let t = self.t.get(self.i).cloned();
        self.i += 1;
        t
    }
    fn done(&self) -> bool {
        self.i >= self.t.len()
    }
    fn ident(&mut self) -> Res<String> {
        match self.next() {
            Some(TokenTree::Ident(i)) => Ok(i.to_string()),
            other => Err(format!("ui!: expected a name, found {other:?}")),
        }
    }
    fn punct(&mut self, c: char) -> Res<()> {
        match self.next() {
            Some(TokenTree::Punct(p)) if p.as_char() == c => Ok(()),
            other => Err(format!("ui!: expected `{c}`, found {other:?}")),
        }
    }
    fn eat_punct(&mut self, c: char) -> bool {
        if let Some(TokenTree::Punct(p)) = self.peek() {
            if p.as_char() == c {
                self.i += 1;
                return true;
            }
        }
        false
    }
    fn group(&mut self, d: Delimiter) -> Res<Toks> {
        match self.next() {
            Some(TokenTree::Group(g)) if g.delimiter() == d => Ok(Toks::new(g.stream())),
            other => Err(format!("ui!: expected a {d:?} group, found {other:?}")),
        }
    }
    fn peek_group(&self, d: Delimiter) -> bool {
        matches!(self.peek(), Some(TokenTree::Group(g)) if g.delimiter() == d)
    }
    /// Tokens up to the next top-level `,` (eaten) or the end, as text.
    fn value(&mut self) -> Vec<TokenTree> {
        let mut out = Vec::new();
        while let Some(t) = self.peek() {
            if let TokenTree::Punct(p) = t {
                if p.as_char() == ',' {
                    self.i += 1;
                    break;
                }
            }
            out.push(self.next().unwrap());
        }
        out
    }
}

fn snake(s: &str) -> String {
    let mut out = String::new();
    for (k, ch) in s.chars().enumerate() {
        if ch.is_uppercase() {
            if k > 0 {
                out.push('_');
            }
            out.extend(ch.to_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}

fn dsl_to_zon(input: TokenStream) -> Res<(String, String)> {
    let mut t = Toks::new(input);
    let kw = t.ident()?;
    if kw != "state" {
        return Err("ui!: start with `state Name { field: type = default, ... }`".into());
    }
    let name = snake(&t.ident()?);
    let mut fields = t.group(Delimiter::Brace)?;
    let mut zon = format!(".{{ .name = \"{name}\", .state = .{{ ");
    while !fields.done() {
        let mut f = fields.ident()?;
        let mut spring = false;
        if f == "spring" {
            spring = true;
            f = fields.ident()?;
        }
        fields.punct(':')?;
        let mut ty = String::new();
        let mut default = None;
        while let Some(tok) = fields.next() {
            match &tok {
                TokenTree::Punct(p)
                    if p.as_char() == '=' && p.spacing() == proc_macro::Spacing::Alone =>
                {
                    let v = fields.value();
                    default = Some(v.iter().map(|x| x.to_string()).collect::<String>());
                    break;
                }
                TokenTree::Punct(p) if p.as_char() == ',' => break,
                _ => ty.push_str(&tok.to_string()),
            }
        }
        let default = default.ok_or_else(|| format!("ui!: field `{f}` needs a default"))?;
        let ty = ty.replace(' ', "");
        let kind = if ty.ends_with("str") {
            "str"
        } else if ty == "bool" {
            "bool"
        } else if ty == "f32" {
            "f32"
        } else if ty == "u32" {
            "u32"
        } else if ty == "u8" {
            "u8"
        } else {
            return Err(format!(
                "ui!: field `{f}`: &'static str, bool, f32, u32 or u8, not {ty}"
            ));
        };
        let default = if kind == "f32" && !default.contains('.') {
            format!("{default}.0")
        } else {
            default
        };
        let default = default
            .trim_end_matches("f32")
            .trim_end_matches("u32")
            .trim_end_matches("u8")
            .to_string();
        let spring = if spring { ", .spring = .{}" } else { "" };
        write!(zon, ".{{ .name = \"{f}\", .{kind} = {default}{spring} }}, ").unwrap();
    }
    zon.push_str("}, .ui = ");
    node(&mut t, &mut zon)?;
    if !t.done() {
        return Err("ui!: one root node, after the state".into());
    }
    zon.push_str(" }");
    Ok((name, zon))
}

fn node(t: &mut Toks, zon: &mut String) -> Res<()> {
    let kind = t.ident()?;
    let mut args = t.group(Delimiter::Parenthesis)?;
    match kind.as_str() {
        "row" | "col" | "list" | "choice" | "custom" => {
            // Region and widget keys go on the node; the rest is its style.
            let mut head = String::new();
            let mut style = String::new();
            while !args.done() {
                let key = args.ident()?;
                args.punct(':')?;
                let v = args.value();
                let word = v.first().map(|t| t.to_string()).unwrap_or_default();
                match key.as_str() {
                    "when" | "count" | "select" | "id" => {
                        write!(head, ".{key} = \"{word}\", ").unwrap()
                    }
                    "max" | "data" => write!(head, ".{key} = {}, ", num(&v[0])?).unwrap(),
                    "dir" => write!(head, ".dir = .{word}, ").unwrap(),
                    _ => write!(style, ".{key} = {}, ", style_value(&key, &v)?).unwrap(),
                }
            }
            write!(zon, ".{{ .{kind} = .{{ {head}.style = .{{ {style}}}").unwrap();
            if kind != "custom" {
                zon.push_str(if kind == "list" {
                    ", .template = .{ "
                } else {
                    ", .children = .{ "
                });
                if t.peek_group(Delimiter::Brace) {
                    let mut kids = t.group(Delimiter::Brace)?;
                    while !kids.done() {
                        node(&mut kids, zon)?;
                        zon.push_str(", ");
                    }
                }
                zon.push_str("}");
            }
            zon.push_str(" } }");
        }
        "label" => {
            let f = args.ident()?;
            write!(zon, ".{{ .label = \"{f}\" }}").unwrap();
        }
        "text" => {
            // `text("Volume {.1} dB", volume)`: a formatted label (src/core/fmt.zig).
            let lit = match args.next() {
                Some(TokenTree::Literal(l)) if l.to_string().starts_with('"') => l.to_string(),
                _ => {
                    return Err(
                        "ui!: text(\"format\", field, ...) starts with a string literal".into(),
                    );
                }
            };
            write!(zon, ".{{ .text = .{{ .format = {lit}, .args = .{{ ").unwrap();
            while !args.done() {
                args.eat_punct(',');
                if args.done() {
                    break;
                }
                let f = args.ident()?;
                write!(zon, "\"{f}\", ").unwrap();
            }
            zon.push_str("} } }");
        }
        "button" | "checkbox" | "slider" => {
            write!(zon, ".{{ .{kind} = .{{ ").unwrap();
            while !args.done() {
                let key = args.ident()?;
                args.punct(':')?;
                let v = args.ident()?;
                args.eat_punct(',');
                write!(zon, ".{key} = \"{v}\", ").unwrap();
            }
            zon.push_str("} }");
        }
        other => return Err(format!("ui!: unknown node `{other}`")),
    }
    Ok(())
}

fn num(t: &TokenTree) -> Res<String> {
    match t {
        TokenTree::Literal(l) => Ok(l.to_string().trim_end_matches("f32").to_string()),
        other => Err(format!("ui!: expected a number, found {other}")),
    }
}

fn length(v: &[TokenTree]) -> Res<String> {
    match v {
        [TokenTree::Ident(i)] if i.to_string() == "fit" || i.to_string() == "fill" => {
            Ok(format!(".{i}"))
        }
        [TokenTree::Ident(i), TokenTree::Group(g)] => {
            let inner: Vec<TokenTree> = g.stream().into_iter().collect();
            Ok(format!(".{{ .{i} = {} }}", num(&inner[0])?))
        }
        _ => Err("ui!: a length is fit, fill, px(n), pct(f) or grow(f)".into()),
    }
}

fn split_commas(g: &proc_macro::Group) -> Vec<Vec<TokenTree>> {
    let mut out = vec![Vec::new()];
    for t in g.stream() {
        if let TokenTree::Punct(p) = &t {
            if p.as_char() == ',' {
                out.push(Vec::new());
                continue;
            }
        }
        out.last_mut().unwrap().push(t);
    }
    out.retain(|v| !v.is_empty());
    out
}

fn color(v: &[TokenTree]) -> Res<String> {
    match v {
        [TokenTree::Ident(f), TokenTree::Group(g)] => {
            let parts = split_commas(g);
            match f.to_string().as_str() {
                "theme" => Ok(format!(".{{ .theme = .{} }}", parts[0][0])),
                "rgb" | "rgba" => {
                    let n: Res<Vec<String>> = parts.iter().map(|p| num(&p[0])).collect();
                    Ok(format!(".{{ .{f} = .{{ {} }} }}", n?.join(", ")))
                }
                _ => Err("ui!: a colour is rgb(..), rgba(..) or theme(token)".into()),
            }
        }
        _ => Err("ui!: a colour is rgb(..), rgba(..) or theme(token)".into()),
    }
}

fn style_value(key: &str, v: &[TokenTree]) -> Res<String> {
    match key {
        "size" => match v {
            [TokenTree::Group(g)] => {
                let parts = split_commas(g);
                Ok(format!(
                    ".{{ {}, {} }}",
                    length(&parts[0])?,
                    length(&parts[1])?
                ))
            }
            _ => Err("ui!: size: (w, h)".into()),
        },
        "pad" => match v {
            [TokenTree::Group(g)] => {
                let n: Res<Vec<String>> = split_commas(g).iter().map(|p| num(&p[0])).collect();
                Ok(format!(".{{ {} }}", n?.join(", ")))
            }
            [n] => {
                let n = num(n)?;
                Ok(format!(".{{ {n}, {n}, {n}, {n} }}"))
            }
            _ => Err("ui!: pad: n or (l, t, r, b)".into()),
        },
        "fill" | "border_color" => color(v),
        "main" | "cross" => Ok(format!(".{}", v[0])),
        "clip" | "shrink" => Ok(v[0].to_string()),
        "gap" | "radius" | "border" | "opacity" => num(&v[0]),
        _ => Err(format!("ui!: unknown style `{key}`")),
    }
}
