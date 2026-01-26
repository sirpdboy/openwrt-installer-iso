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
log_info "[1/7] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== Step 2: Install build tools (ignore GRUB errors) ====================
log_info "[2/7] Installing build tools..."

# Temporarily disable GRUB triggers to avoid errors
mkdir -p /etc/apk
echo "#!/bin/sh" > /etc/apk/scripts/grub-2.12-r5.trigger
echo "exit 0" >> /etc/apk/scripts/grub-2.12-r5.trigger
chmod +x /etc/apk/scripts/grub-2.12-r5.trigger

apk update --no-cache
# Install packages, ignoring any trigger errors
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
    cpio \
    linux-lts 2>/dev/null || {
    log_warning "Some packages had warnings, continuing..."
}

log_success "Build tools installed"

# ==================== Step 2.5: Get kernel ====================
log_info "[2.5/7] Getting kernel..."

# First try to find kernel from installed linux-lts package
log_info "Looking for kernel from linux-lts package..."
KERNEL_FOUND=false

# Check common kernel locations
for kernel_path in \
    "/boot/vmlinuz-lts" \
    "/boot/vmlinuz" \
    "/boot/vmlinuz-$(uname -r)" \
    "/lib/modules/*/vmlinuz"; do
    
    if [ -f "$kernel_path" ] 2>/dev/null; then
        cp "$kernel_path" "$WORK_DIR/vmlinuz"
        KERNEL_FOUND=true
        log_success "Found kernel: $kernel_path"
        break
    fi
done

# If not found, extract from APK cache
if [ ! -f "$WORK_DIR/vmlinuz" ]; then
    log_info "Extracting kernel from APK cache..."
    
    # Find linux-lts APK in cache
    APK_CACHE=$(find /var/cache/apk -name "linux-lts*.apk" 2>/dev/null | head -1)
    if [ -f "$APK_CACHE" ]; then
        # Extract kernel from APK
        TEMP_DIR="$WORK_DIR/apk_extract"
        mkdir -p "$TEMP_DIR"
        
        # Extract APK
        tar -xzf "$APK_CACHE" -C "$TEMP_DIR" 2>/dev/null || true
        
        # Look for kernel
        for kernel_file in "$TEMP_DIR"/boot/vmlinuz* "$TEMP_DIR"/lib/modules/*/vmlinuz; do
            if [ -f "$kernel_file" ]; then
                cp "$kernel_file" "$WORK_DIR/vmlinuz"
                KERNEL_FOUND=true
                log_success "Extracted kernel from APK"
                break
            fi
        done
        
        rm -rf "$TEMP_DIR"
    fi
fi

# Final check
if [ ! -f "$WORK_DIR/vmlinuz" ]; then
    log_error "No kernel found! Cannot continue."
    log_info "Tried:"
    log_info "1. Standard kernel locations"
    log_info "2. APK cache extraction"
    exit 1
fi

KERNEL_SIZE=$(ls -lh "$WORK_DIR/vmlinuz" | awk '{print $5}')
KERNEL_INFO=$(file "$WORK_DIR/vmlinuz" 2>/dev/null | head -c 100)
log_success "Kernel ready: $KERNEL_SIZE ($KERNEL_INFO)"

# ==================== Step 3: Create minimal root filesystem ====================
log_info "[3/7] Creating minimal root filesystem..."

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# Create basic directory structure - ALL directories first
log_info "Creating directory structure..."
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr,var,sbin}
mkdir -p "$ROOTFS_DIR"/usr/{bin,sbin}
mkdir -p "$ROOTFS_DIR"/var/lib
mkdir -p "$ROOTFS_DIR"/etc/modules-load.d  # Create this directory first!
mkdir -p "$ROOTFS_DIR"/lib/modules

# Create init script
log_info "Creating init script..."
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# Minimal init script

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

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
    echo "✓ OpenWRT image found"
    echo ""
    echo "Starting installer..."
    echo ""
    
    # Show available disks
    echo "Available disks:"
    echo "----------------"
    
    # Simple disk detection
    for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
        if [ -b "$disk" ] 2>/dev/null; then
            echo "  $disk"
        fi
    done
    
    echo "----------------"
    echo ""
    
    echo -n "Enter target disk (e.g., sda): "
    read TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "No disk specified"
        sleep 2
        reboot -f
    fi
    
    # Check if disk exists
    if [ ! -b "/dev/$TARGET_DISK" ]; then
        echo "Disk /dev/$TARGET_DISK not found"
        sleep 2
        reboot -f
    fi
    
    echo ""
    echo "WARNING: This will erase ALL DATA on /dev/$TARGET_DISK"
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
        # Try to get file size for pv
        if [ -f /proc/self/fd/0 ] && [ "$(stat -c%s /openwrt.img 2>/dev/null || echo 0)" -gt 0 ]; then
            pv /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
        else
            dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>&1 | tail -1
        fi
    else
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>&1 | tail -1
    fi
    
    DD_EXIT=$?
    
    if [ $DD_EXIT -eq 0 ]; then
        sync
        echo ""
        echo "✓ Installation complete!"
        echo ""
        echo "System will reboot in 5 seconds..."
        sleep 5
        reboot -f
    else
        echo ""
        echo "✗ Installation failed! (Error: $DD_EXIT)"
        sleep 5
    fi
else
    echo "✗ ERROR: OpenWRT image not found!"
    echo ""
    echo "The image should be at: /openwrt.img"
    echo ""
    echo "Dropping to emergency shell..."
    echo ""
    exec /bin/sh
fi
INIT_EOF

chmod +x "$ROOTFS_DIR/init"

# Copy busybox and create symlinks
log_info "Setting up busybox..."
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$ROOTFS_DIR/bin/busybox"
    chmod +x "$ROOTFS_DIR/bin/busybox"
    
    # Create essential symlinks
    cd "$ROOTFS_DIR/bin"
    for app in sh ls cat echo dd mount umount reboot sync; do
        ln -sf busybox $app 2>/dev/null || true
    done
    cd "$WORK_DIR"
fi

# Copy essential binaries
for tool in dd pv sync; do
    if command -v $tool >/dev/null 2>&1; then
        tool_path=$(which $tool)
        mkdir -p "$(dirname "$ROOTFS_DIR$tool_path")" 2>/dev/null || true
        cp "$tool_path" "$ROOTFS_DIR$tool_path" 2>/dev/null || true
    fi
done

# Create essential /etc files
log_info "Creating /etc files..."
cat > "$ROOTFS_DIR/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF

cat > "$ROOTFS_DIR/etc/group" << EOF
root:x:0:root
EOF

# Create modules-load.d files - directory already exists
echo "loop" > "$ROOTFS_DIR/etc/modules-load.d/loop.conf"
echo "squashfs" > "$ROOTFS_DIR/etc/modules-load.d/squashfs.conf"

log_success "Minimal root filesystem created"

# ==================== Step 4: Create bootable ISO structure ====================
log_info "[4/7] Creating bootable ISO structure..."

ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/syslinux"
mkdir -p "$ISO_DIR/boot/grub"
mkdir -p "$ISO_DIR/EFI/BOOT"

# Copy OpenWRT image
cp "$OPENWRT_IMG" "$ISO_DIR/openwrt.img"

# Copy kernel to ISO
cp "$WORK_DIR/vmlinuz" "$ISO_DIR/boot/vmlinuz"
log_success "Kernel copied to ISO: $(ls -lh "$ISO_DIR/boot/vmlinuz" | awk '{print $5}')"

# Create initramfs
log_info "Creating initramfs..."
INITRAMFS_DIR="$WORK_DIR/initramfs"
mkdir -p "$INITRAMFS_DIR"
cp "$ROOTFS_DIR/init" "$INITRAMFS_DIR/init"
chmod +x "$INITRAMFS_DIR/init"

# Copy busybox to initramfs
if [ -f "$ROOTFS_DIR/bin/busybox" ]; then
    mkdir -p "$INITRAMFS_DIR/bin"
    cp "$ROOTFS_DIR/bin/busybox" "$INITRAMFS_DIR/bin/"
    chmod +x "$INITRAMFS_DIR/bin/busybox"
fi

# Create minimal /etc for initramfs
mkdir -p "$INITRAMFS_DIR/etc"
cat > "$INITRAMFS_DIR/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF

# Create initramfs archive
cd "$INITRAMFS_DIR"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img" 2>/dev/null
cd "$WORK_DIR"

INITRD_SIZE=$(ls -lh "$ISO_DIR/boot/initrd.img" 2>/dev/null | awk '{print $5}' || echo "unknown")
log_success "Initramfs created: $INITRD_SIZE"

# ==================== Step 5: Create BIOS boot (SYSLINUX) ====================
log_info "[5/7] Creating BIOS boot configuration..."

cat > "$ISO_DIR/boot/syslinux/syslinux.cfg" << 'SYSLINUX_CFG'
DEFAULT openwrt
TIMEOUT 30
PROMPT 0
UI menu.c32

MENU TITLE OpenWRT Auto Installer

LABEL openwrt
  MENU LABEL Install OpenWRT
  MENU DEFAULT
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
log_info "Copying SYSLINUX files..."
for file in isolinux.bin ldlinux.c32 libutil.c32 menu.c32; do
    find /usr -name "$file" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$ISO_DIR/boot/syslinux/" 2>/dev/null || true
done

# Verify isolinux.bin exists
if [ ! -f "$ISO_DIR/boot/syslinux/isolinux.bin" ]; then
    log_warning "isolinux.bin not found, trying to locate..."
    # Try alternative paths
    for path in /usr/lib/syslinux /usr/share/syslinux /usr/lib/ISOLINUX; do
        if [ -f "$path/isolinux.bin" ]; then
            cp "$path/isolinux.bin" "$ISO_DIR/boot/syslinux/"
            log_info "Found isolinux.bin at $path"
            break
        fi
    done
fi

if [ -f "$ISO_DIR/boot/syslinux/isolinux.bin" ]; then
    log_success "BIOS boot files ready"
else
    log_warning "isolinux.bin not found, BIOS boot may not work"
fi

# ==================== Step 6: Create UEFI boot (GRUB) ====================
log_info "[6/7] Creating UEFI boot configuration..."

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
dd if=/dev/zero of="$EFI_IMG" bs=1M count=32 2>/dev/null
mkfs.vfat -F 32 -n "UEFI_BOOT" "$EFI_IMG" >/dev/null 2>&1

# Create GRUB EFI binary (skip if grub-mkstandalone fails)
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "Building GRUB EFI binary..."
    
    GRUB_TMP="$WORK_DIR/grub_tmp"
    mkdir -p "$GRUB_TMP/boot/grub"
    cp "$ISO_DIR/boot/grub/grub.cfg" "$GRUB_TMP/boot/grub/"
    
    # Build standalone GRUB (suppress errors)
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="$GRUB_TMP/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$GRUB_TMP/boot/grub/grub.cfg" 2>/dev/null; then
        
        log_success "GRUB EFI binary created"
        
        # Mount EFI image and copy files using mcopy (more reliable)
        mmd -i "$EFI_IMG" ::/EFI
        mmd -i "$EFI_IMG" ::/EFI/BOOT
        mcopy -i "$EFI_IMG" "$GRUB_TMP/bootx64.efi" ::/EFI/BOOT/
        
        # Copy EFI image to ISO
        cp "$EFI_IMG" "$ISO_DIR/EFI/BOOT/efiboot.img"
        log_success "UEFI boot image created"
    else
        log_warning "Failed to create GRUB EFI binary, skipping UEFI boot"
        rm -f "$EFI_IMG"
    fi
else
    log_warning "grub-mkstandalone not available, skipping UEFI boot"
fi

# ==================== Step 7: Build final ISO ====================
log_info "[7/7] Building final ISO..."

mkdir -p "$OUTPUT_DIR"

# Check if we have UEFI boot
UEFI_OPTIONS=""
if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
    UEFI_OPTIONS="-eltorito-alt-boot -e EFI/BOOT/efiboot.img -no-emul-boot -isohybrid-gpt-basdat"
    log_info "Creating hybrid ISO (BIOS + UEFI)"
else
    log_warning "UEFI boot image missing, creating BIOS-only ISO"
fi

# Find isohdpfx.bin
ISOHDPFX=""
for path in /usr/share/syslinux /usr/lib/syslinux; do
    if [ -f "$path/isohdpfx.bin" ]; then
        ISOHDPFX="$path/isohdpfx.bin"
        break
    fi
done

# Build ISO with xorriso
log_info "Building ISO with xorriso..."
if command -v xorriso >/dev/null 2>&1; then
    XORRISO_CMD="xorriso -as mkisofs \
        -volid 'OPENWRT_INSTALL' \
        -full-iso9660-filenames \
        -iso-level 3 \
        -output '$ISO_PATH'"
    
    # Add MBR if available
    if [ -n "$ISOHDPFX" ]; then
        XORRISO_CMD="$XORRISO_CMD -isohybrid-mbr '$ISOHDPFX'"
    fi
    
    # Add BIOS boot if available
    if [ -f "$ISO_DIR/boot/syslinux/isolinux.bin" ]; then
        XORRISO_CMD="$XORRISO_CMD \
            -c boot/syslinux/boot.cat \
            -b boot/syslinux/isolinux.bin \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table"
    fi
    
    # Add UEFI boot if available
    if [ -n "$UEFI_OPTIONS" ]; then
        XORRISO_CMD="$XORRISO_CMD $UEFI_OPTIONS"
    fi
    
    XORRISO_CMD="$XORRISO_CMD '$ISO_DIR'"
    
    # Execute command
    eval $XORRISO_CMD 2>&1 | tee "$WORK_DIR/iso.log"
    
    if [ -f "$ISO_PATH" ]; then
        ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
        log_success "ISO created successfully: $ISO_PATH ($ISO_SIZE)"
    else
        log_error "ISO creation failed"
        log_info "Trying simpler method..."
        
        # Try simpler method
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -o "$ISO_PATH" \
            "$ISO_DIR" 2>/dev/null || {
            log_error "All ISO creation methods failed"
            exit 1
        }
    fi
else
    log_error "xorriso not found"
    exit 1
fi

# ==================== Step 8: Verify and display results ====================
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    echo "=========================================="
    echo "           BUILD COMPLETE!"
    echo "=========================================="
    echo ""
    
    echo "Build Summary:"
    echo "  OpenWRT Image:    $IMG_SIZE"
    echo "  Kernel:           $KERNEL_SIZE"
    echo "  Initramfs:        $INITRD_SIZE"
    echo "  Final ISO:        $ISO_SIZE"
    echo ""
    
    echo "Boot Support:"
    if [ -f "$ISO_DIR/boot/syslinux/isolinux.bin" ]; then
        echo "  ✓ BIOS (Legacy) boot"
    else
        echo "  ✗ BIOS boot (missing isolinux.bin)"
    fi
    
    if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then
        echo "  ✓ UEFI boot"
    else
        echo "  ✗ UEFI boot"
    fi
    echo ""
    
    echo "Installation Steps:"
    echo "  1. sudo dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  2. Boot from USB"
    echo "  3. Select 'Install OpenWRT'"
    echo "  4. Enter disk (e.g., sda)"
    echo "  5. Type 'YES' to confirm"
    echo "  6. Wait for completion"
    echo "  7. System reboots automatically"
    echo ""
    
    # Create build info
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Alpine Installer ISO
============================
Build date: $(date)
Image: $(basename "$OPENWRT_IMG") ($IMG_SIZE)
ISO: $ISO_NAME ($ISO_SIZE)
Kernel: $KERNEL_SIZE
Initramfs: $INITRD_SIZE

Boot support:
  BIOS: $(if [ -f "$ISO_DIR/boot/syslinux/isolinux.bin" ]; then echo "Yes"; else echo "No"; fi)
  UEFI: $(if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then echo "Yes"; else echo "No"; fi)

Usage:
  dd if=$ISO_NAME of=/dev/sdX bs=4M
  sync
EOF
    
    log_success "Build completed successfully!"
    
else
    log_error "ISO file was not created"
    exit 1
fi

echo ""
log_info "Build process finished"
