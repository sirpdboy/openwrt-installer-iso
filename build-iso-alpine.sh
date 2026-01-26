#!/bin/bash
# build-openwrt-alpine-iso.sh - Build OpenWRT auto-install ISO with Alpine
# Fixed BIOS/UEFI dual boot support

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
log_info "[1/9] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== Step 2: Install build tools ====================
log_info "[2/9] Installing build tools..."

apk update --no-cache

# Install essential packages
apk add --no-cache \
    bash \
    xorriso \
    syslinux \
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
    grub \
    grub-efi \
    grub-bios \
    e2fsprogs-extra \
    coreutils \
    findutils

log_success "Build tools installed"

# ==================== Step 3: Get kernel ====================
log_info "[3/9] Getting kernel..."

# Find kernel in system
if [ -f "/boot/vmlinuz-lts" ]; then
    cp "/boot/vmlinuz-lts" "$WORK_DIR/vmlinuz"
    log_success "Using kernel: vmlinuz-lts"
elif [ -f "/boot/vmlinuz" ]; then
    cp "/boot/vmlinuz" "$WORK_DIR/vmlinuz"
    log_success "Using kernel: vmlinuz"
else
    # Extract kernel from linux-lts package
    log_info "Extracting kernel from linux-lts package..."
    apk info -L linux-lts | grep '/boot/vmlinuz' | while read line; do
        if [ -f "$line" ]; then
            cp "$line" "$WORK_DIR/vmlinuz"
            log_success "Extracted kernel: $line"
            break
        fi
    done
fi

if [ ! -f "$WORK_DIR/vmlinuz" ]; then
    log_error "No kernel found! Cannot continue."
    exit 1
fi

KERNEL_SIZE=$(ls -lh "$WORK_DIR/vmlinuz" | awk '{print $5}')
log_success "Kernel ready: $KERNEL_SIZE"

# ==================== Step 4: Create minimal root filesystem ====================
log_info "[4/9] Creating minimal root filesystem..."

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# Create all directories
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr,var,sbin,run,root}
mkdir -p "$ROOTFS_DIR"/usr/{bin,sbin}
mkdir -p "$ROOTFS_DIR"/var/{lib,lock,log,tmp}
mkdir -p "$ROOTFS_DIR"/etc/modules-load.d

# Create init script
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/sh
# OpenWRT installer init script

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || {
    # Fallback: create essential devices manually
    mkdir -p /dev
    mknod /dev/console c 5 1 2>/dev/null
    mknod /dev/null c 1 3 2>/dev/null
    mknod /dev/zero c 1 5 2>/dev/null
    mknod /dev/tty c 5 0 2>/dev/null
    mknod /dev/tty1 c 4 1 2>/dev/null
}

# Setup console
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

# Clear screen
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
    read
    exec /bin/sh
fi

echo "✓ OpenWRT image found."
echo ""
echo "Scanning for available disks..."
echo ""

# List available disks
DISK_LIST=""
DISK_COUNT=0

for block in /sys/block/*; do
    DISK_NAME=$(basename "$block")
    
    # Skip virtual devices
    case "$DISK_NAME" in
        loop*|ram*|sr*|fd*)
            continue
            ;;
    esac
    
    if [ -b "/dev/$DISK_NAME" ]; then
        DISK_COUNT=$((DISK_COUNT + 1))
        DISK_LIST="$DISK_LIST $DISK_NAME"
        
        # Get disk size if possible
        SIZE=""
        if [ -f "$block/size" ]; then
            BLOCKS=$(cat "$block/size" 2>/dev/null)
            if [ -n "$BLOCKS" ]; then
                SIZE_BYTES=$((BLOCKS * 512))
                SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
                echo "  [$DISK_COUNT] /dev/$DISK_NAME - ${SIZE_GB}GB"
            else
                echo "  [$DISK_COUNT] /dev/$DISK_NAME"
            fi
        else
            echo "  [$DISK_COUNT] /dev/$DISK_NAME"
        fi
    fi
done

if [ $DISK_COUNT -eq 0 ]; then
    echo "No disks found!"
    echo ""
    echo "Press Enter to retry..."
    read
    # Reboot to restart
    reboot -f
fi

echo ""
echo "----------------------------------------"
echo -n "Select disk number (1-$DISK_COUNT): "
read SELECTION

# Validate selection
if ! echo "$SELECTION" | grep -qE '^[0-9]+$'; then
    echo "Invalid input. Please enter a number."
    sleep 2
    reboot -f
fi

if [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "$DISK_COUNT" ]; then
    echo "Invalid selection. Please choose 1-$DISK_COUNT."
    sleep 2
    reboot -f
fi

# Get selected disk
COUNT=1
for DISK in $DISK_LIST; do
    if [ "$COUNT" -eq "$SELECTION" ]; then
        TARGET_DISK="$DISK"
        break
    fi
    COUNT=$((COUNT + 1))
done

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
    reboot -f
fi

echo ""
echo "========================================"
echo "      INSTALLING OPENWRT"
echo "========================================"
echo ""
echo "Installing to /dev/$TARGET_DISK..."
echo "This may take several minutes..."
echo ""

# Write the image with progress
if command -v pv >/dev/null 2>&1; then
    echo "Progress:"
    TOTAL_SIZE=$(stat -c%s /openwrt.img 2>/dev/null || echo 0)
    if [ "$TOTAL_SIZE" -gt 0 ]; then
        pv -s "$TOTAL_SIZE" /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
    else
        pv /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
    fi
else
    echo "Writing image..."
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>&1 | grep -E 'bytes|copied' || true
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
    echo "✓ OpenWRT has been successfully installed to /dev/$TARGET_DISK"
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
    echo "✗ Error code: $DD_STATUS"
    echo ""
    echo "Possible causes:"
    echo "• Disk may be in use or mounted"
    echo "• Not enough space on target disk"
    echo "• Disk may be failing"
    echo ""
    echo "Press Enter to restart installer..."
    read
    reboot -f
fi
INIT_EOF

chmod +x "$ROOTFS_DIR/init"

# Setup busybox
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$ROOTFS_DIR/bin/busybox"
    chmod 755 "$ROOTFS_DIR/bin/busybox"
    
    # Create essential symlinks
    cd "$ROOTFS_DIR/bin"
    for app in sh ls cat echo dd mount umount sync reboot grep awk; do
        ln -sf busybox $app 2>/dev/null || true
    done
    cd "$WORK_DIR"
fi

# Create essential configuration files
cat > "$ROOTFS_DIR/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF

cat > "$ROOTFS_DIR/etc/group" << EOF
root:x:0:root
EOF

log_success "Minimal root filesystem created"

# ==================== Step 5: Create ISO structure ====================
log_info "[5/9] Creating ISO structure..."

ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR"
mkdir -p "$ISO_DIR/isolinux"
mkdir -p "$ISO_DIR/boot/grub"
mkdir -p "$ISO_DIR/EFI/BOOT"

# Copy files
cp "$OPENWRT_IMG" "$ISO_DIR/openwrt.img"
cp "$WORK_DIR/vmlinuz" "$ISO_DIR/boot/vmlinuz"

log_success "Files copied to ISO structure"

# ==================== Step 6: Create initramfs ====================
log_info "[6/9] Creating initramfs..."

INITRAMFS_DIR="$WORK_DIR/initramfs"
mkdir -p "$INITRAMFS_DIR"

# Copy init script
cp "$ROOTFS_DIR/init" "$INITRAMFS_DIR/init"
chmod +x "$INITRAMFS_DIR/init"

# Copy busybox if available
if [ -f "$ROOTFS_DIR/bin/busybox" ]; then
    mkdir -p "$INITRAMFS_DIR/bin"
    cp "$ROOTFS_DIR/bin/busybox" "$INITRAMFS_DIR/bin/"
    chmod +x "$INITRAMFS_DIR/bin/busybox"
fi

# Create minimal /etc
mkdir -p "$INITRAMFS_DIR/etc"
cat > "$INITRAMFS_DIR/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF

# Create initramfs image
cd "$INITRAMFS_DIR"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img"
cd "$WORK_DIR"

INITRD_SIZE=$(ls -lh "$ISO_DIR/boot/initrd.img" | awk '{print $5}')
log_success "Initramfs created: $INITRD_SIZE"

# ==================== Step 7: Create BIOS boot (SYSLINUX) ====================
log_info "[7/9] Creating BIOS boot configuration..."

# Create isolinux.cfg
cat > "$ISO_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
TIMEOUT 30
PROMPT 0
UI menu.c32

MENU TITLE OpenWRT Auto Installer

LABEL openwrt
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 single
ISOLINUX_CFG

# Copy ALL required SYSLINUX files
log_info "Copying SYSLINUX files..."
copy_syslinux_file() {
    local file="$1"
    for path in /usr/share/syslinux /usr/lib/syslinux /usr/lib/ISOLINUX; do
        if [ -f "$path/$file" ]; then
            cp "$path/$file" "$ISO_DIR/isolinux/"
            log_info "  Found $file at $path"
            return 0
        fi
    done
    log_warning "  WARNING: $file not found!"
    return 1
}

# Essential files for isolinux
copy_syslinux_file "isolinux.bin"
copy_syslinux_file "ldlinux.c32"
copy_syslinux_file "libutil.c32"
copy_syslinux_file "menu.c32"
copy_syslinux_file "libcom32.c32"
copy_syslinux_file "vesamenu.c32"

# Check if we have the essential files
if [ ! -f "$ISO_DIR/isolinux/isolinux.bin" ]; then
    log_error "ERROR: isolinux.bin not found! BIOS boot will not work."
    log_info "Trying to download isolinux..."
    wget -q -O "$ISO_DIR/isolinux/isolinux.bin" \
        "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz" && \
    tar -xzf "$ISO_DIR/isolinux/isolinux.bin" -C "$ISO_DIR/isolinux/" --wildcards "*/bios/core/isolinux.bin" --strip-components=2 2>/dev/null || \
    log_error "Failed to download isolinux.bin"
fi

if [ ! -f "$ISO_DIR/isolinux/ldlinux.c32" ]; then
    log_warning "ldlinux.c32 not found, trying to create ISO without it..."
fi

log_success "BIOS boot configuration created"

# ==================== Step 8: Create UEFI boot (GRUB) ====================
log_info "[8/9] Creating UEFI boot configuration..."

# Create GRUB configuration
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz console=tty0 single
    initrd /boot/initrd.img
}
GRUB_CFG

# Create UEFI boot image
log_info "Creating UEFI boot image..."
EFI_IMG="$WORK_DIR/efiboot.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=64
mkfs.vfat -F 32 -n "UEFI_BOOT" "$EFI_IMG" >/dev/null 2>&1

# Create directory for EFI files
EFI_TMP="$WORK_DIR/efi_tmp"
mkdir -p "$EFI_TMP/EFI/BOOT"

# Create GRUB EFI binary
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "Building GRUB EFI binary..."
    
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="$EFI_TMP/EFI/BOOT/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg" 2>/dev/null; then
        
        log_success "GRUB EFI binary created"
    else
        # Alternative method
        log_info "Trying alternative GRUB creation method..."
        grub-mkimage \
            -o "$EFI_TMP/EFI/BOOT/bootx64.efi" \
            -p /boot/grub \
            -O x86_64-efi \
            boot linux configfile normal part_gpt part_msdos fat iso9660
    fi
fi

if [ -f "$EFI_TMP/EFI/BOOT/bootx64.efi" ]; then
    # Copy GRUB modules
    mkdir -p "$EFI_TMP/boot/grub"
    cp "$ISO_DIR/boot/grub/grub.cfg" "$EFI_TMP/boot/grub/"
    
    # Mount EFI image and copy files
    EFI_MOUNT="$WORK_DIR/efi_mount"
    mkdir -p "$EFI_MOUNT"
    
    if mount -o loop "$EFI_IMG" "$EFI_MOUNT" 2>/dev/null; then
        cp -r "$EFI_TMP/EFI" "$EFI_MOUNT/"
        cp -r "$EFI_TMP/boot" "$EFI_MOUNT/" 2>/dev/null || true
        umount "$EFI_MOUNT"
    else
        # Use mcopy if mount fails
        mcopy -i "$EFI_IMG" -s "$EFI_TMP/EFI" ::
        mcopy -i "$EFI_IMG" -s "$EFI_TMP/boot" :: 2>/dev/null || true
    fi
    
    cp "$EFI_IMG" "$ISO_DIR/EFI/BOOT/efiboot.img"
    log_success "UEFI boot image created"
else
    log_warning "Could not create GRUB EFI binary, UEFI boot will not be available"
fi

# ==================== Step 9: Build ISO ====================
log_info "[9/9] Building final ISO..."

mkdir -p "$OUTPUT_DIR"

# Find isohdpfx.bin for hybrid MBR
ISOHDPFX=""
for path in /usr/share/syslinux /usr/lib/syslinux; do
    if [ -f "$path/isohdpfx.bin" ]; then
        ISOHDPFX="$path/isohdpfx.bin"
        log_info "Found isohdpfx.bin at $path"
        break
    fi
done

if [ -z "$ISOHDPFX" ]; then
    log_warning "isohdpfx.bin not found, creating non-hybrid ISO"
fi

# Build ISO command
XORRISO_ARGS=(
    -as mkisofs
    -volid "OPENWRT_INSTALL"
    -full-iso9660-filenames
    -iso-level 3
    -output "$ISO_PATH"
)

# Add MBR if found
if [ -n "$ISOHDPFX" ]; then
    XORRISO_ARGS+=(-isohybrid-mbr "$ISOHDPFX")
fi

# Add BIOS boot if we have isolinux
if [ -f "$ISO_DIR/isolinux/isolinux.bin" ]; then
    XORRISO_ARGS+=(
        -c "isolinux/boot.cat"
        -b "isolinux/isolinux.bin"
        -no-emul-boot
        -boot-load-size 4
        -boot-info-table
    )
    log_info "Adding BIOS boot support"
fi

# Add UEFI boot if we have EFI image
if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
    XORRISO_ARGS+=(
        -eltorito-alt-boot
        -e "EFI/BOOT/efiboot.img"
        -no-emul-boot
        -isohybrid-gpt-basdat
    )
    log_info "Adding UEFI boot support"
fi

# Add the ISO directory
XORRISO_ARGS+=("$ISO_DIR")

# Build the ISO
log_info "Running xorriso..."
xorriso "${XORRISO_ARGS[@]}" 2>&1 | tee "$WORK_DIR/iso.log"

# Verify ISO was created
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    log_success "ISO created successfully: $ISO_SIZE"
else
    log_error "ISO creation failed!"
    log_info "Build log:"
    cat "$WORK_DIR/iso.log"
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
if [ -f "$ISO_DIR/isolinux/isolinux.bin" ]; then
    echo "  BIOS boot:        ✓ Available"
else
    echo "  BIOS boot:        ✗ Not available (missing isolinux.bin)"
fi

if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
    echo "  UEFI boot:        ✓ Available"
else
    echo "  UEFI boot:        ✗ Not available"
fi
echo ""
echo "ISO Verification:"
echo "  Checking ISO structure..."
if command -v isoinfo >/dev/null 2>&1; then
    isoinfo -i "$ISO_PATH" -R -l 2>/dev/null | head -20
fi
echo ""
echo "Usage Instructions:"
echo "  1. Create bootable USB:"
echo "     sudo dd if='$ISO_NAME' of=/dev/sdX bs=4M status=progress"
echo "     sudo sync"
echo ""
echo "  2. Boot from USB:"
echo "     - BIOS: Select 'Install OpenWRT' from menu"
echo "     - UEFI: Should auto-boot to installer"
echo ""
echo "  3. Follow on-screen instructions:"
echo "     • Select disk number"
echo "     • Type 'YES' to confirm"
echo "     • Wait for installation"
echo "     • System will reboot automatically"
echo ""
echo "========================================"

# Create detailed build info
cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Alpine Installer ISO - Build Report
===========================================
Build date:      $(date)
Build script:    $(basename "$0")

Files:
  OpenWRT image: $(basename "$OPENWRT_IMG") ($IMG_SIZE)
  Kernel:        $(basename "$WORK_DIR/vmlinuz") ($KERNEL_SIZE)
  Initramfs:     $INITRD_SIZE
  ISO:           $ISO_NAME ($ISO_SIZE)

Boot Files Check:
  isolinux.bin:  $(if [ -f "$ISO_DIR/isolinux/isolinux.bin" ]; then echo "Present"; else echo "MISSING"; fi)
  ldlinux.c32:   $(if [ -f "$ISO_DIR/isolinux/ldlinux.c32" ]; then echo "Present"; else echo "MISSING"; fi)
  bootx64.efi:   $(if [ -f "$ISO_DIR/EFI/BOOT/bootx64.efi" ] || [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then echo "Present"; else echo "MISSING"; fi)

ISO Boot Records:
  $(xorriso -indev "$ISO_PATH" -report_el_torito as_mkisofs 2>/dev/null | grep -E "(Boot|El Torito)" | head -5)

Test Commands:
  # Check ISO content
  isoinfo -i "$ISO_NAME" -l
  
  # Check boot info
  xorriso -indev "$ISO_NAME" -report_el_torito as_mkisofs
  
  # Test with QEMU (BIOS)
  qemu-system-x86_64 -cdrom "$ISO_NAME" -m 512
  
  # Test with QEMU (UEFI - requires OVMF)
  qemu-system-x86_64 -cdrom "$ISO_NAME" -bios /usr/share/edk2-ovmf/x64/OVMF_CODE.fd -m 512

Installation Notes:
  1. Use numbers to select disks (1, 2, 3...)
  2. Type YES in uppercase to confirm
  3. Installation erases the entire target disk
  4. Progress bar shows during installation
  5. Automatic reboot after completion

Troubleshooting:
  • If BIOS boot fails: Check isolinux files, try different USB stick
  • If UEFI boot fails: Check if system supports UEFI, try BIOS mode
  • If no disks appear: System may not have storage devices detected
EOF

log_success "Build info saved to: $OUTPUT_DIR/build-info.txt"
echo ""
log_info "Build process finished successfully!"
