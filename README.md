# Ubuntu Cloud Images LVM Converter

This project provides a script and CI pipeline to convert Ubuntu cloud images to LVM format and publish the result as a GitHub Actions artifact.

These images are based on the official Ubuntu Cloud Images provided by Canonical Ltd. (https://cloud-images.ubuntu.com/).

Modifications:
- Create a lvm capable cloud-image by copying the contents into an lvm environment

Ubuntu and Canonical are registered trademarks of Canonical Ltd.

Original Ubuntu software included in this image is licensed under its respective open-source licenses.
See the documentation under /usr/share/doc/ in the image for full license and copyright information.

This image is not endorsed by or affiliated with Canonical Ltd.

## Usage

The main script is `convert-image-to-lvm.sh`. It is used to convert a downloaded Ubuntu cloud image to an LVM-backed image.

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