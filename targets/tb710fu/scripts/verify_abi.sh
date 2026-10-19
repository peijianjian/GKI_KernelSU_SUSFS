#!/usr/bin/env bash
# TB710FU：vendor ABI 门禁
#
# 用法：verify_abi.sh <out_dir>
#   out_dir  内核构建输出目录（含 Module.symvers / vmlinux）
#
# 为什么是这套判据
# ----------------
# pad 的 verify_vendor_abi.py 需要 289 个厂商 .ko 才能逐符号比对，但 CI 上
# 没有这些文件（它们在设备 /vendor/lib/modules 里，不可能进仓库）。
#
# 替代方案基于一个事实：android14-6.1 是 KMI 分支，Google 保证同代内 ABI 冻结，
# 因此整棵树的布局契约收敛到一个哨兵值 —— module_layout 的 CRC。
# 它是 struct 布局 + 类型文本的总校验和，任何一个导出符号的原型变化都会改变它。
#
# pad 的实测记录（kernel-compat/configs/README.md）：
#   * 正常：module_layout = 0xea759d7f，289 个模块全部正常加载
#   * 踩坑：r1+ 配置里 TRIM_UNUSED_KSYMS 关掉 + SYSVIPC=y
#           -> module_layout = 0x28c5e94f，289 个模块全部拒载、开机第一屏重启
#
# 所以这里只做一件事：确认哨兵值没变。便宜、快、直击要害。
set -euo pipefail

OUT_DIR=${1:?usage: verify_abi.sh <out_dir>}
SYMVERS="$OUT_DIR/Module.symvers"
[ -f "$SYMVERS" ] || SYMVERS="$OUT_DIR/../Module.symvers"
[ -f "$SYMVERS" ] || { echo "::error::找不到 Module.symvers（查找路径: $OUT_DIR）" >&2; exit 1; }

EXPECTED_LAYOUT="0xea759d7f"
fail=0

echo "== 1/3 module_layout 哨兵 =="
# Module.symvers 每行格式：<CRC>\t<symbol>\t<module>\t<export type>
# 用 awk 精确匹配第 2 列，避免 grep -w 把 module_layout_foo 之类也算进来。
layout=$(awk '$2=="module_layout"{print $1; exit}' "$SYMVERS")
if [ -z "$layout" ]; then
    echo "::error::Module.symvers 里没有 module_layout —— 构建异常" >&2
    fail=1
elif [ "$layout" = "$EXPECTED_LAYOUT" ]; then
    echo "   ✓ module_layout = $layout（与 6.1.128 原厂一致）"
else
    echo "::error::module_layout = $layout，期望 $EXPECTED_LAYOUT" >&2
    echo "   这意味着导出符号的布局或原型已改变，289 个厂商模块会全部拒载。" >&2
    echo "   常见原因：TRIM_UNUSED_KSYMS 被关 / SYSVIPC 未走 KABI 槽位补丁 / 配置基线被改。" >&2
    fail=1
fi

echo "== 2/3 关键导出符号存在性 =="
# 这些是 BSP 模块与 pad 补丁链依赖的符号，缺一个对应模块就加载失败
REQUIRED=(
    filp_open                 # KGSL 桥与 proc 目录探测
    kernel_write
    stack_guard_gap           # gloom
    arch_mmap_rnd             # gloom
    sysctl_legacy_va_layout   # gloom
    mmap_min_addr             # gloom
    module_layout             # 布局契约本身
)
for s in "${REQUIRED[@]}"; do
    if awk -v s="$s" '$2==s{found=1} END{exit !found}' "$SYMVERS"; then
        echo "   ✓ $s"
    else
        echo "::error::缺少导出符号 $s" >&2
        fail=1
    fi
done

echo "== 3/3 vendor hook 命名空间导出 =="
# gloom 与 pcppages 的钩子必须在 vendor_hooks.c 里导出，否则一加模块链接时未定义。
# tracepoint 在 Module.symvers 里的实际导出名为 __tracepoint_<name> /
# __traceiter_<name>，不是裸 hook 名；这里同时检查两者。
HOOKS=(
    android_vh_get_from_fragment_pool
    android_vh_exclude_reserved_zone
    android_vh_include_reserved_zone
    android_vh_drain_all_pages_bypass
    android_vh_binder_proc_transaction_end
)
for h in "${HOOKS[@]}"; do
    if awk -v s="__tracepoint_$h" '$2==s{found=1} END{exit !found}' "$SYMVERS" || \
       awk -v s="__traceiter_$h" '$2==s{found=1} END{exit !found}' "$SYMVERS"; then
        echo "   ✓ $h"
    else
        echo "::warning::$h 未导出 —— 依赖它的 BSP 模块将加载失败" >&2
        fail=1
    fi
done

echo "== 白名单覆盖检查 =="
# TRIM_UNUSED_KSYMS 只导出白名单内的符号。源码里已删除的符号留在白名单里
# 只会产生告警；但白名单缺失的新符号会被静默裁掉，模块加载时才暴露。
echo "   Module.symvers 导出符号数：$(wc -l < "$SYMVERS")"

# 白名单里的符号若在新版源码中已不存在，TRIM 阶段会告警甚至失败。
# 这里报告数量，并把前 40 个缺失符号列出来供诊断。
WHITELIST="${TARGET_DIR:-}/config/abi_symbollist.raw"
if [ -f "$WHITELIST" ]; then
    missing=0
    missing_list=""
    while IFS= read -r sym; do
        [ -n "$sym" ] || continue
        if ! awk -v s="$sym" '$2==s{found=1} END{exit !found}' "$SYMVERS"; then
            missing=$((missing + 1))
            if [ "$missing" -le 40 ]; then
                missing_list="$missing_list$sym\n"
            fi
        fi
    done < "$WHITELIST"
    echo "   白名单 $(wc -l < "$WHITELIST") 条，导出缺失 $missing 条"
    if [ "$missing" -gt 0 ]; then
        echo "   缺失符号示例（前 40 条）："
        printf '     %s\n' $(printf "$missing_list" | head -40)
        echo "::warning::白名单有 $missing 条符号未被导出，TRIM 阶段可能告警"
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "::error::ABI 门禁未通过 —— 不要刷入该镜像" >&2
    exit 1
fi
echo "== ABI 门禁通过 =="
