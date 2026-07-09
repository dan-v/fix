//! Nix hashing builtins: hashString and hashFile.

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
