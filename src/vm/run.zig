const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const bytecode_mod = @import("../bytecode.zig");
const opcode = bytecode_mod.opcode;
const OpCode = opcode.OpCode;
const heap_mod = @import("../runtime/heap.zig");
const numeric = @import("../runtime/numeric.zig");

const access = @import("access.zig");
const closures = @import("closures.zig");
const equality = @import("equality.zig");
const force = @import("force.zig");
const objects = @import("objects.zig");
const stack = @import("stack.zig");
const strings = @import("strings.zig");

const VM = vm_mod.VM;
const opcode_profile_enabled = vm_mod.opcode_profile_enabled;
const readU16 = vm_mod.readU16;
const readU32 = vm_mod.readU32;

// ---- main loop ----

pub fn run(self: *VM) anyerror!Value {
    return runUntil(self, 0);
}

pub fn runUntil(self: *VM, stop_depth: usize) anyerror!Value {
    while (true) {
        var frame = stack.currentFrame(self);
        const code = frame.chunk_ptr.code;
        if (frame.ip >= code.len) break;

        const op: OpCode = @enumFromInt(code[frame.ip]);
        if (comptime opcode_profile_enabled) self.opcode_counts[@intFromEnum(op)] += 1;
        frame.ip += 1;

        switch (op) {
            .constant => {
                const idx_low = code[frame.ip];
                const idx_high = code[frame.ip + 1];
                frame.ip += 2;
                const idx: u16 = @as(u16, idx_low) | (@as(u16, idx_high) << 8);
                try stack.push(self, frame.chunk_ptr.constants[idx]);
            },

            .push_null => try stack.push(self, Value.null_val),
            .push_true => try stack.push(self, Value.boolVal(true)),
            .push_false => try stack.push(self, Value.boolVal(false)),

            .pop => {
                _ = stack.pop(self);
            },

            .get_local => {
                const slot = code[frame.ip];
                frame.ip += 1;
                const raw = self.stack[frame.frame_base + slot];
                const val = try force.forceValue(self, raw);
                try stack.push(self, val);
            },
            .get_local_long => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const raw = self.stack[frame.frame_base + slot];
                const val = try force.forceValue(self, raw);
                try stack.push(self, val);
            },

            .capture_local => {
                const slot = code[frame.ip];
                frame.ip += 1;
                const val = self.stack[frame.frame_base + slot];
                try stack.push(self, val);
            },
            .capture_local_long => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const val = self.stack[frame.frame_base + slot];
                try stack.push(self, val);
            },

            .capture_upvalue => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const upvalues = frame.upvalues orelse return error.MissingClosure;
                try stack.push(self, upvalues[slot]);
            },

            .set_local => {
                const slot = code[frame.ip];
                frame.ip += 1;
                const val = stack.pop(self);
                stack.setStack(self, frame.frame_base + slot, val);
            },
            .set_local_long => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const val = stack.pop(self);
                stack.setStack(self, frame.frame_base + slot, val);
            },

            .set_cell_local => {
                const slot = code[frame.ip];
                frame.ip += 1;
                const val = stack.pop(self);
                const cell_val = self.stack[frame.frame_base + slot];
                if (cell_val.discriminant != .thunk) return error.TypeError;
                const thunk = try self.heap.getThunk(cell_val.asObjectId());
                // The compiler initializes cells as pass-through thunks
                // wrapping `null` and then sets them to their real RHS here.
                // Update the wrapped value so the first force evaluates it.
                thunk.target = .{ .pass_through = val };
            },
            .set_cell_local_long => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const val = stack.pop(self);
                const cell_val = self.stack[frame.frame_base + slot];
                if (cell_val.discriminant != .thunk) return error.TypeError;
                const thunk = try self.heap.getThunk(cell_val.asObjectId());
                thunk.target = .{ .pass_through = val };
            },

            .get_upvalue => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const upvalues = frame.upvalues orelse return error.MissingClosure;
                const val = try force.forceValue(self, upvalues[slot]);
                try stack.push(self, val);
            },

            // ---- integer arithmetic ----
            .add_int => {
                const b = try force.forceValue(self, stack.pop(self));
                const a = try force.forceValue(self, stack.pop(self));
                if (numeric.isNumeric(a) and numeric.isNumeric(b)) {
                    try stack.push(self, try numeric.add(a, b));
                } else if (a.discriminant == .path) {
                    try stack.push(self, try strings.concatPathLike(self, a, b));
                } else {
                    try stack.push(self, try strings.concatStringLike(self, a, b));
                }
            },
            .sub_int => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                try stack.push(self, try numeric.sub(a, b));
            },
            .mul_int => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                try stack.push(self, try numeric.mul(a, b));
            },
            .div_int => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                try stack.push(self, try numeric.div(a, b));
            },
            .negate_int => {
                const a = stack.pop(self);
                try stack.push(self, try numeric.negate(a));
            },

            // ---- float arithmetic ----
            .add_float => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                try stack.push(self, Value.float(try numeric.toFloat(a) + try numeric.toFloat(b)));
            },
            .sub_float => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                try stack.push(self, Value.float(try numeric.toFloat(a) - try numeric.toFloat(b)));
            },
            .mul_float => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                try stack.push(self, Value.float(try numeric.toFloat(a) * try numeric.toFloat(b)));
            },
            .div_float => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                try stack.push(self, Value.float(try numeric.toFloat(a) / try numeric.toFloat(b)));
            },
            // ---- comparison ----
            .eq => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                try stack.push(self, Value.boolVal(try equality.valuesEqual(self, a, b)));
            },
            .neq => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                try stack.push(self, Value.boolVal(!try equality.valuesEqual(self, a, b)));
            },
            .lt => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                try stack.push(self, Value.boolVal(try equality.compareValues(self, a, b) == .lt));
            },
            .lte => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                const r = try equality.compareValues(self, a, b);
                try stack.push(self, Value.boolVal(r == .lt or r == .eq));
            },
            .gt => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                try stack.push(self, Value.boolVal(try equality.compareValues(self, a, b) == .gt));
            },
            .gte => {
                const b = stack.pop(self);
                const a = stack.pop(self);
                const r = try equality.compareValues(self, a, b);
                try stack.push(self, Value.boolVal(r == .gt or r == .eq));
            },

            // ---- logical ----
            .not => {
                const a = stack.pop(self);
                try stack.push(self, Value.boolVal(!try expectBool(self, a)));
            },

            // ---- control flow ----
            .jump => {
                const offset = readU32(code, frame.ip);
                frame.ip += 4;
                frame.ip += @as(usize, offset);
            },
            .jump_if_false => {
                const offset = readU32(code, frame.ip);
                frame.ip += 4;
                const cond = self.stack[self.sp - 1];
                if (!try expectBool(self, cond)) {
                    frame.ip += @as(usize, offset);
                }
            },
            .fail_assertion => return error.AssertionFailed,
            // ---- data structures ----
            .build_attrs => {
                const count: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                try objects.buildAttrs(self, count);
            },
            .build_attrs_with_pos => {
                const count: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                const pos_count: u16 = readU16(code, frame.ip);
                frame.ip += 2;

                var stack_positions: [32]heap_mod.AttrPosEntry = undefined;
                const positions = if (pos_count <= stack_positions.len)
                    stack_positions[0..pos_count]
                else
                    try self.allocator.alloc(heap_mod.AttrPosEntry, pos_count);
                defer if (positions.ptr != stack_positions[0..].ptr) self.allocator.free(positions);

                for (positions) |*position| {
                    position.* = .{
                        .name = readU32(code, frame.ip),
                        .pos = .{
                            .file = readU32(code, frame.ip + 4),
                            .line = readU32(code, frame.ip + 8),
                            .column = readU32(code, frame.ip + 12),
                        },
                    };
                    frame.ip += 16;
                }
                try objects.buildAttrsWithPositions(self, count, positions);
            },
            .build_list => {
                const count: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                try objects.buildList(self, count);
            },
            .merge_attrs => {
                const right = stack.pop(self);
                const left = stack.pop(self);
                try stack.push(self, try objects.mergeAttrs(self, left, right));
            },
            .merge_attrs_strict => {
                const right = stack.pop(self);
                const left = stack.pop(self);
                try stack.push(self, try objects.mergeAttrsStrict(self, left, right));
            },
            .concat_lists => {
                const right = stack.pop(self);
                const left = stack.pop(self);
                try stack.push(self, try objects.concatLists(self, left, right));
            },
            .push_builtins => try stack.push(self, self.builtins),
            .find_file => {
                const name_id: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                const host = self.import_host orelse return error.SearchPathUnavailable;
                try stack.push(self, try host.find_file(host.context, self.intern.get(@intCast(name_id))));
            },
            .find_file_long => {
                const name_id: InternId = readU32(code, frame.ip);
                frame.ip += 4;
                const host = self.import_host orelse return error.SearchPathUnavailable;
                try stack.push(self, try host.find_file(host.context, self.intern.get(name_id)));
            },
            // ---- closure ----
            .closure => {
                const ch_id: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                const upvalue_count = readU16(code, frame.ip);
                frame.ip += 2;
                try closures.makeClosure(self, ch_id, upvalue_count);
            },
            .closure_long => {
                const ch_id: ChunkId = readU32(code, frame.ip);
                frame.ip += 4;
                const upvalue_count = readU16(code, frame.ip);
                frame.ip += 2;
                try closures.makeClosure(self, ch_id, upvalue_count);
            },
            .closure_captures => {
                const ch_id: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                const upvalue_count = readU16(code, frame.ip);
                frame.ip += 2;
                const descriptor_len = @as(usize, upvalue_count) * 3;
                if (descriptor_len > code.len - frame.ip) return error.InvalidBytecode;
                const descriptors = code[frame.ip .. frame.ip + descriptor_len];
                frame.ip += descriptor_len;
                try closures.makeClosureFromCaptures(self, ch_id, descriptors, frame);
            },
            .closure_captures_long => {
                const ch_id: ChunkId = readU32(code, frame.ip);
                frame.ip += 4;
                const upvalue_count = readU16(code, frame.ip);
                frame.ip += 2;
                const descriptor_len = @as(usize, upvalue_count) * 3;
                if (descriptor_len > code.len - frame.ip) return error.InvalidBytecode;
                const descriptors = code[frame.ip .. frame.ip + descriptor_len];
                frame.ip += descriptor_len;
                try closures.makeClosureFromCaptures(self, ch_id, descriptors, frame);
            },
            .thunk_captures => {
                const ch_id: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                const upvalue_count = readU16(code, frame.ip);
                frame.ip += 2;
                const descriptor_len = @as(usize, upvalue_count) * 3;
                if (descriptor_len > code.len - frame.ip) return error.InvalidBytecode;
                const descriptors = code[frame.ip .. frame.ip + descriptor_len];
                frame.ip += descriptor_len;
                try closures.makeBytecodeThunkFromCaptures(self, ch_id, descriptors, frame);
            },
            .thunk_captures_long => {
                const ch_id: ChunkId = readU32(code, frame.ip);
                frame.ip += 4;
                const upvalue_count = readU16(code, frame.ip);
                frame.ip += 2;
                const descriptor_len = @as(usize, upvalue_count) * 3;
                if (descriptor_len > code.len - frame.ip) return error.InvalidBytecode;
                const descriptors = code[frame.ip .. frame.ip + descriptor_len];
                frame.ip += descriptor_len;
                try closures.makeBytecodeThunkFromCaptures(self, ch_id, descriptors, frame);
            },

            // ---- calls ----
            .call => {
                const arg = stack.pop(self);
                const callee = stack.pop(self);
                try closures.doCall(self, callee, arg);
            },
            .tail_call => {
                const arg = stack.pop(self);
                const callee = stack.pop(self);
                try closures.doTailCall(self, callee, arg);
            },
            // ---- thunks ----
            .make_cell => {
                const val = stack.pop(self);
                try stack.push(self, try force.makeCell(self, val));
            },

            // ---- attribute access ----
            .get_attr => {
                const name_id: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                const attrs_val = stack.pop(self);
                const result = try access.getAttrValue(self, attrs_val, @intCast(name_id));
                try stack.push(self, result);
            },
            .get_attr_long => {
                const name_id: InternId = readU32(code, frame.ip);
                frame.ip += 4;
                const attrs_val = stack.pop(self);
                const result = try access.getAttrValue(self, attrs_val, name_id);
                try stack.push(self, result);
            },
            .get_attr_dynamic => {
                const name_val = try force.forceValue(self, stack.pop(self));
                if (name_val.discriminant != .string) return error.TypeError;
                const attrs_val = stack.pop(self);
                const result = try access.getAttrValue(self, attrs_val, name_val.asInternId());
                try stack.push(self, result);
            },
            .get_attr_dynamic_or => {
                const default_val = stack.pop(self);
                const name_val = try force.forceValue(self, stack.pop(self));
                if (name_val.discriminant != .string) return error.TypeError;
                const attrs_val = stack.pop(self);
                const attrs = try force.forceValue(self, attrs_val);
                if (attrs.discriminant != .attrs) return try force.forceValue(self, default_val);
                const result = self.heap.getAttrValue(attrs.asObjectId(), name_val.asInternId()) catch |err| switch (err) {
                    error.MissingAttribute => try force.forceValue(self, default_val),
                    else => return err,
                };
                try stack.push(self, try force.forceValue(self, result));
            },
            .get_attr_path_dynamic_or => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 2;
                const default_val = stack.pop(self);
                const name_val = stack.pop(self);
                const attrs_val = stack.pop(self);
                const result = try access.getAttrPathDynamicOrValue(self, attrs_val, name_val, default_val, code[names_start..frame.ip], false);
                try stack.push(self, result);
            },
            .get_attr_path_dynamic_or_long => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 4;
                const default_val = stack.pop(self);
                const name_val = stack.pop(self);
                const attrs_val = stack.pop(self);
                const result = try access.getAttrPathDynamicOrValue(self, attrs_val, name_val, default_val, code[names_start..frame.ip], true);
                try stack.push(self, result);
            },
            .get_attr_path_or => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 2;
                const default_val = stack.pop(self);
                const attrs_val = stack.pop(self);
                const result = try access.getAttrPathOrValue(self, attrs_val, default_val, code[names_start..frame.ip], false);
                try stack.push(self, result);
            },
            .get_attr_path_or_long => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 4;
                const default_val = stack.pop(self);
                const attrs_val = stack.pop(self);
                const result = try access.getAttrPathOrValue(self, attrs_val, default_val, code[names_start..frame.ip], true);
                try stack.push(self, result);
            },
            .get_attr_path_mixed_or => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const dynamic_count = code[frame.ip];
                frame.ip += 1;
                const segments_start = frame.ip;
                for (0..segment_count) |_| {
                    const tag = code[frame.ip];
                    frame.ip += 1;
                    switch (tag) {
                        @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => frame.ip += 4,
                        @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => {},
                        else => return error.InvalidBytecode,
                    }
                }
                const default_val = stack.pop(self);
                const dynamic_names = try self.allocator.alloc(Value, dynamic_count);
                defer self.allocator.free(dynamic_names);
                var dynamic_i: usize = dynamic_count;
                while (dynamic_i > 0) {
                    dynamic_i -= 1;
                    dynamic_names[dynamic_i] = stack.pop(self);
                }
                const attrs_val = stack.pop(self);
                const result = try access.getAttrPathMixedOrValue(self, attrs_val, dynamic_names, default_val, code[segments_start..frame.ip], segment_count);
                try stack.push(self, result);
            },
            .has_attr_path => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 2;
                const attrs_val = stack.pop(self);
                try stack.push(self, Value.boolVal(try access.hasAttrPath(self, attrs_val, code[names_start..frame.ip], false)));
            },
            .has_attr_path_long => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 4;
                const attrs_val = stack.pop(self);
                try stack.push(self, Value.boolVal(try access.hasAttrPath(self, attrs_val, code[names_start..frame.ip], true)));
            },
            .has_attr_dynamic => {
                const name_val = try force.forceValue(self, stack.pop(self));
                if (name_val.discriminant != .string) return error.TypeError;
                const attrs_val = try force.forceValue(self, stack.pop(self));
                if (attrs_val.discriminant != .attrs) {
                    try stack.push(self, Value.boolVal(false));
                } else {
                    const present = if (self.heap.getAttrValue(attrs_val.asObjectId(), name_val.asInternId())) |_|
                        true
                    else |err| switch (err) {
                        error.MissingAttribute => false,
                        else => return err,
                    };
                    try stack.push(self, Value.boolVal(present));
                }
            },
            .has_attr_path_mixed => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const dynamic_count = code[frame.ip];
                frame.ip += 1;
                const segments_start = frame.ip;
                for (0..segment_count) |_| {
                    const tag = code[frame.ip];
                    frame.ip += 1;
                    switch (tag) {
                        @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => frame.ip += 4,
                        @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => {},
                        else => return error.InvalidBytecode,
                    }
                }
                const dynamic_names = try self.allocator.alloc(Value, dynamic_count);
                defer self.allocator.free(dynamic_names);
                var dynamic_i: usize = dynamic_count;
                while (dynamic_i > 0) {
                    dynamic_i -= 1;
                    dynamic_names[dynamic_i] = stack.pop(self);
                }
                const attrs_val = stack.pop(self);
                try stack.push(self, Value.boolVal(try access.hasAttrPathMixed(self, attrs_val, dynamic_names, code[segments_start..frame.ip], segment_count)));
            },
            .validate_attrs => {
                const allow_extra = code[frame.ip] != 0;
                frame.ip += 1;
                const expected_count = readU16(code, frame.ip);
                frame.ip += 2;
                const names_start = frame.ip;
                frame.ip += @as(usize, expected_count) * 2;
                const attrs_val = stack.pop(self);
                try access.validateAttrs(self, attrs_val, allow_extra, code[names_start..frame.ip], false);
            },
            .validate_attrs_long => {
                const allow_extra = code[frame.ip] != 0;
                frame.ip += 1;
                const expected_count = readU16(code, frame.ip);
                frame.ip += 2;
                const names_start = frame.ip;
                frame.ip += @as(usize, expected_count) * 4;
                const attrs_val = stack.pop(self);
                try access.validateAttrs(self, attrs_val, allow_extra, code[names_start..frame.ip], true);
            },
            .lookup_with => {
                const name_id: InternId = @intCast(readU16(code, frame.ip));
                frame.ip += 2;
                const scope_count = code[frame.ip];
                frame.ip += 1;
                try access.lookupWith(self, name_id, scope_count);
            },
            .lookup_with_long => {
                const name_id: InternId = readU32(code, frame.ip);
                frame.ip += 4;
                const scope_count = code[frame.ip];
                frame.ip += 1;
                try access.lookupWith(self, name_id, scope_count);
            },
            // ---- termination ----
            .ret => {
                const result = stack.pop(self);
                const finished_frame = stack.popFrame(self);
                if (self.frames_len == stop_depth) {
                    self.sp = finished_frame.frame_base;
                    return result;
                }
                self.sp = finished_frame.frame_base;
                try stack.push(self, result);
            },
            .halt => {
                // Stop execution.
                if (self.sp > 0) return stack.pop(self);
                return Value.null_val;
            },
        }
    }

    return if (self.sp > 0) stack.pop(self) else Value.null_val;
}

// ---- helpers ----

pub fn expectBool(self: *VM, val: Value) !bool {
    const forced = try force.forceValue(self, val);
    return switch (forced.discriminant) {
        .bool_false => false,
        .bool_true => true,
        else => error.TypeError,
    };
}
