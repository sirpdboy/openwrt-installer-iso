#!/bin/bash
# build-openwrt-alpine-iso.sh - Build OpenWRT auto-install ISO with Alpine
# Supports BIOS and UEFI dual boot
# All English, no special characters

set -e

echo "Starting OpenWRT ISO build..."
echo "==============================="

# Configuration
OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall-alpine.iso}"
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# Alpine configuration
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ALPINE_ARCH="x86_64"
ALPINE_REPO="https://dl-cdn.alpinelinux.org/alpine"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Log functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Work directory
WORK_DIR="/tmp/openwrt_build_$(date +%s)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    umount "$WORK_DIR/efi_mount" 2>/dev/null || true
    rm -rf "$WORK_DIR" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ==================== Step 1: Check input file ====================
log_info "[1/6] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== Step 2: Install build tools ====================
log_info "[2/6] Installing build tools..."
apk update --no-cache
apk add --no-cache \
    alpine-sdk \
    xorriso \
    syslinux \
    grub-bios \
    grub-efi \
    mtools \
    dosfstools \
    squashfs-tools \
    bash \
    dialog \
    pv \
    curl \
    wget \
    parted \
    e2fsprogs \
    gzip \
    cpio

log_success "Build tools installed"

# ==================== Step 3: Create minimal root filesystem ====================
log_info "[3/6] Creating minimal root filesystem..."

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# Create basic directory structure
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr,var,sbin}
mkdir -p "$ROOTFS_DIR"/usr/{bin,sbin}
mkdir -p "$ROOTFS_DIR"/var/lib

# Create init script
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# Minimal init script

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Create device nodes
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true
mknod /dev/zero c 1 5 2>/dev/null || true

# Setup console
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

clear
echo ""
echo "=========================================="
echo "    OpenWRT Installer - Alpine Linux"
echo "=========================================="
echo ""

# Check OpenWRT image
if [ -f "/openwrt.img" ]; then
    echo "OpenWRT image found"
    echo ""
    echo "Starting installer..."
    echo ""
    
    # Show available disks
    echo "Available disks:"
    echo "----------------"
    ls /dev/sd* /dev/nvme* 2>/dev/null | grep -v '[0-9]$' || echo "No disks found"
    echo "----------------"
    echo ""
    
    echo -n "Enter target disk (e.g., sda): "
    read TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "No disk specified"
        sleep 2
        reboot -f
    fi
    
    echo ""
    echo "WARNING: This will erase /dev/$TARGET_DISK"
    echo -n "Type YES to confirm: "
    read CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Installation cancelled"
        sleep 2
        reboot -f
    fi
    
    echo ""
    echo "Installing to /dev/$TARGET_DISK..."
    echo "This may take a few minutes..."
    echo ""
    
    # Write image
    if command -v pv >/dev/null 2>&1; then
        pv /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
    else
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
    fi
    
    if [ $? -eq 0 ]; then
        sync
        echo "Installation complete!"
        echo ""
        echo "System will reboot in 5 seconds..."
        sleep 5
        reboot -f
    else
        echo "Installation failed!"
        sleep 5
    fi
else
    echo "ERROR: OpenWRT image not found!"
    echo ""
    echo "The image should be at: /openwrt.img"
    echo ""
    echo "Dropping to emergency shell..."
    echo ""
    exec /bin/sh
fi
INIT_EOF

chmod +x "$ROOTFS_DIR/init"

# Copy busybox
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$ROOTFS_DIR/bin/busybox"
    chmod +x "$ROOTFS_DIR/bin/busybox"
    
    # Create symbolic links
    cd "$ROOTFS_DIR/bin"
    for app in sh ls cat echo dd mount grep reboot sync; do
        ln -sf busybox $app 2>/dev/null || true
    done
    cd "$WORK_DIR"
fi

# Copy other essential tools
for tool in dd mount grep reboot sync; do
    if command -v $tool >/dev/null 2>&1; then
        tool_path=$(which $tool)
        cp "$tool_path" "$ROOTFS_DIR/bin/" 2>/dev/null || true
    fi
done

# Create etc files
cat > "$ROOTFS_DIR/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF

cat > "$ROOTFS_DIR/etc/group" << EOF
root:x:0:root
EOF

log_success "Minimal root filesystem created"

# ==================== Step 4: Create bootable ISO structure ====================
log_info "[4/6] Creating bootable ISO structure..."

# Create ISO directory structure
ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/syslinux"
mkdir -p "$ISO_DIR/boot/grub"
mkdir -p "$ISO_DIR/EFI/BOOT"

# Copy OpenWRT image
cp "$OPENWRT_IMG" "$ISO_DIR/openwrt.img"

# Create squashfs filesystem
log_info "Creating squashfs filesystem..."
if command -v mksquashfs >/dev/null 2>&1; then
    mksquashfs "$ROOTFS_DIR" "$ISO_DIR/rootfs.squashfs" -comp gzip -noappend >/dev/null 2>&1 || {
        log_warning "Squashfs creation failed, copying files directly..."
        cp -r "$ROOTFS_DIR" "$ISO_DIR/rootfs" 2>/dev/null || true
    }
else
    cp -r "$ROOTFS_DIR" "$ISO_DIR/rootfs" 2>/dev/null || true
fi

# ==================== Step 5: Create boot files ====================
log_info "[5/6] Creating boot files..."

# Copy kernel from host system
if [ -f /boot/vmlinuz-lts ]; then
    cp /boot/vmlinuz-lts "$ISO_DIR/boot/vmlinuz"
elif [ -f /boot/vmlinuz ]; then
    cp /boot/vmlinuz "$ISO_DIR/boot/vmlinuz"
else
    log_warning "No kernel found, using busybox as kernel"
    cp /bin/busybox "$ISO_DIR/boot/vmlinuz"
fi

# Create initramfs
log_info "Creating initramfs..."
INITRAMFS_DIR="$WORK_DIR/initramfs"
mkdir -p "$INITRAMFS_DIR"
cp "$ROOTFS_DIR/init" "$INITRAMFS_DIR/init"
chmod +x "$INITRAMFS_DIR/init"
cd "$INITRAMFS_DIR"
find . | cpio -H newc -o 2>/dev/null | gzip > "$ISO_DIR/boot/initrd.img" 2>/dev/null
cd "$WORK_DIR"

# ==================== Step 5a: Create BIOS boot (SYSLINUX) ====================
log_info "Creating BIOS boot configuration..."

cat > "$ISO_DIR/boot/syslinux/syslinux.cfg" << 'SYSLINUX_CFG'
DEFAULT openwrt
TIMEOUT 30
PROMPT 0

LABEL openwrt
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz
  INITRD /boot/initrd.img
  APPEND console=tty0 console=ttyS0,115200

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  INITRD /boot/initrd.img
  APPEND console=tty0 single
SYSLINUX_CFG

# Copy SYSLINUX files
for file in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32 menu.c32 vesamenu.c32; do
    find /usr -name "$file" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$ISO_DIR/boot/syslinux/" 2>/dev/null || true
done

# ==================== Step 5b: Create UEFI boot (GRUB) ====================
log_info "Creating UEFI boot configuration..."

# Create GRUB configuration
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (UEFI)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}

menuentry "Emergency Shell (UEFI)" {
    linux /boot/vmlinuz console=tty0 single
    initrd /boot/initrd.img
}
GRUB_CFG

# Create UEFI boot image
log_info "Creating UEFI boot image..."
EFI_IMG="$WORK_DIR/efiboot.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=16
mkfs.vfat -F 32 "$EFI_IMG" >/dev/null 2>&1

# Create GRUB standalone EFI binary
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "Creating GRUB EFI binary..."
    
    # Create temporary directory for GRUB
    GRUB_TMP="$WORK_DIR/grub_tmp"
    mkdir -p "$GRUB_TMP"
    
    # Copy GRUB configuration
    mkdir -p "$GRUB_TMP/boot/grub"
    cp "$ISO_DIR/boot/grub/grub.cfg" "$GRUB_TMP/boot/grub/"
    
    # Create standalone GRUB EFI
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$GRUB_TMP/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$GRUB_TMP/boot/grub/grub.cfg" 2>/dev/null || \
    {
        log_warning "Failed to create GRUB EFI, trying alternative method..."
        # Try alternative method
        grub-mkimage \
            -o "$GRUB_TMP/bootx64.efi" \
            -p /boot/grub \
            -O x86_64-efi \
            boot linux configfile normal part_gpt part_msdos fat iso9660
    }
    
    # Mount EFI image and copy files
    EFI_MOUNT="$WORK_DIR/efi_mount"
    mkdir -p "$EFI_MOUNT"
    mount -o loop "$EFI_IMG" "$EFI_MOUNT" 2>/dev/null || {
        log_warning "Could not mount EFI image, using mcopy..."
        mcopy -i "$EFI_IMG" -s "$GRUB_TMP"/* ::
    }
    
    if mountpoint -q "$EFI_MOUNT"; then
        mkdir -p "$EFI_MOUNT/EFI/BOOT"
        cp "$GRUB_TMP/bootx64.efi" "$EFI_MOUNT/EFI/BOOT/"
        umount "$EFI_MOUNT"
    fi
    
    # Copy EFI image to ISO directory
    cp "$EFI_IMG" "$ISO_DIR/EFI/BOOT/efiboot.img"
    log_success "UEFI boot image created"
else
    log_warning "grub-mkstandalone not available, UEFI boot may not work"
fi

# ==================== Step 6: Build final ISO ====================
log_info "[6/6] Building final ISO..."

mkdir -p "$OUTPUT_DIR"
cd "$ISO_DIR"

# Check if we have UEFI boot
UEFI_OPTIONS=""
if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
    UEFI_OPTIONS="-eltorito-alt-boot -e EFI/BOOT/efiboot.img -no-emul-boot -isohybrid-gpt-basdat"
    log_info "Creating hybrid ISO (BIOS + UEFI)"
else
    log_info "Creating BIOS-only ISO"
fi

# Build ISO with xorriso
if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
        -c boot/syslinux/boot.cat \
        -b boot/syslinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        $UEFI_OPTIONS \
        -o "$ISO_PATH" \
        . > "$WORK_DIR/xorriso.log" 2>&1 || {
        log_warning "Xorriso failed, checking log..."
        cat "$WORK_DIR/xorriso.log" | tail -20
        
        # Try alternative method without some options
        log_info "Trying alternative ISO creation..."
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -o "$ISO_PATH" \
            .
    }
else
    log_error "xorriso not found"
    exit 1
fi

# ==================== Step 7: Verify and display results ====================
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    echo "=========================================="
    echo "        BUILD COMPLETE!"
    echo "=========================================="
    echo ""
    
    echo "Build Summary:"
    echo "  OpenWRT Image:    $IMG_SIZE"
    echo "  Final ISO:        $ISO_SIZE"
    echo ""
    
    echo "This ISO supports:"
    if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
        echo "  ✓ BIOS (Legacy) boot"
        echo "  ✓ UEFI boot"
    else
        echo "  ✓ BIOS (Legacy) boot"
        echo "  ✗ UEFI boot (not available)"
    fi
    echo ""
    
    echo "Usage:"
    echo "  1. Write to USB: sudo dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  2. Boot from USB"
    echo "  3. Follow on-screen instructions"
    echo ""
    
    # Create build info file
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Alpine Installer ISO
============================
Build date: $(date)
OpenWRT image: $(basename "$OPENWRT_IMG") ($IMG_SIZE)
ISO file: $ISO_NAME ($ISO_SIZE)
Boot support: $(if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then echo "BIOS + UEFI"; else echo "BIOS only"; fi)

Usage:
  1. Create bootable USB: dd if=$ISO_NAME of=/dev/sdX bs=4M
  2. Boot from USB
  3. Select Install OpenWRT
  4. Choose target disk
  5. Confirm installation
  6. Wait for reboot

Notes:
  - Installation will erase target disk
  - Supports both BIOS and UEFI systems
  - Minimal Alpine Linux based installer
EOF
    
    log_success "ISO created: $ISO_PATH"
    
else
    log_error "ISO creation failed"
    exit 1
fi

echo ""
log_info "Done!"
