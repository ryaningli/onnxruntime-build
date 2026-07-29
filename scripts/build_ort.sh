#!/usr/bin/env bash
# 用 clang + libc++ 从源码编译 ONNX Runtime, 经 CMake `bundle_static_library` 把全部分量
# 与依赖(onnx / protobuf / re2 / cpuinfo / absl...)按 target 依赖图递归收集, 用 GNU ar MRI
# 内联合并成单个 libonnxruntime.a —— 移植自 pykeio/ort-artifacts 的 static-build 工程。
#
# 关键: 打包用 ${CMAKE_AR}(Ubuntu 上 = GNU ar)做 MRI, 故符号表索引有效且保留同名 member
# (onnx 各域 defs.cc.o)。此前用 llvm-ar MRI(索引空)+ find 收集(漏库)反复失败,本方案根治。
#
# 刻意偏离 pyke 的三处(否则重制 ABI bug):
#   - ABI:   clang-16 + -stdlib=libc++  (pyke 用 clang-21 默认 libstdc++ / gcc-14)
#   - glibc: ubuntu:20.04 容器           (pyke 用 ubuntu-24.04 裸跑 = glibc 2.39)
#   - arm:   arm64 原生 runner            (pyke 用 gcc 交叉编译)
#
# 用法: build_ort.sh <ref>   其中 <ref> 可以是 tag(如 v1.28.0)或 commit hash。
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

# 分架构的 provider 开关(KLEIDIAI 仅 aarch64;USE_AVX2 运行时检测、安全,不强加 -march)。
ARCH="$(uname -m)"
case "${ARCH}" in
	x86_64)  KLEIDIAI=OFF; AVX2=ON  ;;
	aarch64) KLEIDIAI=ON;  AVX2=OFF ;;
	*) echo "ERROR: unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac

echo "==> Configuring (clang-16 + libc++, arch=${ARCH}, KLEIDIAI=${KLEIDIAI}, AVX2=${AVX2})"
# -stdlib=libc++ 经 ORT adjust_global_compile_flags.cmake 传播到 FetchContent 依赖;
# module/exe linker flag 覆盖 protoc/flatc 等构建期主机工具。
cmake -S "${WORKDIR}/src/static-build" -B "${BUILD_DIR}" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="${OUT_DIR}" \
	-DONNXRUNTIME_SOURCE_DIR="${SRC_DIR}" \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-DCMAKE_CXX_FLAGS="-stdlib=libc++" \
	-DCMAKE_EXE_LINKER_FLAGS="-stdlib=libc++" \
	-DCMAKE_SHARED_LINKER_FLAGS="-stdlib=libc++" \
	-DCMAKE_MODULE_LINKER_FLAGS="-stdlib=libc++" \
	-DCMAKE_COMPILE_WARNING_AS_ERROR=OFF \
	-Donnxruntime_BUILD_UNIT_TESTS=OFF \
	-Donnxruntime_CLIENT_PACKAGE_BUILD=ON \
	-Donnxruntime_USE_KLEIDIAI="${KLEIDIAI}" \
	-Donnxruntime_USE_AVX2="${AVX2}"

echo "==> Building + bundling (this also runs bundle_static_library -> single libonnxruntime.a)"
cmake --build "${BUILD_DIR}" --config Release --parallel "${JOBS}"

echo "==> Installing"
cmake --install "${BUILD_DIR}"

# install 落在 ${OUT_DIR}/lib*/libonnxruntime.a(lib 或 lib64 不定),拷到根目录满足
# ort-sys 单库快速路径契约(ORT_LIB_PATH 根目录放单个 libonnxruntime.a)。
INSTALLED="$(find "${OUT_DIR}" -name libonnxruntime.a -print -quit)"
if [ -z "${INSTALLED}" ]; then
	echo "ERROR: libonnxruntime.a not found under ${OUT_DIR} after install" >&2
	exit 1
fi
cp "${INSTALLED}" "${OUT_DIR}/libonnxruntime.a"

echo "==> Build done. Single bundled lib: ${OUT_DIR}/libonnxruntime.a ($(du -h "${OUT_DIR}/libonnxruntime.a" | cut -f1))"
