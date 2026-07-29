# onnxruntime-build

为 [pyke/ort](https://github.com/pykeio/ort) 的 **zigbuild 交叉编译** 产出 **libc++ ABI** 的 ONNX Runtime 静态库(基于 Ubuntu 20.04 / glibc 2.31,覆盖 x86_64 与 aarch64)。

## 为什么需要

ort 默认下载的 pyke 预编译 ONNX Runtime 是 **libstdc++ ABI**(GCC 编译,符号 `std::__cxx11::*`)。而 `cargo zigbuild` 用 zig 当交叉链接器,zig 工具链只自带 **libc++**(`std::__1::*`),**不提供 libstdc++**。两套 C++ ABI 符号名不同,导致 zigbuild 链接时报一片 `undefined symbol: std::__cxx11::*`。

本项目从源码用 **clang + libc++** 重编 ONNX Runtime,产出 libc++ ABI 的静态库,且基于 **Ubuntu 20.04(glibc 2.31)**,与 zigbuild 的 `--glibc 2.31` 锁定配套。

## 构建(在 GitHub Actions 上)

仓库 Actions → **build** → Run workflow → 输入 ONNX Runtime **tag(如 `v1.28.0`)或 commit hash**。

构建完成后会自动发布到 GitHub Release(tag `<ref>-libcxx`),含两个架构的产物:
- `libonnxruntime-x86_64.a`
- `libonnxruntime-aarch64.a`
- `sha256sums.txt`

> **ref 必须与 ort-sys 的 API 版本对应**:v1.28.x ↔ api-28,v1.27.x ↔ api-27,否则头文件符号错配。(用 commit hash 时自行确认对应关系。)

## 本地消费

从 Release 下载对应架构的 `libonnxruntime-<arch>.a`(可重命名为 `libonnxruntime.a`),然后在 ort 项目里:

```bash
# 以 aarch64 为例
export ORT_LIB_PATH=/path/to/dir-with-libonnxruntime-a  # 库所在目录(直接放根目录,不要放 Release/ 子目录)
export ORT_CXX_STDLIB=c++                                # 链 libc++ 而非默认的 libstdc++
export ORT_SKIP_DOWNLOAD=1                               # 用自编库,不下载 pyke 预编译包

cargo zigbuild --release --target aarch64-unknown-linux-gnu.2.31
```

三个环境变量(对应 ort-sys 源码):
- `ORT_LIB_PATH` → 触发 `static_link` 单库快速路径(`ort-sys/build/static_link/mod.rs:127`),发 `cargo:rustc-link-lib=static=onnxruntime`。
- `ORT_CXX_STDLIB=c++` → 让 ort-sys 发 `cargo:rustc-link-lib=c++`(`static_link/mod.rs:21-34`),由 zig 自带 libc++ 解析 onnxruntime 符号。
- `ORT_SKIP_DOWNLOAD=1` → 跳过下载 pyke 预编译 libstdc++ 版。

`--target <triple>.2.31` 中的 `.2.31` 后缀让 zigbuild 锁定 glibc 2.31(与产物编译时的 glibc 一致)。

## 本地构建(可选,复现 CI;x86_64 无需 ARM 环境)

```bash
docker build -t ort-builder .
mkdir -p out
# 第一个参数可为 tag 或 commit hash
docker run --rm -e ORT_REF=v1.28.0 -v "$PWD/out:/work/dist" ort-builder \
  bash -c '/work/scripts/build_ort.sh "${ORT_REF}" && /work/scripts/merge_lib.sh && /work/scripts/verify_abi.sh'
# 产物: out/libonnxruntime.a
```

## 设计要点

- **Ubuntu 20.04 容器锁 glibc 2.31**:`ubuntu-20.04` runner 已于 2025-04 下线,改用 `ubuntu:20.04` Docker 镜像保证 glibc 2.31。
- **Python 3.11(Miniforge3)**:ORT 的 `build.py` 刚需 `flatbuffers`(schema 生成)等 pip 包,且 ORT 需 cmake≥3.28(apt 仅 3.16)。Ubuntu 20.04 默认 python3 是 3.8;deadsnakes PPA 已失效、python-build-standalone 带 PEP 668 标记且有别名软链坑。改用 **Miniforge3**(conda-forge):跨架构(仅要求 glibc≥2.17)、无 PEP 668、无软链坑,一份 Dockerfile 用 `uname -m` 自动选 amd64/arm64 安装器,pip 顺带装新版 cmake/ninja。
- **clang + libc++ 原生编译,不用 zig 编 ORT**:ORT 的 CMake 工程(FetchContent + protoc/flatc 主机工具 + cpuinfo)交叉编译风险高、无成功先例,故在容器内 clang/libc++ 原生编。两架构各用对应原生 runner(amd64 / arm64),零交叉编译。
- **合并胖单库**:把 ORT 分量 + abseil/protobuf/re2/onnx/cpuinfo 等依赖合并成单个 `libonnxruntime.a`,让 ort-sys 走最简单的单库消费路径(与 pyke 官方包等价)。
- **zigbuild 保留**:仅用于本地最终链接,发挥其 glibc 锁定 + libc++ 解析能力。CI 编 ORT 用 clang,本地链接用 zig,两者靠「glibc 2.31 + libc++ ABI」契约衔接。

## 文件

| 文件 | 作用 |
|---|---|
| `Dockerfile` | ubuntu:20.04 + Miniforge/python3.11 + clang-16 + libc++ 构建环境 |
| `scripts/build_ort.sh` | 按 tag/commit hash 拉取 + 静态编译 ORT(libc++) |
| `scripts/merge_lib.sh` | 合并所有 `.a` 成单个胖 `libonnxruntime.a` |
| `scripts/verify_abi.sh` | CI 质量门禁,确保产物是 libc++ ABI |
| `.github/workflows/build.yml` | 输入 ref,矩阵构建 x86_64 + aarch64,发布到 Release |
