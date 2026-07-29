#!/usr/bin/env bash
# 质量门禁: 确认产物是 libc++ ABI (std::__1), 而非 libstdc++ (std::__cxx11)。
# zig 交叉工具链只提供 libc++, 故产物必须是 libc++ ABI 才能被 zigbuild 链接。
set -euo pipefail

LIB="${1:-${OUT_DIR:-/work/dist}/libonnxruntime.a}"
NM="${NM:-llvm-nm-16}"

if [ ! -f "${LIB}" ]; then
	echo "ERROR: library not found: ${LIB}" >&2
	exit 1
fi

echo "==> Verifying ABI of ${LIB}"
cxx11="$("${NM}" --defined-only "${LIB}" 2>/dev/null | grep -c '__cxx11' || true)"
libcxx="$("${NM}" --defined-only "${LIB}" 2>/dev/null | grep -c 'std::__1' || true)"

echo "    libstdc++ (__cxx11) defined symbols : ${cxx11}"
echo "    libc++      (std::__1)  defined symbols : ${libcxx}"

if [ "${cxx11}" -ne 0 ]; then
	echo "FAIL: found ${cxx11} libstdc++ symbols; library is NOT libc++ ABI" >&2
	exit 1
fi
if [ "${libcxx}" -eq 0 ]; then
	echo "FAIL: found no libc++ symbols; library is NOT libc++ ABI" >&2
	exit 1
fi

echo "PASS: library is libc++ ABI"
