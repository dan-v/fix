//! Cache generation identity and deterministic compile-unit keys.

const std = @import("std");
const common = @import("wire.zig");

/// The running binary's GNU build-id as lowercase hex, read from the
/// already-mapped program headers (no file IO; `-fbuild-id=sha1` is set in
/// build.zig). Null when the platform provides no phdr walk or the binary
/// carries no note — callers fall back to a weaker exe fingerprint.
pub fn selfBuildId(buf: []u8) ?[]const u8 {
    if (!@hasDecl(std.posix.system, "dl_phdr_info")) return null;
    const max_desc = 32;
    const Ctx = struct {
        buf: []u8,
        out: ?[]const u8 = null,

        fn callback(info: *std.posix.dl_phdr_info, size: usize, ctx: *@This()) error{Found}!void {
            _ = size;
            // The main executable is the entry with an empty name.
            if (info.name != null and info.name.?[0] != 0) return;
            const phdrs = info.phdr[0..info.phnum];
            for (phdrs) |phdr| {
                if (phdr.type != .NOTE) continue;
                const base: usize = @intCast(info.addr);
                var at: usize = base + @as(usize, @intCast(phdr.vaddr));
                const end = at + @as(usize, @intCast(phdr.memsz));
                while (at + @sizeOf(std.elf.Elf64_Nhdr) <= end) {
                    const nhdr: *const std.elf.Elf64_Nhdr = @ptrFromInt(at);
                    const name_at = at + @sizeOf(std.elf.Elf64_Nhdr);
                    const desc_at = name_at + std.mem.alignForward(usize, nhdr.n_namesz, 4);
                    const next = desc_at + std.mem.alignForward(usize, nhdr.n_descsz, 4);
                    if (next > end) break;
                    if (nhdr.n_type == std.elf.NT_GNU_BUILD_ID and nhdr.n_namesz == 4) {
                        const name: [*]const u8 = @ptrFromInt(name_at);
                        if (std.mem.eql(u8, name[0..4], "GNU\x00")) {
                            const desc: [*]const u8 = @ptrFromInt(desc_at);
                            const n = @min(nhdr.n_descsz, max_desc);
                            if (ctx.buf.len < n * 2) return;
                            const hex = "0123456789abcdef";
                            for (desc[0..n], 0..) |b, i| {
                                ctx.buf[i * 2] = hex[b >> 4];
                                ctx.buf[i * 2 + 1] = hex[b & 0xF];
                            }
                            ctx.out = ctx.buf[0 .. n * 2];
                            return error.Found;
                        }
                    }
                    at = next;
                }
            }
        }
    };
    var ctx: Ctx = .{ .buf = buf };
    std.posix.dl_iterate_phdr(&ctx, error{Found}, Ctx.callback) catch {};
    return ctx.out;
}

/// Everything identity-relevant. Two runs with equal KeyContext + equal
/// source bytes + equal source path may share cached units. The BINARY's
/// identity is deliberately absent: the cache directory layout carries it
/// (one retained subdirectory per build id), so a rebuilt compiler
/// auto-invalidates without destructive sibling cleanup.
pub const KeyContext = struct {
    policy_fp: u64,
    let_float_enabled: bool,
    full_lazy_enabled: bool,
    mfe_min_applies: u16,
    named_floats: bool,
    chain_split: bool,
    /// `$HOME` affects `~/…` path-literal resolution.
    home: ?[]const u8,
};
pub const Key = [32]u8;

/// sha256 over common.format_version + every `KeyContext` field + path + source,
/// each variable-length piece length-prefixed to avoid ambiguous
/// concatenation.
pub fn computeKey(source: []const u8, source_path: []const u8, ctx: KeyContext) Key {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(std.mem.asBytes(&common.format_version));
    hasher.update(std.mem.asBytes(&ctx.policy_fp));
    hasher.update(std.mem.asBytes(&ctx.let_float_enabled));
    hasher.update(std.mem.asBytes(&ctx.full_lazy_enabled));
    hasher.update(std.mem.asBytes(&ctx.mfe_min_applies));
    hasher.update(std.mem.asBytes(&ctx.named_floats));
    hasher.update(std.mem.asBytes(&ctx.chain_split));
    if (ctx.home) |h| {
        hasher.update(&[_]u8{1});
        hasher.update(std.mem.asBytes(&@as(u64, h.len)));
        hasher.update(h);
    } else {
        hasher.update(&[_]u8{0});
    }
    hasher.update(std.mem.asBytes(&@as(u64, source_path.len)));
    hasher.update(source_path);
    hasher.update(std.mem.asBytes(&@as(u64, source.len)));
    hasher.update(source);
    var out: Key = undefined;
    hasher.final(&out);
    return out;
}
