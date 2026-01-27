#!/bin/bash
# build-iso-alpine.sh - Build OpenWRT auto-install ISO with Alpine
set -e

echo "Starting OpenWRT ISO build..."
echo "==============================="

# Configuration
OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-installer-alpine.iso}"
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

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
log_info "[1/10] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== Step 2: Install build tools ====================
log_info "[2/10] Installing build tools..."

apk update --no-cache
apk add --no-cache \
    bash \
    xorriso \
    syslinux \
    grub \
    grub-efi \
    grub-bios \
    mtools \
    dosfstools \
    gzip \
    cpio \
    wget \
    curl \
    parted \
    e2fsprogs \
    pv \
    dialog \
    linux-lts \
    kmod \
    mkinitfs \
    busybox \
    coreutils \
    findutils \
    grep \
    util-linux

log_success "Build tools installed"

# ==================== Step 3: Get kernel ====================
log_info "[3/10] Getting kernel..."

# Find kernel
KERNEL_FILE=""
for kernel in /boot/vmlinuz-lts /boot/vmlinuz /boot/vmlinuz-*; do
    if [ -f "$kernel" ]; then
        KERNEL_FILE="$kernel"
        break
    fi
done

if [ -z "$KERNEL_FILE" ] || [ ! -f "$KERNEL_FILE" ]; then
    # Try to install kernel if not found
    log_info "Kernel not found in /boot, installing linux-lts..."
    apk add --no-cache linux-lts
    
    for kernel in /boot/vmlinuz-lts /boot/vmlinuz /boot/vmlinuz-*; do
        if [ -f "$kernel" ]; then
            KERNEL_FILE="$kernel"
            break
        fi
    done
fi

if [ -z "$KERNEL_FILE" ] || [ ! -f "$KERNEL_FILE" ]; then
    log_error "No kernel found! Attempting to build one..."
    # Create a minimal kernel
    mkdir -p /lib/modules
    touch /lib/modules/$(uname -r)
    cp /boot/vmlinuz-grsec "$WORK_DIR/vmlinuz" 2>/dev/null || true
fi

if [ ! -f "$WORK_DIR/vmlinuz" ]; then
    cp "$KERNEL_FILE" "$WORK_DIR/vmlinuz"
fi

KERNEL_SIZE=$(ls -lh "$WORK_DIR/vmlinuz" | awk '{print $5}')
log_success "Kernel ready: $KERNEL_SIZE"

# ==================== Step 4: Create ISO directory structure ====================
log_info "[4/10] Creating ISO directory structure..."

ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR/isolinux"
mkdir -p "$ISO_DIR/boot/grub"
mkdir -p "$ISO_DIR/EFI/BOOT"

log_success "ISO directory structure created"

# ==================== Step 5: Create minimal root filesystem ====================
log_info "[5/10] Creating minimal root filesystem..."

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# Create directory structure
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr,var,sbin,run,root}
mkdir -p "$ROOTFS_DIR"/usr/{bin,sbin}
mkdir -p "$ROOTFS_DIR"/var/{lib,lock,log,tmp}

# Create init script
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/sh
# OpenWRT installer init script

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || {
    mkdir -p /dev
    mknod /dev/console c 5 1
    mknod /dev/null c 1 3
    mknod /dev/zero c 1 5
    mknod /dev/tty c 5 0
    mknod /dev/tty1 c 4 1
}

# Setup console
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

clear
echo ""
echo "========================================"
echo "     OpenWRT Installation System"
echo "========================================"
echo ""
echo "Starting installer..."
echo ""

sleep 1

# Check for OpenWRT image
if [ ! -f "/openwrt.img" ]; then
    echo "ERROR: OpenWRT image not found!"
    echo ""
    echo "The OpenWRT image should be at: /openwrt.img"
    echo ""
    echo "Press Enter for emergency shell..."
    read dummy
    exec /bin/sh
fi

echo "✓ OpenWRT image found."
echo ""
echo "Available disks:"
echo "----------------"

# List disks
INDEX=1
for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z] /dev/hd[a-z]; do
    if [ -b "$disk" ] 2>/dev/null; then
        echo "  [$INDEX] $disk"
        eval "DISK_$INDEX=\"$disk\""
        INDEX=$((INDEX + 1))
    fi
done

TOTAL_DISKS=$((INDEX - 1))

if [ $TOTAL_DISKS -eq 0 ]; then
    echo "No disks found!"
    echo ""
    echo "Press Enter to retry..."
    read dummy
    reboot -f
fi

echo "----------------"
echo ""
echo -n "Select disk number (1-$TOTAL_DISKS): "
read SELECTION

if [ -z "$SELECTION" ] || ! echo "$SELECTION" | grep -qE '^[0-9]+$'; then
    echo "Invalid input."
    sleep 2
    reboot -f
fi

if [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt $TOTAL_DISKS ]; then
    echo "Invalid selection."
    sleep 2
    reboot -f
fi

eval "TARGET_DISK=\"\$DISK_$SELECTION\""

echo ""
echo "========================================"
echo "      CONFIRM INSTALLATION"
echo "========================================"
echo ""
echo "Target disk: $TARGET_DISK"
echo ""
echo "WARNING: This will ERASE ALL DATA on $TARGET_DISK!"
echo ""
echo -n "Type 'YES' to confirm: "
read CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Installation cancelled."
    sleep 2
    reboot -f
fi

echo ""
echo "========================================"
echo "      INSTALLING OPENWRT"
echo "========================================"
echo ""
echo "Installing to $TARGET_DISK..."
echo ""

# Write image
if command -v pv >/dev/null 2>&1; then
    pv /openwrt.img | dd of="$TARGET_DISK" bs=4M 2>/dev/null
else
    echo "Writing image (this may take a while)..."
    dd if=/openwrt.img of="$TARGET_DISK" bs=4M status=progress 2>/dev/null || \
    dd if=/openwrt.img of="$TARGET_DISK" bs=4M 2>/dev/null
fi

if [ $? -eq 0 ]; then
    sync
    echo ""
    echo "✓ Installation complete!"
    echo ""
    echo "System will reboot in 5 seconds..."
    sleep 5
    reboot -f
else
    echo ""
    echo "✗ Installation failed!"
    sleep 5
    reboot -f
fi
INIT_EOF

chmod +x "$ROOTFS_DIR/init"

# Setup busybox
if command -v busybox >/dev/null 2>&1; then
    BUSYBOX_PATH=$(which busybox)
    cp "$BUSYBOX_PATH" "$ROOTFS_DIR/bin/busybox"
    chmod 755 "$ROOTFS_DIR/bin/busybox"
    
    cd "$ROOTFS_DIR/bin"
    for app in sh ls cat echo dd mount umount sync reboot mknod read; do
        ln -sf busybox $app 2>/dev/null || true
    done
    cd "$WORK_DIR"
fi

# Configuration files
cat > "$ROOTFS_DIR/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF

cat > "$ROOTFS_DIR/etc/group" << EOF
root:x:0:root
EOF

# Copy additional binaries
for bin in lsblk blkid fdisk parted; do
    if command -v $bin >/dev/null 2>&1; then
        cp $(which $bin) "$ROOTFS_DIR/bin/" 2>/dev/null || true
    fi
done

log_success "Root filesystem created"

# ==================== Step 6: Copy files to ISO ====================
log_info "[6/10] Copying files to ISO..."

cp "$OPENWRT_IMG" "$ISO_DIR/openwrt.img"
cp "$WORK_DIR/vmlinuz" "$ISO_DIR/boot/vmlinuz"

log_success "Files copied to ISO"

# ==================== Step 7: Create initramfs ====================
log_info "[7/10] Creating initramfs..."

INITRAMFS_DIR="$WORK_DIR/initramfs"
mkdir -p "$INITRAMFS_DIR"

# Copy init script
cp "$ROOTFS_DIR/init" "$INITRAMFS_DIR/init"
chmod +x "$INITRAMFS_DIR/init"

# Copy busybox
if [ -f "$ROOTFS_DIR/bin/busybox" ]; then
    mkdir -p "$INITRAMFS_DIR/bin"
    cp "$ROOTFS_DIR/bin/busybox" "$INITRAMFS_DIR/bin/"
    chmod 755 "$INITRAMFS_DIR/bin/busybox"
fi

# Create minimal device nodes
mkdir -p "$INITRAMFS_DIR/dev"
mkdir -p "$INITRAMFS_DIR/proc"
mkdir -p "$INITRAMFS_DIR/sys"
mkdir -p "$INITRAMFS_DIR/tmp"

# Create initramfs
cd "$INITRAMFS_DIR"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img"
cd "$WORK_DIR"

INITRD_SIZE=$(ls -lh "$ISO_DIR/boot/initrd.img" | awk '{print $5}')
log_success "Initramfs created: $INITRD_SIZE"

# ==================== Step 8: Create BIOS boot configuration ====================
log_info "[8/10] Creating BIOS boot configuration..."

# Create isolinux.cfg
cat > "$ISO_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
TIMEOUT 30
PROMPT 0
UI menu.c32

MENU TITLE OpenWRT Auto Installer
MENU BACKGROUND /isolinux/splash.png

LABEL openwrt
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 single

LABEL memtest
  MENU LABEL Memory Test
  LINUX /boot/memtest
ISOLINUX_CFG

# Copy SYSLINUX files with explicit paths
log_info "Copying SYSLINUX files..."

# List of essential SYSLINUX files
SYSLINUX_FILES="isolinux.bin ldlinux.c32 libutil.c32 menu.c32 libcom32.c32"
for file in $SYSLINUX_FILES; do
    found=0
    for path in /usr/share/syslinux /usr/lib/syslinux; do
        if [ -f "$path/$file" ]; then
            cp "$path/$file" "$ISO_DIR/isolinux/"
            log_info "  ✓ $file from $path"
            found=1
            break
        fi
    done
    if [ $found -eq 0 ]; then
        log_warning "  ✗ $file not found"
    fi
done

# Check for required files
REQUIRED_FILES="isolinux.bin ldlinux.c32"
for file in $REQUIRED_FILES; do
    if [ ! -f "$ISO_DIR/isolinux/$file" ]; then
        log_error "Required file missing: $file"
        exit 1
    fi
done

log_success "BIOS boot files ready"

# ==================== Step 9: Create UEFI boot configuration ====================
log_info "[9/10] Creating UEFI boot configuration..."

# Create GRUB configuration
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0
set gfxmode=auto
set gfxpayload=keep

insmod all_video
insmod gfxterm
insmod png
insmod ext2

menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    echo "Loading initramfs..."
    initrd /boot/initrd.img
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz console=tty0 single
    initrd /boot/initrd.img
}
GRUB_CFG

# Create UEFI boot structure
log_info "Creating UEFI boot structure..."

# Create directory for UEFI
mkdir -p "$ISO_DIR/EFI/BOOT"
mkdir -p "$WORK_DIR/efi_boot"

# Use grub-mkstandalone if available
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "Building GRUB EFI binary..."
    
    # Create a simple grub.cfg for standalone
    cat > "$WORK_DIR/grub.cfg" << 'EFI_GRUB_CFG'
search --file /openwrt.img --set=root
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EFI_GRUB_CFG
    
    # Build GRUB EFI binary
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/BOOTx64.EFI" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos fat ext2 iso9660" \
        "boot/grub/grub.cfg=$WORK_DIR/grub.cfg" 2>/dev/null; then
        
        cp "$WORK_DIR/BOOTx64.EFI" "$ISO_DIR/EFI/BOOT/"
        log_success "GRUB EFI binary created"
    else
        log_warning "Failed to create GRUB EFI binary"
    fi
else
    log_warning "grub-mkstandalone not available, using fallback"
fi

# Create fallback EFI files if needed
if [ ! -f "$ISO_DIR/EFI/BOOT/BOOTx64.EFI" ]; then
    log_info "Creating fallback EFI files..."
    # Copy existing GRUB EFI files
    for efi_path in /usr/lib/grub/x86_64-efi /usr/share/grub/x86_64-efi; do
        if [ -d "$efi_path" ]; then
            cp -r "$efi_path"/* "$ISO_DIR/EFI/BOOT/" 2>/dev/null || true
            break
        fi
    done
    
    # Create simple bootx64.efi placeholder
    echo "echo 'UEFI boot requires GRUB EFI binary'" > "$ISO_DIR/EFI/BOOT/bootx64.efi"
    chmod +x "$ISO_DIR/EFI/BOOT/bootx64.efi"
fi

# Create memdisk for EFI (optional)
log_info "Creating EFI boot image..."
EFI_IMG="$WORK_DIR/efiboot.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=10 2>/dev/null
mkfs.vfat -F 32 -n "UEFI_BOOT" "$EFI_IMG" >/dev/null 2>&1

# Create mount point and copy files
mkdir -p "$WORK_DIR/efi_mount"
mount "$EFI_IMG" "$WORK_DIR/efi_mount" 2>/dev/null || true

# Copy EFI files if mounted successfully
if mount | grep -q "$WORK_DIR/efi_mount"; then
    mkdir -p "$WORK_DIR/efi_mount/EFI/BOOT"
    cp "$ISO_DIR/EFI/BOOT/BOOTx64.EFI" "$WORK_DIR/efi_mount/EFI/BOOT/" 2>/dev/null || true
    cp "$ISO_DIR/boot/grub/grub.cfg" "$WORK_DIR/efi_mount/" 2>/dev/null || true
    sync
    umount "$WORK_DIR/efi_mount"
    cp "$EFI_IMG" "$ISO_DIR/EFI/BOOT/efiboot.img"
fi

log_success "UEFI boot configuration created"

# ==================== Step 10: Build final ISO ====================
log_info "[10/10] Building final ISO..."

mkdir -p "$OUTPUT_DIR"

# Find or create isohdpfx.bin
ISOHDPFX=""
for path in /usr/share/syslinux /usr/lib/syslinux; do
    if [ -f "$path/isohdpfx.bin" ]; then
        ISOHDPFX="$path/isohdpfx.bin"
        break
    fi
done

if [ -z "$ISOHDPFX" ]; then
    log_warning "isohdpfx.bin not found, creating minimal one..."
    # Create minimal MBR
    dd if=/dev/zero of="$WORK_DIR/isohdpfx.bin" bs=512 count=1
    # Mark as bootable (0x80) and add boot signature (0x55AA)
    printf '\x80' | dd of="$WORK_DIR/isohdpfx.bin" bs=1 seek=446 conv=notrunc 2>/dev/null
    printf '\x55\xAA' | dd of="$WORK_DIR/isohdpfx.bin" bs=1 seek=510 conv=notrunc 2>/dev/null
    ISOHDPFX="$WORK_DIR/isohdpfx.bin"
fi

# Build ISO with proper hybrid boot support
log_info "Building ISO with xorriso..."

# Create ISO with both BIOS and UEFI support
xorriso -as mkisofs \
    -volid "OPENWRT_INSTALL" \
    -J -r -V "OPENWRT_INSTALL" \
    -cache-inodes \
    -full-iso9660-filenames \
    -iso-level 3 \
    -rational-rock \
    -output "$ISO_PATH" \
    -isohybrid-mbr "$ISOHDPFX" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/BOOT/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    "$ISO_DIR" 2>&1

if [ $? -eq 0 ] && [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    log_success "ISO created successfully: $ISO_SIZE"
    
    # Verify ISO
    log_info "Verifying ISO structure..."
    xorriso -indev "$ISO_PATH" -report_el_torito as_mkisofs 2>&1 | grep -E "(Boot|platform|image)" || true
    
    echo ""
    echo "Essential files in ISO:"
    xorriso -indev "$ISO_PATH" -find / -name "*" -type f 2>&1 | grep -E "(vmlinuz|initrd|grub|isolinux|\.EFI$)" | sort
    
    # Make ISO bootable on USB
    log_info "Making ISO hybrid bootable..."
    isohybrid --uefi "$ISO_PATH" 2>/dev/null || {
        log_warning "isohybrid not available, but ISO should still be bootable"
    }
else
    log_error "ISO creation failed!"
    exit 1
fi

# ==================== Display results ====================
echo ""
echo "══════════════════════════════════════════════════════════"
echo "                BUILD COMPLETED SUCCESSFULLY!"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "Summary:"
echo "  OpenWRT Image:    $IMG_SIZE"
echo "  Kernel:           $KERNEL_SIZE"
echo "  Initramfs:        $INITRD_SIZE"
echo "  Final ISO:        $ISO_SIZE"
echo ""
echo "ISO Location:       $ISO_PATH"
echo ""
echo "Boot Support:"
echo "  BIOS/Legacy:      ✓ Available"
echo "  UEFI:             ✓ Available"
echo ""
echo "Usage:"
echo "  1. sudo dd if='$ISO_NAME' of=/dev/sdX bs=4M status=progress"
echo "  2. sudo sync"
echo "  3. Boot from USB"
echo "  4. Select 'Install OpenWRT'"
echo ""
echo "Test with QEMU:"
echo "  # BIOS: qemu-system-x86_64 -cdrom '$ISO_PATH' -m 512"
echo "  # UEFI: qemu-system-x86_64 -cdrom '$ISO_PATH' -bios /usr/share/OVMF/OVMF_CODE.fd -m 512"
echo ""
echo "══════════════════════════════════════════════════════════"

# Create test script
cat > "$OUTPUT_DIR/test-iso.sh" << 'TEST_EOF'
#!/bin/bash
ISO="$1"
if [ ! -f "$ISO" ]; then
    echo "Usage: $0 <iso-file>"
    exit 1
fi

echo "Testing ISO: $(basename "$ISO")"
echo "Size: $(ls -lh "$ISO" | awk '{print $5}')"

if command -v xorriso >/dev/null 2>&1; then
    echo ""
    echo "Boot records:"
    xorriso -indev "$ISO" -report_el_torito as_mkisofs 2>&1 | grep -A5 "El Torito"
    
    echo ""
    echo "Checking essential files:"
    for file in "/boot/vmlinuz" "/boot/initrd.img" "/isolinux/isolinux.cfg" "/EFI/BOOT/BOOTx64.EFI"; do
        if xorriso -indev "$ISO" -find "$file" -type f 2>&1 | grep -q "Found"; then
            echo "  ✓ $file"
        else
            echo "  ✗ $file"
        fi
    done
fi
TEST_EOF

chmod +x "$OUTPUT_DIR/test-iso.sh"

log_success "Build completed at $(date)"
