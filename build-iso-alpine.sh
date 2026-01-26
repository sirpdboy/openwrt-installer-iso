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

# ==================== Step 2: Install build tools ====================
log_info "[2/7] Installing build tools..."
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
    cpio \
    linux-lts \
    linux-firmware-none

log_success "Build tools installed"

# ==================== Step 2.5: Download Alpine kernel ====================
log_info "[2.5/7] Downloading Alpine Linux kernel..."

# Create directory for kernel
KERNEL_DIR="$WORK_DIR/kernel"
mkdir -p "$KERNEL_DIR"

# Try to download Alpine kernel from repository
ALPINE_KERNEL_URL="http://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64"
KERNEL_PACKAGE="linux-lts-6.6.23-r0.apk"

if curl -s -I "$ALPINE_KERNEL_URL/$KERNEL_PACKAGE" | head -1 | grep -q "200"; then
    log_info "Downloading kernel package..."
    wget -q "$ALPINE_KERNEL_URL/$KERNEL_PACKAGE" -O "$KERNEL_DIR/kernel.apk"
    
    # Extract kernel from APK
    tar -xzf "$KERNEL_DIR/kernel.apk" -C "$KERNEL_DIR" 2>/dev/null || true
    
    # Look for kernel files
    KERNEL_FOUND=false
    for kernel_path in "$KERNEL_DIR"/boot/*; do
        if [[ "$kernel_path" == *vmlinuz* ]]; then
            cp "$kernel_path" "$WORK_DIR/vmlinuz"
            KERNEL_FOUND=true
            log_success "Downloaded kernel: $(basename "$kernel_path")"
            break
        fi
    done
fi

# If download failed, use host kernel
if [ ! -f "$WORK_DIR/vmlinuz" ]; then
    log_warning "Could not download kernel, using host kernel..."
    
    # Try to find kernel on host system
    if [ -f "/boot/vmlinuz-lts" ]; then
        cp "/boot/vmlinuz-lts" "$WORK_DIR/vmlinuz"
        log_info "Using host kernel: vmlinuz-lts"
    elif [ -f "/boot/vmlinuz" ]; then
        cp "/boot/vmlinuz" "$WORK_DIR/vmlinuz"
        log_info "Using host kernel: vmlinuz"
    elif ls /boot/vmlinuz-* 2>/dev/null | head -1; then
        KERNEL_FILE=$(ls /boot/vmlinuz-* 2>/dev/null | head -1)
        cp "$KERNEL_FILE" "$WORK_DIR/vmlinuz"
        log_info "Using host kernel: $(basename "$KERNEL_FILE")"
    else
        # As last resort, extract kernel from installed linux-lts package
        log_info "Extracting kernel from installed package..."
        apk info -L linux-lts | grep -E '/boot/vmlinuz' | while read -r line; do
            if [ -f "$line" ]; then
                cp "$line" "$WORK_DIR/vmlinuz"
                log_info "Using kernel: $line"
                break
            fi
        done
    fi
fi

# Verify we have a kernel
if [ ! -f "$WORK_DIR/vmlinuz" ]; then
    log_error "No kernel found! Cannot continue."
    log_info "Tried:"
    log_info "1. Downloading from Alpine repository"
    log_info "2. Host kernel files"
    log_info "3. Installed linux-lts package"
    exit 1
fi

KERNEL_SIZE=$(ls -lh "$WORK_DIR/vmlinuz" | awk '{print $5}')
log_success "Kernel ready: $KERNEL_SIZE"

# ==================== Step 3: Create minimal root filesystem ====================
log_info "[3/7] Creating minimal root filesystem..."

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# Create basic directory structure
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr,var,sbin,lib/modules}
mkdir -p "$ROOTFS_DIR"/usr/{bin,sbin}
mkdir -p "$ROOTFS_DIR"/var/lib

# Create init script with proper kernel modules loading
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# Minimal init script with kernel modules support

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

# Load essential modules if available
if [ -d /lib/modules ]; then
    for module in loop squashfs; do
        modprobe $module 2>/dev/null || true
    done
fi

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
    # Use simple disk listing
    for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
        if [ -b "$disk" ]; then
            size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo "unknown")
            if [ "$size" != "unknown" ]; then
                size_gb=$((size / 1024 / 1024 / 1024))
                echo "  $disk - ${size_gb}GB"
            else
                echo "  $disk"
            fi
        fi
    done 2>/dev/null
    
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
    
    # Write image with progress indicator
    echo "Progress:"
    TOTAL_SIZE=$(stat -c%s /openwrt.img 2>/dev/null || echo 0)
    
    if command -v pv >/dev/null 2>&1 && [ "$TOTAL_SIZE" -gt 0 ]; then
        pv -s "$TOTAL_SIZE" /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
    else
        # Simple progress using dd status
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>&1 | tail -1
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
    for app in sh ls cat echo dd mount umount modprobe blockdev reboot sync; do
        ln -sf busybox $app 2>/dev/null || true
    done
    cd "$WORK_DIR"
fi

# Copy essential binaries
for tool in dd pv sync; do
    if command -v $tool >/dev/null 2>&1; then
        cp $(which $tool) "$ROOTFS_DIR/bin/" 2>/dev/null || true
    fi
done

# Create essential /etc files
cat > "$ROOTFS_DIR/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF

cat > "$ROOTFS_DIR/etc/group" << EOF
root:x:0:root
EOF

# Create minimal modules.dep for modprobe
mkdir -p "$ROOTFS_DIR/etc/modprobe.d"
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
log_info "Kernel copied to ISO: $(ls -lh "$ISO_DIR/boot/vmlinuz" | awk '{print $5}')"

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

# Create initramfs archive
cd "$INITRAMFS_DIR"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img" 2>/dev/null
cd "$WORK_DIR"

INITRD_SIZE=$(ls -lh "$ISO_DIR/boot/initrd.img" 2>/dev/null | awk '{print $5}' || echo "unknown")
log_info "Initramfs created: $INITRD_SIZE"

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
for file in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32 menu.c32 vesamenu.c32; do
    find /usr -name "$file" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$ISO_DIR/boot/syslinux/" 2>/dev/null || true
done

# Verify isolinux.bin exists
if [ ! -f "$ISO_DIR/boot/syslinux/isolinux.bin" ]; then
    log_warning "isolinux.bin not found, trying alternative locations..."
    # Try to download if missing
    if command -v wget >/dev/null 2>&1; then
        wget -q "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz" -O "$WORK_DIR/syslinux.tar.gz"
        tar -xzf "$WORK_DIR/syslinux.tar.gz" -C "$WORK_DIR" 2>/dev/null || true
        find "$WORK_DIR" -name "isolinux.bin" -type f | head -1 | xargs -I {} cp {} "$ISO_DIR/boot/syslinux/" 2>/dev/null || true
    fi
fi

if [ -f "$ISO_DIR/boot/syslinux/isolinux.bin" ]; then
    log_success "SYSLINUX boot files ready"
else
    log_error "SYSLINUX boot files missing, BIOS boot may not work"
fi

# ==================== Step 6: Create UEFI boot (GRUB) ====================
log_info "[6/7] Creating UEFI boot configuration..."

# Create GRUB configuration
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

insmod all_video
loadfont unicode

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

# Create GRUB EFI binary
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "Building GRUB EFI binary..."
    
    GRUB_TMP="$WORK_DIR/grub_tmp"
    mkdir -p "$GRUB_TMP/boot/grub"
    cp "$ISO_DIR/boot/grub/grub.cfg" "$GRUB_TMP/boot/grub/"
    
    # Build standalone GRUB
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="$GRUB_TMP/bootx64.efi" \
        --locales="en@quot" \
        --themes="" \
        --fonts="" \
        "boot/grub/grub.cfg=$GRUB_TMP/boot/grub/grub.cfg" 2>&1 | tee "$WORK_DIR/grub.log"; then
        
        log_success "GRUB EFI binary created"
        
        # Mount EFI image and copy files
        EFI_MOUNT="$WORK_DIR/efi_mount"
        mkdir -p "$EFI_MOUNT"
        
        if mount -o loop "$EFI_IMG" "$EFI_MOUNT" 2>/dev/null; then
            mkdir -p "$EFI_MOUNT/EFI/BOOT"
            cp "$GRUB_TMP/bootx64.efi" "$EFI_MOUNT/EFI/BOOT/"
            
            # Also create fallback bootx64.efi
            cp "$GRUB_TMP/bootx64.efi" "$EFI_MOUNT/EFI/BOOT/grubx64.efi"
            
            # Create basic grub.cfg in EFI partition
            cat > "$EFI_MOUNT/EFI/BOOT/grub.cfg" << 'EFI_GRUB_CFG'
search --file /openwrt.img --set=root
configfile /boot/grub/grub.cfg
EFI_GRUB_CFG
            
            umount "$EFI_MOUNT"
            
            # Copy EFI image to ISO
            cp "$EFI_IMG" "$ISO_DIR/EFI/BOOT/efiboot.img"
            log_success "UEFI boot image created"
        else
            # Use mcopy if mount fails
            log_warning "Mount failed, using mcopy..."
            mformat -i "$EFI_IMG" -F ::
            mmd -i "$EFI_IMG" ::/EFI
            mmd -i "$EFI_IMG" ::/EFI/BOOT
            mcopy -i "$EFI_IMG" "$GRUB_TMP/bootx64.efi" ::/EFI/BOOT/
            cp "$EFI_IMG" "$ISO_DIR/EFI/BOOT/efiboot.img"
            log_success "UEFI boot image created (via mcopy)"
        fi
    else
        log_warning "Failed to create GRUB EFI binary"
        log_info "GRUB build log:"
        cat "$WORK_DIR/grub.log"
    fi
else
    log_warning "grub-mkstandalone not available, UEFI boot may not work"
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

# Build ISO with xorriso
log_info "Building ISO with xorriso..."
if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -full-iso9660-filenames \
        -iso-level 3 \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
        -c boot/syslinux/boot.cat \
        -b boot/syslinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        $UEFI_OPTIONS \
        -o "$ISO_PATH" \
        "$ISO_DIR" 2>&1 | tee "$WORK_DIR/iso.log"
    
    ISO_EXIT=$?
    
    if [ $ISO_EXIT -eq 0 ] && [ -f "$ISO_PATH" ]; then
        ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
        log_success "ISO created successfully: $ISO_PATH ($ISO_SIZE)"
    else
        log_error "ISO creation failed with exit code $ISO_EXIT"
        log_info "ISO build log:"
        cat "$WORK_DIR/iso.log"
        
        # Try alternative method
        log_info "Trying alternative ISO creation method..."
        if command -v genisoimage >/dev/null 2>&1; then
            genisoimage -volid "OPENWRT_INSTALL" \
                -o "$ISO_PATH" \
                "$ISO_DIR" && \
            log_success "ISO created with genisoimage" || \
            log_error "genisoimage also failed"
        fi
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
        echo "  ✗ UEFI boot (missing efiboot.img)"
    fi
    echo ""
    
    echo "Installation Process:"
    echo "  1. Create bootable USB: sudo dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  2. Boot from USB (BIOS or UEFI)"
    echo "  3. Select 'Install OpenWRT'"
    echo "  4. Enter target disk (e.g., sda)"
    echo "  5. Type 'YES' to confirm"
    echo "  6. Wait for installation to complete"
    echo "  7. System will reboot automatically"
    echo ""
    
    # Create detailed build info
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Alpine Installer ISO - Build Report
===========================================
Build date:      $(date)
Build host:      $(uname -a)

Input Files:
  OpenWRT image: $(basename "$OPENWRT_IMG") ($IMG_SIZE)
  Kernel:        $(file "$ISO_DIR/boot/vmlinuz" 2>/dev/null | cut -d: -f2- | sed 's/^ //')
  Kernel size:   $KERNEL_SIZE
  Initramfs:     $INITRD_SIZE

Output:
  ISO file:      $ISO_NAME ($ISO_SIZE)
  MD5 checksum:  $(md5sum "$ISO_PATH" 2>/dev/null | awk '{print $1}' || echo "N/A")

Boot Configuration:
  BIOS boot:     $(if [ -f "$ISO_DIR/boot/syslinux/isolinux.bin" ]; then echo "Available"; else echo "Not available"; fi)
  UEFI boot:     $(if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then echo "Available"; else echo "Not available"; fi)
  Boot timeout:  30 seconds (BIOS), 5 seconds (UEFI)

Installation Notes:
  - The installer will display available disks
  - Enter the disk name (e.g., sda, nvme0n1)
  - Type 'YES' (uppercase) to confirm installation
  - Installation will erase all data on the target disk
  - Progress is shown during image writing
  - System reboots automatically after installation

Troubleshooting:
  - If no disks are shown, check if system has storage devices
  - If installation fails, try different disk or check image integrity
  - For emergency shell, select 'Emergency Shell' from boot menu

EOF
    
    log_success "Build completed successfully!"
    
else
    log_error "ISO file was not created"
    exit 1
fi

echo ""
log_info "Build process finished"
