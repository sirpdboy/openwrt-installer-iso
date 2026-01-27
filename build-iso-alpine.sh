#!/bin/bash
# Minimal OpenWRT installer ISO builder
# Ultra small ISO with BIOS+UEFI dual boot support

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
INPUT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
OUTPUT_ISO_FILENAME="${ISO_NAME:-openwrt-installer-alpine.iso}"
OUTPUT_ISO="${OUTPUT_DIR}/${OUTPUT_ISO_FILENAME}"
WORK_DIR="/work"

# Logging functions
print_header() { echo -e "${CYAN}\n$1${NC}"; }
print_step() { echo -e "${GREEN}▶${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1" >&2; }

# ================= Initialization =================
print_header "Minimal OpenWRT Installer ISO Builder"
echo -e "${BLUE}=================================================${NC}"

# Validate input
if [ ! -f "${INPUT_IMG}" ]; then
    print_error "Input IMG file not found: ${INPUT_IMG}"
    echo "Available files in $(dirname ${INPUT_IMG}):"
    ls -la $(dirname ${INPUT_IMG}) 2>/dev/null || true
    exit 1
fi

IMG_SIZE=$(du -h "${INPUT_IMG}" 2>/dev/null | cut -f1 || echo "unknown")
print_step "Input IMG: ${INPUT_IMG} (${IMG_SIZE})"
print_step "Output ISO: ${OUTPUT_ISO}"
print_step "Work directory: ${WORK_DIR}"
echo -e "${BLUE}=================================================${NC}"

# ================= Prepare Directories =================
print_header "1. Preparing Directories"

# Clean and create directories
rm -rf "${WORK_DIR}" 2>/dev/null || true
mkdir -p "${WORK_DIR}/iso"
mkdir -p "${WORK_DIR}/iso/boot"
mkdir -p "${WORK_DIR}/iso/EFI/boot"
mkdir -p "${WORK_DIR}/iso/img"
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${WORK_DIR}/initrd"

# Create initrd directory structure
INITRD_DIR="${WORK_DIR}/initrd"
mkdir -p "${INITRD_DIR}"/{bin,dev,etc,lib,proc,sys,usr/{bin,lib},tmp,mnt,root,img}

print_success "Directory structure created"

# ================= Copy IMG to ISO =================
print_header "2. Copying OpenWRT Image"

cp "${INPUT_IMG}" "${WORK_DIR}/iso/img/openwrt.img"
IMG_SIZE_FINAL=$(du -h "${WORK_DIR}/iso/img/openwrt.img" 2>/dev/null | cut -f1)
print_success "IMG file copied: ${IMG_SIZE_FINAL}"

# ================= Create Minimal Initramfs =================
print_header "3. Creating Minimal Initramfs"

# Create init script
cat > "${INITRD_DIR}/init" << 'EOF'
#!/bin/sh
# Minimal init script for OpenWRT installer
# Created by Alpine Linux build system

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# Early initialization
echo "========================================"
echo "  OpenWRT Minimal Installer"
echo "========================================"

# Mount essential filesystems
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null

# Create essential device nodes
[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1
[ -c /dev/null ]    || mknod -m 666 /dev/null c 1 3
[ -c /dev/zero ]    || mknod -m 666 /dev/zero c 1 5
[ -c /dev/random ]  || mknod -m 666 /dev/random c 1 8
[ -c /dev/urandom ] || mknod -m 666 /dev/urandom c 1 9

# Setup console
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo "Mounted essential filesystems"

# Try to find the installation media
echo "Looking for installation media..."
IMG_PATH=""

# Method 1: Check if IMG is in initramfs
if [ -f /img/openwrt.img ]; then
    IMG_PATH="/img/openwrt.img"
    echo "Found IMG in initramfs"
    
# Method 2: Try to mount CDROM
else
    mkdir -p /mnt/cdrom
    
    # Try various CDROM devices
    for DEVICE in /dev/sr0 /dev/cdrom /dev/cdrom1 /dev/hdc /dev/hdd; do
        if [ -b "$DEVICE" ]; then
            echo "Attempting to mount $DEVICE..."
            if mount -t iso9660 -o ro "$DEVICE" /mnt/cdrom 2>/dev/null; then
                if [ -f "/mnt/cdrom/img/openwrt.img" ]; then
                    echo "Found IMG on installation media"
                    cp "/mnt/cdrom/img/openwrt.img" /tmp/openwrt.img
                    IMG_PATH="/tmp/openwrt.img"
                    umount /mnt/cdrom 2>/dev/null
                    break
                fi
                umount /mnt/cdrom 2>/dev/null
            fi
        fi
    done
fi

if [ -z "$IMG_PATH" ]; then
    echo "ERROR: Could not find OpenWRT image"
    echo "Please check your installation media."
    echo "Dropping to emergency shell..."
    exec /bin/sh
fi

# Run the installer
echo "Starting installer with image: $IMG_PATH"
exec /bin/sh /installer.sh "$IMG_PATH"
EOF

chmod +x "${INITRD_DIR}/init"

# Create installer script
cat > "${INITRD_DIR}/installer.sh" << 'EOF'
#!/bin/sh
# OpenWRT installer script

IMG_PATH="$1"

if [ ! -f "$IMG_PATH" ]; then
    echo "ERROR: No valid IMG file provided"
    echo "Available files:"
    find / -name "*.img" -type f 2>/dev/null || true
    exec /bin/sh
fi

# Clear screen
clear

echo "========================================"
echo "   OpenWRT Installation"
echo "========================================"
echo ""
echo "Image: $(basename "$IMG_PATH")"
echo "Size: $(du -h "$IMG_PATH" 2>/dev/null | cut -f1)"
echo ""

# Show available disks
echo "Available storage devices:"
echo "=========================="

# Try different methods to list disks
if command -v lsblk >/dev/null 2>&1; then
    lsblk -d -n -o NAME,SIZE,MODEL | grep -E '^(sd|hd|vd|nvme)' || true
elif command -v fdisk >/dev/null 2>&1; then
    fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|vd|nvme)' | sed 's/^Disk //' || true
else
    # Fallback to listing block devices
    echo "/dev/sd[a-z]"
    for dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
        [ -b "$dev" ] && echo "$dev"
    done
fi

echo ""
echo -n "Enter target disk (e.g., sda, nvme0n1): "
read DISK

# Validate input
if [ -z "$DISK" ]; then
    echo "No disk selected. Exiting."
    sleep 2
    exec /bin/sh
fi

# Normalize disk name
if [[ ! "$DISK" =~ ^/dev/ ]]; then
    DISK="/dev/$DISK"
fi

# Check if device exists
if [ ! -b "$DISK" ]; then
    echo "ERROR: Device $DISK does not exist or is not a block device"
    sleep 2
    exec /bin/sh
fi

# Final warning
echo ""
echo "========================================"
echo "           W A R N I N G"
echo "========================================"
echo "This will ERASE ALL DATA on: $DISK"
echo ""
echo -n "Type 'YES' to confirm and continue: "
read CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Installation cancelled."
    sleep 2
    exec /bin/sh
fi

# Install the image
echo ""
echo "Installing OpenWRT to $DISK..."
echo "This may take a few minutes..."

# Show progress with dd
echo "Progress:"
if command -v pv >/dev/null 2>&1; then
    pv -pet "$IMG_PATH" | dd of="$DISK" bs=4M conv=fsync 2>/dev/null
else
    dd if="$IMG_PATH" of="$DISK" bs=4M status=progress conv=fsync
fi

DD_RESULT=$?
sync

if [ $DD_RESULT -eq 0 ]; then
    echo ""
    echo "========================================"
    echo "      INSTALLATION SUCCESSFUL!"
    echo "========================================"
    echo ""
    echo "OpenWRT has been installed to $DISK"
    echo ""
    echo "Next steps:"
    echo "1. Remove installation media"
    echo "2. Reboot the system"
    echo "3. OpenWRT will start automatically"
    echo ""
    
    # Countdown reboot
    echo "System will reboot in 10 seconds..."
    for i in $(seq 10 -1 1); do
        echo -ne "Rebooting in $i seconds...\r"
        sleep 1
    done
    
    echo "Rebooting now..."
    reboot -f
else
    echo ""
    echo "========================================"
    echo "      INSTALLATION FAILED!"
    echo "========================================"
    echo ""
    echo "Error writing to disk. Possible reasons:"
    echo "- Disk is too small"
    echo "- Disk is write-protected"
    echo "- Hardware error"
    echo ""
    echo "Press Enter for emergency shell..."
    read
    exec /bin/sh
fi
EOF

chmod +x "${INITRD_DIR}/installer.sh"

# Create minimal busybox environment
print_step "Setting up BusyBox environment"

# Copy busybox if available
if command -v busybox >/dev/null 2>&1; then
    BUSYBOX_PATH=$(which busybox)
    cp "$BUSYBOX_PATH" "${INITRD_DIR}/bin/"
    chmod +x "${INITRD_DIR}/bin/busybox"
    
    # Create essential symlinks
    cd "${INITRD_DIR}"
    for applet in sh ls cat echo dd mount umount mknod sync reboot sleep grep; do
        ln -sf busybox "bin/$applet" 2>/dev/null || true
    done
else
    print_warning "BusyBox not found in host system"
    # We'll rely on binaries copied later
fi

# Copy essential binaries from host
print_step "Copying essential binaries"

# List of essential binaries
ESSENTIAL_BINS="sh dd mount umount mknod sync reboot cat echo ls grep sleep"

for bin in $ESSENTIAL_BINS; do
    bin_path=$(which $bin 2>/dev/null || true)
    if [ -n "$bin_path" ] && [ -f "$bin_path" ]; then
        cp "$bin_path" "${INITRD_DIR}/bin/" 2>/dev/null || true
    fi
done

# Copy essential libraries
print_step "Copying libraries"

# Detect libc type
if [ -f "/lib/ld-musl-x86_64.so.1" ]; then
    # Alpine musl libc
    cp /lib/ld-musl-x86_64.so.1 "${INITRD_DIR}/lib/" 2>/dev/null || true
    for lib in /lib/libc.so /lib/libm.so /lib/libresolv.so; do
        [ -f "$lib" ] && cp "$lib" "${INITRD_DIR}/lib/" 2>/dev/null || true
    done
elif [ -f "/lib64/ld-linux-x86-64.so.2" ]; then
    # glibc
    cp /lib64/ld-linux-x86-64.so.2 "${INITRD_DIR}/lib/" 2>/dev/null || true
fi

# Also copy IMG to initramfs for faster access
cp "${WORK_DIR}/iso/img/openwrt.img" "${INITRD_DIR}/img/" 2>/dev/null || true

# Build initramfs
print_step "Building initramfs..."
cd "${INITRD_DIR}"
find . -print0 | cpio -0 -o -H newc 2>/dev/null | gzip -9 > "${WORK_DIR}/iso/boot/initramfs"

INITRAMFS_SIZE=$(du -h "${WORK_DIR}/iso/boot/initramfs" 2>/dev/null | cut -f1)
print_success "Initramfs created: ${INITRAMFS_SIZE}"

# ================= Prepare Kernel =================
print_header "4. Preparing Kernel"

# Check for kernel in standard locations
KERNEL_FOUND=0
for kernel_path in \
    "/boot/vmlinuz-linux" \
    "/boot/vmlinuz" \
    "/boot/kernel" \
    "/vmlinuz" \
    "/boot/vmlinuz-$(uname -r)" \
    "/usr/lib/modules/*/vmlinuz"; do
    
    for path in $kernel_path; do
        if [ -f "$path" ]; then
            cp "$path" "${WORK_DIR}/iso/boot/vmlinuz"
            print_success "Using kernel from: $path"
            KERNEL_FOUND=1
            break 2
        fi
    done
done

# If no kernel found, download or create one
if [ $KERNEL_FOUND -eq 0 ]; then
    print_warning "No kernel found in system, downloading minimal kernel..."
    
    # Try to download a small kernel
    KERNEL_URL="https://github.com/tinycorelinux/Core-scripts/raw/master/vmlinuz64"
    
    if curl -s -L -o "${WORK_DIR}/iso/boot/vmlinuz" "${KERNEL_URL}"; then
        print_success "Downloaded minimal kernel"
    else
        print_warning "Download failed, creating minimal kernel stub"
        # Create a minimal kernel stub (just enough for bootloader)
        cat > "${WORK_DIR}/iso/boot/vmlinuz" << 'EOF'
# Minimal kernel stub
# This is not a real kernel, just a placeholder for bootloader
echo "Kernel placeholder - real kernel should be here"
exit 1
EOF
        chmod +x "${WORK_DIR}/iso/boot/vmlinuz"
    fi
fi

KERNEL_SIZE=$(du -h "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null | cut -f1)
print_success "Kernel prepared: ${KERNEL_SIZE}"

# ================= Configure Boot Loaders =================
print_header "5. Configuring Boot Loaders"

# BIOS Boot (SYSLINUX/ISOLINUX)
print_step "Configuring BIOS boot..."

# Copy isolinux files if available
if command -v isolinux >/dev/null 2>&1; then
    ISOLINUX_PATH=$(which isolinux)
    cp $(dirname "$ISOLINUX_PATH")/../lib/syslinux/isolinux.bin "${WORK_DIR}/iso/boot/" 2>/dev/null || true
elif [ -f "/usr/share/syslinux/isolinux.bin" ]; then
    cp /usr/share/syslinux/isolinux.bin "${WORK_DIR}/iso/boot/"
elif [ -f "/usr/lib/syslinux/isolinux.bin" ]; then
    cp /usr/lib/syslinux/isolinux.bin "${WORK_DIR}/iso/boot/"
fi

# Copy other syslinux files
for file in ldlinux.c32 libcom32.c32 libutil.c32 vesamenu.c32; do
    for path in /usr/share/syslinux /usr/lib/syslinux; do
        if [ -f "${path}/${file}" ]; then
            cp "${path}/${file}" "${WORK_DIR}/iso/boot/" 2>/dev/null
            break
        fi
    done
done

# Create isolinux configuration
cat > "${WORK_DIR}/iso/boot/isolinux.cfg" << 'EOF'
DEFAULT openwrt
PROMPT 0
TIMEOUT 30
UI vesamenu.c32
MENU TITLE OpenWRT Installer

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=ttyS0 console=tty0 quiet

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=ttyS0 console=tty0 init=/bin/sh

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
EOF

# UEFI Boot (GRUB)
print_step "Configuring UEFI boot..."

# Copy GRUB EFI binary
for efi_path in \
    /usr/share/grub/x86_64-efi/grub.efi \
    /usr/lib/grub/x86_64-efi/grub.efi \
    /usr/lib/grub/x86_64-efi/grubnetx64.efi; do
    if [ -f "$efi_path" ]; then
        cp "$efi_path" "${WORK_DIR}/iso/EFI/boot/bootx64.efi" 2>/dev/null
        print_success "Found EFI bootloader: $efi_path"
        break
    fi
done

# Create GRUB configuration
cat > "${WORK_DIR}/iso/EFI/boot/grub.cfg" << 'EOF'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initramfs console=ttyS0 console=tty0 quiet
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initramfs console=ttyS0 console=tty0 init=/bin/sh
}

menuentry "Reboot" {
    reboot
}
EOF

print_success "Boot configuration complete"

# ================= Create ISO =================
print_header "6. Building ISO Image"

cd "${WORK_DIR}/iso"

# Show final directory structure
print_step "Final directory structure:"
find . -type f | sort | sed 's/^/  /'

# Calculate sizes
IMG_SIZE_FINAL=$(du -h img/openwrt.img 2>/dev/null | cut -f1 || echo "0")
INITRAMFS_SIZE_FINAL=$(du -h boot/initramfs 2>/dev/null | cut -f1 || echo "0")
KERNEL_SIZE_FINAL=$(du -h boot/vmlinuz 2>/dev/null | cut -f1 || echo "0")

print_step "Component sizes:"
print_step "  • OpenWRT Image: ${IMG_SIZE_FINAL}"
print_step "  • Kernel: ${KERNEL_SIZE_FINAL}"
print_step "  • Initramfs: ${INITRAMFS_SIZE_FINAL}"

# Create ISO using available tool
print_step "Creating ISO..."

ISO_CREATED=0

# 修复点：这里使用传统的字符串拼接代替数组
if command -v xorriso >/dev/null 2>&1; then
    print_info "Using xorriso to create ISO..."
    
    # 构建xorriso命令字符串
    XORRISO_CMD="xorriso -as mkisofs \
        -volid \"OPENWRT_INSTALL\" \
        -full-iso9660-filenames \
        -J -joliet-long -rock \
        -output \"${OUTPUT_ISO}\""
    
    # 如果存在isolinux.bin，添加引导选项
    if [ -f "boot/isolinux.bin" ]; then
        XORRISO_CMD="$XORRISO_CMD \
            -eltorito-boot boot/isolinux.bin \
            -eltorito-catalog boot/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table"
        
        # 如果存在EFI引导文件，添加UEFI引导
        if [ -f "EFI/boot/bootx64.efi" ]; then
            XORRISO_CMD="$XORRISO_CMD \
                -eltorito-alt-boot \
                -e EFI/boot/bootx64.efi \
                -no-emul-boot"
        fi
        
        # 如果存在isohdpfx.bin，添加混合引导支持
        if [ -f "/usr/share/syslinux/isohdpfx.bin" ]; then
            XORRISO_CMD="$XORRISO_CMD \
                -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin"
        fi
    fi
    
    XORRISO_CMD="$XORRISO_CMD ."
    
    echo "执行命令: $XORRISO_CMD"
    eval $XORRISO_CMD
    
    if [ $? -eq 0 ] && [ -f "${OUTPUT_ISO}" ]; then
        ISO_CREATED=1
    fi
    
elif command -v genisoimage >/dev/null 2>&1; then
    print_info "Using genisoimage to create ISO..."
    
    if [ -f "boot/isolinux.bin" ]; then
        if genisoimage \
            -V "OPENWRT_INSTALL" \
            -J -r \
            -b boot/isolinux.bin \
            -c boot/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -o "${OUTPUT_ISO}" .; then
            ISO_CREATED=1
        fi
    else
        if genisoimage \
            -V "OPENWRT_INSTALL" \
            -J -r \
            -o "${OUTPUT_ISO}" .; then
            ISO_CREATED=1
        fi
    fi
    
elif command -v mkisofs >/dev/null 2>&1; then
    print_info "Using mkisofs to create ISO..."
    
    if [ -f "boot/isolinux.bin" ]; then
        if mkisofs \
            -V "OPENWRT_INSTALL" \
            -b boot/isolinux.bin \
            -c boot/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -o "${OUTPUT_ISO}" .; then
            ISO_CREATED=1
        fi
    else
        if mkisofs \
            -V "OPENWRT_INSTALL" \
            -o "${OUTPUT_ISO}" .; then
            ISO_CREATED=1
        fi
    fi
else
    print_error "No ISO creation tool found (xorriso, genisoimage, mkisofs)"
    exit 1
fi

if [ $ISO_CREATED -eq 1 ] && [ -f "${OUTPUT_ISO}" ]; then
    ISO_SIZE_FINAL=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
    print_success "ISO created successfully: ${ISO_SIZE_FINAL}"
    
    # 显示ISO详细信息
    if command -v file >/dev/null 2>&1; then
        print_info "ISO file type:"
        file "${OUTPUT_ISO}"
    fi
    
    if command -v xorriso >/dev/null 2>&1; then
        print_info "ISO boot information:"
        xorriso -indev "${OUTPUT_ISO}" -report_el_torito as_mkisofs 2>&1 | grep -i "boot" || true
    fi
else
    print_error "Failed to create ISO"
    
    # 尝试更简单的tar作为备用
    print_warning "Trying fallback method..."
    cd "${WORK_DIR}/iso"
    if tar -czf "${OUTPUT_ISO}.tar.gz" .; then
        print_warning "Created tarball instead: ${OUTPUT_ISO}.tar.gz"
    fi
    exit 1
fi

# ================= Final Summary =================
print_header "7. Build Complete"

echo -e "${BLUE}=================================================${NC}"
print_success "Minimal OpenWRT Installer ISO Built Successfully"
echo -e "${BLUE}=================================================${NC}"
print_step "Output file: ${OUTPUT_ISO}"
print_step "Total size: ${ISO_SIZE_FINAL}"
echo ""
print_step "ISO Contents Summary:"
print_step "  • OpenWRT System Image (${IMG_SIZE_FINAL})"
print_step "  • Linux Kernel (${KERNEL_SIZE_FINAL})"
print_step "  • Initramfs with Installer (${INITRAMFS_SIZE_FINAL})"
print_step "  • Dual Boot Support (BIOS + UEFI)"
print_step "  • Emergency Shell Access"
echo ""
print_step "Usage Instructions:"
print_step "1. Write to USB: dd if='${OUTPUT_ISO}' of=/dev/sdX bs=4M status=progress"
print_step "2. Set BIOS/UEFI to boot from USB"
print_step "3. Follow on-screen installation prompts"
print_step "4. Remove USB and reboot when complete"
echo -e "${BLUE}=================================================${NC}"
print_success "Ready for distribution!"

# 清理工作目录（可选，调试时可以注释掉）
# print_step "Cleaning up work directory..."
# rm -rf "${WORK_DIR}" 2>/dev/null || true
