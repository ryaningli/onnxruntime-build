#!/usr/bin/env bash
# 用 clang + libc++ 从源码编译 ONNX Runtime, 经 CMake `bundle_static_library` 把全部分量
# 与依赖(onnx / protobuf / re2 / cpuinfo / absl...)按 target 依赖图递归收集, 用 GNU ar MRI
# 内联合并成单个 libonnxruntime.a —— 打包法移植自 pykeio/ort-artifacts 的 static-build 工程。
#
# CUDA 模式(ORT_ENABLE_CUDA=1):在 nvidia/cuda 容器里原生编译 CUDA EP。CUDA EP 在上游恒为
# 运行时加载的 MODULE 共享库(libonnxruntime_providers_cuda.so),无法静态编进 .a —— 故产物
# 除 .a 外还含 providers_shared.so / providers_cuda.so, 并随包发 libc++.so.1(rpath=$ORIGIN)。
#
# 关键: .a 与 provider .so 必须同为 libc++ ABI(否则跨 provider 桥接的 C++ 对象布局错配),
# 故 -stdlib=libc++ 经 CMAKE_CXX_FLAGS / CMAKE_CUDA_FLAGS 一并传播。
#
# 刻意偏离 pyke 的三处(否则重制 ABI bug 或丢 glibc 锁):
#   - ABI:   clang-16 + -stdlib=libc++            (pyke 用 clang-21 默认 libstdc++)
#   - glibc: 12.8 → ubuntu:20.04 容器(glibc 2.31) (pyke 用 ubuntu-24.04 = glibc 2.39)
#   - nvcc host: clang-16 + libc++                (pyke 用 clang-21 + libstdc++)
#
# 用法:
#   build_ort.sh <ref>                  # CPU 版
#   ORT_ENABLE_CUDA=1 build_ort.sh <ref>  # CUDA 版(需 nvidia/cuda 容器)
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

# 移植自 pyke 的补丁(no-soname / abseil-nvcc 守卫 / CUDA kernel 编译修复)。
# 逐个应用:失败仅警告不中断(防 ORT ref 版本漂移),由 verify_abi.sh 在产物侧兜底。
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

# 前置冒烟:验证 nvcc + clang-16 + libc++ 基础管线(CI 节流 —— 10s 失败好过 40min 后才炸)。
cuda_smoke() {
	local d="${WORKDIR}/smoke"
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
	return static_cast<int>(v.size()) > 0 ? 0 : 1;
}
EOF
	echo "==> CUDA smoke: nvcc + ${CXX:-clang++-16} + -stdlib=libc++"
	if ! nvcc -ccbin "${CXX:-clang++-16}" -Xcompiler=-stdlib=libc++ -std=c++17 \
			"${d}/smoke.cu" -o "${d}/smoke" 2>"${d}/smoke.err"; then
		echo "ERROR: nvcc+clang-16+libc++ 冒烟失败 —— libc++ 传播给 nvcc host 的方式需调整:" >&2
		cat "${d}/smoke.err" >&2
		exit 1
	fi
	echo "    smoke OK"
}

# 统一 cmake 参数(CPU / CUDA 共用)。rpath=$ORIGIN 让 provider .so 能就近找随包 libc++。
# NOTE: \$ORIGIN 在双引号里转义成字面 $ORIGIN。
CMAKE_ARGS=(
	-S "${WORKDIR}/src/static-build"
	-B "${BUILD_DIR}"
	-DCMAKE_BUILD_TYPE=Release
	-DCMAKE_INSTALL_PREFIX="${OUT_DIR}"
	-DONNXRUNTIME_SOURCE_DIR="${SRC_DIR}"
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON
	-DCMAKE_CXX_FLAGS="-stdlib=libc++"
	-DCMAKE_EXE_LINKER_FLAGS="-stdlib=libc++"
	-DCMAKE_SHARED_LINKER_FLAGS="-stdlib=libc++ -Wl,-rpath,\$ORIGIN"
	-DCMAKE_MODULE_LINKER_FLAGS="-stdlib=libc++ -Wl,-rpath,\$ORIGIN"
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
	# nvcc host = clang++-16 + libc++。-Xcompiler 让 nvcc 把 -stdlib=libc++ 传给 host 编译器。
	# NVCC_THREADS=1 限 nvcc 线程内存;QUICK_BUILD + 各 *_ATTENTION/FPA/FP8 OFF 缩小 CUDA kernel 面、提速降风险。
	CMAKE_ARGS+=(
		-Donnxruntime_USE_CUDA=ON
		-Donnxruntime_NVCC_THREADS=1
		-Donnxruntime_CUDNN_HOME="${CUDNN_HOME}"
		-DCUDA_HOME="${CUDA_HOME}"
		-DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}"
		-DCMAKE_CUDA_FLAGS="-ccbin ${CXX:-clang++-16} -Xcompiler=-stdlib=libc++ -compress-mode=size"
		-Donnxruntime_USE_FPA_INTB_GEMM=OFF
		-Donnxruntime_USE_FLASH_ATTENTION=OFF
		-Donnxruntime_USE_MEMORY_EFFICIENT_ATTENTION=OFF
		-Donnxruntime_USE_FP8_KV_CACHE=OFF
		-Donnxruntime_QUICK_BUILD=ON
	)
	export CUDAHOSTCXX="${CXX:-clang++-16}"
	echo "==> CUDA mode: arch=${ARCH} CUDA_HOME=${CUDA_HOME} CUDNN_HOME=${CUDNN_HOME} CUDA_ARCH=${CUDA_ARCH} host=${CUDAHOSTCXX}"

	# 前置冒烟:用最简 .cu 验证 nvcc + clang-16 + libc++ 管线(~10s 失败,免得 40min 后才在 ORT 编译炸)。
	cuda_smoke
else
	echo "==> CPU mode: arch=${ARCH} KLEIDIAI=${KLEIDIAI} AVX2=${AVX2}"
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

# CUDA: 收集 provider .so + libc++ 运行库(provider .so 带 rpath=$ORIGIN 就近找 libc++)。
if [ "${ENABLE_CUDA}" = "1" ]; then
	TARBALL_FILES=(libonnxruntime.a)
	for so in libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so; do
		f="$(find "${OUT_DIR}" -name "${so}" -print -quit)"
		if [ -z "${f}" ]; then
			echo "ERROR: ${so} not found under ${OUT_DIR} after install" >&2
			exit 1
		fi
		cp "${f}" "${OUT_DIR}/${so}"
		TARBALL_FILES+=("${so}")
	done
	for lib in libc++.so.1 libc++abi.so.1; do
		f="$(find /usr /opt -name "${lib}" -print -quit)"
		if [ -z "${f}" ]; then
			echo "ERROR: ${lib} not found in build image (libc++ runtime needed by provider .so)" >&2
			exit 1
		fi
		cp "${f}" "${OUT_DIR}/${lib}"
		TARBALL_FILES+=("${lib}")
	done
else
	TARBALL_FILES=(libonnxruntime.a)
fi

# 统一打包 tar.gz(无论 CPU 单 .a 还是 CUDA 多文件),最终名由 CI 按 arch/cuda 后缀重命名。
PKG_NAME="${ORT_PKG_NAME:-onnxruntime-libcxx}"
( cd "${OUT_DIR}" && tar -czf "${OUT_DIR}/${PKG_NAME}.tar.gz" "${TARBALL_FILES[@]}" )

echo "==> Build done. Package: ${OUT_DIR}/${PKG_NAME}.tar.gz ($(du -h "${OUT_DIR}/${PKG_NAME}.tar.gz" | cut -f1))"
echo "    contents:"; tar -tzf "${OUT_DIR}/${PKG_NAME}.tar.gz"
