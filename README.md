# Ubuntu Cloud Images LVM Converter

[![Build Status](https://github.com/bpmconsultag/ubuntu-cloud-images-lvm/actions/workflows/convert-to-lvm.yml/badge.svg)](https://github.com/bpmconsultag/ubuntu-cloud-images-lvm/actions/workflows/convert-to-lvm.yml)

This project provides a script and CI pipeline to convert Ubuntu cloud images to LVM format and publish the result as a GitHub Actions artifact.

## Latest Build Artifacts

Pre-built images are available as GitHub Actions artifacts from the latest workflow run.
Download the image for your Ubuntu version from the **Artifacts** section at the bottom of the latest run:

**[Download latest build artifacts →](https://github.com/bpmconsultag/ubuntu-cloud-images-lvm/actions/workflows/convert-to-lvm.yml)**

| Image | Artifact name |
| ----- | ------------- |
| Ubuntu 24.04 (amd64) | `lvm-ubuntu-24.04.qcow2` |
| Ubuntu 26.04 (amd64) | `lvm-ubuntu-26.04.qcow2` |
| Ubuntu 26.04 (amd64v3) | `lvm-ubuntu-26.04v3.qcow2` |

These images are based on the official Ubuntu Cloud Images provided by Canonical Ltd. (https://cloud-images.ubuntu.com/).

Modifications:
- Create a lvm capable cloud-image by copying the contents into an lvm environment

Ubuntu and Canonical are registered trademarks of Canonical Ltd.

Original Ubuntu software included in this image is licensed under its respective open-source licenses.
See the documentation under /usr/share/doc/ in the image for full license and copyright information.

This image is not endorsed by or affiliated with Canonical Ltd.

## Disclaimer

**USE AT YOUR OWN RISK.** This project and the images it produces are provided
"as is", without warranty of any kind, express or implied, including but not
limited to the warranties of merchantability, fitness for a particular purpose
and non-infringement. In no event shall the authors or contributors be liable
for any claim, damages or other liability, whether in an action of contract,
tort or otherwise, arising from, out of or in connection with the software or
the use or other dealings in the software. You are solely responsible for
validating the resulting images before using them in any environment.

## Usage

The main script is `convert-image-to-lvm.sh`. It is used to convert a downloaded Ubuntu cloud image to an LVM-backed image.

```bash
./convert-image-to-lvm.sh <source_image> <output_image> [disk_size_gb]
```

The resulting image contains a dedicated EFI System Partition, a separate
`/boot` partition and an LVM root volume, and supports both legacy BIOS and
UEFI boot.

## UEFI Secure Boot

Secure Boot is enabled by default. The image is set up with the standard Ubuntu
boot chain, which works on firmware with Secure Boot enabled without any manual
key enrollment:

- **shim** (Microsoft-signed) → **GRUB** (Canonical-signed) → **kernel** (Canonical-signed)

The signed shim is also installed to the removable/default path
(`/EFI/BOOT/BOOTX64.EFI`) so the image boots even when the firmware has no
matching NVRAM entry.

### Machine Owner Key (MOK)

A MOK is only required when booting **custom** (self-signed) kernels or DKMS
modules under Secure Boot. It is not needed for the stock Ubuntu-signed kernel.

Enable MOK generation with:

```bash
GENERATE_MOK=true ./convert-image-to-lvm.sh <source_image> <output_image> [disk_size_gb]
```

This generates a key pair in the standard Ubuntu location
(`/var/lib/shim-signed/mok/`, used automatically by DKMS) and copies the public
certificate to `/boot/efi/MOK.der`. Because enrollment writes to UEFI
variables, it must be completed interactively on the running system:

```bash
sudo mokutil --import /boot/efi/MOK.der
# reboot and confirm the enrollment in MokManager
```

### Environment variables

| Variable       | Default | Description                                                     |
| -------------- | ------- | --------------------------------------------------------------- |
| `SECURE_BOOT`  | `true`  | Install the signed shim/GRUB chain for UEFI Secure Boot.        |
| `GENERATE_MOK` | `false` | Generate a Machine Owner Key for signing custom kernels/modules.|
| `MOK_SUBJECT`  | `/CN=Ubuntu Cloud Image LVM MOK/` | X.509 subject for the generated MOK certificate. |

## GitHub Actions CI

The CI pipeline automatically:
- Downloads the cloud image(s)
- Converts it to LVM using the provided script
- Publishes the resulting image as a build artifact

### Latest Release

- [Releases](https://github.com/bpmconsultag/ubuntu-cloud-images-lvm/releases/latest)
- [All Releases](https://github.com/bpmconsultag/ubuntu-cloud-images-lvm/releases)

---

For more details, see the script and workflow files in this repository.