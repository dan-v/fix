//! Synthetic compatibility sources traditionally provided by Nix corepkgs.

const std = @import("std");

/// Source for `<nix/fetchurl.nix>`, embedded so evaluation does not depend on
/// a corepkgs store path being present on the host.
pub fn source(path: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, path, "/__corepkgs__/fetchurl.nix")) return null;
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
    \\  unpack = false;
    \\}
    ;
}

test "corepkgs fetchurl source is available only at its synthetic path" {
    try std.testing.expect(source("/__corepkgs__/fetchurl.nix") != null);
    try std.testing.expect(source("/tmp/fetchurl.nix") == null);
}
