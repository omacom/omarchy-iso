# Hardware the test VM does not have

`bin/omarchy-iso-test --fake-pci VENDOR:DEVICE:CLASS` gives the VM a PCI
function with those IDs. The guest is unmodified: `lspci`,
`/sys/bus/pci/devices`, udev and modalias all report them. No driver can
drive the device; what it exercises is everything that keys off the hardware
being present: detection, the kernel and packages an install selects, DKMS
builds and boot configuration.

| Hardware | `--fake-pci` |
| --- | --- |
| Apple T2 | `106b:1802:088000` |
| NVIDIA, open driver (Turing and newer) | `10de:2684:030000` (RTX 4090) |
| NVIDIA, 580xx driver (Maxwell to Volta) | `10de:1b80:030000` (GTX 1080) |

## How it works

QEMU's `vfio-user-pci` device (QEMU 10.1 and newer) attaches a PCI device
that is implemented by another process, over a Unix socket. Its
`x-pci-vendor-id`, `x-pci-device-id` and `x-pci-class-code` properties
replace the IDs the guest reads, so any vfio-user server will do. The harness
starts one per `--fake-pci` and sets the IDs on QEMU's side. The guest's
memory has to be a shareable memfd, which the harness also sets up.

The `x-` properties are experimental in QEMU and may change between releases.

## The server

The harness runs `$VFIO_USER_SERVER <socket>`, by default
`gpio-pci-idio-16` from `PATH`: the sample server of
[libvfio-user](https://github.com/nutanix/libvfio-user). Arch does not
package the library; building the sample needs meson, ninja, json-c and
cmocka:

    git clone --depth 1 https://github.com/nutanix/libvfio-user
    meson setup libvfio-user/build libvfio-user -Ddefault_library=static
    ninja -C libvfio-user/build samples/gpio-pci-idio-16
    export VFIO_USER_SERVER=$PWD/libvfio-user/build/samples/gpio-pci-idio-16
