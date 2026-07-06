//! Parse microbenchmark: `zig build bench -- <file.nix> [file2.nix ...]`.
//! Reports best-of-N cycles/byte for parsing each file (tables come from the
//! wired `parser_tables`, so it measures the real driver).

const std = @import("std");
const syntax = @import("syntax");

inline fn rdtsc() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile ("lfence\nrdtsc\nlfence"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | @as(u64, lo);
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
        var i: usize = 0;
        while (i < iters) : (i += 1) {
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
        const cpb = @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(src.len));
        std.debug.print("{s: <60} {d: >8}B  best {d: >9} cyc  {d:.2} cyc/byte\n", .{ path, src.len, best, cpb });
    }
}
