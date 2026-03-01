// trampoline.S — generic timing trampolines for hung_bench
// Provides 16 trampoline stubs that preserve all argument/return registers
// and bracket the original function call with timing hooks.
//
// Each stub sets a slot ID and jumps to a common handler.
// The common handler:
//   1. Saves all argument registers
//   2. Calls generic_hook_enter(slot) → returns start_time
//   3. Restores all argument registers
//   4. Calls original function via generic_hook_originals[slot]
//   5. Saves return value registers
//   6. Calls generic_hook_exit(slot, start_time)
//   7. Restores return value registers and returns

#if defined(__arm64__) || defined(__aarch64__)

// ---- arm64 ----

.macro TRAMPOLINE_STUB n
    .globl _generic_trampoline_\n
    .p2align 2
_generic_trampoline_\n:
    mov     x9, #\n
    b       _generic_trampoline_common
.endmacro

TRAMPOLINE_STUB 0
TRAMPOLINE_STUB 1
TRAMPOLINE_STUB 2
TRAMPOLINE_STUB 3
TRAMPOLINE_STUB 4
TRAMPOLINE_STUB 5
TRAMPOLINE_STUB 6
TRAMPOLINE_STUB 7
TRAMPOLINE_STUB 8
TRAMPOLINE_STUB 9
TRAMPOLINE_STUB 10
TRAMPOLINE_STUB 11
TRAMPOLINE_STUB 12
TRAMPOLINE_STUB 13
TRAMPOLINE_STUB 14
TRAMPOLINE_STUB 15

    .globl _generic_trampoline_common
    .p2align 2
_generic_trampoline_common:
    // x9 = slot ID

    // Set up frame, save callee-saved registers for slot ID and start time
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x19, x20, [sp, #-16]!

    mov     x19, x9             // x19 = slot ID (callee-saved)

    // Save all argument-passing registers (208 bytes)
    //   x0-x7: 64 bytes, x8: 8+pad, q0-q7: 128 bytes
    sub     sp, sp, #208
    stp     x0,  x1,  [sp, #0]
    stp     x2,  x3,  [sp, #16]
    stp     x4,  x5,  [sp, #32]
    stp     x6,  x7,  [sp, #48]
    stp     x8,  xzr, [sp, #64]    // x8 = indirect result reg, pad with zero
    stp     q0,  q1,  [sp, #80]
    stp     q2,  q3,  [sp, #112]
    stp     q4,  q5,  [sp, #144]
    stp     q6,  q7,  [sp, #176]

    // Call generic_hook_enter(slot_id) → returns uint64_t start_time in x0
    mov     x0, x19
    bl      _generic_hook_enter
    mov     x20, x0             // x20 = start_time (callee-saved)

    // Restore all argument-passing registers
    ldp     x0,  x1,  [sp, #0]
    ldp     x2,  x3,  [sp, #16]
    ldp     x4,  x5,  [sp, #32]
    ldp     x6,  x7,  [sp, #48]
    ldr     x8,        [sp, #64]
    ldp     q0,  q1,  [sp, #80]
    ldp     q2,  q3,  [sp, #112]
    ldp     q4,  q5,  [sp, #144]
    ldp     q6,  q7,  [sp, #176]
    add     sp, sp, #208

    // Load original function pointer: generic_hook_originals[slot]
    adrp    x16, _generic_hook_originals@PAGE
    add     x16, x16, _generic_hook_originals@PAGEOFF
    ldr     x16, [x16, x19, lsl #3]

    // Call original function
    blr     x16

    // Save return value registers (48 bytes: x0, x1 + q0, q1)
    sub     sp, sp, #48
    stp     x0,  x1,  [sp, #0]
    stp     q0,  q1,  [sp, #16]

    // Call generic_hook_exit(slot_id, start_time)
    mov     x0, x19
    mov     x1, x20
    bl      _generic_hook_exit

    // Restore return value registers
    ldp     x0,  x1,  [sp, #0]
    ldp     q0,  q1,  [sp, #16]
    add     sp, sp, #48

    // Restore callee-saved and frame
    ldp     x19, x20, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

#elif defined(__x86_64__)

// ---- x86_64 ----

.macro TRAMPOLINE_STUB n
    .globl _generic_trampoline_\n
    .p2align 4
_generic_trampoline_\n:
    movq    $\n, %r11
    jmp     _generic_trampoline_common
.endmacro

TRAMPOLINE_STUB 0
TRAMPOLINE_STUB 1
TRAMPOLINE_STUB 2
TRAMPOLINE_STUB 3
TRAMPOLINE_STUB 4
TRAMPOLINE_STUB 5
TRAMPOLINE_STUB 6
TRAMPOLINE_STUB 7
TRAMPOLINE_STUB 8
TRAMPOLINE_STUB 9
TRAMPOLINE_STUB 10
TRAMPOLINE_STUB 11
TRAMPOLINE_STUB 12
TRAMPOLINE_STUB 13
TRAMPOLINE_STUB 14
TRAMPOLINE_STUB 15

    .globl _generic_trampoline_common
    .p2align 4
_generic_trampoline_common:
    // r11 = slot ID

    pushq   %rbp
    movq    %rsp, %rbp
    pushq   %rbx                // callee-saved: slot ID
    pushq   %r12                // callee-saved: start time

    movq    %r11, %rbx          // rbx = slot ID

    // Save argument-passing registers (176 bytes)
    //   6 GP regs: 48 bytes, 8 XMM regs: 128 bytes
    subq    $176, %rsp
    movq    %rdi,   0(%rsp)
    movq    %rsi,   8(%rsp)
    movq    %rdx,  16(%rsp)
    movq    %rcx,  24(%rsp)
    movq    %r8,   32(%rsp)
    movq    %r9,   40(%rsp)
    movaps  %xmm0, 48(%rsp)
    movaps  %xmm1, 64(%rsp)
    movaps  %xmm2, 80(%rsp)
    movaps  %xmm3, 96(%rsp)
    movaps  %xmm4, 112(%rsp)
    movaps  %xmm5, 128(%rsp)
    movaps  %xmm6, 144(%rsp)
    movaps  %xmm7, 160(%rsp)

    // Call generic_hook_enter(slot_id) → returns uint64_t start_time in rax
    movq    %rbx, %rdi
    callq   _generic_hook_enter
    movq    %rax, %r12          // r12 = start_time

    // Restore argument-passing registers
    movq      0(%rsp), %rdi
    movq      8(%rsp), %rsi
    movq     16(%rsp), %rdx
    movq     24(%rsp), %rcx
    movq     32(%rsp), %r8
    movq     40(%rsp), %r9
    movaps   48(%rsp), %xmm0
    movaps   64(%rsp), %xmm1
    movaps   80(%rsp), %xmm2
    movaps   96(%rsp), %xmm3
    movaps  112(%rsp), %xmm4
    movaps  128(%rsp), %xmm5
    movaps  144(%rsp), %xmm6
    movaps  160(%rsp), %xmm7
    addq    $176, %rsp

    // Load original function pointer: generic_hook_originals[slot]
    leaq    _generic_hook_originals(%rip), %r11
    movq    (%r11, %rbx, 8), %r11

    // Call original function
    callq   *%r11

    // Save return value registers (48 bytes: rax, rdx, xmm0, xmm1)
    subq    $48, %rsp
    movq    %rax,   0(%rsp)
    movq    %rdx,   8(%rsp)
    movaps  %xmm0, 16(%rsp)
    movaps  %xmm1, 32(%rsp)

    // Call generic_hook_exit(slot_id, start_time)
    movq    %rbx, %rdi
    movq    %r12, %rsi
    callq   _generic_hook_exit

    // Restore return value registers
    movq      0(%rsp), %rax
    movq      8(%rsp), %rdx
    movaps   16(%rsp), %xmm0
    movaps   32(%rsp), %xmm1
    addq    $48, %rsp

    // Restore callee-saved and frame
    popq    %r12
    popq    %rbx
    popq    %rbp
    retq

#endif
