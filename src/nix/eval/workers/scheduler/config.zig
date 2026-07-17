//! Immutable-after-start scheduler policy.

pub const Config = struct {
    disable_speculation: bool = false,
    disable_fanout: bool = false,
    spec_backlog_per_helper: u32 = 128,
    sibling_prefetch: bool = false,
    sibling_min: u32 = 16,
    sibling_max: u32 = 64,
    sibling_budget: u64 = 4096,
    sibling_claim_budget: u64 = 4096,
    sibling_urgent: bool = true,
    sibling_log: bool = false,
    spec_rescue: bool = false,
    readdir_prefetch_min: u32 = 0,
    spec_band_budget: u64 = 512,
    spec_novel: bool = false,
    spec_helper_cap: u8 = 255,
    trace_flows: bool = false,
};
