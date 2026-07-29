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

# 每个 archive 解到独立子目录, 并给 .o 加序号前缀。
# 关键: `ar rcs` 按 basename 当成员名, 仅靠独立子目录无法避免跨库同名 .o 互相覆盖
# (如多个库都有 schema.o/ops.o) → 必须给 .o 重命名成全局唯一, 才不丢符号。
i=0
while IFS= read -r lib; do
	i=$((i + 1))
	sub="${TMP}/x/${i}"
	mkdir -p "${sub}"
	( cd "${sub}" && "${AR}" x "${lib}" )
	for o in "${sub}"/*.o; do
		[ -e "$o" ] || continue
		mv -- "$o" "${sub}/${i}_$(basename "$o")"
	done
done < "${TMP}/libs.txt"

echo "==> Repacking into single libonnxruntime.a"
OUT="${OUT_DIR}/libonnxruntime.a"
rm -f "${OUT}"
# xargs 分批追加(多次 `ar rcs` 为追加模式), 避免 .o 过多超 ARG_MAX
find "${TMP}/x" -name '*.o' -print0 | xargs -0 "${AR}" rcs "${OUT}"

# 合并后校验: 确认 onnx::GetOpSchema 定义已进胖库(rename 修复是否生效的直接证据)。
final_cnt=$("${NM_TOOL}" --defined-only "${OUT}" 2>/dev/null | grep -c '_ZN4onnx11GetOpSchemaI' || true)
echo "==> [诊断] 合并后 onnx::GetOpSchema defined = ${final_cnt:-0} (0 = rename 修复失效, 符号仍丢)"

echo "==> Merged: ${OUT} ($(du -h "${OUT}" | cut -f1))"
