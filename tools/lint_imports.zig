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
//! It also enforces the **down-only** rule: modules form a layered acyclic
//! graph (see `module_levels`), and a file in one module may only `@import` a
//! module at a strictly lower level — so "what may I safely import here?" is a
//! located error, not tribal knowledge.
//!
//! Run via `zig build lint`; the `test` step depends on it.

const std = @import("std");

/// Every build module's name. A file outside a module may not reach into its
/// files by relative path; see `owningModule` for how physical paths (the
/// `base/`, `nix/`, `cli/` tiers) map onto these names.
const module_dirs = [_][]const u8{ "syntax", "runtime", "base", "scheduler", "derivation", "cli", "observ", "bytecode", "probe", "compiler", "vm" };

/// Longest-path topological level of each module in the `build.zig` dependency
/// graph. Imports must point strictly DOWN: a file in module M may only
/// `@import(name)` a module whose level is LOWER than M's. With longest-path
/// levels every legitimate edge is strictly decreasing, so this rejects exactly
/// the up- and sideways-imports. (The `fix` core — `nix/root*`, `nix/eval*` —
/// and `main.zig` own no lint module; they are the top and aren't checked.)
const ModuleLevel = struct { name: []const u8, level: u8 };
const module_levels = [_]ModuleLevel{
    .{ .name = "base", .level = 0 },
    // syntax → base (the parser's AST arena is base's plain arena), so
    // syntax sits one above base; observ → syntax pushes observ to 2.
    .{ .name = "syntax", .level = 1 },
    .{ .name = "runtime", .level = 1 },
    .{ .name = "observ", .level = 2 },
    .{ .name = "scheduler", .level = 2 },
    .{ .name = "derivation", .level = 2 },
    .{ .name = "bytecode", .level = 2 },
    .{ .name = "probe", .level = 3 },
    .{ .name = "compiler", .level = 4 },
    .{ .name = "vm", .level = 5 },
    .{ .name = "cli", .level = 7 },
};

fn levelOf(name: []const u8) ?u8 {
    for (module_levels) |ml| if (std.mem.eql(u8, ml.name, name)) return ml.level;
    return null;
}

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
            // Down-only rule for by-name module imports (`@import("vm")`): a
            // file in module M may only reach a strictly-lower-level module.
            if (namedImport(line)) |name| {
                if (owning) |own| {
                    if (!std.mem.eql(u8, name, own)) {
                        if (levelOf(name)) |imp_lvl| if (levelOf(own)) |own_lvl| {
                            if (imp_lvl >= own_lvl) {
                                violations += 1;
                                std.debug.print(
                                    "src/{s}:{d}: up-import — module '{s}' (level {d}) must not import '{s}' (level {d}); imports point down\n    {s}\n",
                                    .{ entry.path, line_no, own, own_lvl, name, imp_lvl, std.mem.trim(u8, line, " \t") },
                                );
                            }
                        };
                    }
                }
            }

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

/// A bare module name inside `@import("name")` — no `.zig`, no `/`
/// (i.e. `@import("vm")`, not `@import("vm/run.zig")` or `@import("std")`'s
/// callers with a path). Null for relative/path imports and lines without one.
fn namedImport(line: []const u8) ?[]const u8 {
    const marker = "@import(\"";
    const start = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const target = rest[0..end];
    if (std.mem.endsWith(u8, target, ".zig")) return null;
    if (std.mem.indexOfScalar(u8, target, '/') != null) return null;
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
