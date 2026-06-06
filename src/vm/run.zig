const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const bytecode_mod = @import("../bytecode.zig");
const opcode = @import("../opcode.zig");
const OpCode = opcode.OpCode;
const chunk = @import("../chunk.zig");
const Chunk = chunk.Chunk;
const thunk_mod = @import("../thunk.zig");
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;
const heap_mod = @import("../heap.zig");
const Closure = heap_mod.Closure;
const numeric = @import("../runtime/numeric.zig");
const source_paths = @import("../runtime/source_path.zig");
const vm_builtins = @import("builtins.zig");
const diagnostic = @import("../diagnostic.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const opcode_profile_enabled = vm_mod.opcode_profile_enabled;
const readU16 = vm_mod.readU16;
const readU32 = vm_mod.readU32;
const readInternId = vm_mod.readInternId;

// ---- main loop ----

pub fn run(self: *VM) anyerror!Value {
    return self.runUntil(0);
}

pub fn runUntil(self: *VM, stop_depth: usize) anyerror!Value {
    while (true) {
        var frame = self.currentFrame();
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
                try self.push(frame.chunk_ptr.constants[idx]);
            },

            .push_null => try self.push(Value.null_val),
            .push_true => try self.push(Value.boolVal(true)),
            .push_false => try self.push(Value.boolVal(false)),

            .pop => {
                _ = self.pop();
            },

            .get_local => {
                const slot = code[frame.ip];
                frame.ip += 1;
                const raw = self.stack.items[frame.frame_base + slot];
                const val = try self.forceValue(raw);
                try self.push(val);
            },
            .get_local_long => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const raw = self.stack.items[frame.frame_base + slot];
                const val = try self.forceValue(raw);
                try self.push(val);
            },

            .capture_local => {
                const slot = code[frame.ip];
                frame.ip += 1;
                const val = self.stack.items[frame.frame_base + slot];
                try self.push(val);
            },
            .capture_local_long => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const val = self.stack.items[frame.frame_base + slot];
                try self.push(val);
            },

            .capture_upvalue => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const upvalues = frame.upvalues orelse return error.MissingClosure;
                try self.push(upvalues[slot]);
            },

            .set_local => {
                const slot = code[frame.ip];
                frame.ip += 1;
                const val = self.pop();
                self.setStack(frame.frame_base + slot, val);
            },
            .set_local_long => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const val = self.pop();
                self.setStack(frame.frame_base + slot, val);
            },

            .set_cell_local => {
                const slot = code[frame.ip];
                frame.ip += 1;
                const val = self.pop();
                const cell_val = self.stack.items[frame.frame_base + slot];
                if (cell_val.discriminant != .cell) return error.TypeError;
                try self.heap.setCellValue(cell_val.asObjectId(), val);
            },
            .set_cell_local_long => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const val = self.pop();
                const cell_val = self.stack.items[frame.frame_base + slot];
                if (cell_val.discriminant != .cell) return error.TypeError;
                try self.heap.setCellValue(cell_val.asObjectId(), val);
            },

            .get_upvalue => {
                const slot = readU16(code, frame.ip);
                frame.ip += 2;
                const upvalues = frame.upvalues orelse return error.MissingClosure;
                const val = try self.forceValue(upvalues[slot]);
                try self.push(val);
            },

            // ---- integer arithmetic ----
            .add_int => {
                const b = try self.forceValue(self.pop());
                const a = try self.forceValue(self.pop());
                if (numeric.isNumeric(a) and numeric.isNumeric(b)) {
                    try self.push(try numeric.add(a, b));
                } else if (a.discriminant == .path) {
                    try self.push(try self.concatPathLike(a, b));
                } else {
                    try self.push(try self.concatStringLike(a, b));
                }
            },
            .sub_int => {
                const b = self.pop();
                const a = self.pop();
                try self.push(try numeric.sub(a, b));
            },
            .mul_int => {
                const b = self.pop();
                const a = self.pop();
                try self.push(try numeric.mul(a, b));
            },
            .div_int => {
                const b = self.pop();
                const a = self.pop();
                try self.push(try numeric.div(a, b));
            },
            .negate_int => {
                const a = self.pop();
                try self.push(try numeric.negate(a));
            },

            // ---- float arithmetic ----
            .add_float => {
                const b = self.pop();
                const a = self.pop();
                try self.push(Value.float(try numeric.toFloat(a) + try numeric.toFloat(b)));
            },
            .sub_float => {
                const b = self.pop();
                const a = self.pop();
                try self.push(Value.float(try numeric.toFloat(a) - try numeric.toFloat(b)));
            },
            .mul_float => {
                const b = self.pop();
                const a = self.pop();
                try self.push(Value.float(try numeric.toFloat(a) * try numeric.toFloat(b)));
            },
            .div_float => {
                const b = self.pop();
                const a = self.pop();
                try self.push(Value.float(try numeric.toFloat(a) / try numeric.toFloat(b)));
            },
            // ---- comparison ----
            .eq => {
                const b = self.pop();
                const a = self.pop();
                try self.push(Value.boolVal(try self.valuesEqual(a, b)));
            },
            .neq => {
                const b = self.pop();
                const a = self.pop();
                try self.push(Value.boolVal(!try self.valuesEqual(a, b)));
            },
            .lt => {
                const b = self.pop();
                const a = self.pop();
                try self.push(Value.boolVal(try self.compareValues(a, b) == .lt));
            },
            .lte => {
                const b = self.pop();
                const a = self.pop();
                const r = try self.compareValues(a, b);
                try self.push(Value.boolVal(r == .lt or r == .eq));
            },
            .gt => {
                const b = self.pop();
                const a = self.pop();
                try self.push(Value.boolVal(try self.compareValues(a, b) == .gt));
            },
            .gte => {
                const b = self.pop();
                const a = self.pop();
                const r = try self.compareValues(a, b);
                try self.push(Value.boolVal(r == .gt or r == .eq));
            },

            // ---- logical ----
            .not => {
                const a = self.pop();
                try self.push(Value.boolVal(!try self.expectBool(a)));
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
                const cond = self.stack.items[self.sp - 1];
                if (!try self.expectBool(cond)) {
                    frame.ip += @as(usize, offset);
                }
            },
            .fail_assertion => return error.AssertionFailed,
            // ---- data structures ----
            .build_attrs => {
                const count: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                try self.buildAttrs(count);
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
                try self.buildAttrsWithPositions(count, positions);
            },
            .build_list => {
                const count: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                try self.buildList(count);
            },
            .merge_attrs => {
                const right = self.pop();
                const left = self.pop();
                try self.push(try self.mergeAttrs(left, right));
            },
            .merge_attrs_strict => {
                const right = self.pop();
                const left = self.pop();
                try self.push(try self.mergeAttrsStrict(left, right));
            },
            .concat_lists => {
                const right = self.pop();
                const left = self.pop();
                try self.push(try self.concatLists(left, right));
            },
            .push_builtins => try self.push(self.builtins),
            .find_file => {
                const name_id: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                const host = self.import_host orelse return error.SearchPathUnavailable;
                try self.push(try host.find_file(host.context, self.intern.get(@intCast(name_id))));
            },
            .find_file_long => {
                const name_id: InternId = readU32(code, frame.ip);
                frame.ip += 4;
                const host = self.import_host orelse return error.SearchPathUnavailable;
                try self.push(try host.find_file(host.context, self.intern.get(name_id)));
            },
            // ---- closure ----
            .closure => {
                const ch_id: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                const upvalue_count = readU16(code, frame.ip);
                frame.ip += 2;
                try self.makeClosure(ch_id, upvalue_count);
            },
            .closure_long => {
                const ch_id: ChunkId = readU32(code, frame.ip);
                frame.ip += 4;
                const upvalue_count = readU16(code, frame.ip);
                frame.ip += 2;
                try self.makeClosure(ch_id, upvalue_count);
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
                try self.makeClosureFromCaptures(ch_id, descriptors, frame);
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
                try self.makeClosureFromCaptures(ch_id, descriptors, frame);
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
                try self.makeBytecodeThunkFromCaptures(ch_id, descriptors, frame);
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
                try self.makeBytecodeThunkFromCaptures(ch_id, descriptors, frame);
            },

            // ---- calls ----
            .call => {
                const arg = self.pop();
                const callee = self.pop();
                try self.doCall(callee, arg);
            },
            .tail_call => {
                const arg = self.pop();
                const callee = self.pop();
                try self.doTailCall(callee, arg);
            },
            // ---- thunks ----
            .make_cell => {
                const val = self.pop();
                try self.push(try self.makeCell(val));
            },

            // ---- attribute access ----
            .get_attr => {
                const name_id: u16 = readU16(code, frame.ip);
                frame.ip += 2;
                const attrs_val = self.pop();
                const result = try self.getAttrValue(attrs_val, @intCast(name_id));
                try self.push(result);
            },
            .get_attr_long => {
                const name_id: InternId = readU32(code, frame.ip);
                frame.ip += 4;
                const attrs_val = self.pop();
                const result = try self.getAttrValue(attrs_val, name_id);
                try self.push(result);
            },
            .get_attr_dynamic => {
                const name_val = try self.forceValue(self.pop());
                if (name_val.discriminant != .string) return error.TypeError;
                const attrs_val = self.pop();
                const result = try self.getAttrValue(attrs_val, name_val.asInternId());
                try self.push(result);
            },
            .get_attr_dynamic_or => {
                const default_val = self.pop();
                const name_val = try self.forceValue(self.pop());
                if (name_val.discriminant != .string) return error.TypeError;
                const attrs_val = self.pop();
                const attrs = try self.forceValue(attrs_val);
                if (attrs.discriminant != .attrs) return try self.forceValue(default_val);
                const result = self.heap.getAttrValue(attrs.asObjectId(), name_val.asInternId()) catch |err| switch (err) {
                    error.MissingAttribute => try self.forceValue(default_val),
                    else => return err,
                };
                try self.push(try self.forceValue(result));
            },
            .get_attr_path_dynamic_or => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 2;
                const default_val = self.pop();
                const name_val = self.pop();
                const attrs_val = self.pop();
                const result = try self.getAttrPathDynamicOrValue(attrs_val, name_val, default_val, code[names_start..frame.ip], false);
                try self.push(result);
            },
            .get_attr_path_dynamic_or_long => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 4;
                const default_val = self.pop();
                const name_val = self.pop();
                const attrs_val = self.pop();
                const result = try self.getAttrPathDynamicOrValue(attrs_val, name_val, default_val, code[names_start..frame.ip], true);
                try self.push(result);
            },
            .get_attr_path_or => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 2;
                const default_val = self.pop();
                const attrs_val = self.pop();
                const result = try self.getAttrPathOrValue(attrs_val, default_val, code[names_start..frame.ip], false);
                try self.push(result);
            },
            .get_attr_path_or_long => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 4;
                const default_val = self.pop();
                const attrs_val = self.pop();
                const result = try self.getAttrPathOrValue(attrs_val, default_val, code[names_start..frame.ip], true);
                try self.push(result);
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
                const default_val = self.pop();
                const dynamic_names = try self.allocator.alloc(Value, dynamic_count);
                defer self.allocator.free(dynamic_names);
                var dynamic_i: usize = dynamic_count;
                while (dynamic_i > 0) {
                    dynamic_i -= 1;
                    dynamic_names[dynamic_i] = self.pop();
                }
                const attrs_val = self.pop();
                const result = try self.getAttrPathMixedOrValue(attrs_val, dynamic_names, default_val, code[segments_start..frame.ip], segment_count);
                try self.push(result);
            },
            .has_attr_path => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 2;
                const attrs_val = self.pop();
                try self.push(Value.boolVal(try self.hasAttrPath(attrs_val, code[names_start..frame.ip], false)));
            },
            .has_attr_path_long => {
                const segment_count = code[frame.ip];
                frame.ip += 1;
                const names_start = frame.ip;
                frame.ip += @as(usize, segment_count) * 4;
                const attrs_val = self.pop();
                try self.push(Value.boolVal(try self.hasAttrPath(attrs_val, code[names_start..frame.ip], true)));
            },
            .has_attr_dynamic => {
                const name_val = try self.forceValue(self.pop());
                if (name_val.discriminant != .string) return error.TypeError;
                const attrs_val = try self.forceValue(self.pop());
                if (attrs_val.discriminant != .attrs) {
                    try self.push(Value.boolVal(false));
                } else {
                    const present = if (self.heap.getAttrValue(attrs_val.asObjectId(), name_val.asInternId())) |_|
                        true
                    else |err| switch (err) {
                        error.MissingAttribute => false,
                        else => return err,
                    };
                    try self.push(Value.boolVal(present));
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
                    dynamic_names[dynamic_i] = self.pop();
                }
                const attrs_val = self.pop();
                try self.push(Value.boolVal(try self.hasAttrPathMixed(attrs_val, dynamic_names, code[segments_start..frame.ip], segment_count)));
            },
            .validate_attrs => {
                const allow_extra = code[frame.ip] != 0;
                frame.ip += 1;
                const expected_count = readU16(code, frame.ip);
                frame.ip += 2;
                const names_start = frame.ip;
                frame.ip += @as(usize, expected_count) * 2;
                const attrs_val = self.pop();
                try self.validateAttrs(attrs_val, allow_extra, code[names_start..frame.ip], false);
            },
            .validate_attrs_long => {
                const allow_extra = code[frame.ip] != 0;
                frame.ip += 1;
                const expected_count = readU16(code, frame.ip);
                frame.ip += 2;
                const names_start = frame.ip;
                frame.ip += @as(usize, expected_count) * 4;
                const attrs_val = self.pop();
                try self.validateAttrs(attrs_val, allow_extra, code[names_start..frame.ip], true);
            },
            .lookup_with => {
                const name_id: InternId = @intCast(readU16(code, frame.ip));
                frame.ip += 2;
                const scope_count = code[frame.ip];
                frame.ip += 1;
                try self.lookupWith(name_id, scope_count);
            },
            .lookup_with_long => {
                const name_id: InternId = readU32(code, frame.ip);
                frame.ip += 4;
                const scope_count = code[frame.ip];
                frame.ip += 1;
                try self.lookupWith(name_id, scope_count);
            },
            // ---- termination ----
            .ret => {
                const result = self.pop();
                const finished_frame = self.popFrame();
                if (self.frames.items.len == stop_depth) {
                    self.sp = finished_frame.frame_base;
                    return result;
                }
                self.sp = finished_frame.frame_base;
                try self.push(result);
            },
            .halt => {
                // Stop execution.
                if (self.sp > 0) return self.pop();
                return Value.null_val;
            },
        }
    }

    return if (self.sp > 0) self.pop() else Value.null_val;
}

// ---- helpers ----

pub fn expectBool(self: *VM, val: Value) !bool {
    const forced = try self.forceValue(val);
    return switch (forced.discriminant) {
        .bool_false => false,
        .bool_true => true,
        else => error.TypeError,
    };
}
