# onnxruntime-build

为 [pyke/ort](https://github.com/pykeio/ort) 产出两类自编 ONNX Runtime(基于 Ubuntu 20.04 / glibc 2.31):
- **CPU(libc++ ABI)**:单个静态库,供 `cargo zigbuild --target <triple>.2.31` 链接(覆盖 x86_64 / aarch64)。
- **CUDA(libstdc++ ABI,x86_64)**:`.so` 一组,供 ort `load-dynamic` 运行时 dlopen(CUDA EP 上游无法静态编进 `.a`)。

## 为什么需要

ort 默认下载的 pyke 预编译 ONNX Runtime 是 **libstdc++ ABI**(pyke 用 clang 编译但**未指定 `-stdlib=libc++`**,而 clang 在 Linux 默认走 libstdc++,符号 `std::__cxx11::*`)。而 `cargo zigbuild` 用 zig 当交叉链接器,zig 工具链只自带 **libc++**(`std::__1::*`),**不提供 libstdc++**。两套 C++ ABI 符号名不同,导致 zigbuild 静态链接时报一片 `undefined symbol: std::__cxx11::*`。

本项目从源码用 **clang + libc++** 重编 ONNX Runtime,产出 libc++ ABI 的静态库,且基于 **Ubuntu 20.04(glibc 2.31)**,与 zigbuild 的 `--glibc 2.31` 锁定配套。

## 构建(在 GitHub Actions 上)

仓库 Actions → **build** → Run workflow → 输入 ONNX Runtime **tag(如 `v1.28.0`)或 commit hash**。

构建完成后会自动发布到 GitHub Release(tag `<ref>-libcxx`),每个架构打包成一个 `.tar.gz`(内含 `libonnxruntime.a`):
- `libonnxruntime-x86_64-libcxx.tar.gz`
- `libonnxruntime-aarch64-libcxx.tar.gz`
- `sha256sums.txt`

> **ref 必须与 ort-sys 的 API 版本对应**:v1.28.x ↔ api-28,v1.27.x ↔ api-27,否则头文件符号错配。(用 commit hash 时自行确认对应关系。)

## 本地消费

从 Release 下载对应架构的 `libonnxruntime-<arch>-libcxx.tar.gz` 并解压,然后在 ort 项目里:

```bash
# 以 aarch64 为例
mkdir -p /tmp/ort-lib-aarch64
tar -xzf libonnxruntime-aarch64-libcxx.tar.gz -C /tmp/ort-lib-aarch64
export ORT_LIB_PATH=/tmp/ort-lib-aarch64                # 解压后 .a 所在目录(直接放根目录)
export ORT_CXX_STDLIB=c++                                # 链 libc++ 而非默认的 libstdc++
export ORT_SKIP_DOWNLOAD=1                               # 用自编库,不下载 pyke 预编译包

cargo zigbuild --release --target aarch64-unknown-linux-gnu.2.31
```

三个环境变量(对应 ort-sys 源码):
- `ORT_LIB_PATH` → 触发 `static_link` 单库快速路径(`ort-sys/build/static_link/mod.rs:127`),发 `cargo:rustc-link-lib=static=onnxruntime`。
- `ORT_CXX_STDLIB=c++` → 让 ort-sys 发 `cargo:rustc-link-lib=c++`(`static_link/mod.rs:21-34`),由 zig 自带 libc++ 解析 onnxruntime 符号。
- `ORT_SKIP_DOWNLOAD=1` → 跳过下载 pyke 预编译 libstdc++ 版。

`--target <triple>.2.31` 中的 `.2.31` 后缀让 zigbuild 锁定 glibc 2.31(与产物编译时的 glibc 一致)。

## CUDA 版(libstdc++,load-dynamic)

CUDA EP 走另一条路,**libstdc++ ABI**(非 libc++),且**只覆盖 x86_64**。

> **为什么不是 libc++**:CUDA 的 `crt/host_defines.h` 在 x86 上检测到 `_LIBCPP_VERSION` 即
> `#error "libc++ is not supported on x86 system"` —— CUDA 工具链禁止 x86 + libc++ host 编译。
> 故 CUDA 只能用 libstdc++。而 zig 只提供 libc++、不提供 libstdc++,所以 CUDA **无法走 CPU 那套
> 单库静态 + zigbuild** 的消费方式,改走 ort 的 **load-dynamic**(运行时 dlopen)。
> 此外 CUDA EP 在上游**恒为运行时加载的 MODULE 共享库**(`libonnxruntime_providers_cuda.so`),
> 无法静态编进单个 `.a`。

### 构建

仓库 Actions → **build-cuda** → 输入 ONNX Runtime ref + CUDA 版本(当前仅 `13`)+ 可选 `fast`
(快速验证:只编单个 CUDA arch、不发 Release,用于迭代调试)。CUDA 编译**不需要 GPU**(仅运行期需要)。

工具链照搬 [pykeio/ort-artifacts](https://github.com/pykeio/ort-artifacts):**clang-21 + CUDA 13**,
基于 `nvidia/cuda:13.2.1-cudnn-devel-ubuntu22.04`(jammy,glibc 2.35)。CUDA 版与 CPU 版的 clang-16/libc++ 约束无关 ——
CUDA 走 libstdc++(clang 默认 stdlib),且消费端走 load-dynamic(运行时 dlopen、不经 zig 链接 C++),故用哪个 clang 不受 ABI 契约约束。
此前 clang-16 / gcc-12 wrapper / nvcc 诊断探测 那套是为 CPU 的 libc++ 路线,不适用于 CUDA。

Release(tag `<ref>-cuda<ver>`),`tar.gz` 内:
- `libonnxruntime.a` —— 静态核心(libstdc++;仅 `cargo build` 系统链接器可静态链,zig 不行)
- `libonnxruntime.so`(+ 版本符号链接)—— 共享核心,load-dynamic 入口
- `libonnxruntime_providers_shared.so` / `libonnxruntime_providers_cuda.so` —— CUDA 内核(MODULE)

### 消费(load-dynamic)

```bash
mkdir -p /opt/ort-cuda
tar -xzf libonnxruntime-x86_64-cuda13.tar.gz -C /opt/ort-cuda
export ORT_DYLIB_PATH=/opt/ort-cuda/libonnxruntime.so   # 运行时 dlopen 入口
# zigbuild 只编 Rust、不链接 ORT 的 C++(load-dynamic 禁用链接)—— 故 libstdc++ 不影响 zigbuild
cargo zigbuild --release --features load-dynamic --target x86_64-unknown-linux-gnu.2.35
```

运行时宿主须装对应 CUDA 运行库(cudart/cublas/cudnn,匹配 CUDA 13)+ glibc ≥ 2.35;libstdc++ 由宿主提供(Linux 标配)。

## 本地构建(可选,复现 CI;x86_64 无需 ARM 环境)

```bash
docker build -t ort-builder .
mkdir -p out
# 第一个参数可为 tag 或 commit hash
docker run --rm -e ORT_REF=v1.28.0 -v "$PWD/out:/work/dist" ort-builder \
  bash -c '/work/scripts/build_ort.sh "${ORT_REF}" && /work/scripts/verify_abi.sh'
# 产物: out/onnxruntime-libcxx.tar.gz(内含 libonnxruntime.a)
```

## 设计要点

- **Ubuntu 20.04 容器锁 glibc 2.31**:`ubuntu-20.04` runner 已于 2025-04 下线,改用 `ubuntu:20.04` Docker 镜像保证 glibc 2.31。
- **Python 3.11(Miniforge3)**:ORT 的 `build.py` 刚需 `flatbuffers`(schema 生成)等 pip 包,且 ORT 需 cmake≥3.28(apt 仅 3.16)。Ubuntu 20.04 默认 python3 是 3.8;deadsnakes PPA 已失效、python-build-standalone 带 PEP 668 标记且有别名软链坑。改用 **Miniforge3**(conda-forge):跨架构(仅要求 glibc≥2.17)、无 PEP 668、无软链坑,一份 Dockerfile 用 `uname -m` 自动选 amd64/arm64 安装器,pip 顺带装新版 cmake/ninja。
- **clang + libc++ 原生编译,不用 zig 编 ORT**:ORT 的 CMake 工程(FetchContent + protoc/flatc 主机工具 + cpuinfo)交叉编译风险高、无成功先例,故在容器内 clang/libc++ 原生编。两架构各用对应原生 runner(amd64 / arm64),零交叉编译。
- **CMake `bundle_static_library` 内联合并**:移植自 [pykeio/ort-artifacts](https://github.com/pykeio/ort-artifacts) 的 `static-build` 工程——递归遍历 `onnxruntime` target 依赖图收集全部分量 + abseil/protobuf/re2/onnx/cpuinfo 等依赖,用 GNU ar MRI(`${CMAKE_AR}`)合并成单个 `libonnxruntime.a`。GNU ar MRI 保留同名 member(onnx 各域 `defs.cc.o`)且符号表索引有效,根治此前 `ar x` 覆盖 / llvm-ar MRI 空索引 / `find` 漏库三连失败。让 ort-sys 走单库消费路径(与 pyke 官方包等价)。
- **zigbuild 保留**:仅用于本地最终链接,发挥其 glibc 锁定 + libc++ 解析能力。CI 编 ORT 用 clang,本地链接用 zig,两者靠「glibc 2.31 + libc++ ABI」契约衔接。

## 文件

| 文件 | 作用 |
|---|---|
| `Dockerfile` | ubuntu:20.04 + Miniforge/python3.11 + clang-16 + libc++ 的 **CPU** 构建环境 |
| `Dockerfile.cuda` | nvidia/cuda cudnn-devel(ubuntu22.04/jammy)+ clang-21 的 **CUDA** 构建环境(libstdc++,照搬 pyke 的 clang-21 + CUDA 13) |
| `src/static-build/CMakeLists.txt` | CMake `bundle_static_library` 打包工程(移植自 pyke),内联合并成单库 |
| `src/patches/` | 与 [pykeio/ort-artifacts](https://github.com/pykeio/ort-artifacts) 的 `src/patches/all` 对齐(0001–0007,跳 0005):no-soname、cpuinfo arm64、logger-mutex、kernel-registry-release、abseil `__NVCC__` 守卫、CUDA kernel 编译修复;另增 `0009-disable-warnings-as-error.patch`(ORT v1.28 的目标级 `COMPILE_WARNING_AS_ERROR ON` 会盖掉全局 `OFF`,把 cutlass unused-function / upsample unused-lambda-capture 升为 `-Werror`,在源头关掉 —— pyke 用更新 ORT、上游已修,故无需)|
| `scripts/build_ort.sh` | 按 tag/commit hash 拉取 + 打补丁 + cmake 直驱编译 ORT(CPU=libc++ / CUDA=libstdc++)+ 内联 bundle + 打 tar.gz |
| `scripts/verify_abi.sh` | CI 质量门禁(CPU 校验 libc++;CUDA 校验 libstdc++ + `.so` 集合) |
| `.github/workflows/build.yml` | **CPU**:输入 ref,矩阵构建 x86_64 + aarch64,发布到 `<ref>-libcxx` |
| `.github/workflows/build-cuda.yml` | **CUDA**:输入 ref + cuda_version(13),x86_64,发布到 `<ref>-cuda<ver>` |
