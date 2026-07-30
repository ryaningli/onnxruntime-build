#!/usr/bin/env bash
# 从源码编译 ONNX Runtime, 经 CMake `bundle_static_library` 把全部分量与依赖(onnx / protobuf /
# re2 / cpuinfo / absl...)按 target 依赖图递归收集, 用 GNU ar MRI 内联合并成单个 libonnxruntime.a
# —— 打包法移植自 pykeio/ort-artifacts 的 static-build 工程。
#
# 两种模式:
#   - CPU(默认):clang-16 + -stdlib=libc++,产出 libc++ ABI 的单个 libonnxruntime.a,
#     供 cargo zigbuild(--target <triple>.2.31)静态链接(zig 工具链只提供 libc++)。
#   - CUDA(ORT_ENABLE_CUDA=1):CUDA 的 host_defines.h 在 x86 上对 libc++ 直接 #error
#     ("libc++ is not supported on x86 system"),故 CUDA 走 libstdc++(clang-16 默认),
#     产物含 libonnxruntime.so + provider .so(libstdc++),消费端走 ort load-dynamic。
#     CUDA EP 上游恒为运行时加载的 MODULE 共享库,无法静态编进 .a。
#
# 两种模式都基于 ubuntu:20.04 容器(glibc 2.31);CUDA 编译不需 GPU(仅运行期需要)。
# 移植自 pyke 的补丁:no-soname(provider .so 不 NEEDED 核心 .so)、abseil __NVCC__ 守卫、
# CUDA kernel 编译修复。逐个应用,失败仅警告(防 ORT ref 漂移),verify 侧兜底。
#
# 用法:
#   build_ort.sh <ref>                    # CPU 版(libc++)
#   ORT_ENABLE_CUDA=1 build_ort.sh <ref>  # CUDA 版(libstdc++,需 nvidia/cuda 容器)
#   ORT_ENABLE_CUDA=1 ORT_FAST=1 build_ort.sh <ref>  # CUDA 快速验证(单 arch,勿发布)
# <ref> 可以是 tag(如 v1.28.0)或 commit hash。
set -euo pipefail

ORT_REF="${1:-${ORT_REF:-}}"
if [ -z "${ORT_REF}" ]; then
	echo "ERROR: ORT_REF not provided. Pass it as \$1 or set the ORT_REF env var (tag or commit hash)." >&2
	exit 1
fi
JOBS="${JOBS:-$(nproc)}"
WORKDIR="${WORKDIR:-/work}"
SRC_DIR="${WORKDIR}/onnxruntime"
OUT_DIR="${OUT_DIR:-${WORKDIR}/dist}"
BUILD_DIR="${WORKDIR}/build"
PATCH_DIR="${WORKDIR}/src/patches"
ENABLE_CUDA="${ORT_ENABLE_CUDA:-0}"

echo "==> Fetching ONNX Runtime ref='${ORT_REF}' -> ${SRC_DIR}"
if [ ! -d "${SRC_DIR}/.git" ]; then
	git init "${SRC_DIR}"
	cd "${SRC_DIR}"
	git remote add origin https://github.com/microsoft/onnxruntime.git
	# `git fetch --depth 1 origin <ref>` 同时支持 tag 和 commit hash(GitHub 允许按 SHA fetch)。
	if ! git fetch --depth 1 origin "${ORT_REF}"; then
		echo "    shallow fetch of '${ORT_REF}' failed, falling back to full fetch + checkout..." >&2
		git fetch origin
		git checkout "${ORT_REF}"
	else
		git checkout FETCH_HEAD
	fi
	git submodule update --init --depth 1 --recursive
fi

cd "${SRC_DIR}"
echo "==> HEAD = $(git rev-parse --short HEAD) ($(git describe --tags --always 2>/dev/null || echo 'no-tag'))"

# 移植自 pyke 的补丁。逐个应用:失败仅警告不中断(防 ORT ref 版本漂移),由 verify_abi.sh 在产物侧兜底。
if [ -d "${PATCH_DIR}" ]; then
	for p in "${PATCH_DIR}"/*.patch; do
		[ -e "${p}" ] || continue
		if git -C "${SRC_DIR}" apply --ignore-whitespace --recount "${p}"; then
			echo "    applied $(basename "${p}")"
		else
			echo "    WARN: $(basename "${p}") 未应用(对该 ORT ref 可能非必需)—— 继续"
		fi
	done
fi

# 分架构的 provider 开关(KLEIDIAI 仅 aarch64;USE_AVX2 运行时检测、安全,不强加 -march)。
ARCH="$(uname -m)"
case "${ARCH}" in
	x86_64)  KLEIDIAI=OFF; AVX2=ON  ;;
	aarch64) KLEIDIAI=ON;  AVX2=OFF ;;
	*) echo "ERROR: unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac

# 前置冒烟:验证 nvcc + clang-16 host 管线,并自动探测能抑制 nvcc #2803-D([[gsl::]] 属性)的形式。
# nvcc 抑制诊断的选项形式因 CUDA 版本而异(CUDA 12.8 不认裸 --diag_suppress),逐个试,选第一个让
# [[gsl::owner]] 编过的,写入 ${WORKDIR}/nvcc_suppr.txt 供真实构建用。CI 节流(10s 失败好过 40min)。
cuda_smoke() {
	local d="${WORKDIR}/smoke"
	local host="${CXX_WRAPPER:-${CXX:-clang++-16}}"
	mkdir -p "${d}"
	cat > "${d}/smoke.cu" <<'EOF'
#include <cuda_runtime.h>
#include <vector>
__global__ void add_k(int n, const float* x, float* y) {
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i < n) y[i] = x[i] + 1.0f;
}
int main() {
	std::vector<float> v(4, 1.0f);
	[[gsl::owner]] int* gp = nullptr; (void)gp;   // 故意触发 nvcc #2803-D(验证抑制)
	return static_cast<int>(v.size()) > 0 ? 0 : 1;
}
EOF
	echo "==> CUDA smoke: nvcc -ccbin ${host}(libstdc++)+ 探测 2803 抑制形式"
	local suppr=""
	for cand in "-Xcudafe --diag_suppress=2803" "-Xcicc --diag_suppress=2803" "--diag_suppress 2803"; do
		# shellcheck disable=SC2086  # ${cand} 需按空格拆成多个 nvcc 参数
		if nvcc -ccbin "${host}" ${cand} -std=c++17 "${d}/smoke.cu" -o "${d}/smoke" 2>"${d}/smoke.err"; then
			suppr="${cand}"
			break
		fi
		echo "    [${cand}] 不行: $(tail -1 "${d}/smoke.err" 2>/dev/null)"
	done
	if [ -z "${suppr}" ]; then
		echo "ERROR: 未能找到抑制 nvcc #2803-D 的形式(最后错误):" >&2
		cat "${d}/smoke.err" >&2
		exit 1
	fi
	echo "    smoke OK,抑制形式: ${suppr}"
	printf '%s' "${suppr}" > "${WORKDIR}/nvcc_suppr.txt"
}

# 统一 cmake 参数(CPU / CUDA 共用部分;stdlib/CUDA 相关按模式分别追加)。
CMAKE_ARGS=(
	-S "${WORKDIR}/src/static-build"
	-B "${BUILD_DIR}"
	-DCMAKE_BUILD_TYPE=Release
	-DCMAKE_INSTALL_PREFIX="${OUT_DIR}"
	-DONNXRUNTIME_SOURCE_DIR="${SRC_DIR}"
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON
	-DCMAKE_COMPILE_WARNING_AS_ERROR=OFF
	-Donnxruntime_BUILD_UNIT_TESTS=OFF
	-Donnxruntime_CLIENT_PACKAGE_BUILD=ON
	-Donnxruntime_USE_KLEIDIAI="${KLEIDIAI}"
	-Donnxruntime_USE_AVX2="${AVX2}"
)

if [ "${ENABLE_CUDA}" = "1" ]; then
	# cuDNN home: 找 cudnn.h 所在的 include 的上一级。
	CUDNN_H="$(find /usr /opt -name cudnn.h 2>/dev/null | head -1 || true)"
	if [ -n "${CUDNN_H}" ]; then
		CUDNN_HOME="${ORT_CUDNN_HOME:-$(dirname "$(dirname "${CUDNN_H}")")}"
	else
		CUDNN_HOME="${ORT_CUDNN_HOME:-${CUDA_HOME:-/usr/local/cuda}}"
	fi
	CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
	CUDA_ARCH="${CUDA_ARCH:-75;80;86;89;90}"
	# FAST/验证模式:只编单个 CUDA arch(nvcc .cu 编译时间近随 arch 数线性增长,5→1 大幅提速)。
	# 产物仅供验证构建是否走通,勿发布(消费端缺其他 arch 的 kernel)。CI 里由 inputs.fast 触发。
	if [ "${ORT_FAST:-0}" = "1" ]; then
		CUDA_ARCH="${ORT_FAST_ARCH:-75}"
		echo "==> FAST/验证模式: CUDA_ARCH=${CUDA_ARCH}(单 arch —— 仅验证用,勿发布)"
	fi
	# clang-16 默认可能挑 focal 自带 gcc-9 的 libstdc++(缺 <span> 等 C++20 头 → flatbuffers 编译报错)。
	# 装 g++-12 后,用 --gcc-install-dir 显式指向 gcc-12 的现代 libstdc++。做成 wrapper(exec clang++-16
	# --gcc-install-dir=... "$@"),CXX 与 nvcc -ccbin 都指向它,统一且确定(C++ 与 CUDA host 都走 gcc-12)。
	GCC12_DIR="/usr/lib/gcc/$(uname -m)-linux-gnu/12"
	CXX_WRAPPER="${WORKDIR}/clang++-gcc12"
	printf '#!/bin/sh\nexec %s --gcc-install-dir=%s "$@"\n' "${CXX:-clang++-16}" "${GCC12_DIR}" > "${CXX_WRAPPER}"
	chmod +x "${CXX_WRAPPER}"
	export CXX="${CXX_WRAPPER}"
	# CUDA 用 libstdc++(clang-16 + gcc-12 头):host_defines.h 在 x86 上对 libc++ #error,故不设 -stdlib。
	export CUDAHOSTCXX="${CXX_WRAPPER}"
	echo "==> CUDA mode(libstdc++): arch=${ARCH} CUDA_HOME=${CUDA_HOME} CUDNN_HOME=${CUDNN_HOME} CUDA_ARCH=${CUDA_ARCH} host=${CUDAHOSTCXX}"
	# 前置冒烟 + 自动探测 nvcc #2803-D([[gsl::]] 属性)抑制形式 → nvcc_suppr.txt。
	cuda_smoke
	NVCC_SUPPR="$(cat "${WORKDIR}/nvcc_suppr.txt" 2>/dev/null || echo "")"
	# NVCC_THREADS=1 限 nvcc 线程内存;QUICK_BUILD + 各 *_ATTENTION/FPA/FP8 OFF 缩小 CUDA kernel 面、提速降风险。
	CMAKE_ARGS+=(
		-Donnxruntime_USE_CUDA=ON
		-Donnxruntime_NVCC_THREADS=1
		-Donnxruntime_CUDNN_HOME="${CUDNN_HOME}"
		-DCUDA_HOME="${CUDA_HOME}"
		-DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}"
		-DCMAKE_CUDA_FLAGS="-ccbin ${CXX_WRAPPER} -compress-mode=size ${NVCC_SUPPR}"
		-Donnxruntime_USE_FPA_INTB_GEMM=OFF
		-Donnxruntime_USE_FLASH_ATTENTION=OFF
		-Donnxruntime_USE_MEMORY_EFFICIENT_ATTENTION=OFF
		-Donnxruntime_USE_FP8_KV_CACHE=OFF
		-Donnxruntime_QUICK_BUILD=ON
	)
else
	# CPU 用 libc++(zig 工具链只提供 libc++)。
	CMAKE_ARGS+=(
		-DCMAKE_CXX_FLAGS="-stdlib=libc++"
		-DCMAKE_EXE_LINKER_FLAGS="-stdlib=libc++"
		-DCMAKE_SHARED_LINKER_FLAGS="-stdlib=libc++"
		-DCMAKE_MODULE_LINKER_FLAGS="-stdlib=libc++"
	)
	echo "==> CPU mode(libc++): arch=${ARCH} KLEIDIAI=${KLEIDIAI} AVX2=${AVX2}"
fi

echo "==> Configuring"
cmake "${CMAKE_ARGS[@]}"

echo "==> Building + bundling (this also runs bundle_static_library -> single libonnxruntime.a)"
cmake --build "${BUILD_DIR}" --config Release --parallel "${JOBS}"

echo "==> Installing"
cmake --install "${BUILD_DIR}"

# install 落在 ${OUT_DIR}/lib*/libonnxruntime.a(lib/lib64 不定),拷到根目录满足
# ort-sys 单库快速路径契约(ORT_LIB_PATH 根目录放单个 libonnxruntime.a)。
INSTALLED="$(find "${OUT_DIR}" -name libonnxruntime.a -print -quit)"
if [ -z "${INSTALLED}" ]; then
	echo "ERROR: libonnxruntime.a not found under ${OUT_DIR} after install" >&2
	exit 1
fi
cp "${INSTALLED}" "${OUT_DIR}/libonnxruntime.a"
TARBALL_FILES=(libonnxruntime.a)

# CUDA:从构建树收集 onnxruntime 全部共享库(core libonnxruntime.so + provider .so,含版本符号链接),
# 供 load-dynamic 消费。不依赖 install 规则(避开对 onnxruntime target install 的不确定性)。
# libstdc++/CUDA 运行库由宿主提供,不打包。
if [ "${ENABLE_CUDA}" = "1" ]; then
	while IFS= read -r f; do
		[ -z "${f}" ] && continue
		cp -a "${f}" "${OUT_DIR}/$(basename "${f}")"
	done < <(find "${BUILD_DIR}" -name 'libonnxruntime*.so*' 2>/dev/null || true)
	for so in "${OUT_DIR}"/libonnxruntime*.so*; do
		[ -e "${so}" ] || continue
		TARBALL_FILES+=("$(basename "${so}")")
	done
	# 必须有核心 libonnxruntime.so(load-dynamic 入口)与 CUDA provider。
	for need in libonnxruntime.so libonnxruntime_providers_cuda.so; do
		if ! ls "${OUT_DIR}"/${need}* >/dev/null 2>&1; then
			echo "ERROR: ${need}* not found in build tree" >&2
			exit 1
		fi
	done
fi

# 统一打包 tar.gz(无论 CPU 单 .a 还是 CUDA 多文件),最终名由 CI 按 arch/cuda 后缀重命名。
PKG_NAME="${ORT_PKG_NAME:-onnxruntime-libcxx}"
( cd "${OUT_DIR}" && tar -czf "${OUT_DIR}/${PKG_NAME}.tar.gz" "${TARBALL_FILES[@]}" )

echo "==> Build done. Package: ${OUT_DIR}/${PKG_NAME}.tar.gz ($(du -h "${OUT_DIR}/${PKG_NAME}.tar.gz" | cut -f1))"
echo "    contents:"; tar -tzf "${OUT_DIR}/${PKG_NAME}.tar.gz"
