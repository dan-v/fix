//! Pure language-library support used by Nix builtins.
//!
//! These implementations encode Nix-visible parsing and matching semantics,
//! so they live above the generic `base` infrastructure.

pub const regex = @import("language/regex.zig");
pub const toml = @import("language/toml.zig");

test {
    _ = regex;
    _ = toml;
}
