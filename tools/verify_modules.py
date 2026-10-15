#!/usr/bin/env python3
"""逐模块 CRC 校验（比 crc_gate.py 的符号集合比对更贴近"模块能否加载"）。

原理：
  模块加载时，内核内核模块加载器只检查该模块 ELF `__versions` 段里记录的
  符号 CRC 是否与内核导出的 CRC 一致。因此最贴近真实的验收是：
  **对【每个厂商模块】单独检查其 __versions 段里的每一条**，
  而不是把所有模块的符号并成一个集合去比。

判据（与 crc_gate.py 一致）：
  * CRC 冲突（符号存在但值不同）→ 该模块被拒绝加载 → 致命
  * 未导出（内核没有该符号）→ 模块仍可加载（除非它真的引用不到），
    但记录为可疑

用法:
  verify_modules.py <模块目录或单个 .ko> [更多路径...] \
      --symvers <Module.symvers> [--allow SYM ...] [--json out.json]

注意：本脚本只读 ELF，不联网、不下载。
"""
import argparse
import json
import os
import struct
import sys


def elf_sections(d):
    """返回 [(name, type, offset, size, entsize)]。仅支持 ELF64 little-endian。"""
    if d[:4] != b"\x7fELF":
        return None
    if d[4] != 2 or d[5] != 1:
        return None
    e_shoff = struct.unpack_from("<Q", d, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", d, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", d, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", d, 0x3E)[0]
    if not e_shoff or not e_shnum or e_shstrndx >= e_shnum:
        return None
    raw = [struct.unpack_from("<IIQQQQIIQQ", d, e_shoff + i * e_shentsize)
           for i in range(e_shnum)]
    shstr = raw[e_shstrndx]

    def sname(n):
        try:
            end = d.index(b"\0", shstr[4] + n)
        except ValueError:
            return ""
        return d[shstr[4] + n:end].decode("utf8", "replace")

    return [(sname(f[0]), f[1], f[4], f[5], f[9]) for f in raw]


def module_versions(path):
    """读取模块 __versions 段，返回 [(符号, crc)]。

    struct modversion_info { unsigned long crc; char name[56]; }  → 64 字节
    """
    with open(path, "rb") as f:
        d = f.read()
    secs = elf_sections(d)
    if secs is None:
        return None
    for name, typ, off, size, entsize in secs:
        if name == "__versions":
            entry = entsize if entsize else 64
            out = []
            for k in range(size // entry):
                o = off + k * entry
                crc = struct.unpack_from("<Q", d, o)[0]
                nm = d[o + 8:o + 8 + 56].split(b"\0")[0].decode("utf8", "replace")
                out.append((nm, crc & 0xFFFFFFFF))
            return out
    return []  # 没有 __versions = 无版本要求（CONFIG_MODVERSIONS 关时的模块）


def load_symvers(path):
    have = {}
    rows = 0
    with open(path, errors="replace") as f:
        for line in f:
            p = [x for x in line.rstrip("\n").split("\t") if x != ""]
            if len(p) >= 2 and p[0].startswith("0x"):
                rows += 1
                idx = 2 if len(p) >= 5 else 1
                if len(p) > idx:
                    try:
                        have[p[idx]] = int(p[0], 16) & 0xFFFFFFFF
                    except ValueError:
                        pass
    return have, rows


def collect(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for fn in files:
                    if fn.endswith(".ko"):
                        out.append(os.path.join(root, fn))
        elif p.endswith(".ko") and os.path.isfile(p):
            out.append(p)
    return sorted(set(out))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("modules", nargs="+", help=".ko 文件或目录")
    ap.add_argument("--symvers", required=True)
    ap.add_argument("--allow", action="append", default=[],
                    help="允许的已知 CRC 冲突符号（会单独打印）")
    ap.add_argument("--json")
    ap.add_argument("--max-print", type=int, default=40)
    args = ap.parse_args()

    have, rows = load_symvers(args.symvers)
    mods = collect(args.modules)
    print("=== 逐模块 CRC 校验 ===")
    print("  Module.symvers : %s（解析 %d 行 → %d 个符号）" % (args.symvers, rows, len(have)))
    print("  待检模块数     : %d" % len(mods))
    if not mods:
        print("::error::没有找到任何 .ko")
        return 1
    if len(have) < 1000:
        print("::error::Module.symvers 符号数仅 %d，文件可能损坏" % len(have))
        return 1
    print()

    results = []
    n_conflict_mods = 0
    n_missing_mods = 0
    total_syms = 0
    total_conf = 0
    total_miss = 0
    conflict_detail = {}
    missing_detail = {}
    unreadable = []

    for m in mods:
        vers = module_versions(m)
        if vers is None:
            unreadable.append(m)
            continue
        conf, miss = [], []
        for nm, crc in vers:
            total_syms += 1
            if nm not in have:
                miss.append((nm, crc))
            elif have[nm] != crc:
                conf.append((nm, crc, have[nm]))
        if conf:
            n_conflict_mods += 1
        if miss:
            n_missing_mods += 1
        total_conf += len(conf)
        total_miss += len(miss)
        for nm, want, got in conf:
            conflict_detail.setdefault(nm, []).append((os.path.basename(m), want, got))
        for nm, crc in miss:
            missing_detail.setdefault(nm, []).append(os.path.basename(m))
        results.append({"module": os.path.basename(m), "path": m,
                        "checked": len(vers), "conflicts": len(conf), "missing": len(miss),
                        "conflict_syms": [c[0] for c in conf]})

    print("  ── 汇总 ──")
    print("  校验符号条目总数        : %d" % total_syms)
    print("  有 CRC 冲突的模块数     : %d" % n_conflict_mods)
    print("  CRC 冲突条目总数        : %d" % total_conf)
    print("  有未导出符号的模块数    : %d（非致命）" % n_missing_mods)
    print("  未导出条目总数          : %d（非致命）" % total_miss)
    if unreadable:
        print("  无法解析的模块          : %d" % len(unreadable))
        for u in unreadable[:5]:
            print("      %s" % u)
    print()

    fatal = {k: v for k, v in conflict_detail.items() if k not in args.allow}
    allowed = {k: v for k, v in conflict_detail.items() if k in args.allow}

    if allowed:
        print("  ── 已知允许的例外（不影响判定）──")
        for nm, lst in sorted(allowed.items()):
            print("    [ALLOW] %-38s 影响 %d 个模块（如 %s）"
                  % (nm, len(lst), lst[0][0]))
        print()

    if fatal:
        print("  ── ★ 致命：CRC 冲突明细（这些模块会被内核拒绝加载）──")
        for nm, lst in sorted(fatal.items(), key=lambda x: -len(x[1]))[:args.max_print]:
            m0, want, got = lst[0]
            print("    %-38s 期望 0x%08x 实际 0x%08x  影响 %d 个模块（如 %s）"
                  % (nm, want, got, len(lst), m0))
        if len(fatal) > args.max_print:
            print("    ...（还有 %d 个，见 --json）" % (len(fatal) - args.max_print))
        print()

    if missing_detail:
        top = sorted(missing_detail.items(), key=lambda x: -len(x[1]))[:15]
        print("  ── 未导出符号 Top15（非致命，记录用）──")
        for nm, lst in top:
            print("    %-38s 影响 %d 个模块" % (nm, len(lst)))
        print()

    if args.json:
        with open(args.json, "w") as f:
            json.dump({"symvers": args.symvers,
                       "modules": results,
                       "conflict_detail": {k: v for k, v in conflict_detail.items()},
                       "missing_detail": {k: v for k, v in missing_detail.items()},
                       "summary": {"modules": len(mods), "symbols": total_syms,
                                   "conflict_mods": n_conflict_mods, "conflicts": total_conf,
                                   "missing_mods": n_missing_mods, "missing": total_miss}},
                      f, indent=1)
        print("  明细已写入: %s" % args.json)

    if fatal:
        print("::error::存在 %d 个不可容忍的 CRC 冲突符号（影响 %d 个模块）→ 模块会被拒绝加载"
              % (len(fatal), n_conflict_mods))
        return 1
    print("  ✅ 逐模块校验通过：除已知例外外无任何 CRC 冲突")
    return 0


if __name__ == "__main__":
    sys.exit(main())
