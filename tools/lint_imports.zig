//! Module-boundary import lint.
//!
//! The clean-cut subsystems (`syntax`, `runtime`, `base`, `scheduler`,
//! `derivation`) are real `build.zig` modules. Code outside such a module
//! must reach it by name — `@import("runtime")` — never by a relative path
//! into its files.
//!
//! A stray `@import("../runtime/value.zig")` from a main-module file does *not*
//! fail to compile: it pulls that file into a second module instance, silently
//! duplicating its types (so `runtime.Value` != the other copy's `Value`) and
//! producing baffling mismatches far from the cause. This linter makes that a
//! hard, located error instead.
//!
//! Run via `zig build lint`; the `test` step depends on it.

const std = @import("std");

/// Every build module's name. A file outside a module may not reach into its
/// files by relative path; see `owningModule` for how physical paths (the
/// `base/`, `nix/`, `cli/` tiers) map onto these names.
const module_dirs = [_][]const u8{ "syntax", "runtime", "base", "scheduler", "derivation", "cli", "observ", "bytecode", "probe", "compiler", "vm" };

const max_file_bytes = 8 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var src_dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src_dir.close(io);

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();

    var violations: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const owning = owningModule(entry.path);
        const content = try src_dir.readFileAlloc(io, entry.path, gpa, .limited(max_file_bytes));
        defer gpa.free(content);

        var line_no: usize = 0;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            line_no += 1;
            const target = importTarget(line) orelse continue;
            const crossed = crossesModuleBoundary(entry.path, target) orelse continue;
            // Importing your own module's files by relative path is fine.
            if (owning) |own| if (std.mem.eql(u8, own, crossed)) continue;
            violations += 1;
            std.debug.print(
                "src/{s}:{d}: relative import crosses into module '{s}' — use @import(\"{s}\")\n    {s}\n",
                .{ entry.path, line_no, crossed, crossed, std.mem.trim(u8, line, " \t") },
            );
        }
    }

    if (violations != 0) {
        std.debug.print("\nimport lint: {d} module-boundary violation(s)\n", .{violations});
        std.process.exit(1);
    }
    std.debug.print("import lint: ok ({d} module boundaries enforced)\n", .{module_dirs.len});
}

/// Which module (if any) `src/<rel>` belongs to.
///
/// Sources are grouped into three physical tiers under `src/`:
///   - `base/**` is a single module (`base`) — the whole tier.
///   - `cli/**` is a single module (`cli`) — the whole tier.
///   - `nix/**` holds one module per subsystem: `nix/<m>/**` and the facade
///     `nix/<m>.zig` belong to module `<m>` (the `fix` core files `nix/root*`
///     and `nix/eval*` belong to no lint module).
/// A module's own files may freely import its internals by relative path.
fn owningModule(rel: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, rel, "base/")) return "base";
    if (std.mem.startsWith(u8, rel, "cli/")) return "cli";
    // Strip the `nix/` tier segment (if present) before matching subsystem dirs.
    const inner = if (std.mem.startsWith(u8, rel, "nix/")) rel["nix/".len..] else rel;
    for (module_dirs) |m| {
        if (std.mem.startsWith(u8, inner, m) and inner.len > m.len and inner[m.len] == '/') return m;
        if (inner.len == m.len + 4 and std.mem.startsWith(u8, inner, m) and std.mem.eql(u8, inner[m.len..], ".zig")) return m;
    }
    return null;
}

/// The `.zig` path inside an `@import("...")`, or null for non-relative imports
/// (`std`, `runtime`, `build_options`, …) and lines without one.
fn importTarget(line: []const u8) ?[]const u8 {
    const marker = "@import(\"";
    const start = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const target = rest[0..end];
    if (!std.mem.endsWith(u8, target, ".zig")) return null;
    return target;
}

/// If `importer`'s relative import `target` resolves into a module's files
/// (or its facade), return that module name; else null.
fn crossesModuleBoundary(importer_rel: []const u8, target: []const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = resolve(importer_rel, target, &buf) orelse return null;
    return owningModule(resolved);
}

/// Resolve `target` (relative to `importer_rel`'s directory) to an
/// `src/`-relative path with `./` and `../` collapsed. Returns null on a path
/// that escapes `src/`.
fn resolve(importer_rel: []const u8, target: []const u8, buf: []u8) ?[]const u8 {
    const dir = std.fs.path.dirname(importer_rel) orelse "";
    var joined_buf: [std.fs.max_path_bytes]u8 = undefined;
    const joined = std.fmt.bufPrint(&joined_buf, "{s}/{s}", .{ dir, target }) catch return null;

    var stack: [64][]const u8 = undefined;
    var depth: usize = 0;
    var comps = std.mem.splitScalar(u8, joined, '/');
    while (comps.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (depth == 0) return null; // escaped src/
            depth -= 1;
            continue;
        }
        if (depth == stack.len) return null;
        stack[depth] = c;
        depth += 1;
    }
    var len: usize = 0;
    for (stack[0..depth], 0..) |c, i| {
        if (i != 0) {
            buf[len] = '/';
            len += 1;
        }
        @memcpy(buf[len .. len + c.len], c);
        len += c.len;
    }
    return buf[0..len];
}
