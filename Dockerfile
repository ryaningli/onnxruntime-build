# Ubuntu 20.04 底包: 锁定 glibc 2.31。
# 容器内用 clang + libc++ 原生编译 ONNX Runtime, 产出 libc++ ABI 静态库。
# 在 amd64 / arm64 原生 runner 上各跑一次, 零交叉编译。
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=clang-15
ENV CXX=clang++-15

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        gnupg \
        wget \
        software-properties-common \
        build-essential \
        cmake \
        ninja-build \
        git \
    # ONNX Runtime 1.28 的 build.py 用了 set[str] 等 PEP585 语法, 需 Python 3.9+;
    # Ubuntu 20.04 默认 python3 是 3.8, 故从 deadsnakes PPA 装 3.9,
    # 并通过 /usr/local/bin 把默认 python3 指向 3.9(不动系统的 3.8, apt 不受影响)。
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.9 \
        python3.9-dev \
        python3.9-distutils \
    && ln -sf /usr/bin/python3.9 /usr/local/bin/python3 \
    && ln -sf /usr/bin/python3.9 /usr/local/bin/python \
    && wget -qO - https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/focal/ llvm-toolchain-focal-15 main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        clang-15 \
        libc++-15-dev \
        libc++abi-15-dev \
        llvm-15 \
    && rm -rf /var/lib/apt/lists/*

# build.py 依赖 pip / setuptools
RUN python3 -m ensurepip --upgrade \
    && python3 -m pip install --no-cache-dir -U setuptools wheel

WORKDIR /work

COPY scripts/ /work/scripts/
RUN chmod +x /work/scripts/*.sh
