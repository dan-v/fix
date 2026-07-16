//! Language compatibility and feature policy shared by parsing, compilation,
//! and execution. Keeping one value prevents nested compilers and VMs from
//! silently inheriting only a subset of the evaluator's configuration.

const types = @import("runtime").types;

pub const LanguagePolicy = struct {
    pipe_operators_enabled: bool = false,
    fetch_tree_enabled: bool = false,
    flakes_enabled: bool = false,
    max_call_depth: u32 = types.default_max_call_depth,
    coerce_integers_enabled: bool = false,
    allow_nul_bytes: bool = false,
    allow_floor_ceil_corrupt: bool = false,
    allow_rec_set_overrides: bool = false,
    allow_rec_set_merges: bool = false,
    allow_cr_line_endings: bool = false,
    allow_tokens_no_whitespace: bool = false,
    allow_nix_path_shadow: bool = false,
};
