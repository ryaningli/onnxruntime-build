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
        build-essential \
        cmake \
        ninja-build \
        git \
        python3 \
        python3-dev \
    && wget -qO - https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/focal/ llvm-toolchain-focal-15 main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        clang-15 \
        libc++-15-dev \
        libc++abi-15-dev \
        llvm-15 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

COPY scripts/ /work/scripts/
RUN chmod +x /work/scripts/*.sh
