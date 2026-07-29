# Ubuntu 20.04 底包: 锁定 glibc 2.31(配合 zigbuild --glibc 2.31)。
# 容器内 clang + libc++ 原生编译 ONNX Runtime → libc++ ABI 静态库。
# 同一份 Dockerfile 适配 amd64 / arm64(runner 决定容器架构, uname -m 自动选 Miniforge 安装器)。
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=clang-16
ENV CXX=clang++-16

# 1) 系统工具 + clang-16 / libc++-16-dev / libc++abi-16-dev / llvm-16(提供 llvm-ar、llvm-nm)。
#    经 apt.llvm.org focal 套件: amd64 + arm64 均可用。
#    选 16 而非 15: ORT 的 cvtfp16Avx.S 用 AVX-NE-CONVERT 指令, clang 16 才支持(ORT#22519)。
#    不用 18+: focal aarch64 有依赖破损(llvm-project#99453)。
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        wget \
        build-essential \
        git \
    && wget -qO - https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/focal/ llvm-toolchain-focal-16 main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        clang-16 \
        libc++-16-dev \
        libc++abi-16-dev \
        llvm-16 \
    && rm -rf /var/lib/apt/lists/*

# 2) Python 3.11 + 构建工具 via Miniforge3(conda-forge)。
#    根治之前 Python 拼装的三个坑:
#      - deadsnakes PPA 已失效;
#      - python-build-standalone 带 PEP 668 标记 → pip 拒绝;
#      - python-build-standalone 目录有别名软链 → glob 多源 → ln 失败。
#    Miniforge 跨架构、无 PEP 668、无别名软链、sysconfig 干净。
#    uname -m 自动选安装器 → 同一份 Dockerfile 跑 amd64 / arm64。
#    pip 装 ORT build.py 刚需包 + conda 装 cmake(含 ctest, ORT build.py 启动即要求)/ninja。
RUN ARCH="$(uname -m)" \
    && case "$ARCH" in \
         x86_64)  M=x86_64 ;; \
         aarch64) M=aarch64 ;; \
         *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/miniforge.sh \
         "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${M}.sh" \
    && bash /tmp/miniforge.sh -b -p /opt/miniforge3 \
    && rm /tmp/miniforge.sh \
    && /opt/miniforge3/bin/conda create -y -n ortbuild python=3.11 \
    && /opt/miniforge3/envs/ortbuild/bin/pip install --no-cache-dir \
         flatbuffers numpy packaging protobuf \
    && /opt/miniforge3/bin/conda install -n ortbuild -y -c conda-forge cmake ninja \
    && ln -sf /opt/miniforge3/envs/ortbuild/bin/python3 /usr/local/bin/python3 \
    && ln -sf /opt/miniforge3/envs/ortbuild/bin/python3 /usr/local/bin/python

# conda env 的 bin 加入 PATH, 让 ORT build.py 能解析到 cmake / ctest / ninja。
ENV PATH=/opt/miniforge3/envs/ortbuild/bin:${PATH}

WORKDIR /work

COPY scripts/ /work/scripts/
RUN chmod +x /work/scripts/*.sh
