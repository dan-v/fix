//! Minimal append-only x86-64 machine-code emitter shared by the JIT backends.
//!
//! Both the linear whole-body compiler (`linear.zig`) and the tracing-trace
//! code generator (`codegen.zig`) build native code through this same emitter,
//! so it lives on its own rather than inside either backend. Only the
//! instruction forms those backends need; memory operands always use disp32 to
//! keep the encoder branch-free.

const std = @import("std");

const MAX_CODE = 8192; // max emitted bytes per chunk body
const MAX_PATCHES = 128; // max epilogue jump sites

/// Minimal append-only x86-64 emitter. Only the instruction forms the
/// backends need; memory operands always use disp32 to keep the encoder
/// branch-free.
pub const Emitter = struct {
    buf: [MAX_CODE]u8 = undefined,
    len: usize = 0,
    epi_patches: [MAX_PATCHES]usize = undefined,
    n_patches: usize = 0,
    overflow: bool = false,

    pub fn byte(self: *Emitter, v: u8) void {
        if (self.len >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.len] = v;
        self.len += 1;
    }

    pub fn bytes(self: *Emitter, vs: []const u8) void {
        for (vs) |v| self.byte(v);
    }

    pub fn u32le(self: *Emitter, v: u32) void {
        self.byte(@truncate(v));
        self.byte(@truncate(v >> 8));
        self.byte(@truncate(v >> 16));
        self.byte(@truncate(v >> 24));
    }

    pub fn u64le(self: *Emitter, v: u64) void {
        self.u32le(@truncate(v));
        self.u32le(@truncate(v >> 32));
    }

    // ---- memory operands (disp32) ----

    /// mov [rsp + disp], <reg encoded in `modrm_reg`>  (REX provided).
    pub fn movStoreRsp(self: *Emitter, rex: u8, modrm_reg: u8, disp: u32) void {
        self.byte(rex);
        self.byte(0x89);
        self.byte(0x84 | (modrm_reg << 3)); // mod=10, rm=100(SIB)
        self.byte(0x24); // SIB: base=rsp
        self.u32le(disp);
    }
    /// mov <reg>, [rsp + disp]
    pub fn movLoadRsp(self: *Emitter, rex: u8, modrm_reg: u8, disp: u32) void {
        self.byte(rex);
        self.byte(0x8b);
        self.byte(0x84 | (modrm_reg << 3));
        self.byte(0x24);
        self.u32le(disp);
    }
    /// mov <reg>, [r14 + disp]  (REX.W+B = 0x49 baked into callers)
    pub fn movLoadR14(self: *Emitter, rex: u8, modrm_reg: u8, disp: u32) void {
        self.byte(rex);
        self.byte(0x8b);
        self.byte(0x86 | (modrm_reg << 3)); // mod=10, rm=110 (r14, no SIB)
        self.u32le(disp);
    }

    // Common register-encoded variants (modrm_reg in bits 5:3).
    pub fn storeRaxToStack(self: *Emitter, slot: u32) void {
        self.movStoreRsp(0x48, 0, slot * 8); // rax
    }
    pub fn storeR15ToStack(self: *Emitter, slot: u32) void {
        self.movStoreRsp(0x4c, 7, slot * 8); // r15 (REX.R)
    }
    pub fn loadStackToRax(self: *Emitter, slot: u32) void {
        self.movLoadRsp(0x48, 0, slot * 8);
    }
    pub fn loadStackToRsi(self: *Emitter, slot: u32) void {
        self.movLoadRsp(0x48, 6, slot * 8);
    }
    pub fn loadStackToRdx(self: *Emitter, slot: u32) void {
        self.movLoadRsp(0x48, 2, slot * 8);
    }
    pub fn loadUpvalueToRax(self: *Emitter, slot: u32) void {
        self.movLoadR14(0x49, 0, slot * 8);
    }
    pub fn loadUpvalueToRsi(self: *Emitter, slot: u32) void {
        self.movLoadR14(0x49, 6, slot * 8);
    }

    // ---- immediates / reg moves ----
    pub fn movRaxImm64(self: *Emitter, v: u64) void {
        self.bytes(&.{ 0x48, 0xb8 });
        self.u64le(v);
    }
    pub fn movRdiRbx(self: *Emitter) void {
        self.bytes(&.{ 0x48, 0x89, 0xdf });
    }
    pub fn movRsiR15(self: *Emitter) void {
        self.bytes(&.{ 0x4c, 0x89, 0xfe });
    }
    /// mov rsi, imm64 (48 BE imm64) — e.g. a stable snapshot pointer.
    pub fn movRsiImm64(self: *Emitter, v: u64) void {
        self.bytes(&.{ 0x48, 0xbe });
        self.u64le(v);
    }
    /// mov rdx, rsp (48 89 E2) — the slot-array base for a side-exit helper.
    pub fn movRdxRsp(self: *Emitter) void {
        self.bytes(&.{ 0x48, 0x89, 0xe2 });
    }
    pub fn xorEdxEdx(self: *Emitter) void {
        self.bytes(&.{ 0x31, 0xd2 });
    }
    /// mov edx, imm32 (zero-extends to rdx). For passing an attr-name /
    /// chunk-id immediate as a helper's 3rd C-ABI arg.
    pub fn movEdxImm32(self: *Emitter, v: u32) void {
        self.byte(0xba);
        self.u32le(v);
    }

    // ---- calls / control ----
    /// movabs r11, target ; call r11
    pub fn callHelper(self: *Emitter, target: u64) void {
        self.bytes(&.{ 0x49, 0xbb });
        self.u64le(target);
        self.bytes(&.{ 0x41, 0xff, 0xd3 });
    }
    /// test rdx,rdx ; jnz epilogue  (records a patch site)
    pub fn errCheckToEpilogue(self: *Emitter) void {
        self.bytes(&.{ 0x48, 0x85, 0xd2 }); // test rdx,rdx
        self.bytes(&.{ 0x0f, 0x85 }); // jnz rel32
        self.recordEpiPatch();
        self.u32le(0); // placeholder
    }
    /// jmp epilogue (records a patch site)
    pub fn jmpEpilogue(self: *Emitter) void {
        self.byte(0xe9); // jmp rel32
        self.recordEpiPatch();
        self.u32le(0);
    }
    pub fn recordEpiPatch(self: *Emitter) void {
        if (self.n_patches >= self.epi_patches.len) {
            self.overflow = true;
            return;
        }
        self.epi_patches[self.n_patches] = self.len; // offset of rel32 field
        self.n_patches += 1;
    }

    pub fn prologue(self: *Emitter, reserve: u32) void {
        // push rbx ; push r14 ; push r15
        self.bytes(&.{ 0x53, 0x41, 0x56, 0x41, 0x57 });
        // mov rbx,rdi ; mov r14,rsi ; mov r15,rdx
        self.bytes(&.{ 0x48, 0x89, 0xfb, 0x49, 0x89, 0xf6, 0x49, 0x89, 0xd7 });
        // sub rsp, reserve   (48 81 EC imm32)
        self.bytes(&.{ 0x48, 0x81, 0xec });
        self.u32le(reserve);
    }

    pub fn bindEpilogue(self: *Emitter, reserve: u32) void {
        const epi: usize = self.len;
        // add rsp, reserve ; pop r15 ; pop r14 ; pop rbx ; ret
        self.bytes(&.{ 0x48, 0x81, 0xc4 });
        self.u32le(reserve);
        self.bytes(&.{ 0x41, 0x5f, 0x41, 0x5e, 0x5b, 0xc3 });
        // Patch all jumps to point at `epi`.
        for (self.epi_patches[0..self.n_patches]) |off| {
            const rel: i32 = @intCast(@as(i64, @intCast(epi)) - @as(i64, @intCast(off + 4)));
            std.mem.writeInt(i32, self.buf[off..][0..4], rel, .little);
        }
    }
};
