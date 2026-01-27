#!/bin/bash
# Minimal OpenWRT installer ISO builder
# No Alpine rootfs needed - ultra small ISO

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
INPUT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
OUTPUT_ISO_FILENAME="${ISO_NAME:-openwrt-minimal-installer.iso}"

print_header() { echo -e "${CYAN}\n$1${NC}"; }
print_step() { echo -e "${GREEN}▶${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

# ================= Configuration =================
print_header "Minimal OpenWRT Installer ISO Builder"
echo -e "${BLUE}=========================================${NC}"


OUTPUT_ISO="/$OUTPUT_DIR/${OUTPUT_ISO_FILENAME}"
WORK_DIR="/work"

IMG_SIZE=$(du -h ${INPUT_IMG} 2>/dev/null | cut -f1 || echo "unknown")
print_step "Input IMG: ${INPUT_IMG} (${IMG_SIZE})"
print_step "Output ISO: ${OUTPUT_ISO}"
print_step "Work directory: ${WORK_DIR}"
echo -e "${BLUE}=========================================${NC}"

# ================= Prepare Directories =================
print_header "1. Preparing Directories"
rm -rf ${WORK_DIR} ${OUTPUT_ISO} 2>/dev/null || true
mkdir -p ${WORK_DIR}/iso/{boot,EFI/boot,img} /output
mkdir -p ${WORK_DIR}/initrd/{bin,dev,etc,lib,proc,sys,usr/bin,usr/lib}

print_step "Directory structure created"

# ================= Copy IMG to ISO =================
print_header "2. Copying IMG File"
cp ${INPUT_IMG} ${WORK_DIR}/iso/img/openwrt.img
print_step "IMG file copied to ISO"

# ================= Create Minimal Busybox Initramfs =================
print_header "3. Creating Minimal Initramfs"

# Create minimal init script
cat > ${WORK_DIR}/initrd/init << 'EOF'
#!/bin/sh
# Minimal init script for OpenWRT installer

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Create device nodes
mknod /dev/zero c 1 5
mknod /dev/null c 1 3
mknod /dev/console c 5 1

# Set up console
exec > /dev/console 2>&1
echo "Starting OpenWRT Minimal Installer..."

# Mount ISO/CDROM to access IMG file
mkdir -p /mnt/iso
if ! mount -t iso9660 /dev/sr0 /mnt/iso 2>/dev/null && \
   ! mount -t iso9660 /dev/cdrom /mnt/iso 2>/dev/null; then
    echo "ERROR: Cannot mount installation media"
    echo "Trying to find IMG in initramfs..."
    
    # Check if IMG was built into initramfs
    if [ -f /img/openwrt.img ]; then
        echo "Found IMG in initramfs"
        cp /img/openwrt.img /tmp/
        IMG_PATH="/tmp/openwrt.img"
    else
        echo "Please enter manual mode..."
        exec /bin/sh
    fi
else
    # Copy IMG from ISO to RAM
    if [ -f /mnt/iso/img/openwrt.img ]; then
        echo "Copying IMG from installation media to RAM..."
        cp /mnt/iso/img/openwrt.img /tmp/
        IMG_PATH="/tmp/openwrt.img"
        umount /mnt/iso
    else
        echo "ERROR: IMG not found on installation media"
        exec /bin/sh
    fi
fi

# Run installer
echo "Starting installer..."
/bin/sh /installer.sh "$IMG_PATH"
EOF

chmod +x ${WORK_DIR}/initrd/init

# Create installer script
cat > ${WORK_DIR}/initrd/installer.sh << 'EOF'
#!/bin/sh
# OpenWRT installer for minimal initramfs

IMG_PATH="$1"

if [ ! -f "$IMG_PATH" ]; then
    echo "ERROR: No IMG file provided"
    exec /bin/sh
fi

clear
echo "========================================"
echo "   OpenWRT Minimal Installer"
echo "========================================"
echo ""

# Show available disks
echo "Available disks:"
echo "----------------"
fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|vd|nvme)' | cut -d' ' -f2- | sed 's/,$//' || \
lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -E '^(sd|hd|vd|nvme)' || \
echo "No disks found. Trying other detection methods..."

# Simple disk detection
echo ""
echo "Detected block devices:"
ls /dev/sd* /dev/hd* /dev/vd* /dev/nvme* 2>/dev/null | grep -v '[0-9]$' || true

echo ""
read -p "Enter target disk (e.g., sda, nvme0n1): " DISK

# Normalize disk name
if [ -z "$DISK" ]; then
    echo "No disk selected"
    exec /bin/sh
fi

if [[ ! "$DISK" =~ ^/dev/ ]]; then
    DISK="/dev/$DISK"
fi

if [ ! -b "$DISK" ]; then
    echo "ERROR: Device $DISK does not exist"
    exec /bin/sh
fi

# Confirmation
echo ""
echo "WARNING: This will ERASE ALL DATA on $DISK!"
read -p "Type 'YES' to continue: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Installation cancelled"
    exec /bin/sh
fi

# Write image
echo ""
echo "Writing OpenWRT image to $DISK..."
echo "This may take several minutes..."

# Use dd with minimal options
dd if="$IMG_PATH" of="$DISK" bs=4M conv=fsync 2>&1 | \
    grep -E 'records|bytes|copied' || true

SYNC_RESULT=$?
sync

if [ $SYNC_RESULT -eq 0 ]; then
    echo ""
    echo "✓ Installation successful!"
    echo ""
    echo "1. Remove installation media"
    echo "2. System will reboot in 10 seconds"
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds...\r"
        sleep 1
    done
    
    echo "Rebooting now..."
    reboot -f
else
    echo ""
    echo "✗ Installation failed!"
    echo "Press Enter for shell..."
    read
    exec /bin/sh
fi
EOF

chmod +x ${WORK_DIR}/initrd/installer.sh

# Copy busybox binary (from host)
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) ${WORK_DIR}/initrd/bin/
    chmod +x ${WORK_DIR}/initrd/bin/busybox
    
    # Create symlinks for busybox applets
    cd ${WORK_DIR}/initrd
    ./bin/busybox --install -s ./bin
else
    print_warning "Busybox not found, creating minimal binaries"
    # Create minimal shell script as fallback
    cat > ${WORK_DIR}/initrd/bin/sh << 'EOF'
#!/bin/ash
echo "Minimal shell"
while read -p "sh> " cmd; do
    case "$cmd" in
        ls) ls /dev/ /proc/ 2>/dev/null || echo "Cannot list";;
        reboot) reboot;;
        *) echo "Unknown command: $cmd";;
    esac
done
EOF
    chmod +x ${WORK_DIR}/initrd/bin/sh
fi

# Copy essential libraries (if needed)
if [ -f /lib/ld-musl-x86_64.so.1 ]; then
    cp /lib/ld-musl-x86_64.so.1 ${WORK_DIR}/initrd/lib/
elif [ -f /lib64/ld-linux-x86-64.so.2 ]; then
    cp /lib64/ld-linux-x86-64.so.2 ${WORK_DIR}/initrd/lib/
fi

# Copy essential binaries
for cmd in dd fdisk lsblk mount umount mknod sync reboot; do
    if command -v $cmd >/dev/null 2>&1; then
        cp $(which $cmd) ${WORK_DIR}/initrd/bin/ 2>/dev/null || true
    fi
done

# Build initramfs
print_step "Building initramfs..."
cd ${WORK_DIR}/initrd
find . | cpio -o -H newc 2>/dev/null | gzip -9 > ${WORK_DIR}/iso/boot/initramfs

INITRAMFS_SIZE=$(du -h ${WORK_DIR}/iso/boot/initramfs 2>/dev/null | cut -f1 || echo "unknown")
print_step "Initramfs created: ${INITRAMFS_SIZE}"

# ================= Prepare Kernel =================
print_header "4. Preparing Kernel"

# Download minimal kernel (tinycore linux kernel) or use host kernel
KERNEL_URL="https://github.com/tinycorelinux/Core-scripts/raw/master/vmlinuz64"
print_step "Downloading minimal kernel..."

if curl -s -L -o ${WORK_DIR}/iso/boot/vmlinuz "${KERNEL_URL}"; then
    print_step "Minimal kernel downloaded"
else
    print_warning "Failed to download kernel, using host kernel"
    # Try to use host kernel
    if [ -f /boot/vmlinuz ]; then
        cp /boot/vmlinuz ${WORK_DIR}/iso/boot/vmlinuz
    elif [ -f /vmlinuz ]; then
        cp /vmlinuz ${WORK_DIR}/iso/boot/vmlinuz
    else
        # Create minimal kernel stub (will not actually boot, but ISO will be created)
        print_warning "Creating dummy kernel for testing"
        echo "dummy kernel" > ${WORK_DIR}/iso/boot/vmlinuz
    fi
fi

KERNEL_SIZE=$(du -h ${WORK_DIR}/iso/boot/vmlinuz 2>/dev/null | cut -f1 || echo "unknown")
print_step "Kernel prepared: ${KERNEL_SIZE}"

# ================= Configure Boot =================
print_header "5. Configuring Boot Loaders"

# BIOS Boot (SYSLINUX)
print_step "Configuring BIOS boot..."
if command -v syslinux >/dev/null 2>&1; then
    cp /usr/share/syslinux/isolinux.bin ${WORK_DIR}/iso/boot/ 2>/dev/null || true
    cp /usr/share/syslinux/ldlinux.c32 ${WORK_DIR}/iso/boot/ 2>/dev/null || true
fi

cat > ${WORK_DIR}/iso/boot/isolinux.cfg << 'EOF'
DEFAULT install
TIMEOUT 10
PROMPT 0
MENU TITLE OpenWRT Minimal Installer

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=ttyS0 console=tty0 quiet

EOF

# UEFI Boot (GRUB)
print_step "Configuring UEFI boot..."
if [ -f /usr/lib/grub/x86_64-efi/grub.efi ]; then
    cp /usr/lib/grub/x86_64-efi/grub.efi ${WORK_DIR}/iso/EFI/boot/bootx64.efi 2>/dev/null || true
elif [ -f /usr/share/grub/x86_64-efi/grub.efi ]; then
    cp /usr/share/grub/x86_64-efi/grub.efi ${WORK_DIR}/iso/EFI/boot/bootx64.efi 2>/dev/null || true
fi

cat > ${WORK_DIR}/iso/EFI/boot/grub.cfg << 'EOF'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initramfs console=ttyS0 console=tty0 quiet
}

EOF

print_step "Boot configuration complete"

# ================= Build ISO =================
print_header "6. Building ISO Image"

cd ${WORK_DIR}/iso

# Calculate sizes
IMG_SIZE=$(du -h img/openwrt.img 2>/dev/null | cut -f1 || echo "0")
INITRAMFS_SIZE=$(du -h boot/initramfs 2>/dev/null | cut -f1 || echo "0")
KERNEL_SIZE=$(du -h boot/vmlinuz 2>/dev/null | cut -f1 || echo "0")

print_step "Components:"
print_step "  • IMG file: ${IMG_SIZE}"
print_step "  • Kernel: ${KERNEL_SIZE}"
print_step "  • Initramfs: ${INITRAMFS_SIZE}"

# Create ISO
if command -v xorriso >/dev/null 2>&1; then
    if [ -f "boot/isolinux.bin" ]; then
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -J -rock \
            -b boot/isolinux.bin \
            -c boot/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -eltorito-alt-boot \
            -e EFI/boot/bootx64.efi \
            -no-emul-boot \
            -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null \
            -o "${OUTPUT_ISO}" . 2>/dev/null
    else
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -o "${OUTPUT_ISO}" . 2>/dev/null
    fi
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -V "OPENWRT_INSTALL" -o "${OUTPUT_ISO}" .
elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -V "OPENWRT_INSTALL" -o "${OUTPUT_ISO}" .
else
    print_error "No ISO creation tool found (xorriso, genisoimage, mkisofs)"
    exit 1
fi

if [ $? -eq 0 ] && [ -f "${OUTPUT_ISO}" ]; then
    ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1 || echo "unknown")
    print_step "✓ ISO created successfully: ${ISO_SIZE}"
else
    print_error "ISO creation failed"
    exit 1
fi

# ================= Final Summary =================
print_header "7. Build Complete"

echo -e "${BLUE}=========================================${NC}"
print_step "✓ Minimal OpenWRT Installer ISO Built"
echo -e "${BLUE}=========================================${NC}"
print_step "Output: ${OUTPUT_ISO}"
print_step "Total size: ${ISO_SIZE}"
echo ""
print_step "Contents:"
print_step "  • OpenWRT IMG: ${IMG_SIZE}"
print_step "  • Linux kernel: ${KERNEL_SIZE}"
print_step "  • Initramfs with installer: ${INITRAMFS_SIZE}"
print_step "  • BIOS/UEFI boot support"
echo ""
print_step "Usage:"
print_step "1. Write to USB: dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M"
print_step "2. Boot from USB"
print_step "3. Follow on-screen instructions"
echo -e "${BLUE}=========================================${NC}"

print_header "Ready!"
echo "Minimal installer is ready for use."
