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
ARG BTF=0
ARG MODULES=0
ARG KEEP_DRIVER_HEADERS=1

RUN test -n "${TAG}" || { echo "TAG is not set"; exit 1; }

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential flex bison libelf-dev libssl-dev bc cpio \
        curl ca-certificates \
        $([ "${BTF}" = "1" ] && echo dwarves) \
    && rm -rf /var/lib/apt/lists/*

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

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git kmod \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /wsl-kernel /wsl-kernel

# Where kbuild looks, so `KVERSION=$(cat /kversion) make` needs no other setup.
RUN set -eux; \
    KVERSION="$(cat /wsl-kernel/kversion)"; \
    cp /wsl-kernel/kversion /kversion; \
    mkdir -p "/lib/modules/${KVERSION}"; \
    ln -sf "/wsl-kernel/${TAG}-${ARCH}" "/lib/modules/${KVERSION}/build"; \
    test -f "/lib/modules/${KVERSION}/build/Module.symvers"
