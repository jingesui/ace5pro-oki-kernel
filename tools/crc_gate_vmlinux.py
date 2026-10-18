#!/usr/bin/env python3
"""vmlinux 侧 CRC 把关：只比对「内核本体导出」的符号。

为什么只比 vmlinux 侧：
  真机 495 个厂商模块需要的 4998 个符号里，一部分由内核本体（vmlinux）导出，
  一部分由其它模块（vendor_dlkm 里的 .ko）导出。后者由厂商模块之间互相满足，
  与我们的 Image 无关；前者才是我们必须逐位对齐的部分。

  实测基线（config 正确的构建）：vmlinux 提供 3241 个，CRC 冲突 0。
  config 被污染时（如 run#16 的 -g 头文件覆盖）：冲突 2170 个。
  → 这个数字是判断「内核 ABI 是否对齐」最灵敏的单一指标。

退出码：
  0  冲突 0，且提供数达标
  1  有 CRC 冲突（模块会拒绝加载 → bootloop）
  1  提供数低于下限（config 偏离真机太多，构建无意义）
  2  用法错误 / 文件损坏
"""
import sys

MIN_EXPECTED_SYMBOLS = 4000
DEFAULT_MIN_PROVIDED = 3000


def load_symvers(path):
    """返回 (vmlinux 导出 {符号: crc}, 全部 {符号: (crc, owner)})。

    自动识别两种布局：
      AOSP 4 列 : <crc> <symbol> <owner> <export_type>
      上游 5 列 : <crc> <owner> <symbol> <file> <export_type>
    """
    rows = []
    with open(path, errors="replace") as f:
        for line in f:
            p = [x for x in line.rstrip("\n").split("\t") if x]
            if len(p) >= 3 and p[0].startswith("0x"):
                rows.append(p)
    if not rows:
        raise SystemExit("::error::symvers 无有效行: %s" % path)

    # 按【内容】判定布局，不按列数 —— 5 列格式若 export_type 为空会退化成
    # 4 个字段，纯列数判定会误认成 AOSP 布局，导致 sym/owner 全部取错。
    # 可靠判据：AOSP 布局第 3 列固定是 "vmlinux"；上游布局第 2 列固定是
    # "vmlinux"（内核本体）或模块名。取前若干行投票。
    def guess(p):
        # p[0] 是 crc
        if len(p) >= 4 and p[2] == "vmlinux":
            return "aosp"
        if len(p) >= 3 and p[1] == "vmlinux":
            return "upstream"
        return None

    votes = {"aosp": 0, "upstream": 0}
    for r in rows[:200]:
        g = guess(r)
        if g:
            votes[g] += 1

    if votes["aosp"] == 0 and votes["upstream"] == 0:
        raise SystemExit("::error::无法判定 symvers 列布局（前 200 行里既没有 "
                         "AOSP 也没有上游特征行）: %s" % path)

    if votes["aosp"] >= votes["upstream"]:
        sym_idx, owner_idx, layout = 1, 2, "4列(AOSP)"
    else:
        sym_idx, owner_idx, layout = 2, 1, "5列(上游)"

    vml, allsym = {}, {}
    for p in rows:
        if len(p) <= max(sym_idx, owner_idx):
            continue
        try:
            crc = int(p[0], 16) & 0xFFFFFFFF
        except ValueError:
            continue
        sym, owner = p[sym_idx], p[owner_idx]
        allsym[sym] = (crc, owner)
        if owner == "vmlinux":
            vml[sym] = crc
    return vml, allsym, layout


def load_expected(path):
    exp = []
    bad = []
    with open(path, errors="replace") as f:
        for n, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            p = s.split()
            if len(p) != 2:
                bad.append((n, s[:60]))
                continue
            try:
                exp.append((p[0], int(p[1], 16) & 0xFFFFFFFF))
            except ValueError:
                bad.append((n, s[:60]))
    if bad:
        print("::error::expected 文件有 %d 行格式错误:" % len(bad))
        for n, s in bad[:10]:
            print("   第 %d 行: %s" % (n, s))
        raise SystemExit(1)
    return exp


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    min_provided = DEFAULT_MIN_PROVIDED
    for a in sys.argv[1:]:
        if a.startswith("--min-provided="):
            min_provided = int(a.split("=", 1)[1])
    if len(args) != 2:
        print("用法: crc_gate_vmlinux.py <symvers> <expected_crc.txt> [--min-provided=N]")
        return 2

    print("=== vmlinux 侧 CRC 把关 ===")
    vml, allsym, layout = load_symvers(args[0])
    exp = load_expected(args[1])
    print("  symvers 布局: %s" % layout)
    print("  解析符号总数: %d（其中 vmlinux 导出 %d）" % (len(allsym), len(vml)))

    if len(exp) < MIN_EXPECTED_SYMBOLS:
        print("::error::期望符号仅 %d 个（< %d），expected 文件可能损坏"
              % (len(exp), MIN_EXPECTED_SYMBOLS))
        return 1

    ok, bad, from_module, absent = 0, [], 0, 0
    for name, want in exp:
        if name in vml:
            if vml[name] == want:
                ok += 1
            else:
                bad.append((name, want, vml[name]))
        elif name in allsym:
            from_module += 1          # 由其它模块导出，不归我们管
        else:
            absent += 1

    provided = ok + len(bad)
    print("  期望符号总数: %d" % len(exp))
    print("  ├ vmlinux 提供 : %d（CRC 正确 %d，冲突 %d）" % (provided, ok, len(bad)))
    print("  ├ 其它模块提供 : %d（模块间互相满足，不影响 Image）" % from_module)
    print("  └ 未找到       : %d" % absent)
    print()

    if bad:
        print("CRC 冲突明细（这些会让厂商模块拒绝加载 → bootloop）:")
        for n, w, g in bad[:40]:
            print("   %-42s 期望 0x%08x  实际 0x%08x" % (n, w, g))
        if len(bad) > 40:
            print("   ... 共 %d 个" % len(bad))
        print()
        print("::error::vmlinux 侧有 %d 个符号 CRC 冲突" % len(bad))
        return 1

    if provided < min_provided:
        print("::error::vmlinux 只提供了 %d 个期望符号（下限 %d）"
              % (provided, min_provided))
        print("          说明内核配置与真机偏差过大，或 symvers 不完整。")
        return 1

    print("✅ vmlinux 侧 CRC 冲突 0，提供数 %d ≥ %d —— 原厂 vendor_dlkm 模块可加载"
          % (provided, min_provided))
    return 0


if __name__ == "__main__":
    sys.exit(main())
