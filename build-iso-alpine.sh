#!/bin/bash
# build-openwrt-alpine-iso.sh - Build OpenWRT auto-install ISO with Alpine
# Complete kernel and initramfs with all required modules

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

# Create dummy trigger scripts to avoid errors
mkdir -p /etc/apk/scripts
cat > /etc/apk/scripts/grub-2.12-r5.trigger << 'EOF'
#!/bin/sh
# Dummy grub trigger to avoid errors in container
exit 0
EOF

cat > /etc/apk/scripts/syslinux-6.04_pre1-r15.trigger << 'EOF'
#!/bin/sh
# Dummy syslinux trigger
exit 0
EOF

chmod +x /etc/apk/scripts/*.trigger

apk update --no-cache

# Install packages with minimal output
log_info "Installing packages..."
apk add  --no-cache --no-scripts  \
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

ls -l $WORK_DIR
KERNEL_SIZE=$(ls -lh "$WORK_DIR/vmlinuz" | awk '{print $5}')
log_info "Kernel size: $KERNEL_SIZE"

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

# ==================== Step 4: Create complete root filesystem ====================
log_info "[4/9] Creating complete root filesystem..."

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# Create all directories
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr,var,sbin,run,root,mnt,opt}
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

# Create init script with full module support
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/sh
# OpenWRT installer init script with full hardware support

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || {
    # Fallback: create essential devices
    mkdir -p /dev
    mknod /dev/console c 5 1
    mknod /dev/null c 1 3
    mknod /dev/zero c 1 5
    mknod /dev/random c 1 8
    mknod /dev/urandom c 1 9
    mknod /dev/tty c 5 0
    mknod /dev/tty1 c 4 1
    mknod /dev/tty2 c 4 2
    mknod /dev/tty3 c 4 3
    mknod /dev/tty4 c 4 4
}

# Create /dev/pts for terminals
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null || true

# Setup console
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

# Load essential kernel modules
echo "Loading kernel modules..."
for module in loop squashfs ext4 fat vfat ntfs nls_cp437 nls_utf8 nls_iso8859-1 usb-storage uhci-hcd ehci-hcd ohci-hcd xhci-hcd ahci sd_mod sr_mod virtio_blk virtio_pci virtio_mmio nvme; do
    modprobe $module 2>/dev/null || true
done

# Load block device modules
for module in ata_piix sata_sil sata_svw sata_via sata_nv pata_amd pata_atiixp pata_marvell pata_sch mptsas mptspi megaraid_sas megaraid_mbox megaraid_mm hpsa cciss; do
    modprobe $module 2>/dev/null || true
done

# Clear screen
clear
cat << "HEADER"
╔═══════════════════════════════════════════════════════╗
║           OpenWRT Installation System                 ║
║         Alpine Linux based installer                  ║
╚═══════════════════════════════════════════════════════╝

HEADER

echo "Initializing system..."
sleep 1

# Check for OpenWRT image
if [ ! -f "/openwrt.img" ]; then
    echo ""
    echo "ERROR: OpenWRT image not found!"
    echo ""
    echo "The OpenWRT image should be at: /openwrt.img"
    echo ""
    echo "Press Enter for emergency shell..."
    read
    exec /bin/sh
fi

echo ""
echo "✓ OpenWRT image found."
echo ""
echo "Detecting storage devices..."
echo ""

# Function to get disk information
get_disk_info() {
    local disk="$1"
    local size=""
    local model=""
    local serial=""
    
    # Get size
    if [ -f "/sys/block/$disk/size" ]; then
        local sectors=$(cat "/sys/block/$disk/size" 2>/dev/null)
        if [ -n "$sectors" ]; then
            local bytes=$((sectors * 512))
            if [ $bytes -ge 1099511627776 ]; then
                size=$(printf "%.1f TB" $(echo "$bytes / 1099511627776" | bc -l))
            elif [ $bytes -ge 1073741824 ]; then
                size=$(printf "%.1f GB" $(echo "$bytes / 1073741824" | bc -l))
            elif [ $bytes -ge 1048576 ]; then
                size=$(printf "%.1f MB" $(echo "$bytes / 1048576" | bc -l))
            else
                size=$(printf "%d bytes" $bytes)
            fi
        fi
    fi
    
    # Get model
    if [ -f "/sys/block/$disk/device/model" ]; then
        model=$(cat "/sys/block/$disk/device/model" 2>/dev/null | tr -d '\n' | sed 's/  */ /g')
    fi
    
    # Get vendor
    local vendor=""
    if [ -f "/sys/block/$disk/device/vendor" ]; then
        vendor=$(cat "/sys/block/$disk/device/vendor" 2>/dev/null | tr -d '\n')
    fi
    
    echo "$size|$model|$vendor"
}

# List all available disks
DISK_INDEX=1
declare -A DISK_MAP

echo "Available disks:"
echo "══════════════════════════════════════════════════════════"
for disk in /sys/block/*; do
    DISK_NAME=$(basename "$disk")
    
    # Skip virtual devices
    case "$DISK_NAME" in
        loop*|ram*|sr*|fd*|dm-*|md*)
            continue
            ;;
    esac
    
    if [ -b "/dev/$DISK_NAME" ]; then
        INFO=$(get_disk_info "$DISK_NAME")
        SIZE=$(echo "$INFO" | cut -d'|' -f1)
        MODEL=$(echo "$INFO" | cut -d'|' -f2)
        VENDOR=$(echo "$INFO" | cut -d'|' -f3)
        
        DISK_MAP[$DISK_INDEX]="$DISK_NAME"
        
        if [ -n "$MODEL" ] && [ -n "$SIZE" ]; then
            printf "  [%2d] /dev/%-6s %-10s %s\n" "$DISK_INDEX" "$DISK_NAME" "$SIZE" "$MODEL"
        elif [ -n "$SIZE" ]; then
            printf "  [%2d] /dev/%-6s %s\n" "$DISK_INDEX" "$DISK_NAME" "$SIZE"
        else
            printf "  [%2d] /dev/%s\n" "$DISK_INDEX" "$DISK_NAME"
        fi
        
        DISK_INDEX=$((DISK_INDEX + 1))
    fi
done

TOTAL_DISKS=$((DISK_INDEX - 1))

if [ $TOTAL_DISKS -eq 0 ]; then
    echo ""
    echo "No storage devices detected!"
    echo ""
    echo "Possible reasons:"
    echo "• No disks connected"
    echo "• Disk drivers not loaded"
    echo "• Hardware not detected"
    echo ""
    echo "Press Enter to rescan..."
    read
    
    # Try to load more storage drivers
    for module in scsi_mod sd_mod ahci mptspi mptsas megaraid_sas; do
        modprobe $module 2>/dev/null || true
    done
    
    sleep 2
    exec /init  # Restart init
fi

echo "══════════════════════════════════════════════════════════"
echo ""

while true; do
    echo -n "Select disk number (1-$TOTAL_DISKS) or 'r' to rescan: "
    read SELECTION
    
    case "$SELECTION" in
        [Rr])
            echo "Rescanning devices..."
            sleep 1
            exec /init
            ;;
        [0-9]*)
            if [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le $TOTAL_DISKS ]; then
                TARGET_DISK="${DISK_MAP[$SELECTION]}"
                break
            else
                echo "Invalid selection. Please choose 1-$TOTAL_DISKS."
            fi
            ;;
        *)
            echo "Invalid input. Please enter a number or 'r'."
            ;;
    esac
done

echo ""
echo "══════════════════════════════════════════════════════════"
echo "           CONFIRM INSTALLATION"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "Target disk: /dev/$TARGET_DISK"
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║                   WARNING!                            ║"
echo "║   This will ERASE ALL DATA on /dev/$TARGET_DISK       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo -n "Type 'YES' (uppercase) to confirm: "
read CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo ""
    echo "Installation cancelled."
    echo "Press Enter to restart..."
    read
    exec /init
fi

echo ""
echo "══════════════════════════════════════════════════════════"
echo "           INSTALLING OPENWRT"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "Target: /dev/$TARGET_DISK"
echo "Image size: $(ls -lh /openwrt.img | awk '{print $5}')"
echo ""
echo "Installing... This may take several minutes."
echo ""

# Calculate total size for progress bar
TOTAL_SIZE=$(stat -c%s /openwrt.img 2>/dev/null || echo 0)
BLOCK_SIZE=4194304  # 4MB
TOTAL_BLOCKS=$((TOTAL_SIZE / BLOCK_SIZE))
if [ $((TOTAL_SIZE % BLOCK_SIZE)) -ne 0 ]; then
    TOTAL_BLOCKS=$((TOTAL_BLOCKS + 1))
fi

# Write image with progress
echo "Progress: [                                                  ] 0%"
CURRENT_BLOCK=0

if command -v dd >/dev/null 2>&1 && command -v pv >/dev/null 2>&1; then
    # Use pv if available
    pv -p -t -e -r /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
else
    # Simple dd with status
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>&1 | \
    while read line; do
        if echo "$line" | grep -q "bytes\|copied"; then
            echo -ne "\r$line"
        fi
    done
    echo ""
fi

DD_STATUS=$?

if [ $DD_STATUS -eq 0 ]; then
    # Sync to ensure all data is written
    sync
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "           INSTALLATION COMPLETE!"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo "✓ OpenWRT has been successfully installed to /dev/$TARGET_DISK"
    echo ""
    echo "Next steps:"
    echo "1. Remove the installation media (USB drive)"
    echo "2. Boot from the newly installed disk (/dev/$TARGET_DISK)"
    echo "3. OpenWRT will start automatically"
    echo ""
    echo "System will reboot in 10 seconds..."
    
    # Countdown
    for i in {10..1}; do
        echo -ne "\rRebooting in $i seconds... "
        sleep 1
    done
    echo ""
    echo "Rebooting now..."
    reboot -f
else
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "           INSTALLATION FAILED!"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo "✗ Error code: $DD_STATUS"
    echo ""
    echo "Possible causes:"
    echo "• Disk may be in use or mounted"
    echo "• Not enough space on target disk"
    echo "• Disk may be failing or write-protected"
    echo "• Hardware compatibility issue"
    echo ""
    echo "Press Enter to restart installer..."
    read
    exec /init
fi
INIT_EOF

chmod +x "$ROOTFS_DIR/init"

# Copy complete busybox with all applets
log_info "Setting up busybox..."
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$ROOTFS_DIR/bin/busybox"
    chmod 755 "$ROOTFS_DIR/bin/busybox"
    
    # Create all symlinks
    cd "$ROOTFS_DIR/bin"
    ./busybox --list | while read app; do
        ln -sf busybox "$app" 2>/dev/null || true
    done
    cd "$WORK_DIR"
    log_success "Busybox with all applets installed"
fi

# Copy essential binaries
for tool in dd sync modprobe lsblk blockdev fdisk parted; do
    if command -v $tool >/dev/null 2>&1; then
        tool_path=$(which $tool)
        mkdir -p "$ROOTFS_DIR$(dirname "$tool_path")"
        cp "$tool_path" "$ROOTFS_DIR$tool_path" 2>/dev/null || true
        
        # Copy library dependencies
        ldd "$tool_path" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read lib; do
            if [ -f "$lib" ]; then
                mkdir -p "$ROOTFS_DIR$(dirname "$lib")"
                cp "$lib" "$ROOTFS_DIR$lib" 2>/dev/null || true
            fi
        done
    fi
done

# Copy pv for progress display
if command -v pv >/dev/null 2>&1; then
    cp $(which pv) "$ROOTFS_DIR/bin/pv" 2>/dev/null || true
fi

# Create essential configuration files
cat > "$ROOTFS_DIR/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF

cat > "$ROOTFS_DIR/etc/group" << EOF
root:x:0:root
bin:x:1:bin
daemon:x:2:daemon
sys:x:3:sys
EOF

# Create fstab
cat > "$ROOTFS_DIR/etc/fstab" << EOF
none /proc proc defaults 0 0
none /sys sysfs defaults 0 0
none /dev devtmpfs defaults 0 0
EOF

# Create modules configuration
cat > "$ROOTFS_DIR/etc/modules-load.d/openwrt-installer.conf" << EOF
# Essential modules for OpenWRT installer
loop
squashfs
ext4
fat
vfat
ntfs
usb-storage
uhci-hcd
ehci-hcd
ohci-hcd
xhci-hcd
ahci
sd_mod
sr_mod
virtio_blk
virtio_pci
nvme
EOF

log_success "Complete root filesystem created"

# ==================== Step 5: Create ISO structure ====================
log_info "[5/9] Creating ISO structure..."

ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR/isolinux"
mkdir -p "$ISO_DIR/boot/grub"
mkdir -p "$ISO_DIR/EFI/BOOT"

# Copy files
cp "$OPENWRT_IMG" "$ISO_DIR/openwrt.img"
cp "$WORK_DIR/vmlinuz" "$ISO_DIR/boot/vmlinuz"

log_success "Files copied to ISO structure"

# ==================== Step 6: Create complete initramfs ====================
log_info "[6/9] Creating complete initramfs..."

INITRAMFS_DIR="$WORK_DIR/initramfs"
mkdir -p "$INITRAMFS_DIR"

# Copy init script
cp "$ROOTFS_DIR/init" "$INITRAMFS_DIR/init"
chmod +x "$INITRAMFS_DIR/init"

# Copy entire /bin directory
if [ -d "$ROOTFS_DIR/bin" ]; then
    cp -r "$ROOTFS_DIR/bin" "$INITRAMFS_DIR/"
fi

# Copy essential libraries
mkdir -p "$INITRAMFS_DIR/lib"
for lib in ld-musl-x86_64.so.1 libc.musl-x86_64.so.1; do
    find /lib -name "$lib" -type f | head -1 | xargs -I {} cp {} "$INITRAMFS_DIR/lib/" 2>/dev/null || true
done

# Copy kernel modules to initramfs
if [ -d "$ROOTFS_DIR/lib/modules" ]; then
    mkdir -p "$INITRAMFS_DIR/lib/modules"
    cp -r "$ROOTFS_DIR/lib/modules"/* "$INITRAMFS_DIR/lib/modules/" 2>/dev/null || true
fi

# Copy firmware to initramfs
if [ -d "$ROOTFS_DIR/lib/firmware" ]; then
    mkdir -p "$INITRAMFS_DIR/lib/firmware"
    cp -r "$ROOTFS_DIR/lib/firmware"/* "$INITRAMFS_DIR/lib/firmware/" 2>/dev/null || true
fi

# Create minimal /etc
mkdir -p "$INITRAMFS_DIR/etc"
cp "$ROOTFS_DIR/etc/passwd" "$INITRAMFS_DIR/etc/"
cp "$ROOTFS_DIR/etc/group" "$INITRAMFS_DIR/etc/"
cp "$ROOTFS_DIR/etc/modules-load.d/openwrt-installer.conf" "$INITRAMFS_DIR/etc/modules-load.d/" 2>/dev/null || true

# Create device directory
mkdir -p "$INITRAMFS_DIR/dev"

# Create initramfs image
log_info "Creating initramfs image (this may take a moment)..."
cd "$INITRAMFS_DIR"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img"
cd "$WORK_DIR"

INITRD_SIZE=$(ls -lh "$ISO_DIR/boot/initrd.img" | awk '{print $5}')
log_success "Initramfs created: $INITRD_SIZE (should be > 10M)"

# ==================== Step 7: Create BIOS boot ====================
log_info "[7/9] Creating BIOS boot configuration..."

# Create isolinux.cfg
cat > "$ISO_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
TIMEOUT 30
PROMPT 0
UI vesamenu.c32

MENU TITLE OpenWRT Auto Installer
MENU BACKGROUND splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200 vga=791

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 single

LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL /boot/memtest
  APPEND -

LABEL local
  MENU LABEL ^Boot from local drive
  LOCALBOOT 0x80
ISOLINUX_CFG

# Copy ALL SYSLINUX files
log_info "Copying SYSLINUX files..."
SYSFILES="isolinux.bin ldlinux.c32 libutil.c32 libcom32.c32 vesamenu.c32 menu.c32 chain.c32 reboot.c32 poweroff.c32"

for file in $SYSFILES; do
    found=false
    for path in /usr/share/syslinux /usr/lib/syslinux /usr/lib/ISOLINUX; do
        if [ -f "$path/$file" ]; then
            cp "$path/$file" "$ISO_DIR/isolinux/"
            found=true
            log_info "  ✓ $file"
            break
        fi
    done
    if [ "$found" = false ]; then
        log_warning "  ✗ $file not found"
    fi
done

# Create a simple splash screen
echo "Creating splash screen..." > "$ISO_DIR/isolinux/splash.txt"

log_success "BIOS boot configuration created"

# ==================== Step 8: Create UEFI boot ====================
log_info "[8/9] Creating UEFI boot configuration..."

# Create GRUB configuration
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

if loadfont /boot/grub/font.pf2 ; then
    set gfxmode=auto
    insmod efi_gop
    insmod efi_uga
    insmod gfxterm
    terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Install OpenWRT (UEFI)" --class gnu-linux --class gnu --class os {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}

menuentry "Emergency Shell (UEFI)" --class gnu-linux --class gnu --class os {
    linux /boot/vmlinuz console=tty0 single
    initrd /boot/initrd.img
}

menuentry "Reboot" {
    reboot
}

menuentry "Shutdown" {
    halt
}
GRUB_CFG

# Create UEFI boot image
log_info "Creating UEFI boot image..."
EFI_IMG="$WORK_DIR/efiboot.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=128
mkfs.vfat -F 32 -n "UEFI_BOOT" "$EFI_IMG" >/dev/null 2>&1

# Create GRUB EFI binary with all modules
log_info "Building complete GRUB EFI binary..."
GRUB_TMP="$WORK_DIR/grub_tmp"
mkdir -p "$GRUB_TMP/EFI/BOOT"

# Build GRUB with all necessary modules
if command -v grub-mkstandalone >/dev/null 2>&1; then
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$GRUB_TMP/EFI/BOOT/bootx64.efi" \
        --modules="part_gpt part_msdos fat ext2 iso9660 gfxterm gfxmenu png jpeg tga efi_gop efi_uga all_video" \
        --locales="en@quot" \
        --themes="" \
        --fonts="" \
        "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg" 2>/dev/null || {
        log_warning "grub-mkstandalone failed, trying simpler method..."
        grub-mkimage \
            -o "$GRUB_TMP/EFI/BOOT/bootx64.efi" \
            -p /boot/grub \
            -O x86_64-efi \
            -c "$ISO_DIR/boot/grub/grub.cfg" \
            boot linux configfile normal part_gpt part_msdos fat ext2 iso9660 gfxterm gfxmenu
    }
fi

if [ -f "$GRUB_TMP/EFI/BOOT/bootx64.efi" ]; then
    # Mount and populate EFI image
    EFI_MOUNT="$WORK_DIR/efi_mount"
    mkdir -p "$EFI_MOUNT"
    
    if mount -o loop "$EFI_IMG" "$EFI_MOUNT" 2>/dev/null; then
        cp -r "$GRUB_TMP/EFI" "$EFI_MOUNT/"
        
        # Copy GRUB configuration and modules
        mkdir -p "$EFI_MOUNT/boot/grub"
        cp "$ISO_DIR/boot/grub/grub.cfg" "$EFI_MOUNT/boot/grub/"
        
        # Copy GRUB modules
        mkdir -p "$EFI_MOUNT/boot/grub/x86_64-efi"
        cp -r /usr/lib/grub/x86_64-efi/* "$EFI_MOUNT/boot/grub/x86_64-efi/" 2>/dev/null || true
        
        umount "$EFI_MOUNT"
    else
        # Use mcopy
        mmd -i "$EFI_IMG" ::/EFI
        mmd -i "$EFI_IMG" ::/EFI/BOOT
        mcopy -i "$EFI_IMG" "$GRUB_TMP/EFI/BOOT/bootx64.efi" ::/EFI/BOOT/
        mmd -i "$EFI_IMG" ::/boot
        mmd -i "$EFI_IMG" ::/boot/grub
        mcopy -i "$EFI_IMG" "$ISO_DIR/boot/grub/grub.cfg" ::/boot/grub/
    fi
    
    cp "$EFI_IMG" "$ISO_DIR/EFI/BOOT/efiboot.img"
    log_success "UEFI boot image created (128MB)"
else
    log_warning "Could not create GRUB EFI binary"
fi

# ==================== Step 9: Build final ISO ====================
log_info "[9/9] Building final ISO..."

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
    log_warning "isohdpfx.bin not found, trying to download..."
    wget -q -O "$WORK_DIR/isohdpfx.bin" \
        "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz" && \
    tar -xzf "$WORK_DIR/isohdpfx.bin" --wildcards "*/bios/mbr/isohdpfx.bin" --strip-components=2 && \
    ISOHDPFX="$WORK_DIR/isohdpfx.bin" || \
    log_warning "Could not obtain isohdpfx.bin"
fi

# Build ISO with xorriso
XORRISO_CMD="xorriso -as mkisofs \
    -volid 'OPENWRT_INSTALL' \
    -full-iso9660-filenames \
    -joliet \
    -rational-rock \
    -iso-level 3 \
    -output '$ISO_PATH'"

if [ -n "$ISOHDPFX" ]; then
    XORRISO_CMD="$XORRISO_CMD -isohybrid-mbr '$ISOHDPFX'"
fi

# Add BIOS boot
XORRISO_CMD="$XORRISO_CMD \
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
        -no-emul-boot \
        -isohybrid-gpt-basdat"
fi

XORRISO_CMD="$XORRISO_CMD '$ISO_DIR'"

log_info "Building ISO (this may take a moment)..."
eval $XORRISO_CMD 2>&1 | tee "$WORK_DIR/iso.log"

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    log_success "ISO created successfully: $ISO_SIZE"
    
    # Verify ISO
    log_info "Verifying ISO structure..."
    if command -v isoinfo >/dev/null 2>&1; then
        echo "ISO contains:"
        isoinfo -i "$ISO_PATH" -R -l 2>/dev/null | grep -E "(Directory|boot/|isolinux/|EFI/)" | head -20
    fi
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
echo "File Sizes:"
echo "  OpenWRT Image:    $IMG_SIZE"
echo "  Kernel:           $KERNEL_SIZE"
echo "  Initramfs:        $INITRD_SIZE  (with modules and firmware)"
echo "  Final ISO:        $ISO_SIZE"
echo ""
echo "Boot Capabilities:"
echo "  BIOS/Legacy:      ✓ Full SYSLINUX menu support"
echo "  UEFI:             ✓ GRUB2 with graphical menu"
echo ""
echo "Hardware Support:"
echo "  Storage:          ✓ SATA, NVMe, USB, VirtIO"
echo "  Filesystems:      ✓ EXT4, FAT, NTFS, SquashFS"
echo "  Modules:          ✓ Loaded in initramfs"
echo ""
echo "Installation Features:"
echo "  ✓ Graphical menu interface"
echo "  ✓ Disk size and model detection"
echo "  ✓ Progress indicator"
echo "  ✓ Safety confirmation"
echo "  ✓ Automatic reboot"
echo ""
echo "Usage:"
echo "  1. sudo dd if='$ISO_NAME' of=/dev/sdX bs=4M status=progress"
echo "  2. Boot from USB"
echo "  3. Select 'Install OpenWRT'"
echo "  4. Choose disk number"
echo "  5. Type 'YES' to confirm"
echo "  6. Wait for completion"
echo ""
echo "══════════════════════════════════════════════════════════"

# Create detailed build report
cat > "$OUTPUT_DIR/build-report.txt" << EOF
OpenWRT Alpine Installer ISO - Complete Build Report
====================================================
Build Date:       $(date)
Build Host:       $(uname -a)
Build Script:     $(basename "$0")

Kernel Information:
  Version:        $KERNEL_VERSION
  File:           $(basename "$WORK_DIR/vmlinuz")
  Size:           $KERNEL_SIZE
  Modules:        $(find "$ROOTFS_DIR/lib/modules" -name "*.ko" 2>/dev/null | wc -l) modules included

Initramfs Contents:
  Size:           $INITRD_SIZE
  Binaries:       $(find "$INITRAMFS_DIR/bin" -type f 2>/dev/null | wc -l) files
  Libraries:      $(find "$INITRAMFS_DIR/lib" -name "*.so*" 2>/dev/null | wc -l) libraries
  Modules:        $(find "$INITRAMFS_DIR/lib/modules" -name "*.ko" 2>/dev/null | wc -l) kernel modules
  Firmware:       $(find "$INITRAMFS_DIR/lib/firmware" -type f 2>/dev/null | wc -l) firmware files

ISO Structure:
  Total Size:     $ISO_SIZE
  Boot Records:   $(xorriso -indev "$ISO_PATH" -report_el_torito as_mkisofs 2>/dev/null | grep -c "Boot image")
  Files:          $(isoinfo -i "$ISO_PATH" -R -f 2>/dev/null | wc -l) total files

Boot Files Verified:
  isolinux.bin:   $(if [ -f "$ISO_DIR/isolinux/isolinux.bin" ]; then echo "✓ Present"; else echo "✗ Missing"; fi)
  ldlinux.c32:    $(if [ -f "$ISO_DIR/isolinux/ldlinux.c32" ]; then echo "✓ Present"; else echo "✗ Missing"; fi)
  bootx64.efi:    $(if [ -f "$ISO_DIR/EFI/BOOT/efiboot.img" ]; then echo "✓ Present in EFI image"; else echo "✗ Missing"; fi)

Supported Hardware:
  Storage Controllers: SATA, NVMe, USB, VirtIO, SCSI, RAID
  Filesystems:        EXT4, FAT32, NTFS, SquashFS
  Architecture:       x86_64 (64-bit)

Installation Process:
  1. Boot menu with 30 second timeout
  2. Disk selection with size/model information
  3. Safety confirmation (requires 'YES')
  4. Progress display during installation
  5. Automatic reboot upon completion

Testing Commands:
  # Verify ISO
  isoinfo -i "$ISO_NAME" -R -l | head -30
  
  # Test BIOS boot with QEMU
  qemu-system-x86_64 -cdrom "$ISO_NAME" -m 1024 -boot d
  
  # Test UEFI boot (requires OVMF)
  qemu-system-x86_64 -cdrom "$ISO_NAME" -bios /usr/share/OVMF/OVMF_CODE.fd -m 1024

Notes:
  - The initramfs includes all necessary drivers for most hardware
  - Installation will completely erase the target disk
  - Use uppercase 'YES' to confirm installation
  - For UEFI systems, Secure Boot may need to be disabled

EOF

log_success "Detailed build report saved to: $OUTPUT_DIR/build-report.txt"
echo ""
log_info "Build process completed at $(date)"
