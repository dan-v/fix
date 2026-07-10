//! Terminal input decoding: a pure byte-stream → key-event state machine.
//!
//! Handles CSI (`ESC [ … final`, including `1;5C`-style modifier params),
//! SS3 (`ESC O …`), Alt/Meta chords (`ESC x`), UTF-8 assembly, and bracketed
//! paste (`ESC [ 200~ … ESC [ 201~`). Inside a paste every decoded codepoint
//! carries `.pasted = true`, so the editor can insert literally without
//! triggering completion, history, or submission.
//!
//! The decoder is timing-free: a lone ESC cannot be distinguished from the
//! start of a chord without a clock, so the driver calls `idleFlush` when the
//! input has been quiet while `wantsMore()` is true.

const std = @import("std");

pub const Code = union(enum) {
    /// A printable codepoint (with `ctrl` set, the letter of a C0 control:
    /// ^A arrives as `.cp = 'a', .ctrl = true`).
    cp: u21,
    enter,
    tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    delete,
    insert,
    page_up,
    page_down,
    backtab,
    paste_begin,
    paste_end,
    /// An escape sequence we recognized as a sequence but not as a key
    /// (F-keys, exotic CSIs). Swallowed silently by the editor.
    unknown,
};

pub const Key = struct {
    code: Code,
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    /// Decoded inside a bracketed paste.
    pasted: bool = false,

    pub fn char(cp: u21) Key {
        return .{ .code = .{ .cp = cp } };
    }

    pub fn ctrlKey(letter: u8) Key {
        return .{ .code = .{ .cp = letter }, .ctrl = true };
    }

    /// True if this is exactly Ctrl+`letter` (no Alt).
    pub fn isCtrl(self: Key, letter: u8) bool {
        return self.ctrl and !self.alt and self.code == .cp and self.code.cp == letter;
    }
};

const State = union(enum) {
    ground,
    /// Saw ESC; the next byte decides chord vs CSI/SS3 vs lone ESC.
    esc,
    /// Inside `ESC [ …`, collecting parameter/intermediate bytes.
    csi,
    /// Saw `ESC O`; one final byte follows.
    ss3,
    /// Assembling a UTF-8 sequence: bytes still needed + accumulator.
    utf8: struct { need: u3, cp: u21, alt: bool },
};

pub const Decoder = struct {
    state: State = .ground,
    /// Inside a bracketed paste (between 200~ and 201~).
    in_paste: bool = false,
    /// How many bytes of the paste terminator `ESC [ 2 0 1 ~` have matched.
    paste_match: u3 = 0,
    /// CSI parameter/intermediate byte buffer. Oversized sequences are
    /// swallowed and reported as `.unknown`.
    csi_buf: [16]u8 = undefined,
    csi_len: u5 = 0,
    csi_overflow: bool = false,

    const paste_end_seq = "\x1b[201~";

    pub const List = std.ArrayListUnmanaged(Key);

    /// Feed one input byte; decoded keys append to `out`.
    pub fn feed(self: *Decoder, allocator: std.mem.Allocator, byte: u8, out: *List) !void {
        if (self.in_paste) return self.feedPaste(allocator, byte, out);
        return self.feedGround(allocator, byte, out, false);
    }

    /// True when the decoder sits mid-sequence and the driver should wait
    /// (briefly) for more bytes before declaring a lone ESC.
    pub fn wantsMore(self: *const Decoder) bool {
        return self.state != .ground;
    }

    /// The input went quiet mid-sequence: resolve what we have. A pending
    /// ESC becomes an escape key; a half CSI/UTF-8 sequence is dropped.
    pub fn idleFlush(self: *Decoder, allocator: std.mem.Allocator, out: *List) !void {
        switch (self.state) {
            .ground => {},
            .esc => try out.append(allocator, .{ .code = .escape, .pasted = self.in_paste }),
            .csi, .ss3 => try out.append(allocator, .{ .code = .unknown }),
            .utf8 => try out.append(allocator, .{ .code = .{ .cp = 0xFFFD }, .pasted = self.in_paste }),
        }
        self.state = .ground;
    }

    fn feedGround(self: *Decoder, allocator: std.mem.Allocator, byte: u8, out: *List, pasted: bool) !void {
        switch (self.state) {
            .ground => switch (byte) {
                0x1B => self.state = .esc,
                '\r', '\n' => try out.append(allocator, .{ .code = .enter, .pasted = pasted }),
                '\t' => try out.append(allocator, .{ .code = .tab, .pasted = pasted }),
                0x08, 0x7F => try out.append(allocator, .{ .code = .backspace, .pasted = pasted }),
                0x01...0x07, 0x0B, 0x0C, 0x0E...0x1A => try out.append(allocator, .{
                    .code = .{ .cp = 'a' + @as(u21, byte) - 1 },
                    .ctrl = true,
                    .pasted = pasted,
                }),
                0x00, 0x1C...0x1F => try out.append(allocator, .{ .code = .unknown, .pasted = pasted }),
                else => try self.feedUtf8Start(allocator, byte, false, out, pasted),
            },
            .esc => switch (byte) {
                '[' => {
                    self.state = .csi;
                    self.csi_len = 0;
                    self.csi_overflow = false;
                },
                'O' => self.state = .ss3,
                0x1B => {
                    // ESC ESC: report the first, keep waiting on the second.
                    try out.append(allocator, .{ .code = .escape });
                },
                '\r', '\n' => {
                    try out.append(allocator, .{ .code = .enter, .alt = true, .pasted = pasted });
                    self.state = .ground;
                },
                '\t' => {
                    try out.append(allocator, .{ .code = .tab, .alt = true });
                    self.state = .ground;
                },
                0x08, 0x7F => {
                    try out.append(allocator, .{ .code = .backspace, .alt = true });
                    self.state = .ground;
                },
                0x01...0x07, 0x0B, 0x0C, 0x0E...0x1A => {
                    try out.append(allocator, .{
                        .code = .{ .cp = 'a' + @as(u21, byte) - 1 },
                        .ctrl = true,
                        .alt = true,
                    });
                    self.state = .ground;
                },
                0x00, 0x1C...0x1F => {
                    try out.append(allocator, .{ .code = .unknown });
                    self.state = .ground;
                },
                else => {
                    self.state = .ground;
                    try self.feedUtf8Start(allocator, byte, true, out, pasted);
                },
            },
            .csi => {
                // Parameter bytes 0x30–0x3F, intermediates 0x20–0x2F, final 0x40–0x7E.
                if (byte >= 0x40 and byte <= 0x7E) {
                    const seq = self.csi_buf[0..self.csi_len];
                    const overflowed = self.csi_overflow;
                    self.state = .ground;
                    if (overflowed) {
                        try out.append(allocator, .{ .code = .unknown });
                    } else {
                        try self.dispatchCsi(allocator, seq, byte, out);
                    }
                } else if (byte >= 0x20 and byte <= 0x3F) {
                    if (self.csi_len < self.csi_buf.len) {
                        self.csi_buf[self.csi_len] = byte;
                        self.csi_len += 1;
                    } else {
                        self.csi_overflow = true;
                    }
                } else {
                    // Junk inside a CSI (a control byte): abort the sequence.
                    self.state = .ground;
                    try out.append(allocator, .{ .code = .unknown });
                }
            },
            .ss3 => {
                self.state = .ground;
                const code: Code = switch (byte) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    else => .unknown,
                };
                try out.append(allocator, .{ .code = code });
            },
            .utf8 => |*u| {
                if ((byte & 0b1100_0000) != 0b1000_0000) {
                    // Broken sequence: emit replacement, reprocess this byte.
                    self.state = .ground;
                    try out.append(allocator, .{ .code = .{ .cp = 0xFFFD }, .pasted = pasted });
                    return self.feedGround(allocator, byte, out, pasted);
                }
                u.cp = (u.cp << 6) | (byte & 0b0011_1111);
                u.need -= 1;
                if (u.need == 0) {
                    const key: Key = .{ .code = .{ .cp = u.cp }, .alt = u.alt, .pasted = pasted };
                    self.state = .ground;
                    try out.append(allocator, key);
                }
            },
        }
    }

    fn feedUtf8Start(self: *Decoder, allocator: std.mem.Allocator, byte: u8, alt: bool, out: *List, pasted: bool) !void {
        if (byte < 0x80) {
            try out.append(allocator, .{ .code = .{ .cp = byte }, .alt = alt, .pasted = pasted });
            return;
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try out.append(allocator, .{ .code = .{ .cp = 0xFFFD }, .alt = alt, .pasted = pasted });
            return;
        };
        self.state = .{ .utf8 = .{
            .need = @intCast(len - 1),
            .cp = @as(u21, byte) & (@as(u21, 0x7F) >> @intCast(len)),
            .alt = alt,
        } };
    }

    fn dispatchCsi(self: *Decoder, allocator: std.mem.Allocator, params: []const u8, final: u8, out: *List) !void {
        // Parse `p1 ; p2 ; …` decimal parameters.
        var nums: [4]u16 = .{ 0, 0, 0, 0 };
        var nums_len: usize = 0;
        {
            var cur: u16 = 0;
            var any = false;
            for (params) |b| switch (b) {
                '0'...'9' => {
                    cur = cur *| 10 +| (b - '0');
                    any = true;
                },
                ';' => {
                    if (nums_len < nums.len) nums[nums_len] = cur;
                    nums_len += 1;
                    cur = 0;
                    any = false;
                },
                else => {}, // '<', '?', intermediates: not keys we care about
            };
            if (any or nums_len > 0) {
                if (nums_len < nums.len) nums[nums_len] = cur;
                nums_len += 1;
            }
        }

        // xterm modifier encoding: value-1 is a bitmask (1=shift 2=alt 4=ctrl).
        var key: Key = .{ .code = .unknown };
        const mods: u16 = if (nums_len >= 2 and nums[1] > 0) nums[1] - 1 else 0;
        key.shift = mods & 1 != 0;
        key.alt = mods & 2 != 0;
        key.ctrl = mods & 4 != 0;

        key.code = switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'Z' => .backtab,
            '~' => switch (if (nums_len >= 1) nums[0] else 0) {
                1, 7 => .home,
                2 => .insert,
                3 => .delete,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                200 => blk: {
                    self.in_paste = true;
                    self.paste_match = 0;
                    break :blk .paste_begin;
                },
                201 => .paste_end, // stray terminator; harmless
                else => .unknown,
            },
            else => .unknown,
        };
        try out.append(allocator, key);
    }

    /// Paste mode: every byte is literal content, except the exact terminator
    /// `ESC [ 2 0 1 ~`. Bytes that match a terminator prefix are withheld; on
    /// a mismatch the withheld prefix is flushed as literal content and the
    /// current byte is reconsidered (it may itself start the terminator).
    fn feedPaste(self: *Decoder, allocator: std.mem.Allocator, byte: u8, out: *List) !void {
        while (true) {
            if (byte == paste_end_seq[self.paste_match]) {
                self.paste_match += 1;
                if (self.paste_match == paste_end_seq.len) {
                    self.in_paste = false;
                    self.paste_match = 0;
                    // Abandon any half-assembled UTF-8 from the paste body.
                    self.state = .ground;
                    try out.append(allocator, .{ .code = .paste_end });
                }
                return;
            }
            if (self.paste_match == 0) break;
            // Flush the matched prefix as literal bytes, then retry `byte`
            // from a clean match state.
            const matched = paste_end_seq[0..self.paste_match];
            self.paste_match = 0;
            for (matched) |b| try self.feedPasteLiteral(allocator, b, out);
        }
        try self.feedPasteLiteral(allocator, byte, out);
    }

    fn feedPasteLiteral(self: *Decoder, allocator: std.mem.Allocator, byte: u8, out: *List) !void {
        // Reuse the UTF-8 assembly path; C0 bytes map to pasted keys the
        // editor either inserts (enter → '\n', tab → '\t') or drops.
        switch (self.state) {
            .utf8 => try self.feedGround(allocator, byte, out, true),
            else => switch (byte) {
                0x1B => try out.append(allocator, .{ .code = .unknown, .pasted = true }),
                '\r', '\n' => try out.append(allocator, .{ .code = .enter, .pasted = true }),
                '\t' => try out.append(allocator, .{ .code = .tab, .pasted = true }),
                0x00...0x08, 0x0B, 0x0C, 0x0E...0x1A, 0x1C...0x1F, 0x7F => try out.append(allocator, .{ .code = .unknown, .pasted = true }),
                else => try self.feedUtf8Start(allocator, byte, false, out, true),
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn decodeAll(bytes: []const u8) !Decoder.List {
    var dec = Decoder{};
    var out: Decoder.List = .empty;
    errdefer out.deinit(testing.allocator);
    for (bytes) |b| try dec.feed(testing.allocator, b, &out);
    return out;
}

test "plain ascii and control letters" {
    var out = try decodeAll("a\x01\x05\r");
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqual(@as(u21, 'a'), out.items[0].code.cp);
    try testing.expect(out.items[1].isCtrl('a'));
    try testing.expect(out.items[2].isCtrl('e'));
    try testing.expect(out.items[3].code == .enter);
}

test "csi arrows, home/end, delete, modifiers" {
    var out = try decodeAll("\x1b[A\x1b[D\x1b[H\x1b[3~\x1b[1;5C\x1b[1;3D\x1b[Z");
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 7), out.items.len);
    try testing.expect(out.items[0].code == .up);
    try testing.expect(out.items[1].code == .left);
    try testing.expect(out.items[2].code == .home);
    try testing.expect(out.items[3].code == .delete);
    try testing.expect(out.items[4].code == .right and out.items[4].ctrl);
    try testing.expect(out.items[5].code == .left and out.items[5].alt);
    try testing.expect(out.items[6].code == .backtab);
}

test "ss3 arrows" {
    var out = try decodeAll("\x1bOA\x1bOF");
    defer out.deinit(testing.allocator);
    try testing.expect(out.items[0].code == .up);
    try testing.expect(out.items[1].code == .end);
}

test "alt chords" {
    var out = try decodeAll("\x1bb\x1bf\x1b\x7f\x1b\r");
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expect(out.items[0].alt and out.items[0].code.cp == 'b');
    try testing.expect(out.items[1].alt and out.items[1].code.cp == 'f');
    try testing.expect(out.items[2].alt and out.items[2].code == .backspace);
    try testing.expect(out.items[3].alt and out.items[3].code == .enter);
}

test "lone esc resolves via idleFlush" {
    var dec = Decoder{};
    var out: Decoder.List = .empty;
    defer out.deinit(testing.allocator);
    try dec.feed(testing.allocator, 0x1B, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try testing.expect(dec.wantsMore());
    try dec.idleFlush(testing.allocator, &out);
    try testing.expect(out.items[0].code == .escape);
    try testing.expect(!dec.wantsMore());
}

test "utf8 assembly, plain and alt" {
    var out = try decodeAll("\xc3\xa9\x1b\xc3\xa9"); // é, Alt-é
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u21, 0xE9), out.items[0].code.cp);
    try testing.expect(!out.items[0].alt);
    try testing.expectEqual(@as(u21, 0xE9), out.items[1].code.cp);
    try testing.expect(out.items[1].alt);
}

test "bracketed paste marks content and handles embedded newlines" {
    var out = try decodeAll("\x1b[200~a\nb\x1b[201~c");
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), out.items.len);
    try testing.expect(out.items[0].code == .paste_begin);
    try testing.expect(out.items[1].code.cp == 'a' and out.items[1].pasted);
    try testing.expect(out.items[2].code == .enter and out.items[2].pasted);
    try testing.expect(out.items[3].code.cp == 'b' and out.items[3].pasted);
    try testing.expect(out.items[4].code == .paste_end);
    try testing.expect(out.items[5].code.cp == 'c' and !out.items[5].pasted);
}

test "paste: partial terminator prefix flushes as literal content" {
    // "\x1b[20" inside the paste is NOT the terminator; it must surface
    // (as unknown/pasted chars), and the real terminator must still work.
    var out = try decodeAll("\x1b[200~x\x1b[20y\x1b[201~");
    defer out.deinit(testing.allocator);
    // paste_begin, 'x', unknown(ESC), '[', '2', '0', 'y', paste_end
    try testing.expect(out.items[0].code == .paste_begin);
    try testing.expect(out.items[1].code.cp == 'x');
    try testing.expect(out.items[2].code == .unknown and out.items[2].pasted);
    try testing.expect(out.items[3].code.cp == '[');
    try testing.expect(out.items[4].code.cp == '2');
    try testing.expect(out.items[5].code.cp == '0');
    try testing.expect(out.items[6].code.cp == 'y');
    try testing.expect(out.items[out.items.len - 1].code == .paste_end);
}

test "paste: utf8 content assembles with pasted flag" {
    var out = try decodeAll("\x1b[200~\xc3\xa9\x1b[201~");
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expect(out.items[1].code.cp == 0xE9 and out.items[1].pasted);
}

test "csi overflow swallows junk" {
    var dec = Decoder{};
    var out: Decoder.List = .empty;
    defer out.deinit(testing.allocator);
    try dec.feed(testing.allocator, 0x1B, &out);
    try dec.feed(testing.allocator, '[', &out);
    for (0..30) |_| try dec.feed(testing.allocator, '1', &out);
    try dec.feed(testing.allocator, 'm', &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].code == .unknown);
}
