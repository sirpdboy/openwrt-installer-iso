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
log_info "[1/8] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== Step 2: Install build tools ====================
log_info "[2/8] Installing build tools..."

# Update package list
apk update --no-cache

# Install packages one by one to handle errors gracefully
install_package() {
    local pkg="$1"
    log_info "Installing $pkg..."
    apk add --no-cache "$pkg" 2>/dev/null && return 0
    
    log_warning "Failed to install $pkg directly, trying with --force-broken-world..."
    apk add --no-cache --force-broken-world "$pkg" 2>/dev/null || {
        log_warning "Package $pkg may not be fully installed, continuing..."
        return 1
    }
}

# Install essential packages
install_package "xorriso"
install_package "syslinux"
install_package "mtools"
install_package "dosfstools"
install_package "squashfs-tools"
install_package "gzip"
install_package "cpio"
install_package "wget"
install_package "curl"
install_package "parted"
install_package "e2fsprogs"
install_package "pv"
install_package "dialog"

# Try to install GRUB packages (may fail in container)
log_info "Trying to install GRUB packages..."
apk add --no-cache grub grub-efi grub-bios 2>/dev/null || {
    log_warning "GRUB packages may have issues, continuing without full GRUB support"
}

# Install kernel package
log_info "Installing kernel..."
apk add --no-cache linux-lts 2>/dev/null || {
    log_warning "Linux-lts package may have issues, will use existing kernel"
}

log_success "Build tools installation attempted"

# ==================== Step 3: Get kernel ====================
log_info "[3/8] Getting kernel..."

# Find kernel in standard locations
KERNEL_SOURCE=""
for kernel_path in \
    "/boot/vmlinuz-lts" \
    "/boot/vmlinuz" \
    "/lib/modules/*/vmlinuz"; do
    
    if ls $kernel_path 2>/dev/null | head -1; then
        KERNEL_SOURCE=$(ls $kernel_path 2>/dev/null | head -1)
        break
    fi
done

if [ -n "$KERNEL_SOURCE" ] && [ -f "$KERNEL_SOURCE" ]; then
    cp "$KERNEL_SOURCE" "$WORK_DIR/vmlinuz"
    log_success "Found kernel: $(basename "$KERNEL_SOURCE")"
else
    # Try to extract from any linux package
    log_info "Looking for kernel in package files..."
    
    # Check APK cache
    APK_CACHE_FILE=$(find /var/cache/apk -name "*linux*.apk" 2>/dev/null | head -1)
    if [ -f "$APK_CACHE_FILE" ]; then
        log_info "Extracting from APK cache..."
        TEMP_EXTRACT="$WORK_DIR/apk_extract"
        mkdir -p "$TEMP_EXTRACT"
        
        # Extract APK
        tar -xzf "$APK_CACHE_FILE" -C "$TEMP_EXTRACT" 2>/dev/null || true
        
        # Look for kernel
        for kernel_file in "$TEMP_EXTRACT"/boot/vmlinuz* "$TEMP_EXTRACT"/lib/modules/*/vmlinuz; do
            if [ -f "$kernel_file" ]; then
                cp "$kernel_file" "$WORK_DIR/vmlinuz"
                log_success "Extracted kernel from APK"
                rm -rf "$TEMP_EXTRACT"
                break
            fi
        done
        rm -rf "$TEMP_EXTRACT" 2>/dev/null || true
    fi
fi

# Final check
if [ ! -f "$WORK_DIR/vmlinuz" ]; then
    log_error "ERROR: No kernel found! Cannot create bootable ISO."
    log_info "Tried:"
    log_info "1. Standard kernel locations"
    log_info "2. APK cache extraction"
    log_info ""
    log_info "Possible solutions:"
    log_info "1. Ensure linux-lts package is installed"
    log_info "2. Check if /boot/vmlinuz* exists"
    exit 1
fi

KERNEL_SIZE=$(ls -lh "$WORK_DIR/vmlinuz" | awk '{print $5}')
log_success "Kernel ready: $KERNEL_SIZE"

# ==================== Step 4: Create minimal root filesystem ====================
log_info "[4/8] Creating minimal root filesystem..."

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# Create all directories first
log_info "Creating directory structure..."
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr,var,sbin,run}
mkdir -p "$ROOTFS_DIR"/usr/{bin,sbin}
mkdir -p "$ROOTFS_DIR"/var/{lib,lock,log}
mkdir -p "$ROOTFS_DIR"/etc/modules-load.d

# Create init script
log_info "Creating init script..."
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/sh
# OpenWRT installer init script

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# Create device nodes (fallback if devtmpfs failed)
[ -c /dev/console ] || mknod /dev/console c 5 1 2>/dev/null
[ -c /dev/null ] || mknod /dev/null c 1 3 2>/dev/null
[ -c /dev/zero ] || mknod /dev/zero c 1 5 2>/dev/null

# Setup console
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

# Clear screen
printf "\033[2J\033[H"

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
    read
    exec /bin/sh
fi

echo "OpenWRT image found."
echo ""
echo "Scanning for available disks..."
echo ""

# List available disks
DISK_COUNT=0
for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
    if [ -b "$disk" ] 2>/dev/null; then
        DISK_COUNT=$((DISK_COUNT + 1))
        SIZE=""
        if command -v blockdev >/dev/null 2>&1; then
            SIZE=$(blockdev --getsize64 "$disk" 2>/dev/null)
            if [ -n "$SIZE" ]; then
                SIZE_GB=$((SIZE / 1024 / 1024 / 1024))
                echo "  $disk - ${SIZE_GB}GB"
            else
                echo "  $disk"
            fi
        else
            echo "  $disk"
        fi
    fi
done

if [ $DISK_COUNT -eq 0 ]; then
    echo "No disks found!"
    echo ""
    echo "Press Enter to rescan..."
    read
    # Re-exec init to restart
    exec /init
fi

echo ""
echo "----------------------------------------"
echo -n "Enter target disk (e.g., sda): "
read TARGET_DISK

if [ -z "$TARGET_DISK" ]; then
    echo "No disk selected. Restarting..."
    sleep 2
    exec /init
fi

# Validate disk exists
if [ ! -b "/dev/$TARGET_DISK" ]; then
    echo "ERROR: Disk /dev/$TARGET_DISK not found!"
    echo ""
    echo "Press Enter to try again..."
    read
    exec /init
fi

echo ""
echo "========================================"
echo "      CONFIRM INSTALLATION"
echo "========================================"
echo ""
echo "Target disk: /dev/$TARGET_DISK"
echo ""
echo "WARNING: This will ERASE ALL DATA on /dev/$TARGET_DISK!"
echo ""
echo -n "Type 'YES' (uppercase) to confirm: "
read CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Installation cancelled."
    echo ""
    echo "Press Enter to restart..."
    read
    exec /init
fi

echo ""
echo "========================================"
echo "      INSTALLING OPENWRT"
echo "========================================"
echo ""
echo "Installing to /dev/$TARGET_DISK..."
echo "This may take several minutes..."
echo ""

# Write the image
if command -v pv >/dev/null 2>&1; then
    echo "Progress:"
    pv /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
else
    echo "Writing image (no progress indicator)..."
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
fi

DD_STATUS=$?

if [ $DD_STATUS -eq 0 ]; then
    # Sync to ensure all data is written
    sync
    echo ""
    echo "========================================"
    echo "      INSTALLATION COMPLETE!"
    echo "========================================"
    echo ""
    echo "OpenWRT has been successfully installed to /dev/$TARGET_DISK"
    echo ""
    echo "Next steps:"
    echo "1. Remove the installation media"
    echo "2. Boot from the newly installed disk"
    echo "3. OpenWRT will start automatically"
    echo ""
    echo "System will reboot in 10 seconds..."
    
    # Countdown
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds...\r"
        sleep 1
    done
    echo ""
    echo "Rebooting now..."
    reboot -f
else
    echo ""
    echo "========================================"
    echo "      INSTALLATION FAILED!"
    echo "========================================"
    echo ""
    echo "Error code: $DD_STATUS"
    echo ""
    echo "Possible causes:"
    echo "• Disk may be in use or mounted"
    echo "• Not enough space on target disk"
    echo "• Disk may be failing"
    echo ""
    echo "Press Enter to restart installer..."
    read
    exec /init
fi
INIT_EOF

chmod +x "$ROOTFS_DIR/init"

# Setup busybox
log_info "Setting up busybox..."
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$ROOTFS_DIR/bin/busybox"
    chmod 755 "$ROOTFS_DIR/bin/busybox"
    
    # Create essential symlinks
    cd "$ROOTFS_DIR/bin"
    for app in sh ls cat echo dd mount umount sync reboot; do
        ln -sf busybox $app 2>/dev/null || true
    done
    cd "$WORK_DIR"
fi

# Copy other essential binaries
for tool in dd sync; do
    if command -v $tool >/dev/null 2>&1; then
        cp $(which $tool) "$ROOTFS_DIR/bin/" 2>/dev/null || true
    fi
done

# Create essential configuration files
log_info "Creating configuration files..."

# /etc/passwd
cat > "$ROOTFS_DIR/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF

# /etc/group
cat > "$ROOTFS_DIR/etc/group" << EOF
root:x:0:root
EOF

# modules to load
echo "loop" > "$ROOTFS_DIR/etc/modules-load.d/loop.conf"
echo "squashfs" > "$ROOTFS_DIR/etc/modules-load.d/squashfs.conf"

log_success "Minimal root filesystem created"

# ==================== Step 5: Create ISO structure ====================
log_info "[5/8] Creating ISO structure..."

ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR"
mkdir -p "$ISO_DIR/boot"
mkdir -p "$ISO_DIR/EFI/BOOT"

# Copy files
cp "$OPENWRT_IMG" "$ISO_DIR/openwrt.img"
cp "$WORK_DIR/vmlinuz" "$ISO_DIR/boot/vmlinuz"

log_success "Files copied to ISO structure"

# ==================== Step 6: Create initramfs ====================
log_info "[6/8] Creating initramfs..."

INITRAMFS_DIR="$WORK_DIR/initramfs"
mkdir -p "$INITRAMFS_DIR"

# Copy init script
cp "$ROOTFS_DIR/init" "$INITRAMFS_DIR/init"
chmod +x "$INITRAMFS_DIR/init"

# Copy busybox if available
if [ -f "$ROOTFS_DIR/bin/busybox" ]; then
    mkdir -p "$INITRAMFS_DIR/bin"
    cp "$ROOTFS_DIR/bin/busybox" "$INITRAMFS_DIR/bin/"
fi

# Create minimal dev nodes in initramfs
mkdir -p "$INITRAMFS_DIR/dev"
cat > "$INITRAMFS_DIR/dev/MAKEDEV" << 'EOF'
#!/bin/sh
# Simple device creation
mknod console c 5 1 2>/dev/null
mknod null c 1 3 2>/dev/null
mknod zero c 1 5 2>/dev/null
EOF
chmod +x "$INITRAMFS_DIR/dev/MAKEDEV"

# Create initramfs image
cd "$INITRAMFS_DIR"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img"
cd "$WORK_DIR"

INITRD_SIZE=$(ls -lh "$ISO_DIR/boot/initrd.img" 2>/dev/null | awk '{print $5}' || echo "unknown")
log_success "Initramfs created: $INITRD_SIZE"

# ==================== Step 7: Create boot configurations ====================
log_info "[7/8] Creating boot configurations..."

# BIOS boot (SYSLINUX)
log_info "Creating BIOS boot configuration..."
mkdir -p "$ISO_DIR/boot/syslinux"

cat > "$ISO_DIR/boot/syslinux.cfg" << 'SYSLINUX_CFG'
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

# Copy isolinux files if available
if [ -f /usr/share/syslinux/isolinux.bin ]; then
    cp /usr/share/syslinux/isolinux.bin "$ISO_DIR/boot/"
    cp /usr/share/syslinux/ldlinux.c32 "$ISO_DIR/boot/" 2>/dev/null || true
elif [ -f /usr/lib/syslinux/isolinux.bin ]; then
    cp /usr/lib/syslinux/isolinux.bin "$ISO_DIR/boot/"
    cp /usr/lib/syslinux/ldlinux.c32 "$ISO_DIR/boot/" 2>/dev/null || true
else
    log_warning "isolinux.bin not found - BIOS boot may not work"
fi

# UEFI boot (GRUB) - try to create if grub tools are available
log_info "Creating UEFI boot configuration..."
mkdir -p "$ISO_DIR/boot/grub"

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

# Try to create UEFI boot image
create_uefi_image() {
    log_info "Attempting to create UEFI boot image..."
    
    # Check if we have the tools
    if ! command -v grub-mkstandalone >/dev/null 2>&1; then
        log_warning "grub-mkstandalone not available, skipping UEFI boot"
        return 1
    fi
    
    if ! command -v mformat >/dev/null 2>&1; then
        log_warning "mtools not available, skipping UEFI boot"
        return 1
    fi
    
    # Create EFI image
    EFI_IMG="$WORK_DIR/efiboot.img"
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=32 2>/dev/null
    mkfs.vfat -F 32 "$EFI_IMG" >/dev/null 2>&1
    
    # Create GRUB EFI binary
    GRUB_TMP="$WORK_DIR/grub_tmp"
    mkdir -p "$GRUB_TMP/boot/grub"
    cp "$ISO_DIR/boot/grub/grub.cfg" "$GRUB_TMP/boot/grub/"
    
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="$GRUB_TMP/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$GRUB_TMP/boot/grub/grub.cfg" 2>/dev/null; then
        
        # Copy to EFI image
        mmd -i "$EFI_IMG" ::/EFI
        mmd -i "$EFI_IMG" ::/EFI/BOOT
        mcopy -i "$EFI_IMG" "$GRUB_TMP/bootx64.efi" ::/EFI/BOOT/
        
        # Copy to ISO
        cp "$EFI_IMG" "$ISO_DIR/EFI/BOOT/efiboot.img"
        log_success "UEFI boot image created"
        return 0
    else
        log_warning "Failed to create GRUB EFI binary"
        return 1
    fi
}

# Try to create UEFI image
create_uefi_image || {
    log_warning "UEFI boot will not be available in this ISO"
}

log_success "Boot configurations created"

# ==================== Step 8: Build ISO ====================
log_info "[8/8] Building final ISO..."

mkdir -p "$OUTPUT_DIR"

# Check what boot options we have
BOOT_OPTIONS=""
UEFI_BOOT=false

if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
    BOOT_OPTIONS="$BOOT_OPTIONS -eltorito-alt-boot -e EFI/BOOT/efiboot.img -no-emul-boot"
    UEFI_BOOT=true
fi

if [ -f "$ISO_DIR/boot/isolinux.bin" ]; then
    BOOT_OPTIONS="$BOOT_OPTIONS -c boot/boot.cat -b boot/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table"
fi

# Find isohdpfx.bin for hybrid MBR
ISOHDPFX=""
for path in /usr/share/syslinux /usr/lib/syslinux; do
    if [ -f "$path/isohdpfx.bin" ]; then
        ISOHDPFX="$path/isohdpfx.bin"
        break
    fi
done

# Build ISO command
XORRISO_CMD="xorriso -as mkisofs -volid 'OPENWRT_INSTALL' -output '$ISO_PATH'"

if [ -n "$ISOHDPFX" ]; then
    XORRISO_CMD="$XORRISO_CMD -isohybrid-mbr '$ISOHDPFX'"
fi

if [ -n "$BOOT_OPTIONS" ]; then
    XORRISO_CMD="$XORRISO_CMD $BOOT_OPTIONS"
fi

XORRISO_CMD="$XORRISO_CMD '$ISO_DIR'"

# Execute ISO build
log_info "Running: $(echo "$XORRISO_CMD" | tr -s ' ')"
eval $XORRISO_CMD 2>&1 | tee "$WORK_DIR/iso.log"

# Check if ISO was created
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    log_success "ISO created successfully: $ISO_SIZE"
else
    log_error "ISO creation failed!"
    log_info "Last 20 lines of build log:"
    tail -20 "$WORK_DIR/iso.log"
    exit 1
fi

# ==================== Display results ====================
echo ""
echo "========================================"
echo "         BUILD COMPLETED!"
echo "========================================"
echo ""
echo "Summary:"
echo "  OpenWRT Image:    $IMG_SIZE"
echo "  Kernel:           $KERNEL_SIZE"
echo "  Initramfs:        $INITRD_SIZE"
echo "  Final ISO:        $ISO_SIZE"
echo ""
echo "Boot Support:"
echo "  BIOS boot:        $(if [ -f "$ISO_DIR/boot/isolinux.bin" ]; then echo "✓ Available"; else echo "✗ Not available"; fi)"
echo "  UEFI boot:        $(if $UEFI_BOOT; then echo "✓ Available"; else echo "✗ Not available"; fi)"
echo ""
echo "Usage Instructions:"
echo "  1. Create bootable USB:"
echo "     sudo dd if='$ISO_NAME' of=/dev/sdX bs=4M status=progress"
echo "     sudo sync"
echo ""
echo "  2. Boot from USB and select 'Install OpenWRT'"
echo "  3. Enter target disk name (e.g., sda)"
echo "  4. Type 'YES' to confirm"
echo "  5. Wait for installation to complete"
echo "  6. System will reboot automatically"
echo ""
echo "Important Notes:"
echo "  • Installation will erase ALL data on target disk"
echo "  • Type 'YES' in uppercase to confirm"
echo "  • If installation fails, try a different disk"
echo "========================================"

# Create build info file
cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Alpine Installer ISO
============================
Build date: $(date)
Build script: $(basename "$0")

Input files:
  OpenWRT image: $(basename "$OPENWRT_IMG") ($IMG_SIZE)
  Kernel: $KERNEL_SIZE
  Initramfs: $INITRD_SIZE

Output:
  ISO file: $ISO_NAME ($ISO_SIZE)
  MD5: $(md5sum "$ISO_PATH" 2>/dev/null | awk '{print $1}' || echo "N/A")

Boot capabilities:
  BIOS/Legacy: $(if [ -f "$ISO_DIR/boot/isolinux.bin" ]; then echo "Yes"; else echo "No"; fi)
  UEFI: $(if $UEFI_BOOT; then echo "Yes"; else echo "No"; fi)

Installation process:
  1. Boot from USB created with this ISO
  2. Select "Install OpenWRT" from menu
  3. Enter disk name (e.g., sda, nvme0n1)
  4. Type YES to confirm
  5. Wait for progress to complete
  6. System reboots automatically

Troubleshooting:
  • If no disks appear, ensure system has storage devices
  • If installation fails, check disk health and connection
  • For shell access, select "Emergency Shell" option
EOF

log_success "Build info saved to: $OUTPUT_DIR/build-info.txt"
echo ""
log_info "Build process finished successfully!"
