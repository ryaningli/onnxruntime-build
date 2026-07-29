#!/usr/bin/env bash
# 用 clang + libc++ 从源码编译 ONNX Runtime 静态库。
# 不传 --build_shared_lib → onnxruntime_BUILD_SHARED_LIB=OFF → 产出静态分量库。
# FetchContent 拉取的 abseil/protobuf/re2 等会跟着 clang+libc++ 编, ABI 天然一致。
set -euo pipefail

ORT_TAG="${1:-${ORT_TAG:-}}"
if [ -z "${ORT_TAG}" ]; then
	echo "ERROR: ORT_TAG not provided. Pass it as \$1 or set the ORT_TAG env var." >&2
	exit 1
fi
JOBS="${JOBS:-$(nproc)}"
WORKDIR="${WORKDIR:-/work}"
SRC_DIR="${WORKDIR}/onnxruntime"

echo "==> Cloning ONNX Runtime ${ORT_TAG} -> ${SRC_DIR}"
if [ ! -d "${SRC_DIR}/.git" ]; then
	git clone --branch "${ORT_TAG}" --depth 1 --recursive https://github.com/microsoft/onnxruntime.git "${SRC_DIR}"
fi

cd "${SRC_DIR}"

echo "==> Building static lib (clang + libc++, ${JOBS} jobs)"
export CC=clang-15
export CXX=clang++-15

./build.sh \
	--config Release \
	--parallel "${JOBS}" \
	--skip_tests \
	--update --build \
	--cmake_extra_defines onnxruntime_BUILD_SHARED_LIB=OFF \
	--cmake_extra_defines CMAKE_CXX_FLAGS="-stdlib=libc++" \
	--cmake_extra_defines CMAKE_EXE_LINKER_FLAGS="-stdlib=libc++" \
	--cmake_extra_defines CMAKE_SHARED_LINKER_FLAGS="-stdlib=libc++" \
	--cmake_extra_defines CMAKE_POSITION_INDEPENDENT_CODE=ON

echo "==> Build done. Artifacts under ${SRC_DIR}/build/Linux/Release"
