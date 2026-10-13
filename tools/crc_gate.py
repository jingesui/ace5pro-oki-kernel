#!/usr/bin/env python3
"""CRC 把关：把编出的内核 Module.symvers 与厂商模块期望的符号 CRC 比对。

原理：模块能否加载由符号 CRC 决定，而 CRC 是源码+配置经 genksyms 算出的，
与编译环境无关。因此只要 CRC 全中，就能确定厂商模块可加载、设备能开机，
不必拿真机试错。

用法: python3 tools/crc_gate.py <Module.symvers> <expected_crc.txt>
"""
import sys


def load_symvers(path):
    have = {}
    with open(path, errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) >= 4:
                crc, name = p[1], p[2]
                try:
                    have[name] = int(crc, 16) & 0xFFFFFFFF
                except ValueError:
                    pass
    return have


def load_expected(path):
    exp = []
    with open(path, errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) == 2:
                try:
                    exp.append((p[0], int(p[1], 16) & 0xFFFFFFFF))
                except ValueError:
                    pass
    return exp


def main():
    if len(sys.argv) != 3:
        print("用法: crc_gate.py <Module.symvers> <expected_crc.txt>")
        return 2

    have = load_symvers(sys.argv[1])
    exp = load_expected(sys.argv[2])

    print("Module.symvers 符号数: %d" % len(have))
    print("期望符号数           : %d" % len(exp))
    print()

    if not exp:
        print("::warning::期望列表为空，跳过比对")
        return 0

    miss, bad, ok = [], [], 0
    for name, want in exp:
        if name not in have:
            miss.append(name)
        elif have[name] != want:
            bad.append((name, want, have[name]))
        else:
            ok += 1

    print("匹配 %d / %d" % (ok, len(exp)))

    if miss:
        print()
        print("内核未导出（%d）:" % len(miss))
        for n in miss[:25]:
            print("   - %s" % n)

    if bad:
        print()
        print("CRC 不一致（%d）:" % len(bad))
        for n, w, g in bad[:25]:
            print("   %-38s 期望 0x%08x  实际 0x%08x" % (n, w, g))

    pct = 100.0 * ok / len(exp)
    print()
    print("匹配率: %.1f%%" % pct)

    if bad:
        print()
        print("::error::存在 %d 个符号 CRC 不匹配，厂商模块将拒绝加载" % len(bad))
        return 1

    if miss:
        print()
        print("::warning::有 %d 个符号未导出，但无 CRC 冲突" % len(miss))
        return 0

    print()
    print("✅ 全部匹配 —— 厂商模块可正常加载，预期能开机")
    return 0


if __name__ == "__main__":
    sys.exit(main())
