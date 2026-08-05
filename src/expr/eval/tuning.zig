//! Resolve `FIX_*` scheduler and speculation environment overrides.
//!
//! Runs once before `scheduler.start`.

const std = @import("std");
const scheduler_mod = @import("workers/scheduler.zig");
const vm_strings = @import("../vm/strings.zig");
const let_float = @import("../compiler/let_float.zig");

const EnvMap = std.process.Environ.Map;

fn envValue(env: ?*const EnvMap, name: []const u8) ?[]const u8 {
    const map = env orelse return null;
    return map.get(name);
}

fn envInt(comptime T: type, env: ?*const EnvMap, name: []const u8) ?T {
    const value = envValue(env, name) orelse return null;
    return std.fmt.parseInt(T, value, 10) catch null;
}

fn envEnabled(env: ?*const EnvMap, name: []const u8, fallback: bool) bool {
    const value = envValue(env, name) orelse return fallback;
    return !std.mem.eql(u8, value, "0");
}

fn resolveSibling(config: *scheduler_mod.Config, env: ?*const EnvMap, worker_count: u8) void {
    // Sibling prefetch needs helpers and is bounded at wider pools to avoid
    // duplicating the general speculative lanes.
    config.sibling_prefetch = envEnabled(env, "FIX_SIBLING", worker_count > 1 and worker_count <= 16);
    config.sibling_min = envInt(u32, env, "FIX_SIBLING_MIN") orelse 16;
    config.sibling_max = envInt(u32, env, "FIX_SIBLING_MAX") orelse 64;
    if (envInt(u64, env, "FIX_SIBLING_BUDGET")) |budget| {
        config.sibling_budget = budget;
        config.sibling_claim_budget = budget;
    }
    if (envInt(u64, env, "FIX_SIBLING_CLAIMS")) |budget| config.sibling_claim_budget = budget;
    config.sibling_urgent = envEnabled(env, "FIX_SIBLING_URGENT", config.sibling_urgent);
    config.sibling_log = envValue(env, "FIX_SIBLING_LOG") != null;
}

pub const PrefetchPolicy = struct {
    import_budget: u32,
    read_dir_min: u32,
    read_dir_budget: u32,
};

/// Resolve import and directory prefetch limits. Both require helper workers.
pub fn resolvePrefetch(env: ?*const EnvMap, worker_count: u8) PrefetchPolicy {
    const helpers_available = worker_count > 1;
    const import_enabled = helpers_available and envEnabled(env, "FIX_IMPORT_PREFETCH", true);
    const read_dir_enabled = helpers_available and envEnabled(env, "FIX_READDIR_PREFETCH", true);
    return .{
        .import_budget = if (import_enabled) envInt(u32, env, "FIX_IMPORT_PREFETCH_MAX") orelse 8192 else 0,
        .read_dir_min = if (read_dir_enabled) envInt(u32, env, "FIX_READDIR_PREFETCH_MIN") orelse 32 else 0,
        .read_dir_budget = if (read_dir_enabled) envInt(u32, env, "FIX_READDIR_PREFETCH_MAX") orelse 16384 else 0,
    };
}

/// Resolve scheduler and speculation tuning into one immutable policy value.
pub fn resolve(
    base: scheduler_mod.Config,
    env: ?*const EnvMap,
    worker_count: u8,
) scheduler_mod.Config {
    var config = base;

    if (envInt(u32, env, "FIX_SPEC_BACKLOG")) |value| config.spec_backlog_per_helper = value;

    // First-time chunk speculation uses the novel lane whenever helpers exist.
    config.spec_novel = envEnabled(env, "FIX_SPEC_NOVEL", worker_count > 1);

    // Limit bulk speculation drainers in wide pools. 255 disables the cap.
    config.spec_helper_cap = envInt(u8, env, "FIX_SPEC_HELPERS") orelse 16;

    // Promote a speculative fiber when demand blocks on its thunk.
    if (envValue(env, "FIX_RESCUE") != null)
        config.spec_rescue = worker_count > 1 and envEnabled(env, "FIX_RESCUE", false);

    // Bound thunk creation by speculative tasks rooted at small chunks.
    if (envInt(u64, env, "FIX_SPEC_BAND_BUDGET")) |value| config.spec_band_budget = value;

    resolveSibling(&config, env, worker_count);

    // GC-able string threshold: producers route derived text of at least
    // this many bytes to heap strings instead of the immortal intern table.
    // Unset = off (every string interns); 0 = everything eligible goes to
    // the heap (the stress lane). Resolved here (once, before workers
    // start) though it lives on vm/strings — same one-shot contract as the
    // scheduler knobs.
    if (envInt(usize, env, "FIX_HEAP_STR_MIN")) |value|
        vm_strings.heap_string_min = value;

    // Compile-time let-binding placement (`compiler/let_float.zig`) — a
    // kill switch for A/B measurement and debugging, same one-shot contract
    // as the scheduler knobs. FIX_LET_FLOAT_STATS prints the rewrite census
    // to stderr at engine teardown.
    let_float.enabled = !envEnabled(env, "FIX_NO_LET_FLOAT", false);
    let_float.report_on_deinit = envEnabled(env, "FIX_LET_FLOAT_STATS", false);
    return config;
}
