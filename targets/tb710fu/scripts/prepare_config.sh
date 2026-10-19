#!/usr/bin/env bash
# TB710FU：拼接原厂配置基线 + Delta，落成内核编译用 .config
#
# 用法：prepare_config.sh <target_dir> <kernel_src_dir> <out_dir>
#   target_dir   targets/tb710fu
#   kernel_src   $KERNEL_ROOT/common
#   out_dir      编译输出目录（放 .config）
#
# 注意：本脚本【不】安装 abi_symbollist.raw。
# 白名单必须由 apply_patches.sh 在运行 apply_oplus_hooks.py 之前安装，
# 否则 hooks 往白名单里追加的符号会被这里的原版拷贝覆盖掉。
#
# 设计要点（与通用 GKI 的差别）：
#   1. 整份原厂 7550 行作为基线，不用 gki_defconfig + fragment 追加式。
#      gki_defconfig 只声明"要开什么"，不含原厂那 3840 行 "is not set"，
#      追加式会让几千个开关落到编译器默认值上，产出的内核与厂商模块 CRC 对不上。
#   2. olddefconfig 会让新增/删除的符号按 Kconfig 默认值变动，
#      因此落完必须输出差异报告，供人工确认。
set -euo pipefail

TARGET_DIR=${1:?usage: prepare_config.sh <target_dir> <kernel_src> <out_dir>}
KERNEL_SRC=${2:?}
OUT_DIR=${3:?}

BASE="$TARGET_DIR/config/base.config"
DELTA="$TARGET_DIR/config/delta.config"

for f in "$BASE" "$DELTA"; do
    [ -f "$f" ] || { echo "::error::缺少 $f" >&2; exit 1; }
done

mkdir -p "$OUT_DIR"

echo "== 1/3 拼接配置基线 =="
cat "$BASE" "$DELTA" > "$OUT_DIR/.config"
echo "   base  : $(wc -l < "$BASE") 行"
echo "   delta : $(grep -cv '^#' "$DELTA" || true) 行有效项"
echo "   合计  : $(wc -l < "$OUT_DIR/.config") 行"

echo "== 2/3 olddefconfig =="
# Kconfig 的编译器探测（scripts/Kconfig.include）用的是 ${LD}=ld.lld，
# LLVM=1 编译同理。工具链不齐时这里会只甩一行 "linker 'ld.lld' not found"，
# 看不出是 CI 缺工具，所以先自检；CC=ccache clang 与编译步骤保持一致。
missing=0
for t in clang ld.lld llvm-ar llvm-nm llvm-strip llvm-objcopy llvm-objdump; do
    if command -v "$t" >/dev/null 2>&1; then
        echo "   ✓ $t"
    else
        echo "::error::缺少 $t —— LLVM 工具链未装好（走 .github/workflows 的「安装 LLVM 工具链」）" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    echo "::error::工具链自检失败，停止构建" >&2
    exit 1
fi

cp "$OUT_DIR/.config" "$OUT_DIR/.config.pre-olddefconfig"
make -C "$KERNEL_SRC" O="$OUT_DIR" ARCH=arm64 LLVM=1 CC="ccache clang" olddefconfig
echo "   olddefconfig 完成"

echo "== 3/3 关键配置断言 =="
# 这几条缺任一个，289 个厂商模块全部拒载。pad 的 configs/README.md 记录过
# 踩坑：r1+ 的配置 TRIM 关掉 + SYSVIPC=y，module_layout 从 0xea759d7f
# 变成 0x28c5e94f，开机第一屏即重启。
fail=0
assert_on() {
    local k=$1
    if grep -qx "CONFIG_${k}=y" "$OUT_DIR/.config"; then
        echo "   ✓ CONFIG_${k}=y"
    else
        echo "::error::CONFIG_${k} 未启用 —— 会破坏 vendor ABI" >&2
        fail=1
    fi
}
assert_on TRIM_UNUSED_KSYMS
assert_on DEBUG_INFO_BTF
assert_on MODVERSIONS
assert_on ANDROID_VENDOR_HOOKS

if grep -q '^CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw"' "$OUT_DIR/.config"; then
    echo "   ✓ CONFIG_UNUSED_KSYMS_WHITELIST=\"abi_symbollist.raw\""
else
    echo "::error::UNUSED_KSYMS_WHITELIST 未指向 abi_symbollist.raw" >&2
    fail=1
fi

if grep -qx '# CONFIG_MODULE_SIG_PROTECT is not set' "$OUT_DIR/.config"; then
    echo "   ✓ CONFIG_MODULE_SIG_PROTECT 已关闭"
else
    echo "::error::CONFIG_MODULE_SIG_PROTECT 未关闭 —— 厂商模块会 sig_ok=false 被拒" >&2
    fail=1
fi

echo "== 配置漂移报告 =="
# olddefconfig 会静默删除源码里已不存在的 CONFIG，或把新增项按默认值补上。
# 这份报告让漂移可见，人工确认后再判断产物是否可信。
DRIFT="$OUT_DIR/config-drift.txt"
if diff -u "$OUT_DIR/.config.pre-olddefconfig" "$OUT_DIR/.config" > "$DRIFT" 2>&1; then
    echo "   无漂移"
else
    n=$(grep -c '^[+-]CONFIG_\|^[+-]# CONFIG_' "$DRIFT" || true)
    echo "   漂移 ${n} 项，详见 $DRIFT"
    grep '^[+-]CONFIG_\|^[+-]# CONFIG_' "$DRIFT" | head -40 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "::error::配置断言失败，停止构建" >&2
    exit 1
fi
echo "== 配置就绪 =="
