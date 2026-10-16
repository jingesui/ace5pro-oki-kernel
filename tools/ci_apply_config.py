#!/usr/bin/env python3
"""把配置片段安全地追加进 gki_defconfig，并做「已知坑」防护。

为什么要这个脚本而不是在 workflow 里 echo：
  1. 需要去重（重复键会让 Kconfig 用「最后一个」并可能触发 warning）
  2. 需要拒绝写入会 bootloop 的键（CFS_BANDWIDTH / CGROUP_PIDS）
  3. 需要把已知「不存在 / 依赖不满足」的键【跳过而不是写进去】
     —— 写不存在的符号到 defconfig，olddefconfig 会直接丢弃并打印
        "warning: unknown symbol"，若 CONFIG_WERROR 生效还会编译失败
  4. 需要显式关闭 TRIM_UNUSED_KSYMS（见下），并清掉随之失效的 whitelist 行

TRIM_UNUSED_KSYMS 处理（本脚本默认 --trim=off）：
  证据链：
    * run#4 内嵌 config: CONFIG_TRIM_UNUSED_KSYMS=y +
      CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw"
      （来自 perf 变体的 GKI_TRIM_NONLISTED_KMI=1 / BUILD.bazel trim_nonlisted_kmi=True
        以及 prepare_vendor.sh --notrim 默认不传）
    * run#8 实测：白名单 4998 个符号与真机 495 模块期望符号【完全一致】，
      编译期 0 误裁、CRC 0 冲突，上机仍 bootloop
      → 厂商模块还依赖未被 __versions 记录的符号（运行时 kallsyms 查找），
        裁剪它们同样致命。已永久放弃。
    * 已知能开机的参考内核内嵌 config 也是
      "# CONFIG_TRIM_UNUSED_KSYMS is not set"
  因此：
    - 在 gki_defconfig 里写 "# CONFIG_TRIM_UNUSED_KSYMS is not set"
    - 删掉 CONFIG_UNUSED_KSYMS_WHITELIST="..."（未启用 TRIM 时它是死配置）
    - workflow 侧另外传 --notrim 给 build_with_bazel.py（双保险，作用于 bazel
      目标属性 trim_nonlisted_kmi=True）
"""
import argparse
import os
import re
import sys
import tempfile

# 已知会改变结构体大小且无 padding → 厂商模块 CRC 全变 → bootloop 且无解
FORBIDDEN = {
    "CONFIG_CFS_BANDWIDTH": "会改变 struct cfs_rq/task_group 布局，官方文档警告 bootloop 且无解",
    "CONFIG_CGROUP_PIDS": "会改变 struct task_struct 布局，官方文档警告 bootloop 且无解",
}


def read_lines(path):
    with open(path, errors="replace") as f:
        return f.read().splitlines()


def existing_keys(lines):
    """返回 {CONFIG_X: 行号}，同时识别 CONFIG_X=y 与 '# CONFIG_X is not set'。"""
    found = {}
    pat = re.compile(r"^(?:#\s*)?(CONFIG_[A-Za-z0-9_]+)(?:=|\s+is not set)")
    for i, line in enumerate(lines):
        m = pat.match(line.strip())
        if m:
            found.setdefault(m.group(1), i)
    return found


def symbol_exists_in_any(kconfig_dirs, name):
    """在多个 Kconfig 树里查找（任一命中即算存在）。

    perf 变体的内核配置来自 common 树，但部分补丁（如 ADIOS）的 Kconfig
    定义在 msm-kernel 树 —— 必须两棵树都查，否则会假失败。
    """
    for d in kconfig_dirs:
        if d and os.path.isdir(d) and symbol_exists_in_kconfig(d, name):
            return True
    return False


def symbol_exists_in_kconfig(kconfig_dir, name):
    """在整个 Kconfig 树里找 'config <NAME>' 或 'menuconfig <NAME>'。

    注意必须同时认 【menuconfig】 —— 例如 CONFIG_IP_SET 在本树是
    net/netfilter/ipset/Kconfig:2 的
        menuconfig IP_SET
    若只匹配 'config'，会把 IP_SET 这类符号误判为"不存在"，
    从而在 CI 里假失败（这是实测踩到过的坑）。

    文件名必须用 startswith("Kconfig")，不能只判 == "Kconfig"。
    内核里有大量 Kconfig.<suffix> 形式的文件，例如
    block/Kconfig.iosched（MQ_IOSCHED_ADIOS 就定义在这里）、
    kernel/Kconfig.preempt、Kconfig.ext 等。
    实测踩过：若只判 == "Kconfig" 会漏掉 Kconfig.iosched，
    导致 MQ_IOSCHED_ADIOS 被判为"不存在"而假失败。

    找不到 = 符号名确实不存在（或依赖它的菜单不可见）。写进 defconfig 只会被
    olddefconfig 丢弃并告警，故直接跳过更干净、也避免误导。
    """
    key = name[len("CONFIG_"):]
    pat = re.compile(r"^\s*(?:menu)?config\s+" + re.escape(key) + r"\s*$")
    for root, dirs, files in os.walk(kconfig_dir):
        # 跳过 .git / 输出目录，避免无谓遍历
        dirs[:] = [d for d in dirs if d not in (".git", "out", "bazel-bin", "bazel-out")]
        for fn in files:
            if not fn.startswith("Kconfig"):
                continue
            try:
                with open(os.path.join(root, fn), errors="replace") as f:
                    for line in f:
                        if pat.match(line):
                            return True
            except OSError:
                continue
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--defconfig", required=True)
    ap.add_argument("--fragment", required=True)
    ap.add_argument("--kconfig-dir", default=None, action="append",
                    help="Kconfig 树根（可传多次，用于校验符号是否存在）。"
                         "CI 里必须同时传 kernel_platform/common 与 "
                         "kernel_platform/msm-kernel —— 因为 perf 变体的内核配置来自 "
                         "common 树（base_kernel=//common:kernel_aarch64），而 ADIOS 等"
                         "补丁的 Kconfig 定义在 msm-kernel 树（block/Kconfig.iosched）。"
                         "本地精简快照可省略，省略时跳过存在性校验")
    ap.add_argument("--require-all", action="store_true",
                    help="任一符号缺失/校验不通过即失败（默认开启）")
    ap.add_argument("--allow-missing", action="store_true",
                    help="允许符号在 Kconfig 里找不到（仅本地精简快照用；CI 不要开）")
    ap.add_argument("--verify", help="校验目标文件（默认同 --defconfig）")
    ap.add_argument("--trim", choices=["off", "on"], default="off",
                    help="off = 显式关闭 CONFIG_TRIM_UNUSED_KSYMS（默认，见文件头说明）")
    args = ap.parse_args()

    frag = []
    for raw in read_lines(args.fragment):
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        if "=" not in s:
            print("::warning::片段里有非 key=value 行，已跳过: %s" % s)
            continue
        frag.append((s.split("=", 1)[0], s))

    if not frag:
        print("::error::配置片段为空: %s" % args.fragment)
        return 1

    lines = read_lines(args.defconfig)
    have = existing_keys(lines)

    kdirs = [d for d in (args.kconfig_dir or []) if d and os.path.isdir(d)]
    have_kconfig_tree = bool(kdirs)
    if have_kconfig_tree and not args.allow_missing:
        print("  Kconfig 存在性校验: 开启（%s）" % " + ".join(kdirs))
    else:
        print("  Kconfig 存在性校验: %s"
              % ("【关闭】未提供 Kconfig 树，无法区分『符号不存在』和『快照不全』"
                 if not kdirs else
                 "【关闭】--allow-missing（仅限本地精简快照）"))

    print("=== 注入配置项 ===")
    print("  目标 defconfig: %s (%d 行)" % (args.defconfig, len(lines)))
    print("  片段条目数    : %d" % len(frag))
    print()

    to_append = []
    skipped_unknown = []
    replaced = []
    for key, line in frag:
        if key in FORBIDDEN:
            print("::error::片段试图写入禁止项 %s（%s）" % (key, FORBIDDEN[key]))
            return 1
        # 符号存在性校验：不存在则跳过（否则 olddefconfig 丢弃 + 告警）
        if have_kconfig_tree and not args.allow_missing:
            if not symbol_exists_in_any(kdirs, key):
                skipped_unknown.append(key)
                continue
        if key in have:
            cur = lines[have[key]].strip()
            if cur == line:
                print("  [=] %-34s 已是目标值，无需改动" % line)
            else:
                replaced.append((have[key], key, cur, line))
                print("  [~] %-34s 覆盖原值: %s" % (line, cur))
        else:
            to_append.append(line)
            print("  [+] %-34s 追加" % line)

    for idx, key, cur, new in replaced:
        lines[idx] = new

    if skipped_unknown:
        print()
        print("  [skip] 以下符号在本树 Kconfig 中不存在，已跳过（不写入 defconfig）:")
        for k in skipped_unknown:
            print("         - %s" % k)
        if not args.allow_missing:
            print("::error::有 %d 个片段项在 Kconfig 里找不到 —— 符号名写错或依赖不满足。"
                  % len(skipped_unknown))
            print("         写进 defconfig 只会被 olddefconfig 丢弃（并且若 CONFIG_WERROR")
            print("         生效会直接编译失败），因此这里 fail-fast。")
            print("         若确认是精简快照导致，请加 --allow-missing（CI 不要加）。")
            return 1

    # ── TRIM_UNUSED_KSYMS ──
    # ⚠️ run#13 实测：当 --defconfig 是 kleaf fragment 时，【不要】写这一行。
    #   kleaf 的 fragment 检查器会拿它与最终 .config 逐字比对，而构建步骤的
    #   --notrim 让 kleaf 的 _config_trim 在 disable 分支直接 return []，
    #   .config 里根本不会出现 "# CONFIG_TRIM_UNUSED_KSYMS is not set" 这一行
    #   → 报错 CONFIG_TRIM_UNUSED_KSYMS: actual ''。
    #   --notrim 本身就是保证，fragment 里写反而 mismatch。
    print()
    if args.trim == "off" and not args.allow_missing:
        tkey = "CONFIG_TRIM_UNUSED_KSYMS"
        tline = "# CONFIG_TRIM_UNUSED_KSYMS is not set"
        if tkey in have:
            old = lines[have[tkey]].strip()
            lines[have[tkey]] = tline
            print("  [~] %-34s 覆盖原值: %s" % (tline, old))
        else:
            to_append.append(tline)
            print("  [+] %-34s 追加" % tline)
        # 未启用 TRIM 时 whitelist 是死配置，清掉以免误导
        wkey = "CONFIG_UNUSED_KSYMS_WHITELIST"
        if wkey in have:
            print("  [-] %s 已移除（未启用 TRIM 时为死配置）: %s"
                  % (wkey, lines[have[wkey]].strip()))
            del lines[have[wkey]]
            have = existing_keys(lines)  # 行号已错位，重建

    if to_append:
        lines.append("")
        lines.append("# ── CI 注入（风驰/Droidspaces/ADIOS 对齐真机）──")
        lines.extend(to_append)

    with tempfile.NamedTemporaryFile("w", delete=False, dir=os.path.dirname(args.defconfig)) as tf:
        tf.write("\n".join(lines) + "\n")
        tmp = tf.name
    os.replace(tmp, args.defconfig)
    print()
    print("  已写入: %s (%d 个配置项，文件共 %d 行)"
          % (args.defconfig, len(to_append), len(lines)))

    # ── 校验 ──
    verify = args.verify or args.defconfig
    vlines = read_lines(verify)
    vkeys = existing_keys(vlines)
    bad = []
    print("=== 注入校验 ===")
    for key, line in frag:
        if key in FORBIDDEN:
            continue
        if key in skipped_unknown:
            # 明确跳过并已在上方告警/失败，这里不重复计错
            continue
        if key not in vkeys:
            bad.append("%s 未出现在 %s" % (key, verify))
            continue
        got = vlines[vkeys[key]].strip()
        if got != line:
            bad.append("%s 期望 %r 实际 %r" % (key, line, got))
    if args.trim == "off" and not args.allow_missing:
        got = vlines[vkeys["CONFIG_TRIM_UNUSED_KSYMS"]].strip() if "CONFIG_TRIM_UNUSED_KSYMS" in vkeys else "<缺失>"
        if got != "# CONFIG_TRIM_UNUSED_KSYMS is not set":
            bad.append("CONFIG_TRIM_UNUSED_KSYMS 期望未启用，实际 %r" % got)
    for key in FORBIDDEN:
        if key in vkeys and "is not set" not in vlines[vkeys[key]]:
            bad.append("禁止项 %s 被打开了！" % key)
    if bad:
        print("::error::配置注入校验失败:")
        for b in bad:
            print("   - %s" % b)
        return 1
    print("  校验通过 ✅（%d 项全部生效，禁止项未被打开）" % len(frag))
    return 0


if __name__ == "__main__":
    sys.exit(main())
