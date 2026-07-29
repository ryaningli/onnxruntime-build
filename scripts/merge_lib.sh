#!/usr/bin/env bash
# 把 ONNX Runtime 的所有静态分量 + 第三方依赖合并成单个胖 libonnxruntime.a。
# 这样 ort-sys 走「单库快速路径」(ort-sys/build/static_link/mod.rs:127-130) 即可消费,
# 与 pyke 官方包链接行为等价, 绕开凑齐 abseil 等几十个散件的多库路径。
set -euo pipefail

WORKDIR="${WORKDIR:-/work}"
RELEASE_DIR="${WORKDIR}/onnxruntime/build/Linux/Release"
OUT_DIR="${OUT_DIR:-${WORKDIR}/dist}"
AR="${AR:-llvm-ar-16}"

if [ ! -d "${RELEASE_DIR}" ]; then
	echo "ERROR: release dir not found: ${RELEASE_DIR}" >&2
	exit 1
fi

mkdir -p "${OUT_DIR}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "==> Collecting static archives under ${RELEASE_DIR}"
# ORT 自身分量(libonnxruntime_*.a) + _deps/ 下的第三方依赖(onnx/protobuf/re2/cpuinfo/absl...)
find "${RELEASE_DIR}" -name '*.a' \
	\( -name 'libonnxruntime_*.a' -o -path '*/_deps/*' \) \
	-print | sort -u > "${TMP}/libs.txt"
echo "    found $(wc -l < "${TMP}/libs.txt") archives"

# 诊断: 哪些 archive 含 onnx::GetOpSchema 定义(定位 schema 来源, 排查符号缺失)。
# 注意: 必须 `|| true` —— grep 在 0 匹配时退出码=1, 配合 set -euo pipefail 会让
# 命令替换赋值失败 → 整个脚本被 set -e 杀掉(本诊断在首个不含 schema 的 archive 上即崩)。
NM_TOOL="${NM:-llvm-nm-16}"
echo "==> [诊断] 含 onnx::GetOpSchema 定义的 archives:"
while IFS= read -r lib; do
	cnt=$("${NM_TOOL}" "$lib" 2>/dev/null | grep '_ZN4onnx11GetOpSchemaI' | grep -cE '^[0-9a-f]+ [Tt] ' || true)
	[ "${cnt:-0}" -gt 0 ] && echo "    $(basename "$lib") : ${cnt} defined"
done < "${TMP}/libs.txt"

# 用 MRI script 合并: ADDLIB 把每个 archive 的所有 member 整体加入目标 archive。
# 绝不能用 `ar x` 逐个提取再 `ar rcs` 重打包 ——
#   onnx 各域都有 defs.cc → object basename 全是 defs.cc.o, CMake 用 qc(quick-append)
#   归档 → libonnx.a 内含多条同名 defs.cc.o member。`ar x` 提取时同名 member 互相覆盖,
#   每个 basename 只剩一个 → 丢失核心域 onnx::GetOpSchema 模板特化(zigbuild 链接失败)。
# MRI ADDLIB 把整个 archive 的 member 加入目标, 保留所有同名 member; 链接器(lld)按
# archive symbol table 的 offset 解析同名 member(不依赖 member 名唯一), 各取所需。
# 已验证: GNU ar / zig ar(llvm) 的 MRI 兼容; GNU ld / lld 均能正确链接含同名 member 的 archive。
OUT="${OUT_DIR}/libonnxruntime.a"
rm -f "${OUT}"
{
	echo "CREATE ${OUT}"
	while IFS= read -r lib; do
		echo "ADDLIB ${lib}"
	done < "${TMP}/libs.txt"
	echo "SAVE"
	echo "END"
} | "${AR}" -M
# MRI 的 SAVE 通常已写 symbol table, 但部分实现需显式补 index, 保险起见再 ranlib 一次。
"${AR}" s "${OUT}" 2>/dev/null || true

# 合并后校验: 确认 onnx::GetOpSchema 定义已进胖库(rename 修复是否生效的直接证据)。
final_cnt=$("${NM_TOOL}" --defined-only "${OUT}" 2>/dev/null | grep -c '_ZN4onnx11GetOpSchemaI' || true)
echo "==> [诊断] 合并后 onnx::GetOpSchema defined = ${final_cnt:-0} (无损合并的证据; 此前 ar x 覆盖仅余 ~10)"

echo "==> Merged: ${OUT} ($(du -h "${OUT}" | cut -f1))"
