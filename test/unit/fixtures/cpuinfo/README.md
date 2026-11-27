# `/proc/cpuinfo` test fixtures

Grouped by origin:

- `lab/` — captured directly from real test hardware (x86_64 Intel/AMD, aarch64 Apple Silicon/Qualcomm/Raspberry Pi 5/Cortex-A53; board `Serial` lines zeroed).
- `py-cpuinfo/` — extracted from `cat_proc_cpuinfo()` in [`workhorsy/py-cpuinfo`](https://github.com/workhorsy/py-cpuinfo) (MIT) to cover aarch64 without AES (ODROID-C2 / Amlogic S905), older Intel x86_64 without AES-NI (Nehalem, Pentium G640), ARMv7, and non-x86 architectures (MIPS, LoongArch, POWER8).
- `util-linux/` — extracted from `tests/ts/lscpu/dumps/` in [`util-linux/util-linux`](https://github.com/util-linux/util-linux) (GPL-2.0-or-later) to cover heterogeneous ARM64 big.LITTLE (`A510`/`A710`/`A715`/`X3`), and Westmere AES-NI (Intel Core i5 M 560).
