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

SRC="${1:-$GITHUB_WORKSPACE/src}"
REPO_ROOT="${2:-$GITHUB_WORKSPACE/repo}"
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

apply_one() {
  local name="$1"
  echo
  echo "--- git apply --whitespace=nowarn $name ---"
  if git -C "$KERNEL" apply --whitespace=nowarn -v "$PATCH_DIR/$name" 2>&1 | tee "$LOGDIR/apply_${name}.log"; then
    echo "  [OK] $name 应用成功"
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
if [ "$PRE_SCHED_H" = "$POST_SCHED_H" ]; then echo "  [FAIL] include/linux/sched.h 内容未变化"; FAIL=1; fi
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

banner "4. 完成"
echo "  补丁: 3 个已应用并通过断言"
echo "  配置: 已注入 gki_defconfig（DEFCONFIG=gki_defconfig，perf 变体无额外 fragment）"
echo "  下一步: 构建内核"
