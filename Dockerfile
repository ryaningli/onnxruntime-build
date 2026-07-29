# Ubuntu 20.04 底包: 锁定 glibc 2.31。
# 容器内用 clang + libc++ 原生编译 ONNX Runtime, 产出 libc++ ABI 静态库。
# 在 amd64 / arm64 原生 runner 上各跑一次, 零交叉编译。
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=clang-15
ENV CXX=clang++-15

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        wget \
        build-essential \
        cmake \
        ninja-build \
        git \
    && wget -qO - https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/focal/ llvm-toolchain-focal-15 main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        clang-15 \
        libc++-15-dev \
        libc++abi-15-dev \
        llvm-15 \
    && rm -rf /var/lib/apt/lists/*

# ONNX Runtime 1.28 的 build.py 用了 set[str] 等 PEP585 语法, 需 Python 3.9+。
# Ubuntu 20.04 默认 python3 是 3.8; deadsnakes PPA 不提供 arm64 包,
# 故改用 uv 安装跨架构预编译的 Python 3.9(python-build-standalone 同时覆盖 aarch64 与 x86_64)。
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && /root/.local/bin/uv python install 3.9 \
    && ln -sf /root/.local/share/uv/python/cpython-3.9*/bin/python3.9 /usr/local/bin/python3 \
    && ln -sf /usr/local/bin/python3 /usr/local/bin/python

# python-build-standalone (uv 安装) 自带 pip, 直接升级构建依赖;
# 不用 ensurepip —— Debian/deadsnakes 把它拆进 python3.x-venv 包, 不可靠。
RUN python3 -m pip install --no-cache-dir -U setuptools wheel

WORKDIR /work

COPY scripts/ /work/scripts/
RUN chmod +x /work/scripts/*.sh
