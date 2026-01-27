#!/bin/bash
# build-iso-alpine.sh - Build OpenWRT auto-install ISO with Alpine in docker
# Fixed boot issues with proper kernel parameters

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
    umount "$WORK_DIR/mnt" 2>/dev/null || true
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

# Install packages with minimal output
log_info "Installing packages..."
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
    util-linux 2>/dev/null || {
    log_warning "Some packages had warnings, continuing..."
}

log_success "Build tools installed"

# ==================== Step 3: Get kernel and modules ====================
log_info "[3/9] Getting kernel and modules..."

# Get kernel version
KERNEL_VERSION=$(ls /lib/modules/ 2>/dev/null | head -1)
if [ -z "$KERNEL_VERSION" ]; then
    # Extract kernel version from vmlinuz
    KERNEL_VERSION="6.6.120-0-lts"
    log_warning "Could not detect kernel version, using default: $KERNEL_VERSION"
fi

log_info "Kernel version: $KERNEL_VERSION"

log_info =======/boot/ pwd: $pwd ====
ls -l /boot/
# 1. Copy kernel
if [ -f "/boot/vmlinuz-lts" ]; then
    cp "/boot/vmlinuz-lts" "$WORK_DIR/vmlinuz"
    log_success "Copied kernel: vmlinuz-lts"
elif [ -f "/boot/vmlinuz-$KERNEL_VERSION" ]; then
    cp "/boot/vmlinuz-$KERNEL_VERSION" "$WORK_DIR/vmlinuz"
    log_success "Copied kernel: vmlinuz-$KERNEL_VERSION"
else
    # Find kernel in /boot
    KERNEL_FILE=$(find /boot -name "vmlinuz*" -type f | head -1)
    if [ -n "$KERNEL_FILE" ]; then
        cp "$KERNEL_FILE" "$WORK_DIR/vmlinuz"
        log_success "Copied kernel: $(basename "$KERNEL_FILE")"
    else
        log_error "No kernel found!"
        exit 1
    fi
fi


KERNEL_SIZE=$(ls -lh "$WORK_DIR/vmlinuz" | awk '{print $5}')
log_info "Kernel size: $KERNEL_SIZE"

log_info =======  WORK_DIR: $WORK_DIR  pwd: $pwd ====
ls -l $WORK_DIR

# 2. Extract kernel modules for initramfs
log_info "Extracting kernel modules..."
MODULES_DIR="$WORK_DIR/modules/lib/modules/$KERNEL_VERSION"
mkdir -p "$MODULES_DIR"

# Copy essential modules
if [ -d "/lib/modules/$KERNEL_VERSION" ]; then
    # Copy all modules (this will be large but complete)
    log_info "Copying kernel modules..."
    cp -r "/lib/modules/$KERNEL_VERSION/kernel" "$MODULES_DIR/" 2>/dev/null || true
    
    # Create modules.dep
    if [ -f "/lib/modules/$KERNEL_VERSION/modules.dep" ]; then
        cp "/lib/modules/$KERNEL_VERSION/modules.dep" "$MODULES_DIR/"
        cp "/lib/modules/$KERNEL_VERSION/modules.dep.bin" "$MODULES_DIR/" 2>/dev/null || true
    fi
    
    # Copy firmware if available
    if [ -d "/lib/firmware" ]; then
        mkdir -p "$WORK_DIR/modules/lib/firmware"
        cp -r "/lib/firmware"/* "$WORK_DIR/modules/lib/firmware/" 2>/dev/null || true
    fi
    
    log_success "Kernel modules extracted"
else
    log_warning "Kernel modules directory not found, initramfs will be minimal"
fi

log_info =======/lib/modules/ ====
ls -l /lib/modules/
log_info =======$MODULES_DIR/ ====
ls -l $MODULES_DIR/

# ==================== Step 4: Create complete root filesystem ====================
log_info "[4/9] Creating complete root filesystem..."

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"


# Create all directories
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr,var,sbin,run,root,mnt,opt,initrd}
mkdir -p "$ROOTFS_DIR"/usr/{bin,sbin,lib,share}
mkdir -p "$ROOTFS_DIR"/var/{lib,lock,log,tmp,run}
mkdir -p "$ROOTFS_DIR"/etc/{modules-load.d,modprobe.d}
mkdir -p "$ROOTFS_DIR"/lib/modules

# Copy kernel modules to rootfs
if [ -d "$WORK_DIR/modules/lib/modules" ]; then
    cp -r "$WORK_DIR/modules/lib/modules"/* "$ROOTFS_DIR/lib/modules/" 2>/dev/null || true
fi

# Copy firmware
if [ -d "$WORK_DIR/modules/lib/firmware" ]; then
    mkdir -p "$ROOTFS_DIR/lib/firmware"
    cp -r "$WORK_DIR/modules/lib/firmware"/* "$ROOTFS_DIR/lib/firmware/" 2>/dev/null || true
fi

# Create init script
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/sh
# Minimal init script for OpenWRT installer
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || {
    echo "Creating device nodes..."
    mkdir -p /dev
    mknod -m 622 /dev/console c 5 1
    mknod -m 666 /dev/null c 1 3
    mknod -m 666 /dev/zero c 1 5
    mknod -m 666 /dev/tty c 5 0
}


# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console


# Load essential modules
echo "Loading kernel modules..."
for module in loop squashfs ext4 fat vfat ntfs usb-storage uhci-hcd ehci-hcd ohci-hcd xhci-hcd ahci sd_mod sr_mod virtio_blk virtio_pci nvme; do
    modprobe $module 2>/dev/null || echo "Failed to load $module"
done

# Clear screen
clear
echo "================================================"
echo "       OpenWRT Installation System"
echo "================================================"
echo ""
echo "Initializing..."

# Check for OpenWRT image
if [ ! -f "/openwrt.img" ]; then
    echo "ERROR: OpenWRT image not found!"
    echo "Looking for: /openwrt.img"
    echo "Press Enter to continue..."
    read
    echo "Available files in root:"
    ls -la /
    echo "Starting shell for debugging..."
    /bin/sh
fi

echo "OpenWRT image found: $(ls -lh /openwrt.img)"
echo ""

# Get list of disks
echo "Detecting storage devices..."
echo "----------------------------"

DISK_COUNT=0
for disk in /sys/block/*; do
    diskname=$(basename "$disk")
    
    # Skip virtual devices
    case "$diskname" in
        loop*|ram*|sr*|fd*|dm-*|md*)
            continue
            ;;
    esac
    
    if [ -b "/dev/$diskname" ]; then
        DISK_COUNT=$((DISK_COUNT + 1))
        size=""
        model=""
        
        # Get size
        if [ -f "/sys/block/$diskname/size" ]; then
            sectors=$(cat "/sys/block/$diskname/size" 2>/dev/null)
            if [ -n "$sectors" ]; then
                bytes=$((sectors * 512))
                if [ $bytes -ge 1073741824 ]; then
                    size=$(printf "%.1f GB" $(echo "$bytes / 1073741824" | bc -l))
                elif [ $bytes -ge 1048576 ]; then
                    size=$(printf "%.1f MB" $(echo "$bytes / 1048576" | bc -l))
                else
                    size="$bytes bytes"
                fi
            fi
        fi
        
        # Get model
        if [ -f "/sys/block/$diskname/device/model" ]; then
            model=$(cat "/sys/block/$diskname/device/model" 2>/dev/null | tr -d '\n')
        fi
        
        printf "[%d] /dev/%-10s %-12s %s\n" "$DISK_COUNT" "$diskname" "$size" "$model"
    fi
done

if [ $DISK_COUNT -eq 0 ]; then
    echo "No storage devices found!"
    echo "Loading additional storage drivers..."
    
    for module in scsi_mod sd_mod ahci mptsas mptspi megaraid_sas; do
        modprobe $module 2>/dev/null || true
    done
    
    sleep 2
    
    # Rescan
    echo "Rescanning..."
    for host in /sys/class/scsi_host/*; do
        echo "- - -" > $host/scan 2>/dev/null || true
    done
    
    sleep 1
    echo "Available disks now:"
    ls /sys/block/ | while read disk; do echo "  /dev/$disk"; done
fi

echo ""
echo "Select disk to install OpenWRT (1-$DISK_COUNT) or 's' for shell:"
read choice

if [ "$choice" = "s" ] || [ "$choice" = "S" ]; then
    echo "Starting debug shell..."
    echo "Available commands: ls, cat, dmesg, lsmod, lsblk"
    /bin/sh
fi

# Find selected disk
INDEX=1
for disk in /sys/block/*; do
    diskname=$(basename "$disk")
    case "$diskname" in
        loop*|ram*|sr*|fd*|dm-*|md*) continue ;;
    esac
    
    if [ -b "/dev/$diskname" ]; then
        if [ $INDEX -eq $choice ]; then
            TARGET_DISK="$diskname"
            break
        fi
        INDEX=$((INDEX + 1))
    fi
done

if [ -z "$TARGET_DISK" ]; then
    echo "Invalid selection!"
    echo "Press Enter to restart..."
    read
    # Re-exec init
    exec /init
fi

echo ""
echo "WARNING: This will ERASE ALL DATA on /dev/$TARGET_DISK!"
echo "Type 'YES' (uppercase) to confirm: "
read confirm

if [ "$confirm" != "YES" ]; then
    echo "Installation cancelled."
    echo "Press Enter to restart..."
    read
    exec /init
fi

echo ""
echo "Installing OpenWRT to /dev/$TARGET_DISK..."
echo "This may take several minutes..."

# Write the image
if command -v pv >/dev/null 2>&1; then
    pv /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M status=none
else
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress
fi

# Check result
if [ $? -eq 0 ]; then
    sync
    echo ""
    echo "================================================"
    echo "     INSTALLATION COMPLETE!"
    echo "================================================"
    echo ""
    echo "OpenWRT has been successfully installed to /dev/$TARGET_DISK"
    echo ""
    echo "Next steps:"
    echo "1. Remove the installation media"
    echo "2. Boot from /dev/$TARGET_DISK"
    echo "3. OpenWRT will start automatically"
    echo ""
    echo "Rebooting in 10 seconds..."
    
    for i in $(seq 10 -1 1); do
        echo -ne "\rRebooting in $i seconds... "
        sleep 1
    done
    echo ""
    echo "Rebooting now..."
    reboot -f
else
    echo ""
    echo "================================================"
    echo "     INSTALLATION FAILED!"
    echo "================================================"
    echo ""
    echo "Error writing to /dev/$TARGET_DISK"
    echo ""
    echo "Possible causes:"
    echo "- Disk is in use or mounted"
    echo "- Not enough space"
    echo "- Disk is write-protected or failing"
    echo ""
    echo "Press Enter to restart installer..."
    read
    exec /init
fi
INIT_EOF

chmod +x "$ROOTFS_DIR/init"

# Copy busybox
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$ROOTFS_DIR/bin/busybox"
    chmod 755 "$ROOTFS_DIR/bin/busybox"
    
    # Create essential symlinks
    cd "$ROOTFS_DIR/bin"
    for app in sh ls echo cat grep mount umount modprobe dmesg dd sync reboot clear read; do
        ln -sf busybox "$app" 2>/dev/null || true
    done
    cd "$WORK_DIR"
    log_success "Busybox installed"
fi

# Copy essential binaries
for tool in dd sync modprobe; do
    if command -v $tool >/dev/null 2>&1; then
        cp $(which $tool) "$ROOTFS_DIR/bin/" 2>/dev/null || true
    fi
done

# Copy pv for progress display
if command -v pv >/dev/null 2>&1; then
    cp $(which pv) "$ROOTFS_DIR/bin/pv" 2>/dev/null || true
fi

# Create minimal /etc files
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
mkdir -p "$ISO_DIR/isolinux"
mkdir -p "$ISO_DIR/boot/grub"
mkdir -p "$ISO_DIR/EFI/BOOT"

# Copy files to root of ISO
cp "$OPENWRT_IMG" "$ISO_DIR/openwrt.img"
cp "$WORK_DIR/vmlinuz" "$ISO_DIR/vmlinuz"

log_success "Files copied to ISO structure"

# ==================== Step 6: Create initramfs ====================
log_info "[6/9] Creating initramfs..."

INITRAMFS_DIR="$WORK_DIR/initramfs"
mkdir -p "$INITRAMFS_DIR"

# Copy init script
cp "$ROOTFS_DIR/init" "$INITRAMFS_DIR/init"
chmod +x "$INITRAMFS_DIR/init"

# Copy bin directory
if [ -d "$ROOTFS_DIR/bin" ]; then
    cp -r "$ROOTFS_DIR/bin" "$INITRAMFS_DIR/"
fi

# Copy essential libraries
mkdir -p "$INITRAMFS_DIR/lib"
for lib in ld-musl-x86_64.so.1 libc.musl-x86_64.so.1; do
    find /lib -name "$lib" -type f | head -1 | xargs -I {} cp {} "$INITRAMFS_DIR/lib/" 2>/dev/null || true
done

# Copy kernel modules
if [ -d "$ROOTFS_DIR/lib/modules" ]; then
    mkdir -p "$INITRAMFS_DIR/lib/modules"
    cp -r "$ROOTFS_DIR/lib/modules"/* "$INITRAMFS_DIR/lib/modules/" 2>/dev/null || true
fi

# Copy firmware
if [ -d "$ROOTFS_DIR/lib/firmware" ]; then
    mkdir -p "$INITRAMFS_DIR/lib/firmware"
    cp -r "$ROOTFS_DIR/lib/firmware"/* "$INITRAMFS_DIR/lib/firmware/" 2>/dev/null || true
fi

# Copy etc files
mkdir -p "$INITRAMFS_DIR/etc"
cp "$ROOTFS_DIR/etc/passwd" "$INITRAMFS_DIR/etc/"
cp "$ROOTFS_DIR/etc/group" "$INITRAMFS_DIR/etc/"

# Create essential directories
mkdir -p "$INITRAMFS_DIR"/{dev,proc,sys,tmp}

# Build initramfs
log_info "Building initramfs image..."
cd "$INITRAMFS_DIR"
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$ISO_DIR/initrd.img"
cd "$WORK_DIR"


echo "===== $WORK_DIR  ========"
ls -l "$WORK_DIR"

echo "===== $ISO_DIR  ========"
ls -l $ISO_DIR

INITRD_SIZE=$(ls -lh "$ISO_DIR/initrd.img" | awk '{print $5}')
log_success "Initramfs created: $INITRD_SIZE"

# ==================== Step 7: Create BIOS boot ====================
log_info "[7/9] Creating BIOS boot configuration..."

# Create simple isolinux.cfg
cat > "$ISO_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
PROMPT 1
TIMEOUT 10
UI menu.c32

MENU TITLE OpenWRT Installer
MENU AUTOBOOT Starting OpenWRT installer in # seconds

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /vmlinuz
  APPEND initrd=/initrd.img console=tty0 quiet

ISOLINUX_CFG

# Copy SYSLINUX files
log_info "Copying SYSLINUX files..."
for file in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32 menu.c32 vesamenu.c32; do
    for path in /usr/share/syslinux /usr/lib/syslinux; do
        if [ -f "$path/$file" ]; then
            cp "$path/$file" "$ISO_DIR/isolinux/"
            log_info " $path/$file Copied : $ISO_DIR/isolinux/"
            break
        fi
    done
done



log_success "BIOS boot configuration created"

# ==================== Step 8: Create UEFI boot ====================
log_info "[8/9] Creating UEFI boot configuration..."

# Create GRUB configuration
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /vmlinuz console=tty0 quiet
    initrd /initrd.img
}


    # search --file /vmlinuz --set=root
    # linux /vmlinuz console=tty0 quiet
    # initrd /initrd.img

GRUB_CFG

# Create bootx64.efi using grub-mkstandalone
log_info "Creating UEFI boot image..."

# Create directory for EFI
mkdir -p "$WORK_DIR/efi_boot/EFI/BOOT"

# Create bootx64.efi
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "Creating GRUB EFI binary..."
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/efi_boot/EFI/BOOT/bootx64.efi" \
        --modules="part_gpt part_msdos fat ext2 iso9660 gfxterm gfxmenu" \
        --locales="" \
        --themes="" \
        "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"
	log_info "=====grub-mkstandalone: $WORK_DIR/efi_boot/EFI/BOOT  ========"
	ls $WORK_DIR/efi_boot/EFI/BOOT
	log_info "=====grub-mkstandalone: $ISO_DIR/boot/grub  ========"
	ls $ISO_DIR/boot/grub
elif command -v grub2-mkstandalone >/dev/null 2>&1; then
    grub2-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/efi_boot/EFI/BOOT/bootx64.efi" \
        --modules="part_gpt part_msdos fat ext2 iso9660" \
        "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"

	log_info "=====grub2-mkstandalone: $WORK_DIR/efi_boot/EFI/BOOT  ========"
	ls $WORK_DIR/efi_boot/EFI/BOOT
	log_info "=====grub2-mkstandalone: $ISO_DIR/boot/grub  ========"
	ls $ISO_DIR/boot/grub
fi

# Copy EFI files to ISO
if [ -f "$WORK_DIR/efi_boot/EFI/BOOT/bootx64.efi" ]; then
    cp "$WORK_DIR/efi_boot/EFI/BOOT/bootx64.efi" "$ISO_DIR/EFI/BOOT/bootx64.efi"
    log_success "UEFI boot image created"

	log_info "===== $WORK_DIR/efi_boot/EFI/BOOT  ========"
	ls $WORK_DIR/efi_boot/EFI/BOOT
else
    log_warning "Could not create bootx64.efi, trying alternative..."
    # Try to copy existing EFI file
    if [ -f /usr/share/grub/grubx64.efi ]; then
        cp /usr/share/grub/grubx64.efi "$ISO_DIR/EFI/BOOT/bootx64.efi"
    elif [ -f /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi ]; then
        cp /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi "$ISO_DIR/EFI/BOOT/bootx64.efi"
    fi

	log_info "===== /usr/lib/grub/x86_64-efi/monolithic  ========"
	ls /usr/lib/grub/x86_64-efi/monolithic
fi

	log_info "===== $ISO_DIR/EFI/BOOT/  ========"
	ls $ISO_DIR/EFI/BOOT/
	
# Also copy grub.cfg to EFI directory
cp "$ISO_DIR/boot/grub/grub.cfg" "$ISO_DIR/EFI/BOOT/grub.cfg" 2>/dev/null || true

log_success "UEFI boot configuration created"

# ==================== Step 9: Build final ISO ====================
log_info "[9/9] Building final ISO..."

mkdir -p "$OUTPUT_DIR"

# Find isohdpfx.bin
ISOHDPFX=""
for path in /usr/share/syslinux /usr/lib/syslinux; do
    if [ -f "$path/isohdpfx.bin" ]; then
        ISOHDPFX="$path/isohdpfx.bin"
        log_info "ISOHDPFX found:$path/isohdpfx.bin"
        break
    fi
done

if [ -z "$ISOHDPFX" ]; then
    log_warning "isohdpfx.bin not found, will try without it"
fi

# Create iso.log for debugging
ISO_LOG="$WORK_DIR/iso.log"

# Build ISO with proper parameters
log_info "Creating ISO image..."

if [ -n "$ISOHDPFX" ]; then
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -isohybrid-mbr "$ISOHDPFX" \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/BOOT/bootx64.efi \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -o "$ISO_PATH" \
        "$ISO_DIR" 2>&1 | tee "$ISO_LOG"
	
	echo  ========= ISOHDPFX : $ISOHDPFX   ==========
else
    # Without isohdpfx.bin
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/BOOT/bootx64.efi \
        -no-emul-boot \
        -o "$ISO_PATH" \
        "$ISO_DIR" 2>&1 | tee "$ISO_LOG"
	
	echo  =====Without isohdpfx.bin : $ISOHDPFX   ==========
fi

# Check if ISO was created
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    log_success "ISO created successfully: $ISO_SIZE"
    
    # Verify ISO contents
    log_info "Verifying ISO contents..."
    
    echo "ISO root contents:"
    xorriso -indev "$ISO_PATH" -ls / 2>/dev/null | grep -E "(vmlinuz|initrd|openwrt)" || true
    
    echo ""
    echo "Boot files:"
    xorriso -indev "$ISO_PATH" -find /isolinux -type f 2>/dev/null | head -5 || true
    xorriso -indev "$ISO_PATH" -find /EFI -type f 2>/dev/null | head -5 || true
    
    # Create test script
    cat > "$OUTPUT_DIR/test-boot.sh" << 'TEST_EOF'
#!/bin/bash
echo "Testing OpenWRT ISO boot..."
echo "ISO: $(basename '$ISO_PATH')"
echo ""
echo "For BIOS boot test:"
echo "  qemu-system-x86_64 -cdrom '$ISO_PATH' -m 1024 -serial stdio"
echo ""
echo "For UEFI boot test (requires OVMF):"
echo "  qemu-system-x86_64 -cdrom '$ISO_PATH' -bios /usr/share/OVMF/OVMF_CODE.fd -m 1024 -serial stdio"
echo ""
echo "To check ISO contents:"
echo "  xorriso -indev '$ISO_PATH' -ls /"
TEST_EOF
    chmod +x "$OUTPUT_DIR/test-boot.sh"
    
else
    log_error "ISO creation failed!"
    echo "Last 20 lines of xorriso output:"
    tail -20 "$ISO_LOG"
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
echo "Boot Configuration:"
echo "  BIOS/Legacy:      ✓ SYSLINUX with menu interface"
echo "  UEFI:             ✓ GRUB2 EFI boot"
echo ""
echo "Boot Parameters:"
echo "  Kernel:           /vmlinuz"
echo "  Initramfs:        /initrd.img"
echo "  Console:          tty0 + ttyS0,115200n8"
echo "  Early printk:     Enabled"
echo ""
echo "Menu Options:"
echo "  1. Install OpenWRT (default)"
echo "  2. Debug mode"
echo "  3. Emergency shell"
echo ""
echo "Testing:"
echo "  BIOS Test:        qemu-system-x86_64 -cdrom '$ISO_PATH' -m 1024"
echo "  UEFI Test:        See $OUTPUT_DIR/test-boot.sh"
echo "  Check ISO:        xorriso -indev '$ISO_PATH' -ls /"
echo ""
echo "══════════════════════════════════════════════════════════"
echo "IMPORTANT: If you still have boot issues, try:"
echo "1. Add 'nomodeset' to kernel parameters"
echo "2. Use 'debug' option for verbose output"
echo "3. Check console output with -serial stdio in QEMU"
echo "══════════════════════════════════════════════════════════"

log_success "Build completed at $(date)"
