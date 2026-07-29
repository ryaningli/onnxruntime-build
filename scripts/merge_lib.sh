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

# 每个 archive 解到独立子目录, 避免重名 .o 互相覆盖丢失符号
i=0
while IFS= read -r lib; do
	i=$((i + 1))
	sub="${TMP}/x/${i}"
	mkdir -p "${sub}"
	( cd "${sub}" && "${AR}" x "${lib}" )
done < "${TMP}/libs.txt"

echo "==> Repacking into single libonnxruntime.a"
OUT="${OUT_DIR}/libonnxruntime.a"
rm -f "${OUT}"
# xargs 分批追加(多次 `ar rcs` 为追加模式), 避免 .o 过多超 ARG_MAX
find "${TMP}/x" -name '*.o' -print0 | xargs -0 "${AR}" rcs "${OUT}"

echo "==> Merged: ${OUT} ($(du -h "${OUT}" | cut -f1))"
