# An image that carries the kernel-devel equivalent for one WSL2 kernel, so
# out-of-tree modules can be built for WSL2 the way they are for any distro:
# /lib/modules/<release>/build is populated and the release is in /kversion.
#
# TAG=linux-msft-wsl-6.6.123.2
# docker build -t wsl2-kernel-headers:${TAG} --build-arg TAG=${TAG} .

ARG UBUNTU_VERSION=24.04

FROM ubuntu:${UBUNTU_VERSION} AS build

ARG TAG
# x86 (normal WSL2) or arm64 (Windows on ARM). Native only.
ARG ARCH=x86
# 1 by default: Microsoft's kernels set DEBUG_INFO_BTF_MODULES, and a module
# built against a BTF-less tree is rejected by the loader (see build.sh).
ARG BTF=1
ARG MODULES=0
ARG KEEP_DRIVER_HEADERS=1

RUN test -n "${TAG}" || { echo "TAG is not set"; exit 1; }

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential flex bison libelf-dev libssl-dev bc cpio \
        curl ca-certificates \
        $([ "${BTF}" = "1" ] && echo dwarves) \
    && rm -rf /var/lib/apt/lists/*

# Microsoft builds these kernels with GCC 13. ubuntu:24.04 happens to default to
# 13 as well, which is luck rather than intent - pin it so a future base-image
# bump moves the compiler only when someone decides to. If the base ever stops
# carrying gcc-13, this fails loudly instead of drifting.
ARG GCC_VERSION=13
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc-${GCC_VERSION} g++-${GCC_VERSION} \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-${GCC_VERSION} 100 \
        --slave /usr/bin/g++ g++ /usr/bin/g++-${GCC_VERSION} \
    && gcc --version | head -1

COPY build.sh /build.sh
RUN BTF=${BTF} MODULES=${MODULES} KEEP_DRIVER_HEADERS=${KEEP_DRIVER_HEADERS} \
        /build.sh "${TAG}" "${ARCH}"

FROM ubuntu:${UBUNTU_VERSION}

ARG TAG
ARG ARCH=x86

LABEL org.opencontainers.image.title="WSL2 kernel headers"
LABEL org.opencontainers.image.description="Kernel-devel tree for Microsoft's WSL2 kernel ${TAG} (${ARCH})"
LABEL org.opencontainers.image.source="https://github.com/microsoft/WSL2-Linux-Kernel"
LABEL org.opencontainers.image.licenses="GPL-2.0-only"

# libelf1 is not optional: the prebuilt tools/objtool is dynamically linked
# against it, and on x86 kbuild runs objtool over every module object, so
# without it every module build in this image dies with exit 127.
# dwarves supplies pahole, which kbuild runs over every module to generate its
# BTF (DEBUG_INFO_BTF_MODULES); libelf1 is what the prebuilt objtool links
# against, and on x86 objtool runs over every module object.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git kmod libelf1 dwarves \
    && rm -rf /var/lib/apt/lists/*

# Microsoft builds these kernels with GCC 13. ubuntu:24.04 happens to default to
# 13 as well, which is luck rather than intent - pin it so a future base-image
# bump moves the compiler only when someone decides to. If the base ever stops
# carrying gcc-13, this fails loudly instead of drifting.
ARG GCC_VERSION=13
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc-${GCC_VERSION} g++-${GCC_VERSION} \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-${GCC_VERSION} 100 \
        --slave /usr/bin/g++ g++ /usr/bin/g++-${GCC_VERSION} \
    && gcc --version | head -1

COPY --from=build /wsl-kernel /wsl-kernel

# Where kbuild looks, so `KVERSION=$(cat /kversion) make` needs no other setup.
RUN set -eux; \
    KVERSION="$(cat /wsl-kernel/kversion)"; \
    cp /wsl-kernel/kversion /kversion; \
    mkdir -p "/lib/modules/${KVERSION}"; \
    ln -sf "/wsl-kernel/${TAG}-${ARCH}" "/lib/modules/${KVERSION}/build"; \
    test -f "/lib/modules/${KVERSION}/build/Module.symvers"

# Build a trivial module here, not just in CI: the tree is only half the image,
# and the runtime libraries the prebuilt host tools need are the other half.
# Pruning too much, or missing a shared library, fails right here.
RUN set -eux; \
    KVERSION="$(cat /kversion)"; \
    mkdir -p /tmp/selftest; cd /tmp/selftest; \
    printf '#include <linux/module.h>\nMODULE_LICENSE("GPL");\n' > selftest.c; \
    echo 'obj-m += selftest.o' > Makefile; \
    make -C "/lib/modules/${KVERSION}/build" M=/tmp/selftest modules; \
    modinfo -F vermagic selftest.ko | grep -qF "${KVERSION}"; \
    # A .ko without .BTF is rejected by a DEBUG_INFO_BTF_MODULES kernel
    # (struct module is four fields larger there), and stock WSL2 kernels set
    # it. Building is not enough - the BTF has to be in the module.
    if [ "$(cat /wsl-kernel/btf)" = "1" ]; then \
        readelf -S selftest.ko | grep -q "\.BTF"; \
    fi; \
    cd /; rm -rf /tmp/selftest
