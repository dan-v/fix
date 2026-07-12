// Stack-switching primitive for fibers (AArch64 / AAPCS64).
//
// Saves the current execution context (callee-saved registers + sp) to
// `from` and loads the target context from `to`. Returns control to
// whatever the target context's link register (x30) points at.
//
// On entry (AAPCS64):
//   x0 = from: *Context
//   x1 = to:   *Context
//
// AAPCS64 callee-saved set we must preserve across the swap:
//   x19-x28  general-purpose
//   x29      frame pointer (fp)
//   x30      link register (lr) — the "return address" a fresh fiber
//            is bootstrapped with; `ret` branches to it
//   sp       stack pointer
//   d8-d15   low 64 bits of the callee-saved SIMD/FP registers v8-v15
//
// Context layout (matches the Zig `Context` extern struct):
//     0: x19      8: x20     16: x21     24: x22
//    32: x23     40: x24     48: x25     56: x26
//    64: x27     72: x28     80: x29(fp) 88: x30(lr)
//    96: sp
//   104: d8     112: d9     120: d10    128: d11
//   136: d12    144: d13    152: d14    160: d15
//
// Why naked assembly: same reason as the x86_64 variant — the whole
// save/load/branch must be one atomic dance with no compiler-inserted
// prologue/epilogue leaving live registers stranded across the swap.
//
// This file is preprocessed (`.S`), so it targets both ELF (Linux) and
// Mach-O (Darwin). Mach-O prefixes C symbols with `_` and rejects the
// ELF-only `.type`/`.size`/`.note.GNU-stack` directives. AAPCS64 is
// identical on both, so one instruction stream serves all aarch64
// targets. (Apple targets plain arm64, not arm64e, so no pointer-auth
// `ret` variant is needed.)

#if defined(__APPLE__)
# define FIX_SYM(name) _##name
#else
# define FIX_SYM(name) name
#endif

    .text
    .globl FIX_SYM(fix_swap_context)
#if !defined(__APPLE__)
    .type FIX_SYM(fix_swap_context), @function
#endif
FIX_SYM(fix_swap_context):
    // Save callee-saved GPRs + fp/lr into `from` (x0).
    stp x19, x20, [x0, #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]
    // sp can't be stored directly; stage it through x2.
    mov x2, sp
    str x2, [x0, #96]
    // Save callee-saved SIMD/FP (low 64 bits of v8-v15).
    stp d8,  d9,  [x0, #104]
    stp d10, d11, [x0, #120]
    stp d12, d13, [x0, #136]
    stp d14, d15, [x0, #152]

    // Load callee-saved GPRs + fp/lr from `to` (x1).
    ldp x19, x20, [x1, #0]
    ldp x21, x22, [x1, #16]
    ldp x23, x24, [x1, #32]
    ldp x25, x26, [x1, #48]
    ldp x27, x28, [x1, #64]
    ldp x29, x30, [x1, #80]
    ldr x2, [x1, #96]
    mov sp, x2
    ldp d8,  d9,  [x1, #104]
    ldp d10, d11, [x1, #120]
    ldp d12, d13, [x1, #136]
    ldp d14, d15, [x1, #152]

    // Branch to the loaded lr. For a fresh fiber this is the trampoline
    // address `Fiber.init` seeded into the context; for a resumed fiber
    // it is the return address saved by its previous swap.
    ret
#if !defined(__APPLE__)
    .size FIX_SYM(fix_swap_context), .-FIX_SYM(fix_swap_context)
#endif

// Mark stack as non-executable (Linux/ELF convention).
#if defined(__linux__)
.section .note.GNU-stack,"",@progbits
#endif
