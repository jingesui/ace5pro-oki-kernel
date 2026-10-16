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
for p in fengchi-rebased.patch droidspaces.patch adios.patch hmbird-sa-common-scx.patch; do
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
echo
echo "════════════════════════════════════════════════════════════"
echo "  1b. 应用 vendor 侧补丁（给 vendor 版 sa_common_struct.h 补 scx 成员）"
echo "════════════════════════════════════════════════════════════"
# 为什么需要这个补丁（run#6 实测根因）：
#   kernel/oplus_cpu 是【符号链接】→ ../../../vendor/oplus/kernel/cpu
#   所以编译的是 vendor/oplus/kernel/cpu/sched/sched_assist/sa_common.c，
#   它 #include "sa_common.h"（引号形式 → 先在包含者所在目录找）
#     → vendor/.../sa_common.h:24  #include "sa_common_struct.h"（同样引号形式）
#       → 命中【同目录的 vendor 版】sa_common_struct.h
#   而 vendor 版（4527 B）里的 struct oplus_task_struct 【没有 scx 成员】，
#   补丁把 scx 放在了 include/linux/sched/sa_common_struct.h（全树无人以
#   尖括号形式 include 它 → 从未参与编译）；且两者 include guard 同名
#   (_OPLUS_SA_COMMON_STRUCT_H_)，即便被 include 也会被先到的 vendor 版挡住。
#   而 vendor sa_common.c:1633 在 #ifdef CONFIG_HMBIRD_SCHED 里用了 18 处
#   ots->scx.* → run#6 报 "no member named 'scx' in 'struct oplus_task_struct'"。
#
# 修法：把 scx 相关的类型定义 + 成员加进【vendor 版】（与补丁版内容逐行一致，
#       已用 diff 校验），沿用 vendor 版"守卫被注释掉 = 无条件生效"的既有风格
#       （该文件头部自述：IS_ENABLED 在 OKI 里不生效，故守卫都被注释）。
# 注意：该补丁作用于【仓库根】$SRC（vendor/ 在根仓库里），不是 msm-kernel 树。
VENDOR_PATCH="$PATCH_DIR/hmbird-sa-common-scx.patch"
VENDOR_FILE="$SRC/vendor/oplus/kernel/cpu/sched/sched_assist/sa_common_struct.h"
if [ -f "$VENDOR_FILE" ]; then
  if ! git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
    # vendor/ 属于根仓库 android_kernel_modules_and_devicetree_oneplus_sm8750，
    # repo sync 后 $SRC 本身可能不是 git 仓库（根仓库的 .git 在哪取决于 manifest），
    # 因此这里不依赖 git，直接用 patch(1) 应用。
    echo "  $SRC 不是 git 仓库 → 改用 patch -p1"
    if patch -p1 -d "$SRC" --dry-run < "$VENDOR_PATCH" >/dev/null 2>&1; then
      patch -p1 -d "$SRC" < "$VENDOR_PATCH"
      echo "  [OK] hmbird-sa-common-scx.patch 应用成功（patch -p1）"
    else
      echo "  --- dry-run 明细 ---"
      patch -p1 -d "$SRC" --dry-run < "$VENDOR_PATCH" 2>&1 | head -20 || true
      die "hmbird-sa-common-scx.patch 无法应用（vendor 版 sa_common_struct.h 基线不匹配）"
    fi
  else
    if git -C "$SRC" apply --check --reverse "$VENDOR_PATCH" >/dev/null 2>&1; then
      echo "  [SKIP] 已应用过（反向 check 通过）"
    elif git -C "$SRC" apply --whitespace=nowarn -v "$VENDOR_PATCH" 2>&1 | tee "$LOGDIR/apply_vendor_scx.log"; then
      echo "  [OK] hmbird-sa-common-scx.patch 应用成功（git apply）"
    else
      echo "  --- 失败定位 ---"
      git -C "$SRC" apply --whitespace=nowarn --check -v "$VENDOR_PATCH" 2>&1 | head -30 || true
      die "hmbird-sa-common-scx.patch 无法应用"
    fi
  fi
else
  die "找不到 vendor 版 sa_common_struct.h: $VENDOR_FILE"
fi

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
chk "msm gki_defconfig 含 CONFIG_HMBIRD_SCHED=y" grep -q '^CONFIG_HMBIRD_SCHED=y' arch/arm64/configs/gki_defconfig
chk "msm gki_defconfig 已无 CONFIG_SLIM_SCHED"     bash -c '! grep -q "CONFIG_SLIM_SCHED" arch/arm64/configs/gki_defconfig'
chk "msm gki_defconfig 已无 CONFIG_SCHED_CLASS_EXT" bash -c '! grep -q "CONFIG_SCHED_CLASS_EXT" arch/arm64/configs/gki_defconfig'
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

# ── vendor 侧 sa_common_struct.h 必须含 scx 成员（run#6 实测根因）──
# kernel/oplus_cpu 是指向 vendor/oplus/kernel/cpu 的符号链接，
# 编译的 sa_common.c 走 "sa_common.h" → "sa_common_struct.h"（同目录引号包含）
# → 用的是 vendor 版。vendor 版原本没有 scx，而 sa_common.c 用了 18 处 ots->scx.*
# → run#6 报 "no member named 'scx' in 'struct oplus_task_struct'"。
# 本断言确保 vendor 侧补丁真的生效。
VENDOR_SC="$SRC/vendor/oplus/kernel/cpu/sched/sched_assist/sa_common_struct.h"
chk "vendor 版 sa_common_struct.h 含 struct scx_entity scx;" \
    grep -q 'struct scx_entity scx;' "$VENDOR_SC"
chk "vendor 版 sa_common_struct.h 含 struct scx_task_stats" \
    grep -q 'struct scx_task_stats {' "$VENDOR_SC"
chk "vendor 版 sa_common_struct.h 含 SCX_SLICE_DFL" \
    grep -q 'SCX_SLICE_DFL' "$VENDOR_SC"
# 确认没有破坏该结构体原有的对齐属性（会改变布局/CRC）
NVCA=$(grep -c '} ____cacheline_aligned;' "$VENDOR_SC" || true)
if [ "$NVCA" -eq 1 ]; then
  echo "  [OK]   struct oplus_task_struct 末尾仍是 ____cacheline_aligned（1 处，布局未破坏）"
else
  echo "  [FAIL] ____cacheline_aligned 出现 $NVCA 处（期望 1）—— 结构体布局可能被破坏"
  FAIL=1
fi

# 关键定量断言：struct walt_rq 里必须恰好 2 个 _fixed 字段（防止误改到 group_cpu_time）
NW_FIXED=$(awk '/^struct walt_rq \{/,/^\};/' kernel/sched/walt/walt.h | grep -c 'runnable_sum_fixed' || true)
if [ "$NW_FIXED" -eq 2 ]; then
  echo "  [OK]   struct walt_rq 新增字段数 = 2（curr/prev_runnable_sum_fixed）"
else
  echo "  [FAIL] struct walt_rq 新增字段数 = $NW_FIXED（期望 2）"
  awk '/^struct walt_rq \{/,/^\};/' kernel/sched/walt/walt.h | grep -n 'runnable_sum' || true
  FAIL=1
fi

# ── 关键防护：确认 include/linux/sched.h 未被 common 头文件覆盖 ──
# run#6 实测纠正：-g 是【必需】的（msm 的 fs/verity/fsverity_private.h、
# include/crypto/hash.h 都是陈旧版，需要 common 的新版覆盖），
# 唯一需要保护的是 include/linux/sched.h（6 个会被覆盖的补丁文件中
# 只有它 msm 与 common 真正不同，且它是本补丁的核心改动）。
# 第 4 步已把它从 files_gki_aarch64.txt 中精确移除 → -g 不会动它。
# 这里再自证一次（若是符号链接或内容不含 HMBIRD 分支，说明保护失效）。
echo
echo "=== 防护检查：include/linux/sched.h 未被 common 覆盖 ==="
for f in include/linux/sched.h include/linux/sched/task.h include/uapi/linux/sched.h include/asm-generic/vmlinux.lds.h; do
  if [ -L "$f" ]; then
    echo "  [FAIL] $f 是符号链接 -> $(readlink "$f")（common 头文件覆盖了补丁！）"
    FAIL=1
  else
    echo "  [OK]   $f 是普通文件"
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

# ── 配置注入：改用 kleaf 官方 --defconfig_fragment（run#12 实测修正）────────
# 历史脉络（全部实测）：
#   run#9 : 注入 msm-kernel/gki_defconfig 的 18 项全部未生效。
#           根因（msm_kernel_la.bzl 的 define_msm_la）：
#             perf 变体 base_kernel = "//common:kernel_aarch64"
#           → 内核【配置】来自 common 树，msm-kernel 只是叠加层。
#           佐证：run#9 最终 .config 里 SLIM_SCHED=y / SCHED_CLASS_EXT=y
#                 正是 common/gki_defconfig 第 13-14 行原样内容。
#   run#12: 注入 common/gki_defconfig 后，kleaf 的 savedefconfig 一致性校验失败：
#             ERROR: savedefconfig does not match common/arch/arm64/configs/gki_defconfig
#           原因：直接改 defconfig 会与 olddefconfig 后的 .config 在【排序】上不一致
#                 （diffconfig 出现 -/+ 行）→ kleaf 拒绝。
#   → 正解：用 kleaf 官方的 --defconfig_fragment 机制（官方先例：
#           prepare_vendor.sh:238  --defconfig_fragment=//msm-kernel:arch/arm64/configs/oplus_debug_defconfig）
#     fragment 走 create_merge_dot_config_cmd 合并，不触发 savedefconfig 校验。
#
# 做法三步：
#   ① 把片段写到 msm-kernel 树（label 可被 bazel 引用）
#   ② common 树保持原样（不再手改）
#   ③ 通过 EXTRA_KBUILD_ARGS 把 --defconfig_fragment 传给 bazel
#      （工作流的构建步骤会把 CI_DEFCONFIG_FRAGMENT 加进 EXTRA_KBUILD_ARGS）

COMMON_KERNEL="$SRC/kernel_platform/common"
[ -d "$COMMON_KERNEL" ] || die "common 树不存在: $COMMON_KERNEL"

# ⓪ 把 msm 专有符号的 Kconfig 声明补到 common 树
# ── run#15 实测（完整构建日志，取自 keyfiles artifact）──────────────────────
#   ERROR: @@//common:kernel_aarch64_config:
#       CONFIG_MQ_IOSCHED_ADIOS:         actual '', expected '...=y'
#       CONFIG_MQ_IOSCHED_DEFAULT_ADIOS: actual '', expected '...=y'
#       CONFIG_HMBIRD_SCHED:             actual '', expected '...=y'
#       Are they declared in Kconfig?
#
#   根因：--defconfig_fragment 是 kleaf 的【全局 flag】，同时作用于
#         //common:kernel_aarch64_config 与 //msm-kernel:sun_perf_config。
#         而这三个符号的 Kconfig 定义只在【msm-kernel 树】
#         （风驰补丁写 kernel/Kconfig.preempt；ADIOS 补丁写 block/Kconfig.iosched）
#         → common 的 config target 无法让它们生效 → kleaf 检查失败。
#
#   这也解释了 run#9 的症状（hmbird 符号 = 0）：最终 .config 来自 common，
#   而 common 的 Kconfig 缺这三个符号 → CONFIG_HMBIRD_SCHED 永远不可能为 y。
#
#   修法：只把【Kconfig 声明】补到 common 树（不补代码 —— common 里没有引用
#   这些符号的代码，所以对 common 自身是惰性的；而 msm-kernel 的代码本来就在
#   msm-kernel 树里，由另一个 config target 消费）。
patch_common_kconfig() {
  # $1=Kconfig 文件  $2=要补的声明块（多行）  $3=符号名
  local f="$1" decl="$2" sym="$3"
  if [ ! -f "$f" ]; then
    echo "  [WARN] $f 不存在，跳过"
    return
  fi
  if grep -qE "^[[:space:]]*(menu)?config[[:space:]]+$sym[[:space:]]*$" "$f"; then
    echo "  [OK]   common: $sym 已声明于 $(basename "$f")"
  else
    printf '\n%s\n' "$decl" >> "$f"
    echo "  [注入] common: $sym 声明已补入 $(basename "$f")"
  fi
}
echo "=== 第 3 步前置：把 msm 专有符号的 Kconfig 声明补到 common 树 ==="
# 声明文本【逐字对齐补丁原文】，避免类型不一致（tristate/bool 差异会影响
# olddefconfig 的取值接受度）。
patch_common_kconfig "$COMMON_KERNEL/kernel/Kconfig.preempt" \
'config HMBIRD_SCHED
	bool "hmbird Scheduling Class(base on ext scheduler)"
	help
	  CI-injected declaration only. The implementation lives in msm-kernel
	  (kernel/sched/hmbird/), which is the tree that consumes this symbol.' HMBIRD_SCHED
patch_common_kconfig "$COMMON_KERNEL/block/Kconfig.iosched" \
'config MQ_IOSCHED_ADIOS
	tristate "Adaptive Deadline I/O scheduler"
	default m
	help
	  CI-injected declaration only. The implementation (block/adios.c) lives
	  in msm-kernel, which is the tree that consumes this symbol.

config MQ_IOSCHED_DEFAULT_ADIOS
	bool "Enable ADIOS I/O scheduler as default MQ I/O scheduler"
	depends on MQ_IOSCHED_ADIOS=y
	default n
	help
	  CI-injected declaration only.' MQ_IOSCHED_ADIOS
if grep -qE "^[[:space:]]*(menu)?config[[:space:]]+MQ_IOSCHED_DEFAULT_ADIOS[[:space:]]*$" "$COMMON_KERNEL/block/Kconfig.iosched"; then
  echo "  [OK]   common: MQ_IOSCHED_DEFAULT_ADIOS 已声明"
else
  die "MQ_IOSCHED_DEFAULT_ADIOS 声明补入失败"
fi
echo

# ① 生成本轮的 fragment 文件（内容 = ci_config_fragment.txt + HMBIRD/SLIM 处理）
# ⚠️ run#13 实测：kleaf 的 fragment 解析器【不能有注释行】。
#    报错原文：
#      CONFIG_TMPFS_XATTR: actual 'CONFIG_TMPFS_XATTR=y',
#        expected 'CONFIG_TMPFS_XATTR=y
#        # ── CI ── CONFIG_TMPFS_XATTR ──' from msm-kernel/.../ci_fragments.config
#    → 它把注释行拼成了配置值的续行，导致匹配失败。
#    所以这里【只写有效配置行】，注释一律过滤掉。
# ⚠️ run#14 实测：--defconfig_fragment 是 kleaf 的【全局】flag，
#   perf 变体的 base_kernel = //common:kernel_aarch64，
#   所以 bazel 会同时构建 //common:kernel_aarch64_config 和 //msm-kernel:sun_perf_config，
#   两者都消费这个 fragment。
#   run#14 报错：//common:kernel_aarch64_config failed (Exit 1)
#   → fragment 文件必须放在 common 树，label 也指向 //common。
CI_FRAG="$COMMON_KERNEL/arch/arm64/configs/ci_fragments.config"
{
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$CONFIG_FRAG"
  echo "CONFIG_HMBIRD_SCHED=y"
  echo "# CONFIG_SLIM_SCHED is not set"
  echo "# CONFIG_SCHED_CLASS_EXT is not set"
} > "$CI_FRAG"
# ⚠️ 不要往 fragment 里写 "# CONFIG_TRIM_UNUSED_KSYMS is not set"。
#   run#13 实测报错：CONFIG_TRIM_UNUSED_KSYMS: actual ''（.config 里根本没有那一行）。
#   因为构建步骤已传 --notrim，kleaf 的 _config_trim 在 disable 分支直接 return []，
#   它不会往 .config 写这一行 → fragment 里写了反而 mismatch。--notrim 本身就是保证。
echo "  fragment 文件: $CI_FRAG ($(wc -l < "$CI_FRAG") 行, 纯配置行无注释)"

# ② Kconfig 存在性校验（双树：fragment 里的符号要么在 common 要么在 msm-kernel）
python3 "$TOOLS_DIR/ci_apply_config.py" \
  --defconfig "$CI_FRAG" \
  --fragment  "$CONFIG_FRAG" \
  --kconfig-dir "$COMMON_KERNEL" \
  --kconfig-dir "$KERNEL" \
  --verify "$CI_FRAG" --allow-missing || die "fragment 符号校验失败"

# ③ 导出给工作流构建步骤（EXTRA_KBUILD_ARGS 追加）
FRAG_LABEL="//common:arch/arm64/configs/ci_fragments.config"
echo "$FRAG_LABEL" > "$SRC/LOGDIR/ci_frag_label.txt"
echo "  [OK] fragment label: $FRAG_LABEL（工作流构建步骤会追加 --defconfig_fragment）"

# ④ 校验 common 树必须【未被我改动】（防止再次触发 savedefconfig 校验）
if [ -n "$(cd "$COMMON_KERNEL" && git status --porcelain 2>/dev/null | grep -E 'configs/gki_defconfig')" ]; then
  echo "  [WARN] common gki_defconfig 有本地改动，正在还原（避免 savedefconfig 校验失败）"
  (cd "$COMMON_KERNEL" && git checkout -- arch/arm64/configs/gki_defconfig)
fi
echo "  [OK] common gki_defconfig 保持原样（不触发 savedefconfig 校验）"

# ─────────────────────────────────────────────────────────────────────────────
banner "4. --gki-headers（-g）：保护全部 7 个会被覆盖的补丁文件"

# ── 背景（三次修正后的最终结论，run#6/run#7 实测）────────────────────────
#   prepare_vendor.sh:253-256 的条件
#       if ([[ "$KERNEL_VARIANT" == "consolidate" ]] || [[ "$KERNEL_VARIANT" == "perf" ]]) && \
#           [[ !$(grep -q "define_msm_la" "${ROOT_DIR}/msm-kernel/$KERNEL_TARGET.bzl") ]]; then
#           EXTRA_KBUILD_ARGS+=" -g"
#       fi
#   其中 `[[ !$( ... ) ]]` 缺空格 → 恒真 → perf/consolidate 下 -g 必被追加。
#
#   ★ -g 是【必需】的（不能整体禁掉）：
#     msm-kernel 的 fs/verity/fsverity_private.h 是陈旧版（4951 B, 9611eeae35），
#     缺 FS_VERITY_MAX_PENDING_DATA_BLOCKS / mb_max_msgs；
#     common 的是新版（5156 B, 0c9e302dcf）含这两个定义。
#     include/crypto/hash.h 同理（msm 36430 B vs common 38837 B）。
#     run#6 曾把 -g 整体中和 → 报
#       fs/verity/verify.c: error: use of undeclared identifier
#                          'FS_VERITY_MAX_PENDING_DATA_BLOCKS'  (×4)
#       fs/verity/verify.c: error: call to undeclared function 'crypto_shash_finup_mb'
#       fs/verity/verify.c: error: no member named 'mb_max_msgs' in 'struct fsverity_hash_alg'
#     交叉验证：run#4 成功且同样 CONFIG_FS_VERITY=y → -g 在 run#4 必然生效。
#
#   ★ -g 的危害机制（关键，与"两边内容是否相同"无关）：
#     build_with_bazel.py 的 --gki-headers 分支：
#         for f in gki_files:
#             if ".h" in f:
#                 os.remove(msm_f)              # 删除【我们打补丁后的】msm 文件
#                 os.symlink(common_f, msm_f)   # 换成 common 的【未打补丁原始版】
#     即使 msm 与 common 内容字节完全相同，被删掉的也是【补丁后版本】，
#     换成原始版 → 补丁改动被丢弃。
#     run#7 实测：kernel/sched/sched.h:3712: fatal error: 'ext.h' file not found
#       补丁对该文件 +10/-109，其中删掉了 `#include "ext.h"` 换成
#       `#ifdef CONFIG_HMBIRD_SCHED / #include "hmbird.h" / #endif`；
#       而 msm 与 common 的该文件【字节完全相同】(cbc478992cc4, 99494 B)
#       → -g 覆盖后 `#include "ext.h"` 回来，而 ext.h 已被补丁删除 → 报错。
#     同理 kernel/bpf/bpf_struct_ops_types.h 补丁删掉 4 行（含
#       `#include <linux/sched/ext.h>`），而这 4 行在 common 版里存在
#       → 覆盖后同样报错。
#
#   ★ 因此正确做法：保护【补丁改过、含 .h、且在清单里】的全部 6 个文件，
#     外加 1 个【依赖型】文件 include/linux/cpufreq.h（run#8 实测），共 7 个。
#     ── 机制型 6 个（本补丁 73 个文件里恰好这 6 个，已逐一核对 +N/-M 与 blob sha）──
#       include/asm-generic/vmlinux.lds.h    +1/-1     msm==common
#       include/linux/sched.h               +89/-11    msm≠common
#       include/linux/sched/task.h           +4/-2     msm==common
#       include/uapi/linux/sched.h           +1/-1     msm==common
#       kernel/bpf/bpf_struct_ops_types.h    +0/-4     msm==common
#       kernel/sched/sched.h               +10/-109    msm==common
#     ── 依赖型 1 个 ──
#       include/linux/cpufreq.h                        msm≠common
#       为什么（run#8 实测）：补丁新增的 kernel/sched/hmbird/hmbird.c:3717 调
#       store_scaling_governor、hmbird_sched_proc.c:210 调 show_scaling_governor，
#       这两个声明【只在 msm 版 cpufreq.h 里】（msm 1235 行含第 47-49 行三行声明，
#       common 1231 行没有）。-g 覆盖后声明消失 → 报
#         error: call to undeclared function 'show_scaling_governor'
#         error: call to undeclared function 'store_scaling_governor'
#       （run#8 的 2 个错误，正是这两条）
#     穷举依据（Lead 已完成，474 个 hmbird 外部调用 × 16 个 msm≠common 差异头
#     求交集）：只有 cpufreq.h 命中 2 个 → 不存在第 8 个。详见
#     hmbird/out/PROTECT_ANALYSIS.md（含可复跑命令）。
#     做法：从 files_gki_aarch64.txt 中精确移除这 7 行（其余 3597 行 .h 保留
#     → -g 仍为 fs/verity、crypto/hash 等做 common 覆盖）。
#     build_with_bazel.py 的 finally 用同一清单做 git checkout →
#     也不再还原这 7 个文件。
#   不再改 prepare_vendor.sh 的条件，不再整体中和清单。
#   ⚠️ 注意【不要】把 16 个 msm≠common 差异头全保护：
#     fs/verity/fsverity_private.h、include/crypto/hash.h 的 msm 版是陈旧版，
#     必须让 -g 用 common 新版，否则退回 run#6 的 25 个错误。
GKI_LIST="$KERNEL/files_gki_aarch64.txt"
PROTECT_LIST="
include/asm-generic/vmlinux.lds.h
include/linux/cpufreq.h
include/linux/sched.h
include/linux/sched/task.h
include/uapi/linux/sched.h
kernel/bpf/bpf_struct_ops_types.h
kernel/sched/sched.h
kernel/sched/core.c
kernel/sched/build_policy.c
kernel/sched/debug.c
kernel/sched/idle.c
kernel/fork.c
kernel/time/tick-sched.c
drivers/tty/sysrq.c
init/init_task.c
block/elevator.c
"
PROTECT_LIST=$(echo "$PROTECT_LIST" | grep -v '^$')
NPROT=$(echo "$PROTECT_LIST" | wc -l)
if [ -f "$GKI_LIST" ]; then
  echo "  清单: $GKI_LIST（$(wc -l < "$GKI_LIST") 行，含 '.h' 子串 $(grep -c '\.h' "$GKI_LIST" || true) 行）"
  echo "  需保护的补丁文件: $NPROT 个"
  if [ -f "$GKI_LIST.ci-orig" ]; then
    echo "  [OK] 已处理过（存在 $GKI_LIST.ci-orig），跳过移除步骤"
  else
    cp "$GKI_LIST" "$GKI_LIST.ci-orig"
    # 用精确整行匹配逐个移除（不用正则，避免误删 include/linux/sched.h 之外的 sched 相关行）
    echo "$PROTECT_LIST" > /tmp/ci_protect.txt
    grep -vxF -f /tmp/ci_protect.txt "$GKI_LIST.ci-orig" > "$GKI_LIST"
    rm -f /tmp/ci_protect.txt
    echo "  已移除 $(($(wc -l < "$GKI_LIST.ci-orig") - $(wc -l < "$GKI_LIST"))) 行"
    # ── 复核 0：保护不能是"静默空操作" ──
    # 若某个受保护路径不在【原始清单】里（拼错 / 上游改名），上面的 grep -vxF
    # 会静默地什么也不做，而复核 1 依然全绿 → 保护形同虚设。这里显式核对。
    NPRES=0
    for f in $PROTECT_LIST; do
      if grep -qxF "$f" "$GKI_LIST.ci-orig"; then NPRES=$((NPRES+1)); fi
    done
    if [ "$NPRES" -ne "$NPROT" ]; then
      echo "  [FAIL] 原始清单里只找到 $NPRES/$NPROT 个受保护路径 —— 保护是静默空操作"
      for f in $PROTECT_LIST; do
        grep -qxF "$f" "$GKI_LIST.ci-orig" || echo "         缺失: $f"
      done
      die "保护清单与 files_gki_aarch64.txt 不匹配（上游变动？）"
    fi
    echo "  [OK] $NPRES/$NPROT 个受保护路径均存在于原始清单（移除是真实生效的）"
  fi
  # ── 复核 1：7 个文件必须都已不在清单里 ──
  LEFT=0
  for f in $PROTECT_LIST; do
    if grep -qxF "$f" "$GKI_LIST"; then
      echo "  [FAIL] '$f' 仍在清单里 → -g 会覆盖它"
      LEFT=$((LEFT+1))
    fi
  done
  if [ "$LEFT" -ne 0 ]; then die "$LEFT 个受保护文件仍在清单中"; fi
  echo "  [OK] 7 个受保护文件均已不在清单中 → -g 不会覆盖它们"
  # ── 复核 2：其它 .h 必须仍在（防止过度中和）──
  NH=$(grep -c '\.h' "$GKI_LIST" || true)
  echo "  清单中仍保留的 .h 行数: $NH（应为 3597 = 原 3604 减 7）"
  if [ "$NH" -ne 3597 ]; then
    die "清单里 .h 行数 = $NH（期望恰好 3597 = 3604-7）；过多说明保护不足，过少说明过度中和"
  fi
  # ── 复核 2b：总行数必须为 6770（实测值）──
  # 注意：原清单 6785 行【最后一行没有换行符】，wc -l 统计换行符个数 → 实际 6784。
  # 移除 14 行后 = 6770。run#11 实测 6770，勿改成 6771。
  # 非 .h 的 7 个文件（kernel/sched/core.c 等）也会被 finally 的 git checkout
  # 按同一清单还原，所以必须一并移出。之前只查 .h 是漏洞。
  NTOT=$(wc -l < "$GKI_LIST")
  echo "  清单总行数: $NTOT（应为 6769；原清单 wc -l = 6784，减 15）"
  if [ "$NTOT" -ne 6769 ]; then
    die "清单总行数 = $NTOT（期望 6769）；过多说明保护不足，过少说明过度中和"
  fi
  # ── 复核 3：关键的新版头文件仍在清单里 ──
  for f in fs/verity/fsverity_private.h include/crypto/hash.h; do
    if grep -qxF "$f" "$GKI_LIST"; then
      echo "  [OK] '$f' 仍在清单中 → -g 会为它做 common 覆盖"
    else
      die "'$f' 不在清单中 → fs/verity 等会用到陈旧头而编译失败"
    fi
  done
else
  die "找不到 $GKI_LIST（无法确认 -g 行为）"
fi

# ── 复核 4：受保护文件的内容必须仍是【补丁后版本】──────────────
# 这是最直接的断言：确认补丁改动还在（而不是被 common 版顶掉）。
echo
echo "=== 复核受保护文件的内容（必须是补丁后版本）==="
K2="$KERNEL"
ck_has()  { grep -q "$2" "$K2/$1" && echo "  [OK]   $1 含 $3" || { echo "  [FAIL] $1 不含 $3（可能被 common 覆盖）"; FAIL=1; }; }
ck_not()  { grep -q "$2" "$K2/$1" && { echo "  [FAIL] $1 仍含 $3（补丁的删除被恢复）"; FAIL=1; } || echo "  [OK]   $1 不含 $3"; }
ck_has include/linux/sched.h              'CONFIG_HMBIRD_SCHED'          'HMBIRD 分支'
ck_not include/linux/sched.h              '#include <linux/sched/ext.h>' 'ext.h include'
ck_has kernel/sched/sched.h               'CONFIG_HMBIRD_SCHED'          'HMBIRD 分支'
ck_not kernel/sched/sched.h               '^#include "ext\.h"'           'ext.h include（补丁已删）'
ck_not kernel/bpf/bpf_struct_ops_types.h  'sched_ext_ops'                'sched_ext_ops（补丁已删）'
ck_has include/linux/sched/task.h         'CONFIG_HMBIRD_SCHED'          'HMBIRD 分支'
ck_has include/uapi/linux/sched.h         'SCHED_HMBIRD'                 'SCHED_HMBIRD（补丁新增）'
ck_not include/uapi/linux/sched.h         'SCHED_EXT'                    'SCHED_EXT（补丁已删）'
ck_has kernel/sched/sched.h               'hmbird.h'                     'hmbird.h include（补丁新增）'
ck_has include/asm-generic/vmlinux.lds.h  '.'                            '文件存在（+1/-1 改动）'
# ★ 依赖型断言（run#8 的 2 个错误）：cpufreq.h 的这两个声明【只在 msm 版存在】，
#   被 -g 换成 common 版后 hmbird.c:3717 / hmbird_sched_proc.c:210 会报
#   "call to undeclared function"。这里做双向自证：
#     ck_has  → 补丁代码需要的声明必须在
#     ck_not  → 且不能是 common 版（用 common 版独有的"无声明"特征反证）
ck_has include/linux/cpufreq.h            'store_scaling_governor'       'store_scaling_governor 声明（hmbird.c:3717 需要）'
ck_has include/linux/cpufreq.h            'show_scaling_governor'        'show_scaling_governor 声明（hmbird_sched_proc.c:210 需要）'
# 反向自证：cpufreq.h 必须是【普通文件】而非指向 common 的符号链接
if [ -L "$K2/include/linux/cpufreq.h" ]; then
  echo "  [FAIL] include/linux/cpufreq.h 是符号链接 -> $(readlink "$K2/include/linux/cpufreq.h")（被 common 覆盖！）"
  FAIL=1
else
  echo "  [OK]   include/linux/cpufreq.h 是普通文件（未被 common 覆盖）"
fi
# 反向自证：common 版 cpufreq.h 的行数与 msm 版不同（1231 vs 1235），
#   若行数等于 common 版则说明已被覆盖（用行数区间做粗判，避免依赖外部文件）
NCPL=$(wc -l < "$K2/include/linux/cpufreq.h")
if [ "$NCPL" -ge 1235 ]; then
  echo "  [OK]   include/linux/cpufreq.h 行数 = $NCPL（msm 版 ≥1235；common 版为 1231）"
else
  echo "  [FAIL] include/linux/cpufreq.h 行数 = $NCPL（< 1235，疑似已被 common 版覆盖）"
  FAIL=1
fi

# ★ 非 .h 文件的补丁内容断言（run#9 教训：它们也在清单里，会被 git checkout 还原）
#   kernel/sched/build_policy.c 是 hmbird 的接入点（#include "hmbird/*.c"），
#   被还原后 hmbird 符号数会变成 0（run#9 实测就是这个症状）。
ck_has kernel/sched/build_policy.c        'hmbird/hmbird.c'              'hmbird/hmbird.c include（补丁新增）'
ck_has kernel/sched/core.c                'CONFIG_HMBIRD_SCHED'          'HMBIRD 分支（补丁新增）'
ck_has kernel/fork.c                      'hmbird'                       'hmbird 调用（补丁新增）'
ck_has kernel/sched/idle.c                'hmbird'                       'hmbird 调用（补丁新增）'
ck_has kernel/time/tick-sched.c           'hmbird'                       'hmbird 调用（补丁新增）'
ck_has kernel/sched/debug.c               'hmbird'                       'hmbird 引用（补丁新增）'

# ★ 关键：复核 4 的 FAIL 必须真的让脚本失败。
#   历史缺陷：第 2 步末尾（约 273 行）检查过一次 FAIL，但复核 4 在其【之后】，
#   它设的 FAIL=1 再也没有被消费 → 这些内容断言形同虚设（只打印不拦截）。
#   这里补上收口，否则"模拟 -g 覆盖 → 断言拦住"的自证无法成立。
if [ "$FAIL" -ne 0 ]; then
  echo
  die "受保护文件内容断言失败 —— 有文件已被 common 版覆盖（见上面 [FAIL] 行）"
fi

# ── 复核 5：★ 穷举断言（不硬编码路径，未来自动拦截）──────────────────
# 判据来源：补丁自身。从 patches/*.patch 提取所有【被修改】的文件
# （不区分 .h 与非 .h，排除整文件新增/删除），与当前清单取交集，必须为空。
#
# ⚠️ run#14 前只查 .h 是个漏洞：block/elevator.c 是 .c 文件，adios.patch 改了它
#   （默认电梯改 adios），它也在 GKI 清单第 542 行 → -g finally 的 git checkout
#   会还原它 → ADIOS 默认调度器失效。而"只查 .h"的穷举发现不了。
#   现已改为查全部文件类型，并把 elevator.c 加入保护名单。
echo
echo "=== 穷举断言：补丁修改的文件（不分类型）与清单的交集必须为空 ==="
python3 - "$PATCH_DIR" "$GKI_LIST" <<'PYEOF'
import re, sys, glob, os
patch_dir, gki = sys.argv[1], sys.argv[2]
cand = set()
for pat in sorted(glob.glob(os.path.join(patch_dir, "*.patch"))):
    txt = open(pat, errors="replace").read()
    for b in re.split(r"(?m)^diff --git ", txt):
        if not b:
            continue
        head = b.split("\n")[0]
        m = re.match(r"a/(\S+) b/\S+", head)
        if not m:
            continue
        f = m.group(1)
        first = "\n".join(b.split("\n")[1:5])
        # 整文件新增/删除不需要保护：
        #   新增 → common 里没有同名文件，-g 不会 symlink 到它
        #   删除 → 清单里没有（已核实 ext.h/ext.c 均不在清单）
        if "new file mode" in first or "deleted file mode" in first:
            continue
        cand.add(f)
lines = [l.strip() for l in open(gki, errors="replace") if l.strip()]
gki_set = set(lines)
overlap = sorted(cand & gki_set)
print("  补丁中【被修改】的文件数（不分类型）: %d" % len(cand))
print("  当前清单中的条目数            : %d" % len(lines))
print("  交集（会被 -g 覆盖的补丁文件） : %d" % len(overlap))
for f in overlap:
    print("     ★ %s" % f)
if overlap:
    sys.stderr.write("::error::仍有 %d 个补丁文件在清单中，-g 会覆盖它们（补丁改动会被丢弃）\n" % len(overlap))
    sys.exit(1)
print("  [OK] 交集为空 → 没有任何补丁文件会被 -g 覆盖")
PYEOF
if [ $? -ne 0 ]; then die "穷举断言失败：仍有补丁文件会被 -g 覆盖"; fi

# 幂等清理：若上一版留下 prepare_vendor.sh 修改痕迹，还原为上游原文
PV="$SRC/kernel_platform/build/android/prepare_vendor.sh"
if [ -f "$PV.orig" ] && grep -q 'CI-FIX: the original condition' "$PV" 2>/dev/null; then
  echo "  [INFO] 检测到上一版留下的 prepare_vendor.sh 修改，已还原为上游原文"
  cp "$PV.orig" "$PV"
fi


banner "5. 完成"
echo "  补丁: 3 个已应用并通过断言"
echo "  配置: 已注入 gki_defconfig（DEFCONFIG=gki_defconfig，perf 变体无额外 fragment）"
echo "  防护: prepare_vendor.sh 的 -g 条件已置为恒假 + files_gki_aarch64.txt 已中和"
echo "  下一步: 构建内核"
