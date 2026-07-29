#!/usr/bin/env bash
# 质量门禁: 确认产物是 libc++ ABI (std::__1), 而非 libstdc++ (std::__cxx11)。
# zig 交叉工具链只提供 libc++, 故产物(.a 及 CUDA 的 provider .so)必须是 libc++ ABI。
#
# CPU 版:校验 libonnxruntime.a。
# CUDA 版(OUT_DIR 下存在 *.so):额外校验每个 provider .so,并确认随包发了 libc++.so.1。
set -euo pipefail

OUT_DIR="${OUT_DIR:-/work/dist}"
NM="${NM:-llvm-nm-16}"

# 校验单个库文件的 C++ ABI。$1 = 文件路径。
check_lib() {
	local lib="$1"
	if [ ! -f "${lib}" ]; then
		echo "ERROR: library not found: ${lib}" >&2
		return 1
	fi
	# llvm-nm 默认输出 mangled 符号:
	#   libc++      的 std::__1::  → mangle 为 St3__1
	#   libstdc++   的 __cxx11 inline namespace → mangle 里保留字面 __cxx11
	# 故检测 libc++ 要 grep 'St3__1' (mangled), 而非字面 'std::__1' (那是 demangled 形态)。
	local total cxx11 libcxx
	total="$("${NM}" --defined-only "${lib}" 2>/dev/null | wc -l || true)"
	cxx11="$("${NM}" --defined-only "${lib}" 2>/dev/null | grep -c '__cxx11' || true)"
	libcxx="$("${NM}" --defined-only "${lib}" 2>/dev/null | grep -c 'St3__1' || true)"

	echo "    [$(basename "${lib}")] total=${total}  libstdc++(__cxx11)=${cxx11}  libc++(St3__1)=${libcxx}"
	if [ "${cxx11}" -ne 0 ]; then
		echo "FAIL: $(basename "${lib}") 含 ${cxx11} 个 libstdc++ 符号, 非 libc++ ABI" >&2
		return 1
	fi
	if [ "${libcxx}" -eq 0 ]; then
		echo "FAIL: $(basename "${lib}") 无 libc++ 符号, 非 libc++ ABI" >&2
		return 1
	fi
	return 0
}

echo "==> Verifying ABI of ${OUT_DIR}/libonnxruntime.a"
check_lib "${OUT_DIR}/libonnxruntime.a"

# CUDA: 校验每个 provider .so + 确认 libc++ 运行库随包。
shopt -s nullglob
SO_FILES=( "${OUT_DIR}"/*.so )
if [ "${#SO_FILES[@]}" -gt 0 ]; then
	echo "==> Verifying ABI of provider shared libs + libc++ bundle"
	for so in "${SO_FILES[@]}"; do
		check_lib "${so}"
	done
	for lib in libc++.so.1 libc++abi.so.1; do
		if [ ! -f "${OUT_DIR}/${lib}" ]; then
			echo "FAIL: ${lib} 未随包(provider .so 运行期需要 libc++)" >&2
			exit 1
		fi
	done
	# 关键: provider .so 不应 NEEDED 核心库 libonnxruntime.so(否则 dlopen 找不到该文件);
	# 核心符号须从进程全局符号表解析(配合 no-soname 补丁 + 消费端 --export-dynamic)。
	# 注: provider 名 libonnxruntime_providers_*.so 不含子串 "libonnxruntime.so",不会误匹配。
	for so in "${SO_FILES[@]}"; do
		if readelf -d "${so}" 2>/dev/null | grep -q 'libonnxruntime\.so'; then
			echo "WARN: $(basename "${so}") 仍 NEEDED libonnxruntime.so(no-soname 补丁可能未生效)" >&2
		fi
	done
fi

echo "PASS: all artifacts are libc++ ABI"
