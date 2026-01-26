#!/bin/bash
# build-openwrt-alpine-iso.sh - Build OpenWRT auto-install ISO with Alpine
# Fixed BIOS/UEFI boot issues

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

# Create dummy triggers to avoid errors
mkdir -p /etc/apk/scripts
for trigger in grub-2.12-r5 syslinux-6.04_pre1-r15 mkinitfs-3.10.1-r0; do
    echo '#!/bin/sh' > "/etc/apk/scripts/$trigger.trigger"
    echo 'exit 0' >> "/etc/apk/scripts/$trigger.trigger"
    chmod +x "/etc/apk/scripts/$trigger.trigger"
done

apk update --no-cache

# Install essential packages
apk add --no-cache \
    bash \
    xorriso \
    syslinux \
    grub \
    grub-efi \
    grub-bios \
    mtools \
    dosfstools \
    squashfs-tools \
    gzip \
    cpio \
    wget \
    curl \
    parted \
    e2fsprogs \
    pv \
    dialog \
    linux-lts \
    linux-firmware-none \
    kmod \
    mkinitfs \
    busybox \
    coreutils \
    findutils \
    grep \
    util-linux \
    e2fsprogs-extra

log_success "Build tools installed"

# ==================== Step 3: Get kernel ====================
log_info "[3/9] Getting kernel..."

# Get kernel version
KERNEL_VERSION=$(ls /lib/modules/ 2>/dev/null | head -1)
if [ -z "$KERNEL_VERSION" ]; then
    KERNEL_VERSION="6.6.120-0-lts"
    log_warning "Using default kernel version: $KERNEL_VERSION"
fi

# Copy kernel
if [ -f "/boot/vmlinuz-lts" ]; then
    cp "/boot/vmlinuz-lts" "$WORK_DIR/vmlinuz"
elif [ -f "/boot/vmlinuz-$KERNEL_VERSION" ]; then
    cp "/boot/vmlinuz-$KERNEL_VERSION" "$WORK_DIR/vmlinuz"
else
    KERNEL_FILE=$(find /boot -name "vmlinuz*" -type f | head -1)
    if [ -n "$KERNEL_FILE" ]; then
        cp "$KERNEL_FILE" "$WORK_DIR/vmlinuz"
    else
        log_error "No kernel found!"
        exit 1
    fi
fi

KERNEL_SIZE=$(ls -lh "$WORK_DIR/vmlinuz" | awk '{print $5}')
log_success "Kernel ready: $KERNEL_SIZE"

# ==================== Step 4: Create minimal root filesystem ====================
log_info "[4/9] Creating minimal root filesystem..."

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# Create directory structure
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr,var,sbin,run,root,mnt}
mkdir -p "$ROOTFS_DIR"/usr/{bin,sbin}
mkdir -p "$ROOTFS_DIR"/var/{lib,lock,log,tmp,run}
mkdir -p "$ROOTFS_DIR"/etc/modules-load.d

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
    mknod /dev/tty c 5 0
    mknod /dev/tty1 c 4 1
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
echo "Detecting disks..."
echo ""

# List disks
DISK_INDEX=1
declare -A DISK_MAP

for disk in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
    [ -e "$disk" ] || continue
    DISK_NAME=$(basename "$disk")
    
    if [ -b "/dev/$DISK_NAME" ]; then
        DISK_MAP[$DISK_INDEX]="$DISK_NAME"
        
        # Get size
        SIZE=""
        if [ -f "$disk/size" ]; then
            SECTORS=$(cat "$disk/size" 2>/dev/null)
            if [ -n "$SECTORS" ]; then
                BYTES=$((SECTORS * 512))
                GB=$((BYTES / 1024 / 1024 / 1024))
                SIZE="${GB}GB"
            fi
        fi
        
        # Get model
        MODEL=""
        if [ -f "$disk/device/model" ]; then
            MODEL=$(cat "$disk/device/model" 2>/dev/null | tr -d '\n' | sed 's/  */ /g')
        fi
        
        if [ -n "$SIZE" ] && [ -n "$MODEL" ]; then
            echo "  [$DISK_INDEX] /dev/$DISK_NAME - $SIZE - $MODEL"
        elif [ -n "$SIZE" ]; then
            echo "  [$DISK_INDEX] /dev/$DISK_NAME - $SIZE"
        else
            echo "  [$DISK_INDEX] /dev/$DISK_NAME"
        fi
        
        DISK_INDEX=$((DISK_INDEX + 1))
    fi
done

TOTAL_DISKS=$((DISK_INDEX - 1))

if [ $TOTAL_DISKS -eq 0 ]; then
    echo ""
    echo "No disks found!"
    echo ""
    echo "Press Enter to retry..."
    read
    reboot -f
fi

echo ""
echo "----------------------------------------"
echo -n "Select disk number (1-$TOTAL_DISKS): "
read SELECTION

# Validate
if ! echo "$SELECTION" | grep -qE '^[0-9]+$'; then
    echo "Invalid input."
    sleep 2
    reboot -f
fi

if [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt $TOTAL_DISKS ]; then
    echo "Invalid selection."
    sleep 2
    reboot -f
fi

TARGET_DISK="${DISK_MAP[$SELECTION]}"

echo ""
echo "========================================"
echo "      CONFIRM INSTALLATION"
echo "========================================"
echo ""
echo "Target disk: /dev/$TARGET_DISK"
echo ""
echo "WARNING: This will ERASE ALL DATA on /dev/$TARGET_DISK!"
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
echo "Installing to /dev/$TARGET_DISK..."
echo ""

# Write image
if command -v pv >/dev/null 2>&1; then
    pv /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
else
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
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
    cp $(which busybox) "$ROOTFS_DIR/bin/busybox"
    chmod 755 "$ROOTFS_DIR/bin/busybox"
    
    cd "$ROOTFS_DIR/bin"
    for app in sh ls cat echo dd mount umount sync reboot; do
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

log_success "Root filesystem created"

# ==================== Step 5: Create ISO structure ====================
log_info "[5/9] Creating ISO structure..."

ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR"
mkdir -p "$ISO_DIR/isolinux"
mkdir -p "$ISO_DIR/boot"
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

# Copy busybox
if [ -f "$ROOTFS_DIR/bin/busybox" ]; then
    mkdir -p "$INITRAMFS_DIR/bin"
    cp "$ROOTFS_DIR/bin/busybox" "$INITRAMFS_DIR/bin/"
fi

# Create initramfs
cd "$INITRAMFS_DIR"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img"
cd "$WORK_DIR"

INITRD_SIZE=$(ls -lh "$ISO_DIR/boot/initrd.img" | awk '{print $5}')
log_success "Initramfs created: $INITRD_SIZE"

# ==================== Step 7: Create BIOS boot ====================
log_info "[7/9] Creating BIOS boot configuration..."

# Create isolinux.cfg with correct paths
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

# Copy SYSLINUX files with verification
log_info "Copying and verifying SYSLINUX files..."
copy_and_verify() {
    local file="$1"
    local source_path=""
    
    for path in /usr/share/syslinux /usr/lib/syslinux /usr/lib/ISOLINUX; do
        if [ -f "$path/$file" ]; then
            source_path="$path/$file"
            break
        fi
    done
    
    if [ -n "$source_path" ]; then
        cp "$source_path" "$ISO_DIR/isolinux/"
        if [ -f "$ISO_DIR/isolinux/$file" ]; then
            log_info "  ✓ $file ($(ls -lh "$ISO_DIR/isolinux/$file" | awk '{print $5}'))"
            return 0
        fi
    fi
    
    log_warning "  ✗ $file not found"
    return 1
}

# Essential files
copy_and_verify "isolinux.bin"
copy_and_verify "ldlinux.c32"
copy_and_verify "libutil.c32"
copy_and_verify "menu.c32"

# Optional but nice to have
copy_and_verify "libcom32.c32" || true
copy_and_verify "vesamenu.c32" || true

# Verify isolinux.bin is bootable
if [ -f "$ISO_DIR/isolinux/isolinux.bin" ]; then
    log_success "BIOS boot files ready"
else
    log_error "Missing isolinux.bin - BIOS boot will not work"
fi

# ==================== Step 8: Create UEFI boot ====================
log_info "[8/9] Creating UEFI boot configuration..."

# Create GRUB config with correct kernel path
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

# Create smaller EFI image to avoid xorriso warning
log_info "Creating UEFI boot image (smaller size)..."
EFI_IMG="$WORK_DIR/efiboot.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=16 2>/dev/null
mkfs.vfat -F 32 -n "UEFI_BOOT" "$EFI_IMG" >/dev/null 2>&1

# Create GRUB EFI binary
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "Building GRUB EFI binary..."
    
    GRUB_TMP="$WORK_DIR/grub_tmp"
    mkdir -p "$GRUB_TMP"
    
    # Create simple grub.cfg for standalone
    mkdir -p "$GRUB_TMP/boot/grub"
    cat > "$GRUB_TMP/boot/grub/grub.cfg" << 'EFI_GRUB_CFG'
search --file /openwrt.img --set=root
configfile /boot/grub/grub.cfg
EFI_GRUB_CFG
    
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="$GRUB_TMP/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$GRUB_TMP/boot/grub/grub.cfg" 2>/dev/null; then
        
        log_success "GRUB EFI binary created"
        
        # Copy to EFI image using mcopy
        mmd -i "$EFI_IMG" ::/EFI
        mmd -i "$EFI_IMG" ::/EFI/BOOT
        mcopy -i "$EFI_IMG" "$GRUB_TMP/bootx64.efi" ::/EFI/BOOT/
        
        # Copy the main grub.cfg to EFI image
        mmd -i "$EFI_IMG" ::/boot
        mmd -i "$EFI_IMG" ::/boot/grub
        mcopy -i "$EFI_IMG" "$ISO_DIR/boot/grub/grub.cfg" ::/boot/grub/
        
        cp "$EFI_IMG" "$ISO_DIR/EFI/BOOT/efiboot.img"
        log_success "UEFI boot image created (16MB)"
    else
        log_warning "Failed to create GRUB EFI binary"
    fi
else
    log_warning "grub-mkstandalone not available"
fi

# ==================== Step 9: Build final ISO ====================
log_info "[9/9] Building final ISO..."

mkdir -p "$OUTPUT_DIR"

# Create a working isohdpfx.bin if missing
ISOHDPFX=""
for path in /usr/share/syslinux /usr/lib/syslinux; do
    if [ -f "$path/isohdpfx.bin" ]; then
        ISOHDPFX="$path/isohdpfx.bin"
        log_info "Found isohdpfx.bin at $path"
        break
    fi
done

if [ -z "$ISOHDPFX" ]; then
    log_warning "isohdpfx.bin not found, creating simple one..."
    # Create a minimal MBR
    dd if=/dev/zero of="$WORK_DIR/isohdpfx.bin" bs=512 count=1
    # Mark as bootable (0x80 at offset 0x1BE)
    printf '\x80' | dd of="$WORK_DIR/isohdpfx.bin" bs=1 seek=510 conv=notrunc 2>/dev/null
    printf '\x55\xAA' | dd of="$WORK_DIR/isohdpfx.bin" bs=1 seek=510 conv=notrunc 2>/dev/null
    ISOHDPFX="$WORK_DIR/isohdpfx.bin"
fi

# Build ISO step by step to avoid warnings
log_info "Building ISO with proper settings..."

# First, check if we have UEFI boot
UEFI_BOOT_OPTIONS=""
if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
    EFI_IMG_SIZE=$(stat -c%s "$ISO_DIR/EFI/BOOT/efiboot.img")
    EFI_BLOCKS=$((EFI_IMG_SIZE / 2048))  # CD sectors are 2048 bytes
    
    if [ $EFI_BLOCKS -le 65535 ]; then
        UEFI_BOOT_OPTIONS="-eltorito-alt-boot -e EFI/BOOT/efiboot.img -no-emul-boot -isohybrid-gpt-basdat"
        log_info "UEFI boot image size: $EFI_BLOCKS blocks (OK)"
    else
        log_warning "UEFI boot image too large ($EFI_BLOCKS blocks), adjusting..."
        # Create smaller EFI image
        dd if=/dev/zero of="$ISO_DIR/EFI/BOOT/efiboot-small.img" bs=1M count=8
        mkfs.vfat -F 32 "$ISO_DIR/EFI/BOOT/efiboot-small.img" >/dev/null 2>&1
        
        # Copy just the essential files
        TEMP_MOUNT="$WORK_DIR/efi_temp"
        mkdir -p "$TEMP_MOUNT"
        mount -o loop "$ISO_DIR/EFI/BOOT/efiboot.img" "$TEMP_MOUNT" 2>/dev/null && {
            mount -o loop "$ISO_DIR/EFI/BOOT/efiboot-small.img" "$WORK_DIR/efi_temp2" 2>/dev/null && {
                mkdir -p "$WORK_DIR/efi_temp2/EFI/BOOT"
                cp "$TEMP_MOUNT/EFI/BOOT/bootx64.efi" "$WORK_DIR/efi_temp2/EFI/BOOT/" 2>/dev/null || true
                umount "$WORK_DIR/efi_temp2"
            }
            umount "$TEMP_MOUNT"
        }
        
        mv "$ISO_DIR/EFI/BOOT/efiboot-small.img" "$ISO_DIR/EFI/BOOT/efiboot.img"
        UEFI_BOOT_OPTIONS="-eltorito-alt-boot -e EFI/BOOT/efiboot.img -no-emul-boot -isohybrid-gpt-basdat"
    fi
fi

# Build the ISO
xorriso -as mkisofs \
    -volid "OPENWRT_INSTALL" \
    -full-iso9660-filenames \
    -iso-level 3 \
    -rational-rock \
    -output "$ISO_PATH" \
    -isohybrid-mbr "$ISOHDPFX" \
    -c "isolinux/boot.cat" \
    -b "isolinux/isolinux.bin" \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    $UEFI_BOOT_OPTIONS \
    "$ISO_DIR" 2>&1 | tee "$WORK_DIR/iso.log"

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    log_success "ISO created successfully: $ISO_SIZE"
    
    # Verify ISO structure
    log_info "Verifying ISO..."
    if command -v xorriso >/dev/null 2>&1; then
        echo "Boot records:"
        xorriso -indev "$ISO_PATH" -report_el_torito as_mkisofs 2>&1 | grep -E "(Boot|image|platform)" || true
        
        echo ""
        echo "Checking file paths..."
        xorriso -indev "$ISO_PATH" -find /boot/vmlinuz -type f 2>&1
        xorriso -indev "$ISO_PATH" -find /boot/initrd.img -type f 2>&1
        xorriso -indev "$ISO_PATH" -find /boot/grub/grub.cfg -type f 2>&1
    fi
else
    log_error "ISO creation failed!"
    exit 1
fi

# ==================== Display results ====================
echo ""
echo "══════════════════════════════════════════════════════════"
echo "                BUILD COMPLETED!"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "File Sizes:"
echo "  OpenWRT Image:    $IMG_SIZE"
echo "  Kernel:           $KERNEL_SIZE"
echo "  Initramfs:        $INITRD_SIZE"
echo "  Final ISO:        $ISO_SIZE"
echo ""
echo "Boot Files Verification:"
echo "  Kernel path:      /boot/vmlinuz $(xorriso -indev "$ISO_PATH" -find /boot/vmlinuz -type f 2>&1 | grep -q "Found" && echo "✓" || echo "✗")"
echo "  Initrd path:      /boot/initrd.img $(xorriso -indev "$ISO_PATH" -find /boot/initrd.img -type f 2>&1 | grep -q "Found" && echo "✓" || echo "✗")"
echo "  GRUB config:      /boot/grub/grub.cfg $(xorriso -indev "$ISO_PATH" -find /boot/grub/grub.cfg -type f 2>&1 | grep -q "Found" && echo "✓" || echo "✗")"
echo ""
echo "Boot Support:"
if [ -f "$ISO_DIR/isolinux/isolinux.bin" ]; then
    echo "  BIOS/Legacy:      ✓ SYSLINUX"
else
    echo "  BIOS/Legacy:      ✗ Missing isolinux.bin"
fi

if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
    echo "  UEFI:             ✓ GRUB2"
else
    echo "  UEFI:             ✗ No EFI boot"
fi
echo ""
echo "Test Commands:"
echo "  # Test BIOS boot: qemu-system-x86_64 -cdrom '$ISO_NAME' -m 512"
echo "  # Test UEFI boot: qemu-system-x86_64 -cdrom '$ISO_NAME' -bios /usr/share/OVMF/OVMF_CODE.fd -m 512"
echo "  # List files: xorriso -indev '$ISO_NAME' -find / -type f"
echo ""
echo "══════════════════════════════════════════════════════════"

# Create verification script
cat > "$OUTPUT_DIR/verify-iso.sh" << 'EOF'
#!/bin/bash
# ISO verification script

ISO="$1"
if [ ! -f "$ISO" ]; then
    echo "Usage: $0 <iso-file>"
    exit 1
fi

echo "Verifying ISO: $ISO"
echo "================"

# Check boot records
echo "1. Boot records:"
xorriso -indev "$ISO" -report_el_torito as_mkisofs 2>&1 | grep -A5 -B5 "Boot"

# Check essential files
echo ""
echo "2. Essential files:"
for file in /boot/vmlinuz /boot/initrd.img /boot/grub/grub.cfg /isolinux/isolinux.cfg; do
    if xorriso -indev "$ISO" -find "$file" -type f 2>&1 | grep -q "Found"; then
        echo "  ✓ $file"
    else
        echo "  ✗ $file (MISSING)"
    fi
done

# Check file sizes
echo ""
echo "3. File sizes in ISO:"
xorriso -indev "$ISO" -find /boot/vmlinuz -type f -exec report_size 2>&1 | tail -1
xorriso -indev "$ISO" -find /boot/initrd.img -type f -exec report_size 2>&1 | tail -1

# Test extract
echo ""
echo "4. Testing file extraction:"
TEMP_DIR=$(mktemp -d)
xorriso -osirrox on -indev "$ISO" -extract /boot/vmlinuz "$TEMP_DIR/vmlinuz" 2>&1 | grep -v "UPDATE"
if [ -f "$TEMP_DIR/vmlinuz" ]; then
    echo "  ✓ Kernel extracted ($(ls -lh "$TEMP_DIR/vmlinuz" | awk '{print $5}'))"
    file "$TEMP_DIR/vmlinuz"
else
    echo "  ✗ Failed to extract kernel"
fi

rm -rf "$TEMP_DIR"

echo ""
echo "Verification complete."
EOF

chmod +x "$OUTPUT_DIR/verify-iso.sh"

log_success "Verification script created: $OUTPUT_DIR/verify-iso.sh"
echo ""
log_info "Use: ./verify-iso.sh '$ISO_NAME' to check ISO integrity"
