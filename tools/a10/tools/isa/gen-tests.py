#!/usr/bin/env python3
"""Write hand-assembled test kernels for pvr-compute-test (USC.bin INDEX VALUE).

Each kernel is built by g9p.py from decoded encodings only, not copied from
the compiler, and stores one value the test checks:

  gen-tests.py OUTDIR      # writes NAME.bin and prints "NAME INDEX VALUE"
"""
import importlib.util
import pathlib
import struct
import sys

spec = importlib.util.spec_from_file_location('g9p', pathlib.Path(__file__).with_name('g9p.py'))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def kernel(body, result_reg, index, nregs):
    st = g.store('u32', result_reg, 0, index)
    return g.program(body + [g.branch_to(2 * (3 + len(st))), st], nregs)


TESTS = {
    # 32-bit immediate at a new offset
    'imm32': (kernel([g.mov_imm(0, 0xdeadbeef)], 0, 7, 1), 7, 0xdeadbeef),
    # register ALU
    'iadd': (kernel([g.mov_imm(0, 0x1234), g.mov_imm(1, 0x5678),
                     g.alu2(g.IADD, 2, 0, 1)], 2, 3, 3), 3, 0x1234 + 0x5678),
    # chained ALU
    'mulxor': (kernel([g.mov_imm(0, 0x1234), g.mov_imm(1, 0x5678),
                       g.alu2(g.IMUL, 2, 0, 1), g.mov_imm(3, 0xff00ff00),
                       g.alu2(g.XOR, 0, 2, 3)], 0, 5, 4),
               5, (0x1234 * 0x5678) ^ 0xff00ff00),
    'imul': (kernel([g.mov_imm(0, 0x1234), g.mov_imm(1, 0x5678),
                     g.alu2(g.IMUL, 2, 0, 1)], 2, 4, 3), 4, 0x1234 * 0x5678),
    'xor': (kernel([g.mov_imm(0, 0x1234), g.mov_imm(1, 0xff00ff00),
                    g.alu2(g.XOR, 2, 0, 1)], 2, 6, 3), 6, 0x1234 ^ 0xff00ff00),
    'regs4': (kernel([g.mov_imm(3, 0x4444)], 3, 8, 4), 8, 0x4444),
    'reuse': (kernel([g.mov_imm(0, 0x1234), g.mov_imm(1, 0x5678),
                      g.alu2(g.IADD, 0, 0, 1)], 0, 9, 2), 9, 0x1234 + 0x5678),
}


def ifelse(x):
    """out[2] = r0 == 5 ? 0x5555 : 0x6666, structured as the compiler does."""
    return g.assemble([g.prologue(0x89), g.push_init(2), (g.jmp_none, 'pop'),
                       g.mov_imm(0, x), g.cmp_imm(g.EQ, 5), g.push_if(2), (g.jmp_none, 'else'),
                       g.mov_imm(1, 0x5555), g.store('u32', 1, 0, 2),
                       'else', g.else_(2), (g.jmp_none, 'pop'),
                       g.mov_imm(1, 0x6666), g.store('u32', 1, 0, 2),
                       'pop', g.pop(2, 2), (g.jmp, 'end')])


def ifreg(x, y, cond):
    """out[3] = (r0 COND r1) ? 0x1111 : 0x2222."""
    return g.assemble([g.prologue(0x89), g.push_init(3), (g.jmp_none, 'pop'),
                       g.mov_imm(0, x), g.mov_imm(1, y), g.cmp_reg(cond, 0, 1), g.push_if(3),
                       (g.jmp_none, 'else'),
                       g.mov_imm(2, 0x1111), g.store('u32', 2, 0, 3),
                       'else', g.else_(3), (g.jmp_none, 'pop'),
                       g.mov_imm(2, 0x2222), g.store('u32', 2, 0, 3),
                       'pop', g.pop(3, 2), (g.jmp, 'end')])


TESTS.update({
    'if_eq5': (ifelse(5), 2, 0x5555),
    'if_eq6': (ifelse(6), 2, 0x6666),
    'if_ult_t': (ifreg(3, 9, g.ULT), 3, 0x1111),
    'if_ult_f': (ifreg(9, 3, g.ULT), 3, 0x2222),
    'if_slt_t': (ifreg(0xfffffffe, 3, g.SLT), 3, 0x1111),
    'if_ugt_f': (ifreg(3, 0xfffffffe, g.UGT), 3, 0x2222),
})


def pow3(n):
    """out[4] = 3**n by a loop (n >= 1)."""
    return g.assemble([g.prologue(0x89), g.push_init(4), (g.jmp_none, 'exit'),
                       g.mov_imm(0, 1), g.mov_imm(1, n), g.mov_imm(2, 0), g.mov_imm(3, 3),
                       g.loop_begin(4),
                       'body', g.alu2(g.IMUL, 0, 0, 3, kill=False), g.add_imm(2, 2, 1),
                       g.cmp_reg(g.EQ, 2, 1, kill=False), g.loop_break(4, True),
                       (g.jmp_any, 'body'),
                       g.pop(4, 2), g.store('u32', 0, 0, 4),
                       'exit', g.pop(4, 1), (g.jmp, 'end')])


def countdown(x):
    """out[5] = x + (x-1) + ... + 2, a while loop on x > 1."""
    return g.assemble([g.prologue(0x89), g.push_init(3), (g.jmp_none, 'exit'),
                       g.mov_imm(0, x), g.mov_imm(1, 0), g.mov_imm(2, 0xffffffff),
                       g.loop_begin(3),
                       'body', g.alu2(g.IADD, 1, 1, 0, kill=False),
                       g.alu2(g.IADD, 0, 0, 2, kill=False),
                       g.cmp_imm(g.UGT, 1, reg=0), g.loop_break(3, False),
                       (g.jmp_any, 'body'),
                       g.pop(3, 2), g.store('u32', 1, 0, 5),
                       'exit', g.pop(3, 1), (g.jmp, 'end')])


def select(x, y, imm_else=False):
    """out[6] = x < y ? 0x1234 : (5 if imm_else else 0x5678)."""
    other = g.movf_imm(0, 5) if imm_else else g.movf(0, 3)
    return g.assemble([g.prologue(0x89), g.push_init(4), (g.jmp_none, 'exit'),
                       g.mov_imm(0, x), g.mov_imm(1, y), g.mov_imm(2, 0x1234),
                       g.mov_imm(3, 0x5678), g.sel(g.ULT, 0, 0, 1, 2), other,
                       g.store('u32', 0, 0, 6),
                       'exit', g.pop(4, 1), (g.jmp, 'end')])


TESTS.update({
    'pow3': (pow3(5), 4, 243),
    'pow3_1': (pow3(1), 4, 3),
    'countdown': (countdown(10), 5, 54),
    'sel_t': (select(3, 9), 6, 0x1234),
    'sel_f': (select(9, 3), 6, 0x5678),
    'sel_fk': (select(9, 3, True), 6, 5),
})


def main():
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, (words, index, value) in TESTS.items():
        words = words + [0xc000] * (-len(words) % 32)      # pad to 64 bytes
        (out / f'{name}.bin').write_bytes(struct.pack(f'<{len(words)}H', *words))
        print(name, index, hex(value))


if __name__ == '__main__':
    main()
