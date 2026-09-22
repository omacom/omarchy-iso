# Pinned firmware inputs

`../fetch-firmware.py` downloads and extracts these inputs automatically.
`../prepare-packages.py` consumes the verified files directly. The machine needs
no retained packages or sibling repository. Vendor installers are never executed.
Archive pins are in `sources.json`; final files are checked against
`hp-files.sha256` and `t14s-files.sha256`.

## HP GPU and DSP

- Source: https://ftp.hp.com/pub/softpaq/sp162501-163000/sp162865.exe
- Metadata: https://ftp.hp.com/pub/softpaq/sp162501-163000/sp162865.cva
- Pack: SP162865, 7700.1 revision E pass 5.
- Archive SHA256: `215ec14bef7090660a5e868f22e84fbeea2ee1139706a0615bfda62948417e08`.

Extract with 7z, without executing the archive. Under `src/Driver/`, use:

| Input directory | Files |
| --- | --- |
| `qcdx8380` | `qcdxkmsuc8380.mbn` |
| `1ADSP_7700_0711_hamoa` | `qcadsp8380.mbn`, `adsp_dtbs.elf` |
| `1qcnspmcdm_ext_cdsp8380_7800` | `qccdsp8380.mbn`, `cdsp_dtbs.elf` |

Destination is `/usr/lib/firmware/updates/qcom/x1e80100/hp/elitebook-ultra-g1q/`.
Redistribution permission for these extracted HP files has not been established. Obtain the original vendor terms before hosting these binaries.

## Lenovo cDSP replacement pair

- Source: https://download.lenovo.com/pccbbs/mobiles/n42qq23w.exe
- Metadata: https://download.lenovo.com/pccbbs/mobiles/n42qq23w_2_.xml
- Archive SHA256: `9ec6ae30abd40f56aa6b3b0b480686acbbb72ff12ba186b3f45f61fc924ef4f3`.

Use `innoextract`, never execute the installer. Selected directory:
`code$GetExtractPath$/N42QQ23W/N42QG16W/Core_drivers/qcnspmcdm_ext_cdsp8380`.
Copy `qccdsp8380.mbn` and `cdsp_dtbs.elf` over the base Lenovo firmware in
`/usr/lib/firmware/updates/qcom/x1e80100/LENOVO/21N1/`.
Redistribution terms for this exact pair remain to be established.

## Lenovo base firmware

The base Lenovo files are extracted from `casper/minimal.squashfs` of
`https://cdimage.ubuntu.com/releases/26.04/release/ubuntu-26.04.1-desktop-arm64.iso`.
The retained bootstrap manifest pins that ISO to
`c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517`.
The clean-input validation downloaded this ISO directly and verified its archive
and selected-file hashes. Do not substitute another release without comparing payloads.

Original extraction used xorriso to extract `/casper`, then unsquashfs on
`minimal.squashfs` for `usr/lib/firmware` and `usr/share/doc/linux-firmware*`.
Select the `qcom/x1e80100/LENOVO/21N1` files, decompress `.zst` files, retain the
T14 topology alias, and replace the cDSP pair as above. `t14s-files.sha256` lists
exact final payloads. Preserve the source Qualcomm graphics/misc/wireless copyright
notices and resolve per-file terms before binary redistribution.

## Audio topology and HP UCM

The HP topology was built from BSD-3-Clause AudioReach sources at
`e7b20b2b16cdda18eb8ae143c8d95c4815c0288e`:
https://codeload.github.com/linux-msm/audioreach-topology/tar.gz/e7b20b2b16cdda18eb8ae143c8d95c4815c0288e

Archive SHA256: `bce3f22893decde37a810ed17ac690abc9c9fd39e7417021abc37e925cb1c82e`.
Run m4 with the source directory as its include path on
`X1E80100-LENOVO-Thinkpad-T14s.m4`, then `alsatplg -c` on the generated text.
Output topology SHA256:
`aa303397750f883ecaeed874d7547da658500596247676a6d405bf1ec43290b5`.
Install as `qcom/x1e80100/X1E80100-HP-ELITEBOOK-ULTRA-G1Q-tplg.bin` and carry
`LICENSE.BSD-3-Clause`. HP UCM generation is in `../prepare-packages.py`; it checks
three exact ALSA UCM source hashes before applying the DMIC2 change.

## Verification and distribution

The clean-input check runs in the Dockerfile alongside this document and uses
only network downloads plus the checked-in scripts/manifests. It rebuilds the
topology and verifies every selected payload byte. The ISO builder repeats those
checks and carries source provenance and licenses in the generated packages.
The vendor archives remain download-at-build inputs; binary redistribution terms
for the extracted HP/Lenovo files must still be resolved before public ISO release.
No QNN SDK or proprietary inference runtime is included.

## Official package-source inputs

The clean-build launcher uses these official repositories:

| Input | Commit | Purpose |
| --- | --- | --- |
| `omacom/omarchy` | `66a33c339914cfa0e41ec1fce8f198ea779b8aea` | Dragon runtime and hardware setup |
| `omacom/omarchy-pkgs` | `e0959b06f5f5745dc67ea2f207619a096bd485fd` | Runtime/settings/Neovim recipes |
| `omacom/omarchy-pkgs` PR 221 | `4a232b639957a251bfe9220d7d253b95fe5ae635` | Firmware extraction recipe |
| `omacom/omarchy-pkgs` PR 222 | `3951d934ccd30b72b68f3d954a220b830fb8143d` | Kernel metadata recipe |

A checked-in patch retains ARM UEFI settings and Limine dependencies in the
source-built runtime/settings packages. The helper fails if that patch no longer
applies. These are build-local changes, not claims that upstream merged the patch.
