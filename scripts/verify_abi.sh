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
# llvm-nm 默认输出 mangled 符号:
#   libc++      的 std::__1::  → mangle 为 St3__1
#   libstdc++   的 __cxx11 inline namespace → mangle 里保留字面 __cxx11
# 故检测 libc++ 要 grep 'St3__1' (mangled), 而非字面 'std::__1' (那是 demangled 形态)。
total="$("${NM}" --defined-only "${LIB}" 2>/dev/null | wc -l || true)"
cxx11="$("${NM}" --defined-only "${LIB}" 2>/dev/null | grep -c '__cxx11' || true)"
libcxx="$("${NM}" --defined-only "${LIB}" 2>/dev/null | grep -c 'St3__1' || true)"

echo "    total defined symbols         : ${total}"
echo "    libstdc++ (__cxx11 mangled)   : ${cxx11}"
echo "    libc++      (St3__1 mangled)  : ${libcxx}"

if [ "${cxx11}" -ne 0 ]; then
	echo "FAIL: found ${cxx11} libstdc++ symbols; library is NOT libc++ ABI" >&2
	exit 1
fi
if [ "${libcxx}" -eq 0 ]; then
	echo "FAIL: found no libc++ symbols; library is NOT libc++ ABI" >&2
	exit 1
fi

echo "PASS: library is libc++ ABI"
