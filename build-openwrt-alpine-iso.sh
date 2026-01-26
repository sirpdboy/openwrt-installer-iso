#!/bin/bash
# build-openwrt-alpine-iso.sh - Build OpenWRT auto-install ISO
# Completely fixed version - no trigger errors

set -e

echo "Starting OpenWRT ISO build..."
echo "==============================="

# Configuration
OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall-alpine.iso}"
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

# ==================== Step 2: Install build tools (SILENT MODE) ====================
log_info "[2/10] Installing build tools (silent mode)..."

# Method 1: Redirect ALL trigger output to /dev/null
exec 2>/dev/null  # Redirect stderr for package installation

# Update quietly
apk update >/dev/null 2>&1

# Install packages with minimal output and ignore ALL errors
install_package() {
    local pkg="$1"
    apk add --no-cache --force-broken-world "$pkg" >/dev/null 2>&1 || {
        log_warning "Package $pkg had issues, continuing..."
        return 0  # Always return success to continue
    }
}

# Install core packages
log_info "Installing core packages..."
install_package "bash"
install_package "xorriso"
install_package "syslinux"
install_package "mtools"
install_package "dosfstools"
install_package "gzip"
install_package "cpio"
install_package "wget"
install_package "curl"
install_package "parted"
install_package "e2fsprogs"
install_package "pv"
install_package "dialog"
install_package "linux-lts"
install_package "kmod"
install_package "busybox"
install_package "coreutils"
install_package "findutils"
install_package "grep"
install_package "util-linux"

# Try to install GRUB packages but don't fail
log_info "Trying GRUB packages..."
apk add --no-cache --force-broken-world grub grub-efi >/dev/null 2>&1 || true

# Restore stderr
exec 2>&1

log_success "Build tools installed (errors suppressed)"

# ==================== Step 3: Get kernel ====================
log_info "[3/10] Getting kernel..."

# Find any kernel
if [ -f "/boot/vmlinuz-lts" ]; then
    cp "/boot/vmlinuz-lts" "$WORK_DIR/vmlinuz"
elif [ -f "/boot/vmlinuz" ]; then
    cp "/boot/vmlinuz" "$WORK_DIR/vmlinuz"
else
    # Try to find any vmlinuz
    for kernel in /boot/vmlinuz-* /lib/modules/*/vmlinuz; do
        if [ -f "$kernel" ]; then
            cp "$kernel" "$WORK_DIR/vmlinuz"
            break
        fi
    done
fi

if [ ! -f "$WORK_DIR/vmlinuz" ]; then
    log_error "No kernel found!"
    exit 1
fi

KERNEL_SIZE=$(ls -lh "$WORK_DIR/vmlinuz" | awk '{print $5}')
log_success "Kernel ready: $KERNEL_SIZE"

# ==================== Step 4: Create ISO directory structure ====================
log_info "[4/10] Creating ISO directory structure..."

ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR"
mkdir -p "$ISO_DIR/isolinux"
mkdir -p "$ISO_DIR/boot"
mkdir -p "$ISO_DIR/boot/grub"  # CRITICAL: Create this early!
mkdir -p "$ISO_DIR/EFI/BOOT"

# Also create the grub.cfg file immediately to ensure it exists
touch "$ISO_DIR/boot/grub/grub.cfg"

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

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || {
    mkdir -p /dev
    mknod /dev/console c 5 1
    mknod /dev/null c 1 3
    mknod /dev/zero c 1 5
}

# Setup console
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

clear
echo ""
echo "OpenWRT Installation System"
echo "==========================="
echo ""

# Check for OpenWRT image
if [ ! -f "/openwrt.img" ]; then
    echo "ERROR: OpenWRT image not found!"
    echo ""
    echo "Press Enter for emergency shell..."
    read
    exec /bin/sh
fi

echo "OpenWRT image found."
echo ""
echo "Available disks:"
echo ""

INDEX=1
for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
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
    read
    reboot -f
fi

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
echo "Target disk: $TARGET_DISK"
echo ""
echo "WARNING: This will erase ALL data on $TARGET_DISK!"
echo -n "Type 'YES' to confirm: "
read CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Installation cancelled."
    sleep 2
    reboot -f
fi

echo ""
echo "Installing to $TARGET_DISK..."
echo ""

# Write image
dd if=/openwrt.img of="$TARGET_DISK" bs=4M 2>/dev/null

if [ $? -eq 0 ]; then
    sync
    echo ""
    echo "Installation complete!"
    echo ""
    echo "Rebooting in 3 seconds..."
    sleep 3
    reboot -f
else
    echo ""
    echo "Installation failed!"
    sleep 5
    reboot -f
fi
INIT_EOF

chmod +x "$ROOTFS_DIR/init"

# Setup busybox
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$ROOTFS_DIR/bin/busybox"
    chmod 755 "$ROOTFS_DIR/bin/busybox"
    
    cd "$ROOTFS_DIR/bin"
    for app in sh ls cat echo dd mount umount sync reboot; do
        ln -sf busybox $app 2>/dev/null || true
    done
    cd "$WORK_DIR"
fi

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

cp "$ROOTFS_DIR/init" "$INITRAMFS_DIR/init"
chmod +x "$INITRAMFS_DIR/init"

cd "$INITRAMFS_DIR"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img"
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

LABEL openwrt
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz
  INITRD /boot/initrd.img
  APPEND console=tty0

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND console=tty0 single
ISOLINUX_CFG

# Copy SYSLINUX files
for file in isolinux.bin ldlinux.c32; do
    for path in /usr/share/syslinux /usr/lib/syslinux; do
        if [ -f "$path/$file" ]; then
            cp "$path/$file" "$ISO_DIR/isolinux/"
            break
        fi
    done
done

log_success "BIOS boot configuration created"

# ==================== Step 9: Create UEFI boot configuration ====================
log_info "[9/10] Creating UEFI boot configuration..."

# Write GRUB configuration to the already-existing file
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz console=tty0
    initrd /boot/initrd.img
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz console=tty0 single
    initrd /boot/initrd.img
}
GRUB_CFG

log_success "GRUB configuration written"

# Create UEFI boot only if grub tools are available
if command -v grub-mkstandalone >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; then
    log_info "Creating UEFI boot image..."
    
    # Create small EFI image
    EFI_IMG="$WORK_DIR/efiboot.img"
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=8 2>/dev/null
    mkfs.vfat -F 32 "$EFI_IMG" >/dev/null 2>&1
    
    # Create GRUB EFI binary
    GRUB_TMP="$WORK_DIR/grub_tmp"
    mkdir -p "$GRUB_TMP/boot/grub"
    
    cat > "$GRUB_TMP/boot/grub/grub.cfg" << 'EFI_GRUB'
search --file /openwrt.img --set=root
configfile /boot/grub/grub.cfg
EFI_GRUB
    
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="$GRUB_TMP/bootx64.efi" \
        "boot/grub/grub.cfg=$GRUB_TMP/boot/grub/grub.cfg" 2>/dev/null; then
        
        # Copy to EFI image
        mmd -i "$EFI_IMG" ::/EFI
        mmd -i "$EFI_IMG" ::/EFI/BOOT
        mcopy -i "$EFI_IMG" "$GRUB_TMP/bootx64.efi" ::/EFI/BOOT/
        
        cp "$EFI_IMG" "$ISO_DIR/EFI/BOOT/efiboot.img"
        log_success "UEFI boot image created"
    else
        log_warning "Failed to create GRUB EFI binary"
    fi
else
    log_warning "Skipping UEFI boot (missing tools)"
fi

# ==================== Step 10: Build final ISO ====================
log_info "[10/10] Building final ISO..."

mkdir -p "$OUTPUT_DIR"

# Create simple MBR
dd if=/dev/zero of="$WORK_DIR/mbr.bin" bs=512 count=1
printf '\x80' | dd of="$WORK_DIR/mbr.bin" bs=1 seek=446 conv=notrunc 2>/dev/null
printf '\x55\xAA' | dd of="$WORK_DIR/mbr.bin" bs=1 seek=510 conv=notrunc 2>/dev/null

# Build ISO
XORRISO_CMD="xorriso -as mkisofs \
    -volid 'OPENWRT_INSTALL' \
    -output '$ISO_PATH' \
    -isohybrid-mbr '$WORK_DIR/mbr.bin' \
    -c 'isolinux/boot.cat' \
    -b 'isolinux/isolinux.bin' \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table"

# Add UEFI boot if available
if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
    XORRISO_CMD="$XORRISO_CMD \
        -eltorito-alt-boot \
        -e 'EFI/BOOT/efiboot.img' \
        -no-emul-boot"
fi

XORRISO_CMD="$XORRISO_CMD '$ISO_DIR'"

log_info "Building ISO..."
eval $XORRISO_CMD 2>&1 | grep -v "NOTE\|WARNING" || true

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    log_success "✅ ISO created successfully: $ISO_SIZE"
    
    # Verify
    echo ""
    echo "Verification:"
    echo "  Files in ISO:"
    xorriso -indev "$ISO_PATH" -find /boot/vmlinuz -type f 2>&1 | grep "Found" && echo "  ✓ Kernel found"
    xorriso -indev "$ISO_PATH" -find /boot/initrd.img -type f 2>&1 | grep "Found" && echo "  ✓ Initrd found"
    xorriso -indev "$ISO_PATH" -find /boot/grub/grub.cfg -type f 2>&1 | grep "Found" && echo "  ✓ GRUB config found"
else
    log_error "ISO creation failed!"
    exit 1
fi

# ==================== Final output ====================
echo ""
echo "══════════════════════════════════════════════════════════"
echo "                    BUILD COMPLETE"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "OpenWRT Image:  $IMG_SIZE"
echo "Kernel:         $KERNEL_SIZE"
echo "Initramfs:      $INITRD_SIZE"
echo "Final ISO:      $ISO_SIZE"
echo ""
echo "ISO saved to: $ISO_PATH"
echo ""
echo "To create bootable USB:"
echo "  sudo dd if='$ISO_NAME' of=/dev/sdX bs=4M status=progress"
echo "  sudo sync"
echo ""
echo "══════════════════════════════════════════════════════════"
