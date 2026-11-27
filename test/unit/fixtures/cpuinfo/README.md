# `/proc/cpuinfo` test fixtures

Real `/proc/cpuinfo` dumps from x86_64 and aarch64, the architectures the
installer ships, with and without AES instructions. `has_aes_acceleration()`
must read each one the way its name says.

- `lab/`: captured from real test hardware, board `Serial` lines zeroed.
  - x86_64 with AES-NI: AMD Ryzen 7 PRO 5850U, Intel Core Ultra 7 155H (hybrid).
  - x86_64 without it: Intel Core 2 Duo P8400, Intel Celeron N2840 (Bay Trail).
  - aarch64 with the crypto extensions: Qualcomm Oryon, Raspberry Pi 5
    (Cortex-A76), a Cortex-A53.
- `py-cpuinfo/`: extracted from `cat_proc_cpuinfo()` in
  [`workhorsy/py-cpuinfo`](https://github.com/workhorsy/py-cpuinfo) (MIT).
  - x86_64 without AES-NI: Intel Pentium G640 (Sandy Bridge).
  - aarch64 without the crypto extensions: ODROID-C2 (Amlogic S905,
    Cortex-A53), the same core as `lab/arm-cortex-a53-aes.txt`.
