#!/usr/bin/env python3
"""CRC 把关：把编出的内核 Module.symvers 与厂商模块期望的符号 CRC 比对。

原理：模块能否加载由符号 CRC 决定，而 CRC 是源码+配置经 genksyms 算出的，
与编译环境无关。

判据分两类（关键区别）：
  * CRC 冲突 : 符号存在但校验值不同 -> 内核拒绝加载该模块 -> 致命，必须为 0
  * 未导出   : 内核没有该符号      -> 不拒绝加载，仅该代码路径失效 -> 非致命

失败模式：
  任何解析异常（列表为空、文件缺列等）一律返回非 0，绝不静默通过。

用法: crc_gate.py <Module.symvers> <expected_crc.txt>
"""
import os
import sys

# Module.symvers 两种已知布局（制表符分隔）：
#   AOSP/高通 4 列: <crc> <symbol> <module> <export_type>
#   上游内核 5 列 : <crc> <module> <symbol> <file> <export_type>
# 自动探测：某行的第 3 列若为 "vmlinux"/模块名，则是 5 列布局。
MIN_EXPECTED_SYMBOLS = 10


def load_symvers(path):
    """返回 {符号名: crc}。自动识别 4 列 / 5 列布局。"""
    if not os.path.isfile(path):
        raise SystemExit("::error::Module.symvers 不存在: %s" % path)

    rows = []
    with open(path, errors="replace") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            p = [x for x in p if x != ""]
            if len(p) >= 2 and p[0].startswith("0x"):
                rows.append(p)

    if not rows:
        raise SystemExit("::error::Module.symvers 无有效行: %s" % path)

    # 探测列布局：4 列时 p[2] 是模块名(vmlinux)，p[1] 是符号名
    #             5 列时 p[1] 是模块名，p[2] 是符号名
    sample = rows[0]
    if len(sample) >= 5:
        sym_idx = 2
        layout = "5列(上游)"
    else:
        sym_idx = 1
        layout = "4列(AOSP)"

    have = {}
    for p in rows:
        if len(p) <= sym_idx:
            continue
        try:
            have[p[sym_idx]] = int(p[0], 16) & 0xFFFFFFFF
        except ValueError:
            continue

    print("  Module.symvers 布局: %s，解析出 %d 个符号" % (layout, len(have)))
    return have


def load_expected(path):
    """返回 [(符号名, crc)]，忽略注释与空行。"""
    if not os.path.isfile(path):
        raise SystemExit("::error::expected 文件不存在: %s" % path)

    exp = []
    bad_lines = []
    with open(path, errors="replace") as f:
        for n, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            p = s.split()
            if len(p) != 2:
                bad_lines.append((n, s[:60]))
                continue
            try:
                exp.append((p[0], int(p[1], 16) & 0xFFFFFFFF))
            except ValueError:
                bad_lines.append((n, s[:60]))

    if bad_lines:
        print("::error::expected 文件有 %d 行格式错误:" % len(bad_lines))
        for n, s in bad_lines[:10]:
            print("   第 %d 行: %s" % (n, s))
        raise SystemExit(1)

    return exp


def main():
    if len(sys.argv) != 3:
        print("用法: crc_gate.py <Module.symvers> <expected_crc.txt>")
        return 2

    print("=== CRC 把关 ===")
    have = load_symvers(sys.argv[1])
    exp = load_expected(sys.argv[2])

    print("  期望符号数: %d" % len(exp))
    print()

    # 空列表 => 配置/文件错误，绝不当作通过（这是曾经的假绿根源）
    if len(exp) < MIN_EXPECTED_SYMBOLS:
        print("::error::期望符号数仅 %d（少于下限 %d），expected 文件可能损坏"
              % (len(exp), MIN_EXPECTED_SYMBOLS))
        return 1

    miss, bad, ok = [], [], 0
    for name, want in exp:
        if name not in have:
            miss.append(name)
        elif have[name] != want:
            bad.append((name, want, have[name]))
        else:
            ok += 1

    print("  匹配            : %d / %d (%.1f%%)" % (ok, len(exp), 100.0 * ok / len(exp)))
    print("  CRC 冲突(致命)  : %d" % len(bad))
    print("  未导出(非致命)  : %d" % len(miss))
    print()

    if bad:
        print("CRC 冲突明细（这些会导致模块被拒绝加载）:")
        for n, w, g in bad[:30]:
            print("   %-38s 期望 0x%08x  实际 0x%08x" % (n, w, g))
        print()
        print("::error::存在 %d 个符号 CRC 冲突，厂商模块将拒绝加载" % len(bad))
        return 1

    if miss:
        print("未导出明细（模块仍可加载，但相关功能路径失效）:")
        for n in miss[:30]:
            print("   - %s" % n)
        print()
        print("::warning::有 %d 个符号未导出，但 CRC 冲突为 0" % len(miss))

    print("✅ CRC 冲突为 0 —— 厂商模块可正常加载")
    return 0


if __name__ == "__main__":
    sys.exit(main())
