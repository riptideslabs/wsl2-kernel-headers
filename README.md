# wsl2-kernel-headers

Kernel-devel trees for Microsoft's WSL2 kernels, as container images.

WSL2 boots a Microsoft-built kernel (`*-microsoft-standard-WSL2`) and ships no
kernel-headers package for it, so there is nothing on the machine to build an
out-of-tree module against — DKMS included. Microsoft has left this open for
years ([WSL#11557](https://github.com/microsoft/WSL/issues/11557)). This repo
builds the tree from Microsoft's own tags and publishes it in the shape a distro
`kernel-devel` package would take.

## Using it

```bash
docker run --rm -it ghcr.io/riptideslabs/wsl2-kernel-headers:linux-msft-wsl-6.6.123.2-x86
# /kversion                        -> 6.6.123.2-microsoft-standard-WSL2
# /lib/modules/<release>/build     -> the kernel-devel tree
```

Building a module needs no WSL2-specific setup, because the layout is the one
kbuild expects anyway:

```dockerfile
FROM ghcr.io/riptideslabs/wsl2-kernel-headers:linux-msft-wsl-6.6.123.2-x86
COPY . /src
WORKDIR /src
RUN KVERSION="$(cat /kversion)" make
```

A module built here loads on a stock WSL2 kernel of the same tag: same source,
same config, so vermagic and the symbol CRCs match. Verify before shipping:

```bash
modinfo -F vermagic your.ko   # must equal the running `uname -r` line
```

## Building locally

```bash
./build.sh linux-msft-wsl-6.6.123.2 x86      # ~15-30 min, mostly the kernel
docker build --build-arg TAG=linux-msft-wsl-6.6.123.2 -t wsl2-kernel-headers:local .
```

Knobs (env for `build.sh`, `--build-arg` for the image):

| | default | |
|-|-|-|
| `BTF` | `0` | keep BTF, for CO-RE eBPF against this kernel. Slower, much larger, needs pahole. |
| `MODULES` | `0` | run the real `make modules` instead of reusing `vmlinux.symvers`. These configs carry 1-2.5k modules. |
| `KEEP_DRIVER_HEADERS` | `1` | keep `drivers/**/*.h` (~500 MB). Only in-tree drivers need them; drop for a ~220 MB image. |

Native only — `build.sh` refuses a non-host arch rather than half-configuring a
tree. Cross-building is possible but not wired up here.

## What the nightly job does

Polls Microsoft's live branches (6.6.y, 6.18.y) for the highest tag, skips what
is already published, and builds the rest. WSL2 kernels land a few times a year
per branch, so most nights are a no-op. Each image is smoke-tested by building
a trivial module inside it before the push.

`arm64` (Windows on ARM) is left out of the nightly matrix for now: hosted
arm64 runners are not free for private repos. Build it by hand on an arm64 host,
or add the matrix entry once this repo is public.

## Notes

- **Source**: unmodified tags from
  [microsoft/WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel).
  The kernel is GPL-2.0; these images redistribute part of it (headers,
  `Module.symvers`, the built kernel image), and the corresponding source is that
  public tag plus the in-tree `arch/<arch>/configs/config-wsl*` config, with
  debug info disabled unless `BTF=1`.
- **Pruning**: objects, sources, docs and other architectures are removed;
  headers, generated config, `scripts/`, `tools/` and `Module.symvers` are kept.
  `scripts/` and `tools/` sources stay, since kbuild may re-link those host
  tools.
- This repo is private for now. Pick a license for the scripts before making it
  public.
