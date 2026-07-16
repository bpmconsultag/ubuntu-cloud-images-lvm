#!/bin/bash
# Script to fully convert Ubuntu cloud images to use LVM for the root filesystem
# This script uses guestfish to convert the image entirely offline (no boot required)
#
# Usage: ./convert-image-to-lvm.sh <source_image> <output_image> [disk_size_gb]
#
# The resulting disk layout:
#   - Partition 1: BIOS boot (1MB) - for legacy BIOS booting
#   - Partition 2: EFI System Partition (512MB) - for UEFI booting
#   - Partition 3: /boot partition (1GB) - ext4, contains kernel/initramfs
#   - Partition 4: LVM PV (remaining space) - contains VG with root LV
#
# UEFI Secure Boot:
#   - Uses the Microsoft-signed shim -> Canonical-signed GRUB -> signed kernel
#     chain, which boots on firmware with Secure Boot enabled out of the box.
#   - Optionally generates a Machine Owner Key (MOK) for signing custom kernels
#     or DKMS modules (enable with GENERATE_MOK=true).
#
# Requirements:
#   - qemu-img
#   - guestfish, virt-customize, virt-resize (from libguestfs-tools)
#   - No root access required (uses libguestfs appliance)

set -e

# Default values
DISK_SIZE_GB="${3:-50}"
SOURCE_IMAGE="$1"
OUTPUT_IMAGE="$2"

# The output is a qcow2 image, so make sure it always carries a .qcow2
# extension. This keeps the format unambiguous when importing elsewhere
# (e.g. Proxmox otherwise guesses "raw" from a generic .img name).
case "$OUTPUT_IMAGE" in
    "") ;;
    *.qcow2) ;;
    *) OUTPUT_IMAGE="${OUTPUT_IMAGE%.img}.qcow2" ;;
esac

# Partition sizes in MB
BIOS_BOOT_SIZE_MB=1
EFI_SIZE_MB=512
BOOT_SIZE_MB=1024

# LVM configuration
VG_NAME="vg_system"
LV_ROOT_NAME="lv_root"

# Secure Boot configuration
# SECURE_BOOT:   install the signed shim/GRUB chain for UEFI Secure Boot (default: true)
# GENERATE_MOK:  generate a Machine Owner Key for signing custom kernels/modules (default: false)
# MOK_SUBJECT:   X.509 subject used for the generated MOK certificate
SECURE_BOOT="${SECURE_BOOT:-true}"
GENERATE_MOK="${GENERATE_MOK:-false}"
MOK_SUBJECT="${MOK_SUBJECT:-/CN=Ubuntu Cloud Image LVM MOK/}"

# Sector size (standard 512 bytes)
SECTOR_SIZE=512

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    echo "Usage: $0 <source_image> <output_image> [disk_size_gb]"
    echo ""
    echo "Arguments:"
    echo "  source_image   - Path to the source Ubuntu cloud image"
    echo "  output_image   - Path for the output LVM-enabled image"
    echo "  disk_size_gb   - Size of the output disk in GB (default: 50)"
    echo ""
    echo "This script creates a fully LVM-based disk image where:"
    echo "  - /boot is on a separate ext4 partition (1GB)"
    echo "  - / (root) is on LVM logical volume"
    echo "  - Supports both BIOS and UEFI boot (incl. UEFI Secure Boot)"
    echo ""
    echo "The conversion is done entirely offline using guestfish."
    echo "No root access or kernel modules required."
    echo ""
    echo "Environment variables:"
    echo "  SECURE_BOOT   - Install signed shim/GRUB chain for Secure Boot (default: true)"
    echo "  GENERATE_MOK  - Generate a Machine Owner Key for custom signing (default: false)"
    echo "  MOK_SUBJECT   - X.509 subject for the generated MOK certificate"
    echo ""
    echo "Example:"
    echo "  $0 ubuntu-24.04-server-cloudimg-amd64.img ubuntu-24.04-lvm.qcow2 100"
    echo "  GENERATE_MOK=true $0 ubuntu-24.04-server-cloudimg-amd64.img ubuntu-24.04-lvm.qcow2 100"
    exit 1
}

check_requirements() {
    local missing=()

    for cmd in qemu-img guestfish virt-customize virt-tar-out; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        echo "Install with: apt install qemu-utils libguestfs-tools"
        exit 1
    fi

    log_info "All required tools found"
}

validate_source_image() {
    if [ ! -f "$SOURCE_IMAGE" ]; then
        log_error "Source image not found: $SOURCE_IMAGE"
        exit 1
    fi

    if ! qemu-img info "$SOURCE_IMAGE" &> /dev/null; then
        log_error "Invalid source image format: $SOURCE_IMAGE"
        exit 1
    fi

    log_info "Source image validated: $SOURCE_IMAGE"
}

# Main execution
if [ $# -lt 2 ]; then
    usage
fi

log_info "Starting full LVM image conversion using guestfish"
log_info "Source: $SOURCE_IMAGE"
log_info "Output: $OUTPUT_IMAGE"
log_info "Disk size: ${DISK_SIZE_GB}GB"

check_requirements
validate_source_image

# Create a temporary directory for work files
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

log_info "Working directory: $WORK_DIR"

# Calculate partition boundaries in sectors (512 bytes per sector)
# Using MiB alignment for optimal performance
SECTORS_PER_MB=$((1024 * 1024 / SECTOR_SIZE))

# Calculate total sectors and account for GPT overhead
# GPT uses 34 sectors at the start and 33 sectors at the end
TOTAL_SECTORS=$((DISK_SIZE_GB * 1024 * 1024 * 1024 / SECTOR_SIZE))
GPT_END_RESERVED=34  # Sectors reserved at end for backup GPT header
LAST_USABLE_SECTOR=$((TOTAL_SECTORS - GPT_END_RESERVED))

# Start at 1MiB (2048 sectors) for alignment
BIOS_START_SECTOR=2048
BIOS_END_SECTOR=$((BIOS_START_SECTOR + (BIOS_BOOT_SIZE_MB * SECTORS_PER_MB) - 1))

EFI_START_SECTOR=$((BIOS_END_SECTOR + 1))
EFI_END_SECTOR=$((EFI_START_SECTOR + (EFI_SIZE_MB * SECTORS_PER_MB) - 1))

BOOT_START_SECTOR=$((EFI_END_SECTOR + 1))
BOOT_END_SECTOR=$((BOOT_START_SECTOR + (BOOT_SIZE_MB * SECTORS_PER_MB) - 1))

LVM_START_SECTOR=$((BOOT_END_SECTOR + 1))
LVM_END_SECTOR=$LAST_USABLE_SECTOR

log_info "Partition layout (in sectors):"
log_info "  Total sectors: $TOTAL_SECTORS"
log_info "  Last usable sector: $LAST_USABLE_SECTOR"
log_info "  BIOS: $BIOS_START_SECTOR - $BIOS_END_SECTOR"
log_info "  EFI:  $EFI_START_SECTOR - $EFI_END_SECTOR"
log_info "  Boot: $BOOT_START_SECTOR - $BOOT_END_SECTOR"
log_info "  LVM:  $LVM_START_SECTOR - $LVM_END_SECTOR"

# Step 1: Extract the root filesystem from the source image
log_info "Extracting root filesystem from source image..."
virt-tar-out -a "$SOURCE_IMAGE" / "$WORK_DIR/rootfs.tar"

# Step 2: Create the new disk image with explicit size
log_info "Creating new disk image (${DISK_SIZE_GB}GB)..."
rm -f "$OUTPUT_IMAGE"
qemu-img create -f qcow2 "$OUTPUT_IMAGE" "${DISK_SIZE_GB}G"

# Verify the image size
log_info "Verifying disk image size..."
qemu-img info "$OUTPUT_IMAGE"

# Step 3: Use guestfish to partition, format, and populate the new image
log_info "Setting up LVM disk layout with guestfish..."

guestfish --rw -a "$OUTPUT_IMAGE" <<EOF
run

# Show disk size for debugging
echo "Disk size information:"
blockdev-getsize64 /dev/sda

# Create GPT partition table
echo "Create GPT partition table"
part-init /dev/sda gpt

# Partition 1: BIOS boot (1MB)
echo "Create BIOS partition"
part-add /dev/sda primary $BIOS_START_SECTOR $BIOS_END_SECTOR
part-set-gpt-type /dev/sda 1 21686148-6449-6E6F-744E-656564454649

# Partition 2: EFI System Partition (512MB)
echo "Create EFI partition"
part-add /dev/sda primary $EFI_START_SECTOR $EFI_END_SECTOR
part-set-gpt-type /dev/sda 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B

# Partition 3: /boot (1GB)
echo "Create boot partition"
part-add /dev/sda primary $BOOT_START_SECTOR $BOOT_END_SECTOR

# Partition 4: LVM (rest of disk, accounting for GPT backup header)
echo "Create LVM partition"
part-add /dev/sda primary $LVM_START_SECTOR $LVM_END_SECTOR
part-set-gpt-type /dev/sda 4 E6D6D379-F507-44C2-A23C-238F2A3DF928

# Format EFI partition
echo "Format EFI partition"
mkfs vfat /dev/sda2
set-label /dev/sda2 EFI

# Format /boot partition
echo "Format boot partition"
mkfs ext4 /dev/sda3
set-label /dev/sda3 boot

# Create LVM structure
echo "Format LVM partition"
pvcreate /dev/sda4
vgcreate $VG_NAME /dev/sda4
lvcreate-free $LV_ROOT_NAME $VG_NAME 100

# Format root LV
echo "Format root LVM"
mkfs ext4 /dev/$VG_NAME/$LV_ROOT_NAME
set-label /dev/$VG_NAME/$LV_ROOT_NAME root

# Mount filesystems
echo "Mount FS"
mount /dev/$VG_NAME/$LV_ROOT_NAME /
mkdir-p /boot
mount /dev/sda3 /boot
mkdir-p /boot/efi
mount /dev/sda2 /boot/efi

# Extract the root filesystem
echo "Extract root FS"
tar-in $WORK_DIR/rootfs.tar / xattrs:true acls:true

# Get UUIDs for fstab
!echo "Getting partition UUIDs..."

EOF

# Step 4: Get UUIDs and update configuration files
log_info "Updating system configuration..."

# Get UUIDs using guestfish
BOOT_UUID=$(guestfish --ro -a "$OUTPUT_IMAGE" -i <<EOF
get-uuid /dev/sda3
EOF
)

EFI_UUID=$(guestfish --ro -a "$OUTPUT_IMAGE" -i <<EOF
get-uuid /dev/sda2
EOF
)

log_info "Boot UUID: $BOOT_UUID"
log_info "EFI UUID: $EFI_UUID"

# Step 5: Update fstab, initramfs config, and GRUB using guestfish
log_info "Configuring fstab, initramfs, and GRUB..."

# Create config files in work directory first, then copy them in
cat > "$WORK_DIR/fstab" << FSTAB_EOF
# /etc/fstab: static file system information.
# <file system>                           <mount point>  <type>  <options>                   <dump>  <pass>
/dev/$VG_NAME/$LV_ROOT_NAME               /              ext4    defaults,errors=remount-ro  0       1
UUID=$BOOT_UUID                           /boot          ext4    defaults                    0       2
UUID=$EFI_UUID                            /boot/efi      vfat    umask=0077                  0       1
FSTAB_EOF

cat > "$WORK_DIR/lvm.conf" << LVM_EOF
# Enable LVM support in initramfs
MODULES=lvm
LVM_EOF

cat > "$WORK_DIR/grub" << GRUB_EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=Ubuntu
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="root=/dev/$VG_NAME/$LV_ROOT_NAME"
GRUB_DISABLE_OS_PROBER=true
GRUB_EOF

# Copy the config files into the image
guestfish --rw -a "$OUTPUT_IMAGE" -i <<EOF
mkdir-p /etc/initramfs-tools/conf.d
mkdir-p /etc/cloud/cloud.cfg.d
copy-in $WORK_DIR/fstab /etc
copy-in $WORK_DIR/grub /etc/default
copy-in $WORK_DIR/lvm.conf /etc/initramfs-tools/conf.d
mv /etc/initramfs-tools/conf.d/lvm.conf /etc/initramfs-tools/conf.d/lvm
EOF

# Step 6: Install GRUB and rebuild initramfs using virt-customize
log_info "Installing bootloader and rebuilding initramfs..."

# Assemble the package list. Secure Boot requires the Microsoft-signed shim,
# the Canonical-signed GRUB and the MOK/signing utilities.
#
# NOTE: use the *-bin GRUB packages, not the grub-pc / grub-efi-amd64 meta
# packages. The meta packages Conflict with each other (you can only have one
# installed), which makes apt unsolvable for a dual BIOS+UEFI image and also
# drags unrelated packages like qemu-guest-agent into "unmet dependencies".
# The -bin packages ship the platform modules, coexist fine, and this script
# already runs grub-install for both targets manually.
INSTALL_PACKAGES="lvm2,grub-pc-bin,grub-efi-amd64-bin,qemu-guest-agent"
if [ "$SECURE_BOOT" = "true" ]; then
    log_info "Secure Boot enabled: adding signed shim/GRUB and MOK tooling"
    INSTALL_PACKAGES="$INSTALL_PACKAGES,shim-signed,grub-efi-amd64-signed,mokutil,sbsigntool,efibootmgr,openssl"
fi

# First install packages and update initramfs.
# Refresh the package indexes before installing; stale indexes are a common
# cause of silent install failures. Do NOT swallow errors here: if a package
# (e.g. qemu-guest-agent) fails to install the whole conversion must fail
# loudly instead of producing an image with missing packages.
virt-customize -a "$OUTPUT_IMAGE" \
    --update \
    --install "$INSTALL_PACKAGES" \
    --run-command "update-initramfs -u -k all"

# SELinux relabelling is only meaningful on SELinux-based guests; on Ubuntu it
# is a no-op and may emit warnings, so keep it separate and tolerant.
virt-customize -a "$OUTPUT_IMAGE" --selinux-relabel 2>/dev/null || true

# Install GRUB bootloader (legacy BIOS on /dev/sda + UEFI on the ESP)
if [ "$SECURE_BOOT" = "true" ]; then
    # Create a script that installs the Secure Boot chain inside the image.
    # It is run through virt-customize so the guest tooling (grub-install,
    # shim, openssl, mokutil) does the heavy lifting.
    cat > "$WORK_DIR/setup-secureboot.sh" << SECUREBOOT_EOF
#!/bin/bash
set -e

EFI_DIR=/boot/efi
UBUNTU_EFI="\$EFI_DIR/EFI/ubuntu"
BOOT_EFI="\$EFI_DIR/EFI/BOOT"

# Install the signed GRUB via shim for Secure Boot. --no-nvram is required
# because there is no EFI runtime (efivars) inside the offline appliance.
grub-install --target=x86_64-efi --efi-directory="\$EFI_DIR" \\
    --bootloader-id=ubuntu --uefi-secure-boot --no-nvram --recheck

# Make sure the Microsoft-signed shim is present as the first-stage loader.
if [ ! -f "\$UBUNTU_EFI/shimx64.efi" ]; then
    for shim in /usr/lib/shim/shimx64.efi.signed.latest /usr/lib/shim/shimx64.efi.signed; do
        if [ -f "\$shim" ]; then
            cp "\$shim" "\$UBUNTU_EFI/shimx64.efi"
            break
        fi
    done
fi

# MokManager, used to enrol a Machine Owner Key from the firmware.
if [ ! -f "\$UBUNTU_EFI/mmx64.efi" ]; then
    for mm in /usr/lib/shim/mmx64.efi.signed /usr/lib/shim/mmx64.efi; do
        if [ -f "\$mm" ]; then
            cp "\$mm" "\$UBUNTU_EFI/mmx64.efi"
            break
        fi
    done
fi

# Provide the removable/default boot path so the image also boots on firmware
# that has no matching NVRAM entry (typical for freshly deployed cloud images).
mkdir -p "\$BOOT_EFI"
cp "\$UBUNTU_EFI/shimx64.efi" "\$BOOT_EFI/BOOTX64.EFI"
cp "\$UBUNTU_EFI/grubx64.efi" "\$BOOT_EFI/grubx64.efi"
[ -f "\$UBUNTU_EFI/mmx64.efi" ] && cp "\$UBUNTU_EFI/mmx64.efi" "\$BOOT_EFI/mmx64.efi"

# Optionally generate a Machine Owner Key (MOK) for signing custom kernels or
# DKMS modules. It is stored in the standard Ubuntu location so DKMS picks it
# up automatically. Enrolment must be completed interactively at first boot
# (see MOK.der copied onto the ESP).
if [ "$GENERATE_MOK" = "true" ]; then
    MOK_DIR=/var/lib/shim-signed/mok
    mkdir -p "\$MOK_DIR"
    if [ ! -f "\$MOK_DIR/MOK.der" ]; then
        openssl req -new -x509 -newkey rsa:2048 -nodes \\
            -keyout "\$MOK_DIR/MOK.priv" \\
            -outform DER -out "\$MOK_DIR/MOK.der" \\
            -days 36500 -subj "$MOK_SUBJECT"
        chmod 600 "\$MOK_DIR/MOK.priv"
    fi
    # Copy the public key onto the ESP so it can be enrolled via MokManager
    # (Enroll key from disk) or 'mokutil --import' on the running system.
    cp "\$MOK_DIR/MOK.der" "\$EFI_DIR/MOK.der"
fi
SECUREBOOT_EOF

    log_info "Installing Secure Boot bootloader chain (shim -> signed GRUB)..."
    virt-customize -a "$OUTPUT_IMAGE" \
        --run-command "update-initramfs -u" \
        --run-command "update-grub" \
        --run-command "grub-install --target=i386-pc --recheck /dev/sda" \
        --run "$WORK_DIR/setup-secureboot.sh"

    if [ "$GENERATE_MOK" = "true" ]; then
        log_warn "MOK generated at /var/lib/shim-signed/mok/ and /boot/efi/MOK.der"
        log_warn "Enrol it at first boot with: sudo mokutil --import /boot/efi/MOK.der"
    fi
else
    # Install GRUB bootloader (unsigned, BIOS + UEFI)
    virt-customize -a "$OUTPUT_IMAGE" \
        --run-command "update-initramfs -u" \
        --run-command "update-grub" \
        --run-command "grub-install /dev/sda" \
        --run-command "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck"
fi

# Step 7: Compress the output image
log_info "Compressing output image..."
qemu-img convert -f qcow2 -O qcow2 -c "$OUTPUT_IMAGE" "${OUTPUT_IMAGE}.tmp"
mv "${OUTPUT_IMAGE}.tmp" "$OUTPUT_IMAGE"
qemu-img convert -f qcow2 -O vdi "$OUTPUT_IMAGE" "${OUTPUT_IMAGE%.qcow2}.vdi"

# Show final result
log_info "Done: $OUTPUT_IMAGE"
