#!/usr/bin/env python3
"""构建后产物验证（四项验收闸门）。

a. walt_rq CRC 必须是 0xda944f6d      —— 不是则厂商模块拒绝加载 → bootloop
b. Image 里 hmbird 符号数必须 > 0     —— 证明风驰真的编进去了
c. 从 Image 提取内嵌 config 做断言    —— 证明配置真的生效（不是"以为生效"）
d. CRC 全量比对：与真机 495 个厂商模块的期望 CRC 比对，冲突必须为 0

设计要点：
  * 每项都打印【真实输出】，不做摘要粉饰
  * a/d 是致命的（exit 非 0）；b/c 失败也报错
  * 已知唯一可忽略例外: clk_alpha_pll_regs（影响 5 个 tuna 平台模块，本机不加载）
    用 --allow 显式声明，且会打印出来，绝不静默放过

用法:
  ci_verify.py --dist <dist目录> --repo-root <仓库checkout根> \
               --expected <expected_crc.txt> --crc-gate <crc_gate.py> \
               --allow clk_alpha_pll_regs
"""
import argparse
import gzip
import os
import re
import subprocess
import sys

MAGIC_START = b"IKCFG_ST"
MAGIC_END = b"IKCFG_ED"

# 期望内嵌 config（与「已知能开机且带风驰」的参考内核一致）
EXPECT_CONFIG = [
    ("CONFIG_HMBIRD_SCHED", "y"),
    ("CONFIG_SYSVIPC", "y"),
    ("CONFIG_MQ_IOSCHED_ADIOS", "y"),
    ("CONFIG_MQ_IOSCHED_DEFAULT_ADIOS", "y"),
]
EXPECT_ABSENT = [
    "CONFIG_SLIM_SCHED",
    "CONFIG_SCHED_CLASS_EXT",
    "CONFIG_CFS_BANDWIDTH",
    "CONFIG_CGROUP_PIDS",
]


def banner(t):
    print()
    print("═" * 72)
    print("  " + t)
    print("═" * 72)


def extract_ikconfig(path):
    """从内核镜像里提取内嵌 config（IKCFG_ST ... gzip ... IKCFG_ED）。

    注意：不能用第一个 IKCFG_ST 就完事 —— 压缩流里可能恰好出现该字节序列，
    因此从后往前试，并校验 gzip 能解开、内容像 config。
    """
    with open(path, "rb") as f:
        data = f.read()
    starts = [m.start() for m in re.finditer(re.escape(MAGIC_START), data)]
    ends = [m.start() for m in re.finditer(re.escape(MAGIC_END), data)]
    print("  IKCFG_ST 出现次数: %d" % len(starts))
    print("  IKCFG_ED 出现次数: %d" % len(ends))
    for s in starts:
        body_start = s + len(MAGIC_START)
        for e in ends:
            if e <= body_start:
                continue
            blob = data[body_start:e]
            try:
                text = gzip.decompress(blob).decode("utf8", "replace")
            except Exception:
                continue
            if "CONFIG_" in text and "Kernel Configuration" in text:
                print("  命中: offset %d..%d，解出 %d 字节 / %d 行"
                      % (s, e, len(blob), text.count("\n")))
                return text
    return None


def parse_cfg(text):
    """{CONFIG_X: 'y'|'m'|'n'|'"str"'}；'# CONFIG_X is not set' 记作 'n'。"""
    d = {}
    for line in text.splitlines():
        s = line.strip()
        m = re.match(r"^#\s*(CONFIG_[A-Za-z0-9_]+)\s+is not set$", s)
        if m:
            d[m.group(1)] = "n"
            continue
        if s.startswith("CONFIG_") and "=" in s:
            k, v = s.split("=", 1)
            d[k] = v
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dist", required=True, help="dist 目录（含 Image / Module.symvers）")
    ap.add_argument("--repo-root", required=True, help="仓库 checkout 根（有 tools/crc_gate.py）")
    ap.add_argument("--expected", required=True)
    ap.add_argument("--crc-gate", required=True)
    ap.add_argument("--allow", action="append", default=[],
                    help="允许存在的已知冲突符号（会打印出来）")
    ap.add_argument("--symvers", default=None, help="默认 <dist>/Module.symvers")
    ap.add_argument("--image", default=None, help="默认 <dist>/Image")
    args = ap.parse_args()

    symvers = args.symvers or os.path.join(args.dist, "Module.symvers")
    image = args.image or os.path.join(args.dist, "Image")
    fails = []

    print("dist   : %s" % args.dist)
    print("symvers: %s (%s B)" % (symvers, os.path.getsize(symvers) if os.path.exists(symvers) else "缺失"))
    print("image  : %s (%s B)" % (image, os.path.getsize(image) if os.path.exists(image) else "缺失"))

    # ── a. walt_rq CRC ──
    banner("a. walt_rq CRC（walt_rq 必须 = 0xda944f6d）")
    want = 0xDA944F6D
    got = None
    if os.path.exists(symvers):
        with open(symvers, errors="replace") as f:
            for line in f:
                p = [x for x in line.rstrip("\n").split("\t") if x != ""]
                if len(p) >= 2 and ("walt_rq" == p[1] or (len(p) >= 3 and "walt_rq" == p[2])):
                    got = int(p[0], 16) & 0xFFFFFFFF
                    print("  原始行: %s" % line.rstrip())
                    break
    if got is None:
        print("  [FAIL] Module.symvers 里找不到 walt_rq")
        fails.append("walt_rq 未导出")
    else:
        print("  期望: 0x%08x" % want)
        print("  实际: 0x%08x" % got)
        if got == want:
            print("  [OK] walt_rq CRC 与真机一致 ✅")
        else:
            print("  [FAIL] walt_rq CRC 不匹配（差 0x%08x）" % (got ^ want))
            fails.append("walt_rq CRC 不匹配（实际 0x%08x）" % got)

    # ── b. hmbird 符号数 ──
    banner("b. Image 里的 hmbird 符号数（必须 > 0）")
    n = 0
    if os.path.exists(image):
        with open(image, "rb") as f:
            blob = f.read()
        n = len(re.findall(rb"hmbird", blob))
        print("  Image 里 'hmbird' 出现次数: %d" % n)
        for kw in (b"hmbird_sched", b"hmbird_sched_proc", b"/proc/hmbird_sched"):
            print("    %-24s %d 次" % (kw.decode(), len(re.findall(re.escape(kw), blob))))
        if n > 0:
            print("  [OK] 风驰已编入内核 ✅")
        else:
            print("  [FAIL] hmbird 符号数 = 0 —— 风驰没编进去，必然 bootloop")
            fails.append("hmbird 符号数 = 0")
    else:
        print("  [FAIL] Image 不存在")
        fails.append("Image 缺失")

    # ── c. 内嵌 config ──
    banner("c. Image 内嵌 config 断言")
    if os.path.exists(image):
        text = extract_ikconfig(image)
        if text is None:
            print("  [FAIL] 无法从 Image 提取内嵌 config")
            fails.append("内嵌 config 提取失败")
        else:
            cfg = parse_cfg(text)
            print("  解析出 %d 个 CONFIG_ 项" % len(cfg))
            print()
            for k, v in EXPECT_CONFIG:
                actual = cfg.get(k, "<缺失>")
                mark = "OK  " if actual == v else "FAIL"
                print("  [%s] %-36s 期望 %-4s 实际 %s" % (mark, k, v, actual))
                if actual != v:
                    fails.append("%s 期望 %s 实际 %s" % (k, v, actual))
            print()
            for k in EXPECT_ABSENT:
                actual = cfg.get(k, "<缺失>")
                ok = actual in ("n", "<缺失>")
                print("  [%s] %-36s 期望 未启用 实际 %s" % ("OK  " if ok else "FAIL", k, actual))
                if not ok:
                    fails.append("%s 应为未启用，实际 %s" % (k, actual))
            print()
            print("  —— 其他关键项（信息性）——")
            for k in ("CONFIG_TRIM_UNUSED_KSYMS", "CONFIG_IPC_NS", "CONFIG_PID_NS",
                      "CONFIG_DEVTMPFS", "CONFIG_IP_SET", "CONFIG_TMPFS_XATTR",
                      "CONFIG_TMPFS_POSIX_ACL", "CONFIG_POSIX_MQUEUE", "CONFIG_USER_NS",
                      "CONFIG_MACVLAN", "CONFIG_MODVERSIONS", "CONFIG_DEBUG_INFO",
                      "CONFIG_LOCALVERSION", "CONFIG_UNUSED_KSYMS_WHITELIST"):
                print("    %-38s %s" % (k, cfg.get(k, "<缺失>")))
            # 内嵌 config 与 dist 里的 .config 交叉核对
            dotconfig = os.path.join(os.path.dirname(args.dist.rstrip("/")), ".config")
            if not os.path.exists(dotconfig):
                dotconfig = os.path.join(args.dist, ".config")
            if os.path.exists(dotconfig):
                print()
                print("  交叉核对 .config: %s" % dotconfig)
                c2 = parse_cfg(open(dotconfig, errors="replace").read())
                diff = [(k, c2.get(k), cfg.get(k)) for k in EXPECT_CONFIG if c2.get(k) != cfg.get(k)]
                if diff:
                    for k, a, b in diff:
                        print("    [WARN] %s: .config=%s 内嵌=%s" % (k, a, b))
                else:
                    print("    [OK] 关键项在 .config 与内嵌 config 中一致")
    else:
        print("  [skip] 无 Image")

    # ── d. CRC 全量比对 ──
    banner("d. CRC 全量比对（与真机 495 个厂商模块的期望 CRC）")
    if not os.path.exists(args.crc_gate):
        print("  [FAIL] 找不到 crc_gate.py: %s" % args.crc_gate)
        fails.append("crc_gate.py 缺失")
    elif not os.path.exists(args.expected):
        print("  [FAIL] 找不到 expected: %s" % args.expected)
        fails.append("expected_crc.txt 缺失")
    else:
        rc = subprocess.run([sys.executable, args.crc_gate, symvers, args.expected])
        print("  crc_gate.py 退出码: %d（0=无冲突）" % rc.returncode)
        if rc.returncode != 0:
            print()
            print("  —— 判定 ——")
            # 允许的已知例外：重跑一次并只统计非 allow 的冲突
            if args.allow:
                print("  已知允许的例外: %s" % ", ".join(args.allow))
                bad = []
                exp = []
                for line in open(args.expected, errors="replace"):
                    s = line.strip()
                    if not s or s.startswith("#"):
                        continue
                    p = s.split()
                    if len(p) == 2:
                        exp.append((p[0], int(p[1], 16) & 0xFFFFFFFF))
                have = {}
                for line in open(symvers, errors="replace"):
                    p = [x for x in line.rstrip("\n").split("\t") if x != ""]
                    if len(p) >= 2 and p[0].startswith("0x"):
                        idx = 2 if len(p) >= 5 else 1
                        if len(p) > idx:
                            have[p[idx]] = int(p[0], 16) & 0xFFFFFFFF
                for name, w in exp:
                    if name in have and have[name] != w:
                        bad.append((name, w, have[name]))
                print("  全部 CRC 冲突 %d 个:" % len(bad))
                for nm, w, g in bad:
                    tag = "ALLOW" if nm in args.allow else "FATAL"
                    print("    [%s] %-34s 期望 0x%08x 实际 0x%08x" % (tag, nm, w, g))
                fatal = [b for b in bad if b[0] not in args.allow]
                if fatal:
                    print("  [FAIL] 存在 %d 个不可容忍的 CRC 冲突 → 厂商模块将拒绝加载 → bootloop"
                          % len(fatal))
                    fails.append("CRC 冲突 %d 个（非例外）" % len(fatal))
                else:
                    print("  [OK] 除已知例外外 CRC 冲突为 0 ✅（%d 个已知例外见上）" % len(bad))
            else:
                print("  [FAIL] crc_gate 报冲突，且未声明任何允许例外")
                fails.append("CRC 冲突（未声明例外）")
        else:
            print("  [OK] CRC 冲突为 0 ✅")

    # ── 总结 ──
    banner("验收结论")
    if fails:
        print("  ❌ 未通过，共 %d 项:" % len(fails))
        for f in fails:
            print("     - %s" % f)
        return 1
    print("  ✅ 四项全部通过")
    print("     a. walt_rq CRC = 0xda944f6d（与真机一致）")
    print("     b. Image 里含 hmbird 符号")
    print("     c. 内嵌 config 断言通过")
    print("     d. CRC 全量比对：除已知例外外冲突为 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
