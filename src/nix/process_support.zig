//! Process-level support for the application composition root.
//!
//! Keeps allocator and memory-backing policy out of CLI commands while letting
//! `main` configure the evaluator's process-wide memory machinery.

const base = @import("base");
const mem_tag = @import("runtime").mem_tag;

pub const LargeBlockAllocator = base.block_cache.BlockCacheAllocator(mem_tag.vma);
pub const memory_backing = base.hugetlb;
