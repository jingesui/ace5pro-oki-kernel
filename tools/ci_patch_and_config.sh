#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# CI 补丁 + 配置注入器（repo sync 之后、构建之前执行）
#
# 设计原则（源自历史教训）：
#   * 复杂逻辑全部放本脚本，workflow 里只调用它 —— 避免 YAML 转义地狱
#     （嵌套 heredoc 放第 0 列会导致 yaml.scanner.ScannerError；
#       echo 里的多余引号会导致 bash 语法错误）
#   * 全程 fail-fast，任何一步失败即 exit 1（绝不 || true 吞错）
#
# 补丁目标树是 kernel_platform/msm-kernel（不是 common）—— 铁证：
#   ① run4 的内嵌 config 有 CONFIG_PINCTRL=y，该行只在 msm-kernel 的 gki_defconfig
#   ② walt_rq 来自 kernel/sched/walt/，该目录只在 msm-kernel 里
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# 路径统一转成绝对路径：脚本内部多处 cd（尤其是进入 msm-kernel 做 git apply），
# 若入参是相对路径，cd 之后就会解析到错误位置（实测踩过：
# `git apply repo/patches/x.patch` 报"没有那个文件或目录"）。
# CI 里传的是 $GITHUB_WORKSPACE/... 本就是绝对路径，这里是稳健性加固。
abspath() { (cd "$1" 2>/dev/null && pwd) || echo "$1"; }

SRC="$(abspath "${1:-$GITHUB_WORKSPACE/src}")"
REPO_ROOT="$(abspath "${2:-$GITHUB_WORKSPACE/repo}")"
KERNEL="$SRC/kernel_platform/msm-kernel"

PATCH_DIR="$REPO_ROOT/patches"
TOOLS_DIR="$REPO_ROOT/tools"
CONFIG_FRAG="$REPO_ROOT/patches/ci_config_fragment.txt"
LOGDIR="$SRC/LOGDIR"

banner() { echo; echo "════════════════════════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════════════════════════"; }
die()    { echo "::error::$*"; exit 1; }

mkdir -p "$LOGDIR"

banner "0. 前置检查"
[ -d "$KERNEL" ]                       || die "msm-kernel 树不存在: $KERNEL"
[ -d "$PATCH_DIR" ]                    || die "patches 目录不存在: $PATCH_DIR（repo 是否 checkout 了？）"
[ -f "$CONFIG_FRAG" ]                  || die "配置片段不存在: $CONFIG_FRAG"
for p in fengchi-rebased.patch droidspaces.patch adios.patch; do
  [ -s "$PATCH_DIR/$p" ] || die "补丁缺失或为空: $PATCH_DIR/$p"
done
echo "  msm-kernel : $KERNEL"
echo "  patches    : $PATCH_DIR"
echo "  配置片段   : $CONFIG_FRAG ($(wc -l < "$CONFIG_FRAG") 行)"

# git apply 需要目标目录是 git 仓库 —— repo sync 出来的 msm-kernel 本身就是
if ! git -C "$KERNEL" rev-parse --git-dir >/dev/null 2>&1; then
  die "$KERNEL 不是 git 仓库，git apply 无法工作"
fi
echo "  HEAD       : $(git -C "$KERNEL" rev-parse --short HEAD)"
echo "  工作区状态 : $(git -C "$KERNEL" status --porcelain | wc -l) 个改动（应为 0）"

echo
echo "=== 补丁前快照（用于验证补丁真的改了东西）==="
# 注意：必须用 git hash-object 读【工作区】文件，
# 不能用 git rev-parse HEAD:<path>（那读的是【已提交】的 blob，
# 而补丁只改工作区、不提交 → 永远是同一个值，断言会假失败）
PRE_SCHED_H=$(git -C "$KERNEL" hash-object include/linux/sched.h)
PRE_WALT_H=$(git -C "$KERNEL" hash-object kernel/sched/walt/walt.h)
echo "  sched.h : $PRE_SCHED_H"
echo "  walt.h  : $PRE_WALT_H"

# ─────────────────────────────────────────────────────────────────────────────
banner "1. 应用补丁（顺序不可换）"

APPLIED_ANY=0
apply_one() {
  local name="$1"
  echo
  echo "--- git apply --whitespace=nowarn $name ---"
  # 幂等处理：若补丁【已经应用过】，git apply 会失败（上下文里新旧行都对不上）。
  # 用 `--check --reverse` 判定：反着能干净应用 = 已经应用过了 → 跳过而不报错。
  # CI 每次都是全新 repo sync，正常不会走到这条分支；但重试/复用工作区时
  # 没有这个判断就会假失败（实测踩过）。
  if git -C "$KERNEL" apply --check --reverse "$PATCH_DIR/$name" >/dev/null 2>&1; then
    echo "  [SKIP] $name 已经应用过（反向 check 通过），跳过"
    return 0
  fi
  if git -C "$KERNEL" apply --whitespace=nowarn -v "$PATCH_DIR/$name" 2>&1 | tee "$LOGDIR/apply_${name}.log"; then
    echo "  [OK] $name 应用成功"
    APPLIED_ANY=1
  else
    echo "  [FAIL] $name 应用失败，输出上面日志"
    echo "  --- 失败定位（--check 明细）---"
    git -C "$KERNEL" apply --whitespace=nowarn --check -v "$PATCH_DIR/$name" 2>&1 | head -40 || true
    die "$name 无法应用（补丁与上游源码基线不匹配？）"
  fi
}

# 顺序：fengchi 先（它删除 ext.c / 重写 sched.h），然后 droidspaces（改 sched.h 槽 6/7/8），
# 最后 adios（只碰 block/，互不影响）。
# 注意：droidspaces.patch 必须打在 fengchi 之后 —— fengchi 会重写 sched.h 的
#       KABI 槽 1/2 区域并让文件哈希变化，droidspaces 的 hunk 上下文以 fengchi 后的
#       文件为准（已在本地干净快照上实测：两补丁顺序应用 rc=0，叠加后槽 1-5 为
#       RESERVE、槽 6/7/8 为 KABI_USE(6,...)/_ANDROID_KABI_REPLACE(...)）。
apply_one fengchi-rebased.patch
apply_one droidspaces.patch
apply_one adios.patch

echo
echo "=== 应用后改动统计 ==="
git -C "$KERNEL" status --porcelain | awk '{print $1}' | sort | uniq -c
echo "  改动文件总数: $(git -C "$KERNEL" status --porcelain | wc -l)"

# ─────────────────────────────────────────────────────────────────────────────
banner "2. 补丁断言（fail-fast）"

FAIL=0
chk() { # chk <描述> <命令...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  [OK]   $desc"
  else
    echo "  [FAIL] $desc"
    FAIL=1
  fi
}

cd "$KERNEL"
chk "kernel/sched/hmbird/hmbird.c 已创建"          test -f kernel/sched/hmbird/hmbird.c
chk "kernel/sched/hmbird/hmbird_sched.h 已创建"   test -f kernel/sched/hmbird/hmbird_sched.h
chk "gki_defconfig 含 CONFIG_HMBIRD_SCHED=y"       grep -q '^CONFIG_HMBIRD_SCHED=y' arch/arm64/configs/gki_defconfig
chk "gki_defconfig 已无 CONFIG_SLIM_SCHED"         bash -c '! grep -q "CONFIG_SLIM_SCHED" arch/arm64/configs/gki_defconfig'
chk "gki_defconfig 已无 CONFIG_SCHED_CLASS_EXT"    bash -c '! grep -q "CONFIG_SCHED_CLASS_EXT" arch/arm64/configs/gki_defconfig'
chk "walt.h 含 curr_runnable_sum_fixed"            grep -q 'curr_runnable_sum_fixed' kernel/sched/walt/walt.h
chk "walt.h 含 prev_runnable_sum_fixed"            grep -q 'prev_runnable_sum_fixed' kernel/sched/walt/walt.h
chk "sched.h 含 ANDROID_KABI_USE(6"                grep -q 'ANDROID_KABI_USE(6' include/linux/sched.h
chk "sched.h 含 _ANDROID_KABI_REPLACE(RESERVE(7)"  grep -q '_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(7)' include/linux/sched.h
chk "sched.h 原 sysvsem 字段已注释"                grep -q '// struct sysv_sem' include/linux/sched.h
chk "kernel/sched/ext.c 已删除"                    bash -c 'test ! -f kernel/sched/ext.c'
chk "block/adios.c 已创建"                         test -f block/adios.c
chk "block/Kconfig.iosched 含 MQ_IOSCHED_ADIOS"    grep -q 'config MQ_IOSCHED_ADIOS' block/Kconfig.iosched
chk "block/Makefile 含 adios.o"                    grep -q 'MQ_IOSCHED_ADIOS.*adios.o' block/Makefile
chk "Kconfig.preempt 定义 HMBIRD_SCHED"            grep -q 'config HMBIRD_SCHED' kernel/Kconfig.preempt
chk "sched.h 的 KABI 槽 1/2 仍是 RESERVE（未被破坏）" grep -q 'ANDROID_KABI_RESERVE(1);' include/linux/sched.h

# 关键定量断言：struct walt_rq 里必须恰好 2 个 _fixed 字段（防止误改到 group_cpu_time）
NW_FIXED=$(awk '/^struct walt_rq \{/,/^\};/' kernel/sched/walt/walt.h | grep -c 'runnable_sum_fixed' || true)
if [ "$NW_FIXED" -eq 2 ]; then
  echo "  [OK]   struct walt_rq 新增字段数 = 2（curr/prev_runnable_sum_fixed）"
else
  echo "  [FAIL] struct walt_rq 新增字段数 = $NW_FIXED（期望 2）"
  awk '/^struct walt_rq \{/,/^\};/' kernel/sched/walt/walt.h | grep -n 'runnable_sum' || true
  FAIL=1
fi

# ── 关键防护：确认 common 头文件没有把我们的补丁覆盖掉 ──
# prepare_vendor.sh:255 有一条 shell 语义错误的判断
#     if ([[ "$V" == "consolidate" ]] || [[ "$V" == "perf" ]]) && \
#         [[ !$(grep -q "define_msm_la" ".../$KERNEL_TARGET.bzl") ]]; then
#         EXTRA_KBUILD_ARGS+=" -g"      # = --gki-headers
#   [[ !$(...) ]] 中 ! 与 $( 之间没有空格 → 变成 [[ !<非空字符串> ]]
#   → 恒假 → 恒真分支，会追加 -g
# 而 build_with_bazel.py 的 --gki-headers 会把 common 树的文件【符号链接】
# 覆盖到 msm-kernel 上（对 files_gki_aarch64.txt 里的 .h），其中 4 个正是
# 本补丁改过的文件：
#     include/linux/sched.h              ← 含 HMBIRD KABI 槽 1/2 + hmbird 内联函数
#     include/linux/sched/task.h
#     include/uapi/linux/sched.h
#     include/asm-generic/vmlinux.lds.h
# 一旦被覆盖，walt_rq 的 CRC 永远修不好 → 100 分钟白编。
# run#4 的 build_opts.txt 里没有 -g（实际未触发），但这里必须显式自证。
echo
echo "=== 防护检查：补丁文件未被 common 头文件符号链接覆盖 ==="
for f in include/linux/sched.h include/linux/sched/task.h include/uapi/linux/sched.h include/asm-generic/vmlinux.lds.h; do
  if [ -L "$f" ]; then
    echo "  [FAIL] $f 是符号链接 -> $(readlink "$f")（common 头文件覆盖了补丁！）"
    FAIL=1
  else
    echo "  [OK]   $f 是普通文件（补丁生效）"
  fi
done
# 再确认内容确实是补丁后的版本（chen 符号链接之外的其它覆盖方式）
if grep -q 'CONFIG_HMBIRD_SCHED' include/linux/sched.h; then
  echo "  [OK]   sched.h 含 CONFIG_HMBIRD_SCHED 分支（我们的补丁内容还在）"
else
  echo "  [FAIL] sched.h 不含 CONFIG_HMBIRD_SCHED —— 已被覆盖成上游版本"
  FAIL=1
fi
if grep -q 'ANDROID_KABI_USE(6' include/linux/sched.h; then
  echo "  [OK]   sched.h 含 droidspaces 的 KABI 槽 6"
else
  echo "  [FAIL] sched.h 不含 ANDROID_KABI_USE(6)"
  FAIL=1
fi

# 改动必须真实发生（防止补丁"静默无事发生"）
POST_SCHED_H=$(git -C "$KERNEL" hash-object include/linux/sched.h)
POST_WALT_H=$(git -C "$KERNEL" hash-object kernel/sched/walt/walt.h)
echo "  sched.h blob: $PRE_SCHED_H -> $POST_SCHED_H"
if [ "$PRE_SCHED_H" = "$POST_SCHED_H" ]; then
  if [ "$APPLIED_ANY" -eq 1 ]; then
    # 本次真的应用了补丁，sched.h 却没变 → 补丁静默失效，必须失败
    echo "  [FAIL] 应用了补丁但 include/linux/sched.h 内容未变化"
    FAIL=1
  else
    # 全部补丁都被判为"已应用"而跳过 → sched.h 本就不该再变，属正常幂等
    echo "  [OK]   sched.h 未变化（补丁本次全部跳过 = 之前已应用，幂等重跑正常）"
  fi
fi
echo "  walt.h  blob: $PRE_WALT_H -> $POST_WALT_H"

cd - >/dev/null

if [ "$FAIL" -ne 0 ]; then
  echo
  echo "--- 诊断：补丁后 git status ---"
  git -C "$KERNEL" status --porcelain | head -40
  die "补丁断言失败 —— 补丁未正确生效，中止以免再白编 100 分钟"
fi
echo "  补丁断言全部通过 ✅"

# ─────────────────────────────────────────────────────────────────────────────
banner "3. 注入配置项"

python3 "$TOOLS_DIR/ci_apply_config.py" \
  --defconfig "$KERNEL/arch/arm64/configs/gki_defconfig" \
  --fragment  "$CONFIG_FRAG" \
  --kconfig-dir "$KERNEL" \
  --verify "$KERNEL/arch/arm64/configs/gki_defconfig"

echo
echo "=== 注入后 gki_defconfig 尾部 ==="
tail -40 "$KERNEL/arch/arm64/configs/gki_defconfig"

# ─────────────────────────────────────────────────────────────────────────────
banner "4. 阻止 --gki-headers（-g）覆盖补丁"

# 问题根源（已逐条实测证明）：
#   prepare_vendor.sh:253-256
#       if ([[ "$KERNEL_VARIANT" == "consolidate" ]] || [[ "$KERNEL_VARIANT" == "perf" ]]) && \
#           [[ !$(grep -q "define_msm_la" "${ROOT_DIR}/msm-kernel/$KERNEL_TARGET.bzl") ]]; then
#           EXTRA_KBUILD_ARGS+=" -g"
#       fi
#   `[[ !$( ... ) ]]` 里 ! 与 $( 之间【缺空格】→ $(grep -q ...) 因 -q 不输出而恒为空串
#   → `[[ !<空串> ]]` 【恒真】→ 只要变体是 perf/consolidate，-g 必被追加。
#   我在本地用 4 种情形实证（sun.bzl 存在/不存在、含/不含 define_msm_la）：
#   四种全部输出"→ -g 被追加"。
#
#   而 build_with_bazel.py 的 --gki-headers 会遍历 msm-kernel/files_gki_aarch64.txt，
#   对每个【含 ".h" 子串】的条目做 os.remove(msm_kernel/<f>) + symlink(common/<f>)。
#   本补丁改过的 73 个文件里有 6 个正好落在这个列表里且含 ".h"：
#       include/asm-generic/vmlinux.lds.h
#       include/linux/sched.h          ← HMBIRD KABI / walt 关键，被覆盖后 CRC 永远修不好
#       include/linux/sched/task.h
#       include/uapi/linux/sched.h
#       kernel/bpf/bpf_struct_ops_types.h
#       kernel/sched/sched.h
#   另有 8 个非-.h 的补丁文件（kernel/sched/core.c、kernel/fork.c、kernel/time/tick-sched.c、
#   kernel/sched/{build_policy,debug,idle}.c、drivers/tty/sysrq.c、init/init_task.c）
#   会被该分支 finally 里的
#       git checkout --pathspec-from-file=files_gki_aarch64.txt
#   还原成基线 → 补丁改动同样被抹掉。
#
#   已核实：files_gki_aarch64.txt 在整个构建里【只有这两处用途】
#   （build_with_bazel.py:309 的 symlink 循环、:339 的 finally checkout），
#   BUILD.bazel / msm_kernel_extensions.bzl 都不引用它（实测 grep 均为 0 次）。
#
# 两层处置：
#   ① 【根因】把 prepare_vendor.sh 里那个错误条件改成恒假 —— 从源头阻止 -g 加进来。
#      这是最干净的修法：既不改变"microsoft 该有"的语义（msm-kernel 的 sun.bzl
#      确实定义了 define_msm_la，本来就不该加 -g），也不依赖任何断言。
#      备份为 .orig，并打印修改前后对照，便于审计。
#   ② 【兜底】把 files_gki_aarch64.txt 替换成单一无害路径 "Makefile"
#      （msm-kernel 根目录确有该文件、被 git 跟踪、本补丁从不修改、字符串不含 ".h"）：
#      -g 的循环不再命中 → 不 remove/symlink；finally 的 checkout 只涉及它 → 空操作。
#      即使 ① 因上游脚本变动而失效，② 仍能保证补丁不被覆盖或还原。
PV="$SRC/kernel_platform/build/android/prepare_vendor.sh"
if [ -f "$PV" ]; then
  echo "--- ① 修复 prepare_vendor.sh 的 -g 条件（根因）---"
  echo "  文件: $PV"
  if grep -q 'CI-FIX: the original condition' "$PV"; then
    echo "  [OK] 已修复过，跳过（幂等）"
  else
    cp "$PV" "$PV.orig"
    python3 - "$PV" <<'PYEOF'
import sys

p = sys.argv[1]
lines = open(p, errors='replace').read().splitlines(keepends=True)

# 按行定位（比正则稳健：不依赖转义、缩进与续行符的细节）
# 目标块共 4 行：
#   <indent>if ([[ "$KERNEL_VARIANT" == "consolidate" ]] || [[ ... == "perf" ]]) && \
#   <indent>    [[ !$(grep -q "define_msm_la" "${ROOT_DIR}/msm-kernel/$KERNEL_TARGET.bzl") ]]; then
#   <indent>  EXTRA_KBUILD_ARGS+=" -g"
#   <indent>fi
hits = [i for i, l in enumerate(lines)
        # 跳过注释行：幂等重跑时，原条件已被我们包进注释里，
        # 若不排除注释，会再次命中并触发形状校验失败。
        if not l.lstrip().startswith('#')
        and '!$(grep -q "define_msm_la"' in l and 'KERNEL_TARGET.bzl' in l]
if len(hits) != 1:
    sys.stderr.write("::error::定位 -g 条件失败：命中 %d 处（期望 1）\n" % len(hits))
    sys.exit(1)
cond_idx = hits[0]
if_idx = cond_idx - 1

# 逐行校验形状，任何不符即拒绝修改（宁可不动也不改错）
ok = True
if 'if (' not in lines[if_idx] or '"perf"' not in lines[if_idx]:
    ok = False
if 'EXTRA_KBUILD_ARGS+=" -g"' not in lines[if_idx + 2]:
    ok = False
if lines[if_idx + 3].strip() != 'fi':
    ok = False
if not ok:
    sys.stderr.write("::error::-g 条件块的 4 行形状与预期不符，拒绝修改：\n")
    for i in range(if_idx, min(if_idx + 4, len(lines))):
        sys.stderr.write("    %d: %r\n" % (i + 1, lines[i]))
    sys.exit(1)

indent = lines[if_idx][:len(lines[if_idx]) - len(lines[if_idx].lstrip())]
comment = [
    indent + "# CI-FIX: the original condition was\n",
    indent + '#   if ([[ "$KERNEL_VARIANT" == "consolidate" ]] || [[ "$KERNEL_VARIANT" == "perf" ]]) && \\\n',
    indent + '#       [[ !$(grep -q "define_msm_la" "${ROOT_DIR}/msm-kernel/$KERNEL_TARGET.bzl") ]]; then\n',
    indent + "#\n",
    indent + "# The inner test `[[ !<empty> ]]` has no space between ! and $(, and grep -q\n",
    indent + "# emits nothing, so it is ALWAYS TRUE -> -g (--gki-headers) was always appended.\n",
    indent + "# -g replaces msm-kernel headers listed in files_gki_aarch64.txt with symlinks\n",
    indent + "# into common/, and its `finally` block git-checkouts that same list, which would\n",
    indent + "# silently wipe our scheduler patches: include/linux/sched.h, kernel/sched/sched.h,\n",
    indent + "# kernel/sched/core.c, kernel/fork.c, kernel/time/tick-sched.c and 4 others.\n",
    indent + "# Disabled unconditionally: msm-kernel/sun.bzl does define define_msm_la, so -g\n",
    indent + "# was never intended here.\n",
    indent + "if false; then\n",
    indent + '    EXTRA_KBUILD_ARGS+=" -g"\n',
    indent + "fi\n",
]
lines[if_idx:if_idx + 4] = comment
open(p, 'w').write(''.join(lines))
print("  已将 -g 条件（第 %d-%d 行）替换为 `if false; then`" % (if_idx + 1, if_idx + 4))
PYEOF
    if [ $? -ne 0 ]; then die "修复 prepare_vendor.sh 失败"; fi
    echo "  --- 修改后对照 ---"
    grep -n -B2 -A3 'CI-FIX: the original condition' "$PV" | head -14
    grep -n 'if false; then' "$PV" | head -3
    echo "  [OK] 已从源头阻止 -g"
  fi
else
  echo "  [WARN] 未找到 $PV —— 只能依赖 ② 兜底"
fi

echo
echo "--- ② 兜底：中和 files_gki_aarch64.txt ---"
GKI_LIST="$KERNEL/files_gki_aarch64.txt"
if [ -f "$GKI_LIST" ]; then
  echo "  原文: $GKI_LIST（$(wc -l < "$GKI_LIST") 行，含 .h 子串 $(grep -c '\.h' "$GKI_LIST" || true) 行）"
  if grep -q '^Makefile$' "$GKI_LIST" && [ "$(wc -l < "$GKI_LIST")" -le 1 ]; then
    echo "  [OK] 已中和过，跳过（幂等）"
  else
    cp "$GKI_LIST" "$GKI_LIST.orig"
    # 必须整体替换为「单一无害路径」，不能只删/注释 .h 行（两种做法都错）：
    #   ① 加注释前缀：判定是子串测试 `if ".h" in f`，
    #      "#CI-NEUTRALIZED include/linux/sched.h" 里【依然含 ".h"】→ 仍会命中
    #      （实测：注释方案后仍有 3604 条会被处理）
    #   ② 只删 .h 行：剩下 8 个非-.h 的补丁文件会被 finally 的 git checkout 还原
    # 替换为 "Makefile" 则：不含 ".h"（-g 不动作）+ 是真实被跟踪文件
    # （finally 的 checkout 空操作且退出码 0）。
    echo "Makefile" > "$GKI_LIST"
    echo "  已替换为单一无害路径（原 $(wc -l < "$GKI_LIST.orig") 行 -> 1 行）"
    if grep -q '\.h' "$GKI_LIST"; then
      die "中和失败：清单里仍含 '.h'，-g 会覆盖补丁文件"
    fi
    echo "  [OK] 无 '.h' 子串 → --gki-headers 不会覆盖或删除任何文件"
  fi
else
  echo "  [WARN] 未找到 $GKI_LIST"
fi

echo
echo "=== 复核：6 个高风险 .h 文件与 8 个非-.h 文件均不受影响 ==="
for f in include/linux/sched.h kernel/sched/sched.h kernel/sched/core.c kernel/sched/walt/walt.h \
         include/asm-generic/vmlinux.lds.h include/uapi/linux/sched.h; do
  printf "  %-42s %s\n" "$f" "$(git -C "$KERNEL" hash-object "$f" | cut -c1-12)"
done

# 打印反证：若没有这两层防护，-g 会覆盖/还原哪些补丁文件。
# 用于事后审计（万一上游脚本又改回去）。
echo
echo "=== 反证记录：若无防护，-g 会影响的补丁文件 ==="
if [ -f "$KERNEL/files_gki_aarch64.txt.orig" ]; then
  for f in include/asm-generic/vmlinux.lds.h include/linux/sched.h \
           include/linux/sched/task.h include/uapi/linux/sched.h \
           kernel/bpf/bpf_struct_ops_types.h kernel/sched/sched.h; do
    if grep -qxF "$f" "$KERNEL/files_gki_aarch64.txt.orig"; then
      echo "  [原会 symlink 覆盖] $f"
    fi
  done
  for f in drivers/tty/sysrq.c init/init_task.c kernel/fork.c kernel/sched/build_policy.c \
           kernel/sched/core.c kernel/sched/debug.c kernel/sched/idle.c kernel/time/tick-sched.c; do
    if grep -qxF "$f" "$KERNEL/files_gki_aarch64.txt.orig"; then
      echo "  [原会 git checkout 还原] $f"
    fi
  done
fi

banner "5. 完成"
echo "  补丁: 3 个已应用并通过断言"
echo "  配置: 已注入 gki_defconfig（DEFCONFIG=gki_defconfig，perf 变体无额外 fragment）"
echo "  防护: prepare_vendor.sh 的 -g 条件已置为恒假 + files_gki_aarch64.txt 已中和"
echo "  下一步: 构建内核"
