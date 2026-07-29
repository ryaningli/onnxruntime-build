#!/usr/bin/env bash
# 质量门禁。
#
# CPU 版(OUT_DIR 下无 *.so):确认 libonnxruntime.a 是 libc++ ABI(std::__1),而非 libstdc++。
#   zig 交叉工具链只提供 libc++,故 CPU 产物必须是 libc++ ABI 才能被 zigbuild 静态链接。
#
# CUDA 版(OUT_DIR 下有 *.so):CUDA 走 libstdc++(host_defines.h 在 x86 拒 libc++)。
#   确认 .a/.so 是 libstdc++ ABI,且含 core libonnxruntime.so + provider .so;provider .so
#   不应 NEEDED 核心 libonnxruntime.so(配 no-soname 补丁,核心符号从进程符号表解析)。
set -euo pipefail

OUT_DIR="${OUT_DIR:-/work/dist}"
NM="${NM:-llvm-nm-16}"

# 统计某库的 libstdc++/libc++ mangled 符号数。$1=文件。
symbol_counts() {
	local lib="$1"
	local cxx11 libcxx
	cxx11="$("${NM}" --defined-only "${lib}" 2>/dev/null | grep -c '__cxx11' || true)"
	libcxx="$("${NM}" --defined-only "${lib}" 2>/dev/null | grep -c 'St3__1' || true)"
	echo "${cxx11} ${libcxx}"
}

shopt -s nullglob
SO_FILES=( "${OUT_DIR}"/*.so* )
IS_CUDA=0
[ "${#SO_FILES[@]}" -gt 0 ] && IS_CUDA=1

if [ "${IS_CUDA}" = "1" ]; then
	echo "==> CUDA 模式:校验 libstdc++ ABI + .so 集合"
	# .a 与每个 .so 都应是 libstdc++(__cxx11>0),不应是 libc++(St3__1 应为 0 或极少)。
	for lib in "${OUT_DIR}/libonnxruntime.a" "${SO_FILES[@]}"; do
		[ -e "${lib}" ] || continue
		read -r cxx11 libcxx < <(symbol_counts "${lib}")
		echo "    [$(basename "${lib}")] libstdc++(__cxx11)=${cxx11}  libc++(St3__1)=${libcxx}"
		if [ "${libcxx}" -gt 0 ] && [ "${cxx11}" -eq 0 ]; then
			echo "FAIL: $(basename "${lib}") 是 libc++ 而非 libstdc++(CUDA 应为 libstdc++)" >&2
			exit 1
		fi
	done
	# core libonnxruntime.so 必须在(load-dynamic 消费入口)。
	if ! ls "${OUT_DIR}"/libonnxruntime.so* >/dev/null 2>&1; then
		echo "FAIL: 缺 libonnxruntime.so(load-dynamic 消费需要核心共享库)" >&2
		exit 1
	fi
	# provider .so 不应 NEEDED 核心 libonnxruntime.so(否则 dlopen 找不到文件)。
	# 注:provider 名 libonnxruntime_providers_*.so 不含子串 "libonnxruntime.so",不会误匹配。
	for so in "${OUT_DIR}"/libonnxruntime_providers_*.so*; do
		[ -e "${so}" ] || continue
		if readelf -d "${so}" 2>/dev/null | grep -q 'libonnxruntime\.so'; then
			echo "WARN: $(basename "${so}") 仍 NEEDED libonnxruntime.so(no-soname 补丁可能未生效)" >&2
		fi
	done
else
	echo "==> CPU 模式:校验 libc++ ABI"
	lib="${OUT_DIR}/libonnxruntime.a"
	if [ ! -f "${lib}" ]; then
		echo "ERROR: library not found: ${lib}" >&2
		exit 1
	fi
	read -r cxx11 libcxx < <(symbol_counts "${lib}")
	total="$("${NM}" --defined-only "${lib}" 2>/dev/null | wc -l || true)"
	echo "    total=${total}  libstdc++(__cxx11)=${cxx11}  libc++(St3__1)=${libcxx}"
	if [ "${cxx11}" -ne 0 ]; then
		echo "FAIL: 含 ${cxx11} 个 libstdc++ 符号,非 libc++ ABI" >&2
		exit 1
	fi
	if [ "${libcxx}" -eq 0 ]; then
		echo "FAIL: 无 libc++ 符号,非 libc++ ABI" >&2
		exit 1
	fi
fi

echo "PASS"
