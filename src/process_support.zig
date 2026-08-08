//! Process-level support for the application composition root.
//!
//! Keeps allocator and memory-backing policy out of CLI commands while letting
//! `main` configure the evaluator's process-wide memory machinery.

const std = @import("std");
const builtin = @import("builtin");
const base = @import("base");
const mem_tag = @import("runtime").mem_tag;

pub const LargeBlockAllocator = base.block_cache.BlockCacheAllocator(mem_tag.vma);

/// Tune glibc malloc for many-worker evaluation. glibc grows per-thread heap
/// arenas page-by-page (`sysmalloc -> grow_heap -> mprotect`), and every
/// mprotect takes the process's mmap_lock in WRITE mode, serializing all
/// other workers' page faults (read-mode holders). On an 11k-job walk this
/// ran at 27,724 mprotects and capped a production-scale eval at 4 useful
/// workers. Padding arena growth (top_pad) and raising the trim/mmap
/// thresholds drops the walk to ~600 mm-syscalls total with unchanged wall
/// time and +0.6% max RSS.
///
/// Must run before evaluation threads start; a no-op off linux-gnu.
pub fn tuneMalloc() void {
    if (comptime builtin.os.tag == .linux and builtin.abi.isGnu()) {
        // Constants from glibc malloc.h.
        const M_TRIM_THRESHOLD = -1;
        const M_TOP_PAD = -2;
        const M_MMAP_THRESHOLD = -3;
        _ = mallopt(M_TOP_PAD, 64 << 20);
        _ = mallopt(M_TRIM_THRESHOLD, 128 << 20);
        _ = mallopt(M_MMAP_THRESHOLD, 128 << 20);
    }
}

extern "c" fn mallopt(param: c_int, value: c_int) c_int;
