//! Compiler: AST → Bytecode
//!
//! Walks the AST tree and emits bytecode into a ChunkBuilder.
//! The compiler is stack-based: expressions push their result,
//! statements push/discard as needed.

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeTag = ast.NodeTag;
const BinaryOp = ast.BinaryOp;
const OpCode = @import("opcode.zig").OpCode;
const chunk = @import("chunk.zig");
const ChunkBuilder = chunk.ChunkBuilder;
const types = @import("types.zig");

const InternId = types.InternId;

/// A local variable tracked during compilation.
const Local = struct {
    name: []const u8,
    name_id: InternId,
    depth: u8,
    /// Index from frame base on the stack.
    slot: u16,
};

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    builder: *ChunkBuilder,
    source: []const u8,
    intern: *@import("intern.zig").InternTable,
    locals: std.ArrayListUnmanaged(Local),
    scope_depth: u8,
    slot_count: u16,

    pub fn init(
        allocator: std.mem.Allocator,
        builder: *ChunkBuilder,
        source: []const u8,
        intern: *@import("intern.zig").InternTable,
    ) Compiler {
        return .{
            .allocator = allocator,
            .builder = builder,
            .source = source,
            .intern = intern,
            .locals = .empty,
            .scope_depth = 0,
            .slot_count = 0,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.locals.deinit(self.allocator);
    }

    pub fn compile(self: *Compiler, node: *const Node) !void {
        try self.compileNode(node);
    }

    fn compileNode(self: *Compiler, node: *const Node) anyerror!void {
        switch (node.tag) {
            .integer => try self.compileInt(node),
            .float_val => try self.compileFloat(node),
            .string => try self.compileString(node),
            .path => try self.compilePath(node),
            .identifier => try self.compileIdent(node),
            .bool_true => try self.emitOp(.push_true),
            .bool_false => try self.emitOp(.push_false),
            .null => try self.emitOp(.push_null),
            .binary_op => try self.compileBinary(node),
            .unary_op => try self.compileUnary(node),
            .apply => try self.compileApply(node),
            .let_in => try self.compileLetIn(node),
            .if_else => try self.compileIfElse(node),
            .attr_set => try self.compileAttrSet(node),
            .attr_path => try self.compileAttrPath(node),
            .list => try self.compileList(node),
            .parens => try self.compileNode(node.data.parens),
            else => return error.UnsupportedNode,
        }
    }

    fn emitOp(self: *Compiler, op: OpCode) !void {
        try self.builder.writeOp(self.allocator, op);
    }

    fn emitOpU16(self: *Compiler, op: OpCode, val: u16) !void {
        try self.emitOp(op);
        try self.builder.writeU16(self.allocator, val);
    }

    fn emitOpByte(self: *Compiler, op: OpCode, val: u8) !void {
        try self.emitOp(op);
        try self.builder.writeByte(self.allocator, val);
    }

    // ---- atom compilers ----

    fn compileInt(self: *Compiler, node: *const Node) !void {
        const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
        const val = std.fmt.parseInt(i64, span, 10) catch 0;
        const v = @import("value.zig").Value.int(val);
        try self.builder.emitConstant(self.allocator, v);
    }

    fn compileFloat(self: *Compiler, node: *const Node) !void {
        const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
        const val = std.fmt.parseFloat(f64, span) catch 0.0;
        const v = @import("value.zig").Value.float(val);
        try self.builder.emitConstant(self.allocator, v);
    }

    fn compileString(self: *Compiler, node: *const Node) !void {
        const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
        // Strip quotes "..." → ...
        var content = span;
        if (content.len >= 2 and content[0] == '"' and content[content.len - 1] == '"') {
            content = content[1 .. content.len - 1];
        }
        const id = try self.intern.intern(content);
        const v = @import("value.zig").Value.string(id);
        try self.builder.emitConstant(self.allocator, v);
    }

    fn compilePath(self: *Compiler, node: *const Node) !void {
        const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
        const id = try self.intern.intern(span);
        const v = @import("value.zig").Value.path(id);
        try self.builder.emitConstant(self.allocator, v);
    }

    fn compileIdent(self: *Compiler, node: *const Node) !void {
        const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
        if (self.resolveLocal(span)) |slot| {
            try self.emitOpByte(.get_local, @intCast(slot));
        } else {
            return error.UndefinedVariable;
        }
    }

    // ---- compound compilers ----

    fn compileBinary(self: *Compiler, node: *const Node) !void {
        const bin = node.data.binary;
        switch (bin.op) {
            .and_ => return self.compileAnd(bin.left, bin.right),
            .or_ => return self.compileOr(bin.left, bin.right),
            else => {},
        }

        try self.compileNode(bin.left);
        try self.compileNode(bin.right);

        switch (bin.op) {
            .add => try self.emitOp(.add_int),
            .sub => try self.emitOp(.sub_int),
            .mul => try self.emitOp(.mul_int),
            .div => try self.emitOp(.div_int),
            .eq => try self.emitOp(.eq),
            .neq => try self.emitOp(.neq),
            .lt => try self.emitOp(.lt),
            .lte => try self.emitOp(.lte),
            .gt => try self.emitOp(.gt),
            .gte => try self.emitOp(.gte),
            .and_, .or_ => unreachable,
            .update => return error.UnsupportedBinaryOp,
            .impl => return error.UnsupportedBinaryOp,
            .concat => return error.UnsupportedBinaryOp,
        }
    }

    fn compileAnd(self: *Compiler, left: *const Node, right: *const Node) !void {
        try self.compileNode(left);

        const end_jump = self.builder.code.items.len;
        try self.emitOpU16(.jump_if_false, 0);
        try self.emitOp(.pop);

        try self.compileNode(right);
        self.patchJump(end_jump, self.builder.code.items.len);
    }

    fn compileOr(self: *Compiler, left: *const Node, right: *const Node) !void {
        try self.compileNode(left);

        const false_jump = self.builder.code.items.len;
        try self.emitOpU16(.jump_if_false, 0);

        const end_jump = self.builder.code.items.len;
        try self.emitOpU16(.jump, 0);

        self.patchJump(false_jump, self.builder.code.items.len);
        try self.emitOp(.pop);

        try self.compileNode(right);
        self.patchJump(end_jump, self.builder.code.items.len);
    }

    fn compileUnary(self: *Compiler, node: *const Node) !void {
        const un = node.data.unary;
        try self.compileNode(un.expr);
        switch (un.op) {
            .negate => try self.emitOp(.negate_int),
            .not => try self.emitOp(.not),
        }
    }

    fn compileApply(self: *Compiler, node: *const Node) !void {
        const ap = node.data.apply;
        try self.compileNode(ap.func);
        try self.compileNode(ap.arg);
        try self.emitOp(.call);
    }

    fn compileLetIn(self: *Compiler, node: *const Node) !void {
        const let_in = node.data.let_in;
        self.beginScope();

        for (let_in.bindings) |binding| {
            const name = self.source[binding.name_offset .. binding.name_offset + binding.name_len];
            const name_id = try self.intern.intern(name);
            try self.compileNode(binding.expr);
            const slot = self.declareLocal(name, name_id);
            try self.emitOpByte(.set_local, @intCast(slot));
        }

        try self.compileNode(let_in.body);

        self.endScope();
    }

    fn compileIfElse(self: *Compiler, node: *const Node) !void {
        const ife = node.data.if_else;

        try self.compileNode(ife.cond);

        // Emit placeholder for jump_if_false
        const jump_pos = self.builder.code.items.len;
        try self.emitOpU16(.jump_if_false, 0);
        try self.emitOp(.pop);

        try self.compileNode(ife.then_branch);
        const jump_over_pos = self.builder.code.items.len;
        try self.emitOpU16(.jump, 0);

        // Patch jump_if_false target
        self.patchJump(jump_pos, self.builder.code.items.len);

        try self.emitOp(.pop);
        try self.compileNode(ife.else_branch);

        // Patch jump (skip else)
        self.patchJump(jump_over_pos, self.builder.code.items.len);
    }

    fn compileAttrSet(self: *Compiler, node: *const Node) !void {
        const aset = node.data.attr_set;
        const count = aset.entries.len;

        for (aset.entries) |entry| {
            // Push name as interned string value.
            const name_span = self.source[entry.name_offset .. entry.name_offset + entry.name_len];
            const name_id = try self.intern.intern(name_span);
            const name_val = @import("value.zig").Value.string(name_id);
            try self.builder.emitConstant(self.allocator, name_val);

            // Compile value.
            try self.compileNode(entry.expr);
        }

        try self.emitOpU16(.build_attrs, @intCast(count));
    }

    fn compileAttrPath(self: *Compiler, node: *const Node) !void {
        const apath = node.data.attr_path;
        try self.compileNode(apath.root);

        for (apath.segments) |seg| {
            const name_span = self.attrSegmentSpan(seg);
            const name_id = try self.intern.intern(name_span);
            try self.emitOpU16(.get_attr, @intCast(name_id));
        }
    }

    fn compileList(self: *Compiler, node: *const Node) !void {
        const list = node.data.list;
        for (list.items) |item| {
            try self.compileNode(item);
        }
        try self.emitOpU16(.build_list, @intCast(list.items.len));
    }

    // ---- patch helpers ----

    fn patchJump(self: *Compiler, instruction_offset: usize, target_offset: usize) void {
        const operand_offset = instruction_offset + 1;
        const next_instruction = instruction_offset + 3;
        const relative: u16 = @intCast(target_offset - next_instruction);
        self.builder.code.items[operand_offset] = @truncate(relative);
        self.builder.code.items[operand_offset + 1] = @truncate(relative >> 8);
    }

    fn attrSegmentSpan(self: *const Compiler, atom: Node.Atom) []const u8 {
        const span = self.source[atom.offset .. atom.offset + atom.len];
        if (span.len >= 2 and span[0] == '"' and span[span.len - 1] == '"') {
            return span[1 .. span.len - 1];
        }
        return span;
    }

    // ---- scope management ----

    fn beginScope(self: *Compiler) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *Compiler) void {
        self.scope_depth -= 1;
        // Pop locals defined in this scope.
        while (self.locals.items.len > 0) {
            const local = self.locals.items[self.locals.items.len - 1];
            if (local.depth <= self.scope_depth) break;
            _ = self.locals.pop();
        }
    }

    fn declareLocal(self: *Compiler, name: []const u8, name_id: InternId) u16 {
        const slot = self.slot_count;
        self.slot_count += 1;
        self.locals.append(self.allocator, .{
            .name = name,
            .name_id = name_id,
            .depth = self.scope_depth,
            .slot = slot,
        }) catch @panic("oom: locals");
        return slot;
    }

    fn resolveLocal(self: *const Compiler, name: []const u8) ?u16 {
        var i: usize = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (std.mem.eql(u8, local.name, name)) {
                return local.slot;
            }
        }
        return null;
    }
};
