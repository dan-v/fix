// Stack-switching primitive for fibers (System V x86_64 ABI).
//
// Saves the current execution context (callee-saved registers + rsp)
// to `from` and loads the target context from `to`. Returns control to
// whatever the target context's return address points at.
//
// On entry (SysV):
//   %rdi = from: *Context
//   %rsi = to:   *Context
//
// Context layout (matches the Zig `Context` extern struct):
//    0(ctx): rbx
//    8(ctx): rbp
//   16(ctx): r12
//   24(ctx): r13
//   32(ctx): r14
//   40(ctx): r15
//   48(ctx): rsp
//
// Why naked assembly: we need full control over the stack at the swap
// point. Compiler prologue/epilogue would leave saved registers around
// the swap whose lifetime no longer matches the function's, corrupting
// state on resume. Doing the entire save/load/ret as one atomic dance
// is the only correct shape.
//
// This file is preprocessed (`.S`), so it targets both ELF (Linux) and
// Mach-O (Darwin). Mach-O prefixes C symbols with `_` and rejects the
// ELF-only `.type`/`.size`/`.note.GNU-stack` directives.

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
    // Save callee-saved registers + rsp into `from`.
    movq %rbx,  0(%rdi)
    movq %rbp,  8(%rdi)
    movq %r12, 16(%rdi)
    movq %r13, 24(%rdi)
    movq %r14, 32(%rdi)
    movq %r15, 40(%rdi)
    movq %rsp, 48(%rdi)

    // Load callee-saved registers + rsp from `to`.
    movq  0(%rsi), %rbx
    movq  8(%rsi), %rbp
    movq 16(%rsi), %r12
    movq 24(%rsi), %r13
    movq 32(%rsi), %r14
    movq 40(%rsi), %r15
    movq 48(%rsi), %rsp

    // `ret` pops the next instruction pointer from the (newly loaded)
    // rsp. For a fresh fiber, this is the trampoline address that
    // `Fiber.init` wrote at the top of the new stack. For a resumed
    // fiber, this is the saved return address from its previous
    // `fix_swap_context` call.
    retq
#if !defined(__APPLE__)
    .size FIX_SYM(fix_swap_context), .-FIX_SYM(fix_swap_context)
#endif

// Mark stack as non-executable (Linux/ELF convention; Mach-O has no
// equivalent directive and doesn't need one).
#if defined(__linux__)
.section .note.GNU-stack,"",@progbits
#endif
