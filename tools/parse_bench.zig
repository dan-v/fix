//! Parse microbenchmark: `zig build bench-parse -- <file.nix> [file2.nix ...]`.
//! Reports best-of-N cycles/byte for parsing each file (tables come from the
//! wired `parser_tables`, so it measures the real driver).

const std = @import("std");
const builtin = @import("builtin");
const syntax = @import("syntax");

/// Cheap monotonic tick counter for the inner timing loop. x86_64 uses the
/// cycle-accurate TSC; aarch64 reads the virtual count register (a fixed-
/// frequency tick, so the reported "cyc/byte" is really "ticks/byte" there,
/// fine for the relative best-of-N comparison this tool does). Anything else
/// falls back to a nanosecond clock.
inline fn rdtsc() u64 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            var hi: u32 = undefined;
            var lo: u32 = undefined;
            asm volatile ("lfence\nrdtsc\nlfence"
                : [lo] "={eax}" (lo),
                  [hi] "={edx}" (hi),
            );
            return (@as(u64, hi) << 32) | @as(u64, lo);
        },
        .aarch64 => {
            var v: u64 = undefined;
            asm volatile ("isb\nmrs %[v], cntvct_el0"
                : [v] "=r" (v),
            );
            return v;
        },
        else => return @intCast(std.time.nanoTimestamp()),
    }
}

fn readAll(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    return try reader.interface.allocRemaining(a, .unlimited);
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(a);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |path| {
        const src = try readAll(a, io, path);
        defer a.free(src);
        const iters: usize = @max(30, 20_000_000 / (src.len + 1));
        var best: u64 = std.math.maxInt(u64);
        var best_elide: u64 = std.math.maxInt(u64);
        var best_scan: u64 = std.math.maxInt(u64);
        var best_toks: u64 = std.math.maxInt(u64);
        var ntok_total: usize = 0;
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            {
                var sc = syntax.scanner.Scanner.init(src);
                const t0 = rdtsc();
                var ntok: usize = 0;
                while (true) {
                    const tk = sc.next();
                    ntok += 1;
                    if (tk.type == .eof) break;
                }
                const dt = rdtsc() - t0;
                std.mem.doNotOptimizeAway(ntok);
                ntok_total = ntok;
                if (dt < best_scan) best_scan = dt;
            }
            {
                // Token-array build, mirroring Parser.parse's first phase.
                var toks: std.ArrayListUnmanaged(syntax.token.Token) = .empty;
                defer toks.deinit(a);
                const t0 = rdtsc();
                toks.ensureTotalCapacity(a, src.len / 3 + 16) catch continue;
                var sc = syntax.scanner.Scanner.init(src);
                while (true) {
                    const tk = sc.next();
                    toks.append(a, tk) catch break;
                    if (tk.type == .eof) break;
                }
                const dt = rdtsc() - t0;
                std.mem.doNotOptimizeAway(toks.items.len);
                if (dt < best_toks) best_toks = dt;
            }
            {
                var arena = syntax.ast.AstArena.init(a);
                defer arena.deinit();
                var p = syntax.Parser.init(a, &arena, src);
                defer p.deinit();
                const t0 = rdtsc();
                const node = p.parse() catch continue;
                const dt = rdtsc() - t0;
                std.mem.doNotOptimizeAway(node);
                if (dt < best) best = dt;
            }
            {
                // Body-span elision on (the file-compile configuration).
                var arena = syntax.ast.AstArena.init(a);
                defer arena.deinit();
                var p = syntax.Parser.init(a, &arena, src);
                defer p.deinit();
                p.elide_bodies = true;
                const t0 = rdtsc();
                const node = p.parse() catch continue;
                const dt = rdtsc() - t0;
                std.mem.doNotOptimizeAway(node);
                if (dt < best_elide) best_elide = dt;
            }
        }
        const b: f64 = @floatFromInt(src.len);
        std.debug.print("{s: <30} {d: >7}B {d: >7} toks  full {d:5.2}  elide {d:5.2}  scan {d:5.2}  toks {d:5.2}  cyc/byte\n", .{ std.fs.path.basename(path), src.len, ntok_total, @as(f64, @floatFromInt(best)) / b, @as(f64, @floatFromInt(best_elide)) / b, @as(f64, @floatFromInt(best_scan)) / b, @as(f64, @floatFromInt(best_toks)) / b });
    }
}
