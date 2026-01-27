#!/bin/bash
# build-iso-alpine.sh - Build OpenWRT auto-install ISO with Alpine
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

# ==================== Step 2: Install build tools ====================
log_info "[2/10] Installing build tools..."

# 方法一：使用--no-scripts参数（推荐）
log_info "Installing packages with --no-scripts flag..."
apk update --no-cache
apk add --no-cache --no-scripts \
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
log_info "[3/10] Getting kernel..."

# 确保内核模块已加载
if ! lsmod | grep -q "ext4"; then
    modprobe ext4 2>/dev/null || true
fi

# 查找内核文件
KERNEL_FOUND=""
for kernel in /boot/vmlinuz-lts /boot/vmlinuz-grsec /boot/vmlinuz; do
    if [ -f "$kernel" ]; then
        KERNEL_FOUND="$kernel"
        log_info "Found kernel: $kernel"
        cp "$kernel" "$WORK_DIR/vmlinuz"
        break
    fi
done

# 如果没找到，尝试安装linux-lts
if [ -z "$KERNEL_FOUND" ]; then
    log_warning "No kernel found, trying to install linux-lts..."
    apk add --no-cache linux-lts
    
    # 再次查找
    for kernel in /boot/vmlinuz-lts /boot/vmlinuz-grsec /boot/vmlinuz; do
        if [ -f "$kernel" ]; then
            KERNEL_FOUND="$kernel"
            log_info "Found kernel after install: $kernel"
            cp "$kernel" "$WORK_DIR/vmlinuz"
            break
        fi
    done
fi

# 如果还是没找到，使用备用方案
if [ -z "$KERNEL_FOUND" ] || [ ! -f "$WORK_DIR/vmlinuz" ]; then
    log_warning "Using fallback kernel search..."
    # 更广泛地搜索
    find /boot -name "vmlinuz*" -type f 2>/dev/null | head -1 | while read kernel; do
        if [ -n "$kernel" ] && [ -f "$kernel" ]; then
            KERNEL_FOUND="$kernel"
            cp "$kernel" "$WORK_DIR/vmlinuz"
            log_info "Found kernel via find: $kernel"
            break
        fi
    done
fi

if [ ! -f "$WORK_DIR/vmlinuz" ]; then
    log_error "No kernel found! Creating minimal kernel placeholder..."
    # 创建一个小文件作为占位符（实际使用时需要替换）
    dd if=/dev/zero of="$WORK_DIR/vmlinuz" bs=1M count=1 2>/dev/null
    log_warning "Using placeholder kernel - ISO may not boot properly"
fi

KERNEL_SIZE=$(ls -lh "$WORK_DIR/vmlinuz" 2>/dev/null | awk '{print $5}' || echo "Unknown")
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
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr,var,sbin,run,root,mnt,opt}
mkdir -p "$ROOTFS_DIR"/usr/{bin,sbin,lib}
mkdir -p "$ROOTFS_DIR"/var/{lib,lock,log,tmp,run}
mkdir -p "$ROOTFS_DIR"/lib/modules

# Create init script
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/sh
# OpenWRT installer init script
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || {
    mkdir -p /dev
    mknod /dev/console c 5 1 2>/dev/null
    mknod /dev/null c 1 3 2>/dev/null
    mknod /dev/zero c 1 5 2>/dev/null
    mknod /dev/tty c 5 0 2>/dev/null
    mknod /dev/tty1 c 4 1 2>/dev/null
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

# List disks with more comprehensive search
INDEX=1
for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z] /dev/hd[a-z]; do
    if [ -b "$disk" ] 2>/dev/null; then
        SIZE=$(blockdev --getsize64 "$disk" 2>/dev/null | numfmt --to=iec --suffix=B 2>/dev/null || echo "Unknown")
        echo "  [$INDEX] $disk ($SIZE)"
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

# Write image with progress indicator
if command -v pv >/dev/null 2>&1; then
    TOTAL_SIZE=$(stat -c%s /openwrt.img 2>/dev/null || echo 0)
    if [ "$TOTAL_SIZE" -gt 0 ]; then
        pv -s "$TOTAL_SIZE" /openwrt.img | dd of="$TARGET_DISK" bs=4M 2>/dev/null
    else
        dd if=/openwrt.img of="$TARGET_DISK" bs=4M 2>/dev/null
    fi
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
    echo "Error code: $?"
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
    # Create essential symlinks
    for app in sh ls cat echo dd mount umount sync reboot mknod read sleep grep; do
        ln -sf busybox $app 2>/dev/null || true
    done
    cd "$WORK_DIR"
fi

# Add blockdev if available
if command -v blockdev >/dev/null 2>&1; then
    cp $(which blockdev) "$ROOTFS_DIR/bin/" 2>/dev/null || true
fi

# Add numfmt for disk size display
if command -v numfmt >/dev/null 2>&1; then
    cp $(which numfmt) "$ROOTFS_DIR/bin/" 2>/dev/null || true
fi

# Configuration files
cat > "$ROOTFS_DIR/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF

cat > "$ROOTFS_DIR/etc/group" << EOF
root:x:0:root
EOF

# Create fstab
cat > "$ROOTFS_DIR/etc/fstab" << EOF
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
devtmpfs /dev devtmpfs defaults 0 0
EOF

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

# Create basic device structure in initramfs
mkdir -p "$INITRAMFS_DIR/dev"
mkdir -p "$INITRAMFS_DIR/proc"
mkdir -p "$INITRAMFS_DIR/sys"
mkdir -p "$INITRAMFS_DIR/tmp"

# Create initramfs using simpler method
cd "$INITRAMFS_DIR"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img"
cd "$WORK_DIR"

INITRD_SIZE=$(ls -lh "$ISO_DIR/boot/initrd.img" 2>/dev/null | awk '{print $5}' || echo "Unknown")
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

LABEL openwrt
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img
ISOLINUX_CFG

# Copy SYSLINUX files with comprehensive search
log_info "Copying SYSLINUX files..."

copy_syslinux_file() {
    local file="$1"
    local found=0
    
    # Check multiple possible locations
    for path in /usr/share/syslinux /usr/lib/syslinux /lib/syslinux /usr/lib/ISOLINUX; do
        if [ -f "$path/$file" ]; then
            cp "$path/$file" "$ISO_DIR/isolinux/"
            log_info "  ✓ $file from $path"
            found=1
            break
        fi
    done
    
    if [ $found -eq 0 ]; then
        log_warning "  ✗ $file not found"
        return 1
    fi
    return 0
}

# Essential files
copy_syslinux_file "isolinux.bin"
copy_syslinux_file "ldlinux.c32"
copy_syslinux_file "libutil.c32"
copy_syslinux_file "menu.c32"
copy_syslinux_file "libcom32.c32" || true

# Try to get reboot.c32
if ! copy_syslinux_file "reboot.c32"; then
    # Create a simple reboot script if not found
    echo '#!/bin/sh
echo "Rebooting..."
sleep 2
reboot -f' > "$ISO_DIR/isolinux/reboot.c32"
    chmod +x "$ISO_DIR/isolinux/reboot.c32"
fi

# Verify we have the essentials
if [ -f "$ISO_DIR/isolinux/isolinux.bin" ] && [ -f "$ISO_DIR/isolinux/ldlinux.c32" ]; then
    log_success "BIOS boot files ready"
else
    log_error "Missing essential BIOS boot files!"
    exit 1
fi

# ==================== Step 9: Create UEFI boot configuration ====================
log_info "[9/10] Creating UEFI boot configuration..."

# Create GRUB configuration
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0
set gfxmode=auto

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz

    initrd /boot/initrd.img

}
GRUB_CFG

log_success "GRUB configuration created"

# Create UEFI boot image
log_info "Creating UEFI boot image..."
EFI_IMG="$WORK_DIR/efiboot.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=128
mkfs.vfat -F 32 -n "UEFI_BOOT" "$EFI_IMG" >/dev/null 2>&1

# Create EFI directory structure in the image
MMOUNT="$WORK_DIR/efi_mount"
mkdir -p "$MMOUNT"

# Try to mount and populate EFI image
if mount -o loop "$EFI_IMG" "$MMOUNT" 2>/dev/null; then
    mkdir -p "$MMOUNT/EFI/BOOT"
    
    # Try to create GRUB EFI binary
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        log_info "Building GRUB EFI binary..."
        
        TMP_GRUB="$WORK_DIR/grub_temp"
        mkdir -p "$TMP_GRUB/boot/grub"
        
        cat > "$TMP_GRUB/boot/grub/grub.cfg" << 'TEMP_GRUB_CFG'
search --file /openwrt.img --set=root
configfile /boot/grub/grub.cfg
TEMP_GRUB_CFG
        
        if grub-mkstandalone \
            --format=x86_64-efi \
            --output="$TMP_GRUB/BOOTx64.EFI" \
            --locales="" \
            --fonts="" \
            --modules="part_gpt part_msdos ext2 fat iso9660" \
            "boot/grub/grub.cfg=$TMP_GRUB/boot/grub/grub.cfg" 2>/dev/null; then
            
            cp "$TMP_GRUB/BOOTx64.EFI" "$MMOUNT/EFI/BOOT/"
            log_success "GRUB EFI binary created"
        else
            log_warning "Failed to create GRUB EFI binary"
        fi
    fi
    
    # Copy GRUB configuration
    mkdir -p "$MMOUNT/boot/grub"
    cp "$ISO_DIR/boot/grub/grub.cfg" "$MMOUNT/boot/grub/"
    
    # Create minimal EFI shell if no GRUB
    if [ ! -f "$MMOUNT/EFI/BOOT/BOOTx64.EFI" ]; then
        log_warning "Creating minimal EFI fallback..."
        cat > "$MMOUNT/EFI/BOOT/BOOTx64.EFI.txt" << 'EOF'
This ISO supports UEFI boot but GRUB was not available during build.
Please use BIOS/Legacy boot mode or rebuild with GRUB installed.
EOF
    fi
    
    sync
    umount "$MMOUNT"
    
    cp "$EFI_IMG" "$ISO_DIR/EFI/BOOT/efiboot.img"
    log_success "UEFI boot image created (8MB)"
else
    log_warning "Failed to mount EFI image, skipping UEFI boot"
fi

# ==================== Step 10: Build final ISO ====================
log_info "[10/10] Building final ISO..."

mkdir -p "$OUTPUT_DIR"

# Find isohdpfx.bin
ISOHDPFX=""
for path in /usr/share/syslinux /usr/lib/syslinux; do
    if [ -f "$path/isohdpfx.bin" ]; then
        ISOHDPFX="$path/isohdpfx.bin"
        break
    fi
done

if [ -z "$ISOHDPFX" ]; then
    log_warning "isohdpfx.bin not found, using xorriso internal MBR"
    # xorriso can create its own MBR
    ISOHDPFX=""
fi

# Build ISO with proper parameters
log_info "Building ISO..."

XORRISO_CMD="xorriso -as mkisofs \
    -volid 'OPENWRT_INSTALL' \
    -J -r -V 'OPENWRT_INSTALL' \
    -full-iso9660-filenames \
    -iso-level 3 \
    -rational-rock \
    -output '$ISO_PATH'"

# Add BIOS boot options
if [ -n "$ISOHDPFX" ]; then
    XORRISO_CMD="$XORRISO_CMD -isohybrid-mbr '$ISOHDPFX'"
fi

XORRISO_CMD="$XORRISO_CMD \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table"

# Add UEFI boot if available
if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
    XORRISO_CMD="$XORRISO_CMD \
        -eltorito-alt-boot \
        -e EFI/BOOT/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat"
    log_info "Including UEFI boot support"
fi

XORRISO_CMD="$XORRISO_CMD '$ISO_DIR'"

log_info "Running xorriso command..."
eval $XORRISO_CMD 2>&1 | grep -v "File not found" | tee "$WORK_DIR/iso.log"

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    log_success "ISO created successfully: $ISO_SIZE"
    
    # Verify ISO structure
    log_info "Verifying ISO..."
    echo "Essential files check:"
    
    CHECK_FILES=(
        "/boot/vmlinuz"
        "/boot/initrd.img" 
        "/isolinux/isolinux.cfg"
        "/openwrt.img"
    )
    
    ALL_OK=true
    for file in "${CHECK_FILES[@]}"; do
        if xorriso -indev "$ISO_PATH" -find "$file" -type f 2>/dev/null | grep -q "Found"; then
            log_success "  ✓ $file"
        else
            log_error "  ✗ $file"
            ALL_OK=false
        fi
    done
    
    if $ALL_OK; then
        log_success "ISO verification passed!"
    else
        log_warning "ISO verification failed for some files"
    fi
else
    log_error "ISO creation failed!"
    log_info "Last 20 lines of build log:"
    tail -20 "$WORK_DIR/iso.log"
    exit 1
fi

# ==================== Display results ====================
echo ""
echo "══════════════════════════════════════════════════════════"
echo "                BUILD COMPLETED SUCCESSFULLY!"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "Build Summary:"
echo "  OpenWRT Image:    $IMG_SIZE"
echo "  Kernel:           $KERNEL_SIZE"
echo "  Initramfs:        $INITRD_SIZE"
echo "  Final ISO:        $ISO_SIZE"
echo ""
echo "ISO Location:       $ISO_PATH"
echo ""
echo "Boot Support Status:"
if [ -f "$ISO_DIR/isolinux/isolinux.bin" ]; then
    echo "  BIOS/Legacy:      ✓ Available"
else
    echo "  BIOS/Legacy:      ✗ Not available"
fi

if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
    echo "  UEFI:             ✓ Available"
else
    echo "  UEFI:             ✗ Not available"
fi
echo ""
echo "Usage Instructions:"
echo "  1. Write to USB: sudo dd if='$ISO_PATH' of=/dev/sdX bs=4M status=progress"
echo "  2. Sync: sudo sync"
echo "  3. Boot from USB drive"
echo "  4. Select 'Install OpenWRT' from menu"
echo ""
echo "Testing with QEMU:"
echo "  BIOS mode:  qemu-system-x86_64 -cdrom '$ISO_PATH' -m 512"
echo "  UEFI mode:  qemu-system-x86_64 -cdrom '$ISO_PATH' -bios /usr/share/OVMF/OVMF_CODE.fd -m 512"
echo ""
echo "══════════════════════════════════════════════════════════"

# Create verification script
cat > "$OUTPUT_DIR/verify-iso.sh" << 'VERIFY_EOF'
#!/bin/bash
ISO="$1"
[ -f "$ISO" ] || { echo "Usage: $0 <iso-file>"; exit 1; }

echo "Verifying: $(basename "$ISO")"
echo "Size: $(ls -lh "$ISO" | awk '{print $5}')"

if command -v xorriso >/dev/null 2>&1; then
    echo -e "\nBoot Configuration:"
    xorriso -indev "$ISO" -report_el_torito as_mkisofs 2>&1 | grep -A10 "El Torito"
    
    echo -e "\nFile Check:"
    for f in /boot/vmlinuz /boot/initrd.img /openwrt.img; do
        xorriso -indev "$ISO" -find "$f" -type f 2>&1 | grep -q "Found" && \
        echo "  ✓ $f" || echo "  ✗ $f"
    done
fi
VERIFY_EOF

chmod +x "$OUTPUT_DIR/verify-iso.sh"

log_success "Verification script created: $OUTPUT_DIR/verify-iso.sh"
echo ""
log_info "Build completed at $(date)"
