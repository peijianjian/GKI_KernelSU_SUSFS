#!/usr/bin/env bash
# TB710FU：安装 ABI 白名单 → 按 ordered.list 应用内核树补丁 → 运行锚点改写器
#
# 用法：apply_patches.sh <target_dir> <kernel_src_dir>
#   target_dir   targets/tb710fu
#   kernel_src   $KERNEL_ROOT/common
#
# 顺序不可调整：
#   1. 白名单必须在 hooks 之前安装 —— apply_oplus_hooks.py 会往白名单里
#      追加 android_vh_binder_proc_transaction_end，若之后被原版覆盖就丢了。
#   2. 补丁必须在 hooks 之前 —— hooks 靠锚点匹配，补丁可能移动锚点附近的行。
#
# 与通用 GKI 的关键差别：补丁冲突直接 fail。
# GKI 的 build.yml 里大量 `patch -p1 ... || true`，那是为了兼容几十个版本、
# 允许部分 hunk 失败后继续。TB710FU 的补丁是精确对着 6.1.128 @5c2cea985a84
# 写的，冲突就意味着源码版本没对准，继续编出来的内核不可信 —— 必须停下来。
set -euo pipefail

TARGET_DIR=${1:?usage: apply_patches.sh <target_dir> <kernel_src>}
KERNEL_SRC=${2:?}

# 全部转成绝对路径：脚本后面会 cd 到内核源码目录，
# 若这里保留相对路径，PATCH_DIR / ORDER 会随之失效。
TARGET_DIR=$(cd "$TARGET_DIR" && pwd)
KERNEL_SRC=$(cd "$KERNEL_SRC" && pwd)

PATCH_DIR="$TARGET_DIR/patches"
ORDER="$PATCH_DIR/ordered.list"
WHITELIST="$TARGET_DIR/config/abi_symbollist.raw"
[ -f "$ORDER" ] || { echo "::error::缺少 $ORDER" >&2; exit 1; }
[ -f "$WHITELIST" ] || { echo "::error::缺少 $WHITELIST" >&2; exit 1; }

echo "== 0/2 安装 ABI 白名单 =="
# TRIM_UNUSED_KSYMS 只导出白名单内的符号（CONFIG_UNUSED_KSYMS_WHITELIST）
cp "$WHITELIST" "$KERNEL_SRC/abi_symbollist.raw"
echo "   $(wc -l < "$WHITELIST") 行 -> $KERNEL_SRC/abi_symbollist.raw"

cd "$KERNEL_SRC"

echo "== 1/2 应用内核树补丁 =="
FAIL=0
APPLIED=0
while IFS= read -r line; do
    # 去注释与空行
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [ -n "$line" ] || continue

    p="$PATCH_DIR/$line"
    if [ ! -f "$p" ]; then
        echo "::error::ordered.list 引用了不存在的补丁: $line" >&2
        FAIL=1
        continue
    fi

    echo "-- 应用 $line"
    # --batch：找不到目标文件或上下文不符时直接失败，不进交互式提示。
    # CI 里没有 stdin，缺了它 patch 会停在 "File to patch:" 等待输入直到超时。
    if patch -p1 --batch --dry-run --forward < "$p" >/dev/null 2>&1; then
        patch -p1 --batch --no-backup-if-mismatch < "$p"
        APPLIED=$((APPLIED + 1))
        echo "   ✓ 已应用"
    elif patch -p1 --batch -R --dry-run < "$p" >/dev/null 2>&1; then
        # 幂等：已经打过了
        echo "   = 已应用过，跳过"
        APPLIED=$((APPLIED + 1))
    else
        # dry-run 失败时不再重跑真实 patch：进了分支只会在日志里再刷一遍
        # "No file to patch"，而真正要看的冲突信息由下面的 dry-run 输出提供。
        echo "::error::$line 补丁冲突" >&2
        echo "--- 冲突详情 ---" >&2
        patch -p1 --batch --dry-run --forward < "$p" 2>&1 | grep -E '^(patching|Hunk|.*FAILED|.*rej)' | head -30 >&2 || true
        FAIL=1
    fi
done < "$ORDER"

echo "   共处理 $APPLIED 个补丁"

echo "== 2/2 运行锚点改写器 =="
# Python 锚点改写器：声明 + 调用点 + 导出 + 白名单 四处
# 这类改动无法用 patch 表达（依赖锚点匹配而非上下文行号），跨版本最稳。
HOOKS="$PATCH_DIR/hooks/apply_oplus_hooks.py"
if [ -f "$HOOKS" ]; then
    if python3 "$HOOKS" "$KERNEL_SRC"; then
        echo "   ✓ 锚点改写完成"
    else
        echo "::error::apply_oplus_hooks.py 锚点未命中 —— 源码结构已变化" >&2
        FAIL=1
    fi
else
    echo "::error::缺少 $HOOKS" >&2
    FAIL=1
fi

# 冲突文件汇总
mapfile -t REJS < <(find "$KERNEL_SRC" -type f -name '*.rej' 2>/dev/null | sort)
if [ "${#REJS[@]}" -gt 0 ]; then
    echo "::error::产生 ${#REJS[@]} 个 .rej 冲突文件" >&2
    printf '   %s\n' "${REJS[@]}" >&2
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    echo "::error::补丁阶段失败" >&2
    exit 1
fi
echo "== 补丁全部就绪 =="
