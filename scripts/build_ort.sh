#!/usr/bin/env bash
# 用 clang + libc++ 从源码编译 ONNX Runtime 静态库。
# 不传 --build_shared_lib → onnxruntime_BUILD_SHARED_LIB=OFF → 产出静态分量库。
# FetchContent 拉取的 abseil/protobuf/re2 等会跟着 clang+libc++ 编, ABI 天然一致。
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

echo "==> Building static lib (clang + libc++, ${JOBS} jobs)"
export CC=clang-15
export CXX=clang++-15

./build.sh \
	--config Release \
	--parallel "${JOBS}" \
	--skip_tests \
	--allow_running_as_root \
	--update --build \
	--cmake_extra_defines onnxruntime_BUILD_SHARED_LIB=OFF \
	--cmake_extra_defines onnxruntime_BUILD_UNIT_TESTS=OFF \
	--cmake_extra_defines onnxruntime_ENABLE_PYTHON=OFF \
	--cmake_extra_defines CMAKE_CXX_FLAGS="-stdlib=libc++" \
	--cmake_extra_defines CMAKE_EXE_LINKER_FLAGS="-stdlib=libc++" \
	--cmake_extra_defines CMAKE_SHARED_LINKER_FLAGS="-stdlib=libc++" \
	--cmake_extra_defines CMAKE_MODULE_LINKER_FLAGS="-stdlib=libc++" \
	--cmake_extra_defines CMAKE_POSITION_INDEPENDENT_CODE=ON

echo "==> Build done. Artifacts under ${SRC_DIR}/build/Linux/Release"
