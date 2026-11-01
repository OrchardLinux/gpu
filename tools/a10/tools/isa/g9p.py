#!/usr/bin/env python3
"""applegpu_g9p (A10) assembler for the instructions decoded so far (ISA.md).

Each function returns one instruction as a list of 16-bit words; bit 8 of a
word means another word follows. `program()` adds the compute frame the
compiler emits (prologue, register count, epilogue, end) around a body.

Self-test: `g9p.py CORPUS.txt` re-assembles the probe kernels it knows and
compares them with Apple's code word for word.
"""
import sys

END = [0x8000]
WAIT = [0x004d]                 # wait for outstanding loads


def prologue(shared):
    """Program entry. @shared: the W1 low byte the compiler emits (0x89 with
    one buffer binding, 0x91 with two); meaning not decoded yet."""
    return [0x1181, 0x8100 | shared, 0x4100, 0xacb7]


def push_init(st):
    """Start the execution-mask stack in register @st (the compiler uses the
    first register after the kernel's own)."""
    return [0x01c8, 0x0300 | 2 * st, 0x0101, 0x0120, 0x46d1]


def push_if(st, invert=False):
    """Push the execution mask; lanes whose last compare failed (passed,
    with @invert) are disabled."""
    return [0x21c8, 0x0300 | 2 * st, 0x0100 | st << 2, 0x46d1 | invert << 13]


def else_(st):
    """Flip the lanes of the innermost if."""
    return [0x21c8, 0x0300 | 2 * st, 0x0100 | st << 2, 0x46d4]


def pop(st, levels=1):
    """Pop @levels execution-mask levels."""
    return [0x21c8, 0x0300 | 2 * st, 0x0180 | st << 2, 0x06d2 | levels << 14]


regs = push_init
epilogue = pop


def mov_imm(dst, imm):
    """dst = imm (32-bit)."""
    imm &= 0xffffffff
    w0 = 0x0198 | ((imm >> 9) & 1) << 13
    w2 = 0x0101 | (imm & 0x3f) << 1
    w3 = (0x0120 | ((imm >> 6) & 7) << 1 | ((imm >> 10) & 1) << 4 | ((imm >> 14) & 1) << 6 |
          ((imm >> 15) & 1) << 7 | ((imm >> 11) & 7) << 12)
    words = [w0, 0x0300 | 2 * dst, w2, w3]
    if imm >> 16:
        words[3] |= 1 | ((imm >> 24) & 1) << 15
        words.append(0x0100 | ((imm >> 16) & 0xff) | ((imm >> 25) & 0x7f) << 9)
    return words + [0x0154, 0x0038]


SIZE = {'u8': 1, 'u16': 2, 'u32': 4, 'u32x2': 5, 'u32x3': 6, 'u32x4': 7}


def _mem(store, size, reg, buf, offset):
    w0 = SIZE[size] << 11 | 0x0312
    w1 = 0x0100 | buf << 10 | (0x80 if store else 0) | reg << 1
    if offset < 0x100:
        return [w0, w1, 0x8000 | offset]
    return [w0, w1, 0x8100 | (offset & 0xff), offset >> 8]


def store(size, reg, buf, offset=0):
    """buffer[buf][offset] = reg (offset in elements)."""
    return _mem(True, size, reg, buf, offset)


def load(size, reg, buf, offset=0):
    return _mem(False, size, reg, buf, offset)


SHIFT = {'u8': 0, 'u16': 1, 'u32': 2, 'u32x2': 3}


def addr(dst, buf_dword, idx, size='u32', kill=True):
    """r[dst]:r[dst+1] = address of buffer element r[idx] (ISA.md "Register-
    indexed memory access"); the buffer's address is the uniform at common-
    store dword @buf_dword."""
    w2 = (kill << 15) | ((1 | idx << 2) << 8) | 0x81 | 4 * buf_dword
    return [0x1189, 0x0300 | 2 * dst, w2, 0x4100, 0x01a1, 0x0600 | SHIFT[size] << 13]


def _mem_addr(store, size, reg, pair):
    return [SIZE[size] << 11 | 0x0310, (1 | pair << 2) << 8 | (0x80 if store else 0) | reg << 1,
            0x8800]


def store_at(size, reg, pair):
    """*(r[pair]:r[pair+1]) = r[reg]"""
    return _mem_addr(True, size, reg, pair)


def load_at(size, reg, pair):
    """r[reg] = *(r[pair]:r[pair+1]); follow with WAIT before use"""
    return _mem_addr(False, size, reg, pair)


def srcs(a, b, kill):
    """Two register sources; bit 7 / bit 15 mark @a / @b as last use, which
    the compiler sets only where the value is dead afterwards."""
    return 0x0100 | a << 2 | b << 10 | (0x80 if kill else 0) | (0x8000 if kill else 0)


def alu2(op, dst, a, b, kill=True):
    """dst = a OP b, two registers."""
    return [0x3199, 0x0300 | 2 * dst, srcs(a, b, kill), op]


def add_imm(dst, src, imm):
    """dst = src + imm (6-bit immediate)."""
    assert 0 <= imm < 0x40
    return [0x1199, 0x0300 | 2 * dst, 0x0101 | imm << 1 | src << 10, 0x0120, 0x09a1, 0x0070]


def sel(cond, dst, a, b, c, kill=True):
    """dst = c where (a COND b); pair with movf() for the other lanes. W0 bit
    2 goes with the last-use bits (`399a` with them, `399e` without)."""
    return [0x399a | (0 if kill else 4), 0x0300 | 2 * dst, srcs(a, b, kill), 0x0180 | c << 2,
            0x6000 | cond]


def movf(dst, d):
    """dst = d where the preceding sel()'s compare failed."""
    return [0x21f8, 0x0300 | 2 * dst, 0x0180 | d << 2, 0x0154, 0x0038]


def movf_imm(dst, imm):
    assert 0 <= imm < 0x40
    return [0x01f8, 0x0300 | 2 * dst, 0x0101 | imm << 1, 0x0120, 0x0154, 0x0038]


IADD, IMUL, ISUB = 0xa1, 0xa2, 0xa5
AND, OR, XOR = 0xc8, 0xce, 0xc6
FADD, FMUL = 0x44, 0x48


# compare conditions (low byte of the compare's third word)
ULT, UGT, EQ, SLT, SGT = 0xb6, 0xb7, 0xbd, 0xbe, 0xbf


def cmp_imm(cond, imm, reg=0):
    """Compare @reg with a 10-bit immediate, for a following push_if."""
    assert 0 <= imm < 0x400
    return [0x1181 | (imm >> 9 & 1) << 13, 0x0101 | (imm & 0x3f) << 1 | reg << 10,
            0x0120 | (imm >> 6 & 7) << 1, 0xa100 | cond, 0x0070]


def cmp_reg(cond, a, b, kill=True):
    """Compare registers @a and @b, for a following push_if."""
    return [0x3181, srcs(a, b, kill), 0xa000 | cond]


def loop_begin(st):
    """Open a loop: two mask levels (loop and break)."""
    return [0x21c8, 0x0300 | 2 * st, 0x0100 | st << 2, 0x86d0]


def loop_break(st, when_true):
    """Leave the loop for the lanes whose last compare passed (@when_true)
    or failed."""
    return [0x21c8, 0x0300 | 2 * st, 0x0100 | st << 2, 0x86d7 | when_true << 13]


def _jump(op, offset_bytes):
    """A jump: byte offset in two words; bit 8 of each word is the
    continuation flag, so offset bit 8 (and 24) sits in bit 0, which even
    offsets leave free (ISA.md "Jump offsets")."""
    off = offset_bytes & 0xffffffff
    return [op, (off & 0xfefe) | 0x0100 | (off >> 8 & 1),
            (off >> 16 & 0xfefe) | (off >> 24 & 1)]


def jmp_none(offset_bytes):
    """Jump forward if no lane is active."""
    return _jump(0x0900, offset_bytes)


def jmp(offset_bytes):
    """Jump forward unconditionally."""
    return _jump(0x0100, offset_bytes)


def jmp_any(offset_bytes):
    """Jump (backward, to a loop body) while any lane is active."""
    return _jump(0x0101, offset_bytes)


def assemble(items):
    """Words from instructions and labels: an item is a word list, a label
    string, or (jmp_none|jmp, label) for a forward jump to that label. The
    label 'end' is the end word, placed as program() places it."""
    def layout(sizes):
        pos, at = 0, {}
        for it in items:
            if isinstance(it, str):
                at[it] = pos
            else:
                pos += sizes.get(id(it), 2 * len(it) if isinstance(it, list) else 6)
        at['end'] = (pos + 63) // 64 * 64
        return at
    at = layout({})
    words, pos = [], 0
    for it in items:
        if isinstance(it, str):
            continue
        if isinstance(it, tuple):
            fn, label = it
            it = fn(at[label] - pos)
        words += it
        pos += 2 * len(it)
    return words + [0xc000] * ((at['end'] - pos) // 2) + END


def branch_to(offset_bytes):
    """Forward branch by @offset_bytes from this instruction (before stores)."""
    return [0x0900, 0x0100 | offset_bytes, 0x0000]


def program(body, nregs, shared=0x89):
    """Compute kernel: prologue, body, a branch to the epilogue before the
    final stores is the caller's (see ISA.md), epilogue, then a jump to the
    end word, which starts the next 64-byte block after `c000` padding."""
    words = prologue(shared) + regs(nregs) + [w for insn in body for w in insn]
    words += epilogue(nregs)
    jump = 2 * len(words)
    end = (jump + 6 + 63) // 64 * 64
    words += _jump(0x0100, end - jump)
    words += [0xc000] * ((end - 2 * len(words)) // 2) + END
    return words


def normalized(words):
    """@words as explore.py prints them: without the padding before the end."""
    while words and words[-1] == 0xc000:
        words = words[:-1]
    if words and words[-1] == 0x8000:
        body = words[:-1]
        while body and body[-1] == 0xc000:
            body = body[:-1]
        words = body + [0x8000]
    return words


def from_listing(words):
    """Code as the GPU needs it from an explore.py listing: put the padding
    back so that the final jump lands on the end word."""
    assert words[-4] == 0x0100 and words[-1] == 0x8000
    jump = 2 * (len(words) - 4)
    end = jump + (words[-3] & 0xff)
    return words[:-1] + [0xc000] * ((end - 2 * (len(words) - 1)) // 2) + END


def store_kernel(imm, offset=0):
    """o[offset] = imm, as the compiler emits it (probes/imm.metal, seq.metal)."""
    st = store('u32', 0, 0, offset)
    body = [mov_imm(0, imm), branch_to(2 * (3 + len(st))), st]
    return program(body, 1)


def main():
    known = {f'imm_b{k}': store_kernel(1 << k) for k in range(32)}
    known.update({'imm_0': store_kernel(0), 'imm_ff': store_kernel(0xffffffff),
                  'st_1357': store_kernel(0x1357), 'st_2468': store_kernel(0x2468),
                  'st_big': store_kernel(0x12345678), 'st_off1': store_kernel(0x1357, 1),
                  'st_off5': store_kernel(0x1357, 5), 'off_far': store_kernel(0x11, 1000),
                  'one': store_kernel(0x11)})
    ok = bad = 0
    for line in open(sys.argv[1]):
        name, *hexwords = line.split()
        if name not in known or 'failed' in line:
            continue
        apple = [int(w, 16) for w in hexwords]
        ours = normalized(known.pop(name))
        if ours == apple:
            ok += 1
        else:
            bad += 1
            print(f'{name}: differs\n  apple {" ".join(f"{w:04x}" for w in apple)}\n'
                  f'  ours  {" ".join(f"{w:04x}" for w in ours)}')
    print(f'{ok} identical, {bad} differ')


if __name__ == '__main__':
    main()
