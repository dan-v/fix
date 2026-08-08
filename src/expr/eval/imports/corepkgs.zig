//! Synthetic import sources traditionally provided by Nix corepkgs.

const std = @import("std");

/// The `<...>` search-path name that resolves to the synthetic fetchurl file.
pub const fetchurl_name = "nix/fetchurl.nix";
/// The synthetic path `<nix/fetchurl.nix>` resolves to. Not a real file:
/// `source` supplies its contents, and pure eval treats it as always readable.
pub const fetchurl_path = "/__corepkgs__/fetchurl.nix";

/// Source for `<nix/fetchurl.nix>`, embedded so evaluation does not depend on
/// a corepkgs store path being present on the host.
pub fn source(path: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, path, fetchurl_path)) return null;
    return
    \\{
    \\  system ? "", # obsolete
    \\  name ? baseNameOf url,
    \\  url,
    \\  hash ? "",
    \\  sha256 ? "",
    \\  executable ? false,
    \\  unpack ? false,
    \\  ...
    \\}:
    \\let
    \\  outputHash = if hash != "" then hash else sha256;
    \\in
    \\derivation {
    \\  inherit name url executable;
    \\  urls = [ url ];
    \\  builder = "builtin:fetchurl";
    \\  system = "builtin";
    \\  inherit outputHash;
    \\  outputHashAlgo = if hash != "" then null else "sha256";
    \\  outputHashMode = if unpack || executable then "recursive" else "flat";
    \\  preferLocalBuild = true;
    \\  impureEnvVars = [ "http_proxy" "https_proxy" "ftp_proxy" "all_proxy" "no_proxy" ];
    \\  inherit unpack;
    \\}
    ;
}

test "corepkgs fetchurl source is available only at its synthetic path" {
    try std.testing.expect(source("/__corepkgs__/fetchurl.nix") != null);
    try std.testing.expect(source("/tmp/fetchurl.nix") == null);
}
