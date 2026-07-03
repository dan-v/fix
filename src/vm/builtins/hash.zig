const Value = @import("runtime").value.Value;
const nix_hash = @import("runtime").hash;
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");

const stringArg = strings.stringArg;
const pathArg = strings.pathArg;
const stringTextInternId = strings.stringTextInternId;
const isPlainString = strings.isPlainString;

pub fn builtinHashString(self: anytype, algorithm_arg: Value, string_arg: Value) !Value {
    const algorithm_value = try vm_force.forceValue(self, algorithm_arg);
    const string_value = try vm_force.forceValue(self, string_arg);
    if (!isPlainString(algorithm_value) or !isPlainString(string_value)) return error.TypeError;
    const algorithm = self.intern.get(try stringTextInternId(self, algorithm_value));
    const string = self.intern.get(try stringTextInternId(self, string_value));
    const digest = try nix_hash.hashBytes(self.allocator, algorithm, string);
    defer self.allocator.free(digest);
    return Value.string(try self.intern.intern(digest));
}

pub fn builtinHashFile(self: anytype, algorithm_arg: Value, path_arg: Value) !Value {
    const algorithm = try stringArg(self, algorithm_arg);
    const contents = try self.files.readFile(try pathArg(self, path_arg));
    const digest = try nix_hash.hashBytes(self.allocator, algorithm, contents);
    defer self.allocator.free(digest);
    return Value.string(try self.intern.intern(digest));
}

const std = @import("std");
const Evaluator = @import("../../eval.zig").Evaluator;

// Test vectors independently verified via `printf 'abc' | md5sum` /
// `printf 'abc' | sha512sum` rather than trusting self-consistency.

test "hashString md5 matches the independently-computed digest of \"abc\"" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    const result = try ev.evaluate("builtins.hashString \"md5\" \"abc\"");
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", ev.intern.get(result.asInternId()));
}

test "hashString sha512 matches the independently-computed digest of \"abc\"" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    const result = try ev.evaluate("builtins.hashString \"sha512\" \"abc\"");
    try std.testing.expectEqualStrings(
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        ev.intern.get(result.asInternId()),
    );
}

test "hashString rejects an unsupported algorithm name" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(
        error.UnsupportedHashAlgorithm,
        ev.evaluate("builtins.hashString \"md4\" \"abc\""),
    );
}

test "hashString rejects a non-string argument" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.hashString \"sha256\" 1"));
}
