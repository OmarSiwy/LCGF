//! Binary-size report: text, rodata, data and bss bytes of each ELF64 file given as an argument.
//! Sections are classed by flags, as `size` does, with read-only data split from text:
//! not allocated is skipped (debug info, symbols), NOBITS is bss, executable is text, writable
//! is data, anything else allocated is rodata.
//!
//!   zig build size                     the report for every example root build.zig lists
const std = @import("std");
const elf = std.elf;

const Sizes = struct { text: u64 = 0, rodata: u64 = 0, data: u64 = 0, bss: u64 = 0 };

fn classify(bytes: []const u8) !Sizes {
    if (bytes.len < @sizeOf(elf.Elf64_Ehdr) or !std.mem.eql(u8, bytes[0..4], elf.MAGIC)) return error.NotElf;
    if (bytes[elf.EI.CLASS] != elf.ELFCLASS64 or bytes[elf.EI.DATA] != elf.ELFDATA2LSB) return error.NotElf64LittleEndian;
    const eh = std.mem.bytesToValue(elf.Elf64_Ehdr, bytes[0..@sizeOf(elf.Elf64_Ehdr)]);
    var s: Sizes = .{};
    for (0..eh.e_shnum) |i| {
        const off = eh.e_shoff + i * eh.e_shentsize;
        if (off + @sizeOf(elf.Elf64_Shdr) > bytes.len) return error.Truncated;
        const sh = std.mem.bytesToValue(elf.Elf64_Shdr, bytes[off..][0..@sizeOf(elf.Elf64_Shdr)]);
        if (sh.sh_flags & elf.SHF_ALLOC == 0) continue;
        const field = if (sh.sh_type == elf.SHT_NOBITS)
            &s.bss
        else if (sh.sh_flags & elf.SHF_EXECINSTR != 0)
            &s.text
        else if (sh.sh_flags & elf.SHF_WRITE != 0)
            &s.data
        else
            &s.rodata;
        field.* += sh.sh_size;
    }
    return s;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    try w.print("{s:<12} {s:>9} {s:>9} {s:>9} {s:>9}\n", .{ "example", "text", "rodata", "data", "bss" });
    while (args.next()) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, init.gpa, .limited(1 << 30));
        defer init.gpa.free(bytes);
        const s = try classify(bytes);
        try w.print("{s:<12} {d:>9} {d:>9} {d:>9} {d:>9}\n", .{ std.fs.path.basename(path), s.text, s.rodata, s.data, s.bss });
    }
    try w.flush();
}

test "classify reads its own test binary" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const self = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(self);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, self, gpa, .limited(1 << 30));
    defer gpa.free(bytes);
    const s = try classify(bytes);
    try std.testing.expect(s.text > 0 and s.rodata > 0);
    try std.testing.expectError(error.NotElf, classify("not an elf file at all, padded to be long enough for a header......"));
}
