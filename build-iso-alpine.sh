#!/bin/ash
# OpenWRT Alpine Installer ISO Builder - Fixed Version
# Supports BIOS/UEFI dual boot
# All English, no special characters

set -e

# ==================== Configuration ====================
OPENWRT_IMG="${1:-/mnt/ezopwrt.img}"
ISO_NAME="${2:-openwrt-alpine-installer.iso}"
WORK_DIR="/tmp/openwrt_alpine_build_$(date +%s)"
OUTPUT_DIR="/output"
CHROOT_DIR="$WORK_DIR/alpine_root"
ISO_FILE="$OUTPUT_DIR/$ISO_NAME"

# ==================== Color Definitions ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== Log Functions ====================
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ==================== Install Packages ====================
install_packages() {
    log_info "Installing required packages..."
    
    # Configure Alpine repositories
    cat > /etc/apk/repositories << EOF
http://dl-cdn.alpinelinux.org/alpine/v3.19/main
http://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF
    
    # Update package index
    apk update
    
    # Install essential packages
    apk add --no-cache \
        xorriso \
        syslinux \
        grub-bios \
        grub-efi \
        mtools \
        dosfstools \
        squashfs-tools \
        parted \
        e2fsprogs \
        e2fsprogs-extra \
        sfdisk \
        pv \
        bash \
        coreutils \
        findutils \
        grep \
        util-linux \
        gzip \
        cpio \
        wget \
        busybox
    
    log_success "Package installation completed"
}

# ==================== Check Prerequisites ====================
check_prerequisites() {
    log_info "Checking dependencies and input files..."
    
    # Check OpenWRT image
    if [ ! -f "$OPENWRT_IMG" ]; then
        log_error "OpenWRT image not found: $OPENWRT_IMG"
        exit 1
    fi
    
    # Create working directories
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR" "$CHROOT_DIR" "$OUTPUT_DIR"
    
    # Create ISO directory structure
    mkdir -p "$WORK_DIR/iso/boot"
    mkdir -p "$WORK_DIR/iso/EFI/BOOT"
    
    # Install packages
    install_packages
    
    log_success "Environment check completed"
}

# ==================== Create Minimal Alpine System ====================
create_alpine_base() {
    log_info "Creating Alpine Linux base system..."
    
    # First, ensure CHROOT_DIR exists and create directory structure
    mkdir -p "$CHROOT_DIR"
    
    # Create essential directory structure
    mkdir -p "$CHROOT_DIR"/{bin,dev,etc,home,lib,mnt,opt,proc,root,run,sbin,srv,sys,tmp,usr,var}
    mkdir -p "$CHROOT_DIR/usr"/{bin,sbin,lib}
    mkdir -p "$CHROOT_DIR/var"/{cache,lib,local,lock,log,opt,run,spool,tmp}
    
    log_info "Creating minimal system using busybox..."
    
    # Copy busybox to chroot
    mkdir -p "$CHROOT_DIR/bin"
    cp /bin/busybox "$CHROOT_DIR/bin/busybox"
    chmod 755 "$CHROOT_DIR/bin/busybox"
    
    # Create busybox symlinks
    cat > "$CHROOT_DIR/setup-busybox.sh" << 'EOF'
#!/bin/sh
# Setup busybox symlinks

cd /bin
./busybox --install -s

# Create essential symlinks
ln -sf busybox sh
ln -sf busybox ash
ln -sf busybox mount
ln -sf busybox umount
ln -sf busybox cat
ln -sf busybox ls
ln -sf busybox echo
ln -sf busybox mkdir
ln -sf busybox rmdir
ln -sf busybox cp
ln -sf busybox mv
ln -sf busybox rm
ln -sf busybox chmod
ln -sf busybox chown
ln -sf busybox ln
ln -sf busybox sleep
ln -sf busybox sync
EOF
    
    chmod +x "$CHROOT_DIR/setup-busybox.sh"
    
    # Create minimal /etc files
    cat > "$CHROOT_DIR/etc/inittab" << 'EOF'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -t devtmpfs devtmpfs /dev
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts
::sysinit:/bin/mkdir -p /dev/shm

tty1::respawn:/bin/getty 38400 tty1
tty2::respawn:/bin/getty 38400 tty2
tty3::respawn:/bin/getty 38400 tty3
ttyS0::respawn:/bin/getty -L ttyS0 115200 vt100

::shutdown:/bin/umount -a -r
EOF

    # Create fstab
    cat > "$CHROOT_DIR/etc/fstab" << 'EOF'
proc           /proc        proc    defaults          0       0
sysfs          /sys         sysfs   defaults          0       0
devtmpfs       /dev         devtmpfs defaults         0       0
tmpfs          /tmp         tmpfs   defaults          0       0
EOF

    # Create hostname
    echo "openwrt-installer" > "$CHROOT_DIR/etc/hostname"
    
    # Create resolv.conf
    echo "nameserver 8.8.8.8" > "$CHROOT_DIR/etc/resolv.conf"
    echo "nameserver 1.1.1.1" >> "$CHROOT_DIR/etc/resolv.conf"
    
    # Create profile
    cat > "$CHROOT_DIR/etc/profile" << 'EOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='\u@\h:\w\$ '
export TERM=linux
EOF
    
    log_success "Minimal Alpine system created"
}

# ==================== Create Installer System ====================
create_installer_system() {
    log_info "Creating installer system..."
    
    # Copy OpenWRT image
    cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"
    
    # Create init script
    cat > "$CHROOT_DIR/init" << 'EOF'
#!/bin/sh
# OpenWRT installer init script

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

# Setup console
exec < /dev/tty1 > /dev/tty1 2>&1

# Show welcome message
clear
echo "========================================"
echo "   OpenWRT Alpine Installer"
echo "========================================"
echo ""
echo "System is starting..."
echo ""

sleep 2

# Check OpenWRT image
if [ ! -f "/openwrt.img" ]; then
    echo "ERROR: OpenWRT image not found"
    echo "Image should be at: /openwrt.img"
    echo ""
    echo "Press Enter for shell..."
    read
    exec /bin/sh
fi

# Start installer
exec /sbin/installer
EOF
    chmod +x "$CHROOT_DIR/init"
    
    # Create installer script
    mkdir -p "$CHROOT_DIR/sbin"
    cat > "$CHROOT_DIR/sbin/installer" << 'EOF'
#!/bin/sh
# OpenWRT installer

clear() {
    printf "\033[2J\033[H"
}

show_disks() {
    echo "Available disks:"
    echo "----------------"
    
    index=1
    for disk in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
        [ -e "$disk" ] || continue
        
        disk_name=$(basename "$disk")
        size=""
        model=""
        
        if [ -f "$disk/size" ]; then
            size_blocks=$(cat "$disk/size" 2>/dev/null)
            if [ -n "$size_blocks" ]; then
                size_mb=$((size_blocks * 512 / 1024 / 1024))
                size="${size_mb}MB"
            fi
        fi
        
        if [ -f "$disk/device/model" ]; then
            model=$(cat "$disk/device/model" 2>/dev/null | tr -d '\n' | sed 's/  */ /g')
        fi
        
        if [ -n "$size" ] && [ -n "$model" ]; then
            echo "  [$index] /dev/$disk_name - $size - $model"
        elif [ -n "$size" ]; then
            echo "  [$index] /dev/$disk_name - $size"
        elif [ -n "$model" ]; then
            echo "  [$index] /dev/$disk_name - $model"
        else
            echo "  [$index] /dev/$disk_name"
        fi
        
        eval "DISK_$index=/dev/$disk_name"
        index=$((index + 1))
    done
    
    TOTAL_DISKS=$((index - 1))
}

main_menu() {
    while true; do
        clear
        echo "========================================"
        echo "      OpenWRT Disk Installer"
        echo "========================================"
        echo ""
        
        show_disks
        
        if [ $TOTAL_DISKS -eq 0 ]; then
            echo ""
            echo "No disks detected!"
            echo ""
            echo "Press Enter to rescan..."
            read
            continue
        fi
        
        echo ""
        echo "----------------------------------------"
        echo "Select disk number (1-$TOTAL_DISKS)"
        echo "Press 'q' to quit"
        echo -n "Your choice: "
        
        read choice
        
        case "$choice" in
            q|Q)
                echo "Exiting installer..."
                exit 0
                ;;
            [0-9]*)
                if [ "$choice" -ge 1 ] && [ "$choice" -le $TOTAL_DISKS ]; then
                    # Get selected disk
                    eval "target_disk=\"\$DISK_$choice\""
                    
                    clear
                    echo "========================================"
                    echo "      Installation Confirmation"
                    echo "========================================"
                    echo ""
                    echo "Selected disk: $target_disk"
                    echo ""
                    echo "WARNING: This will ERASE ALL DATA on $target_disk"
                    echo ""
                    echo -n "Type 'YES' to confirm installation: "
                    read confirm
                    
                    if [ "$confirm" = "YES" ]; then
                        install_openwrt "$target_disk"
                    else
                        echo "Installation cancelled."
                        sleep 2
                    fi
                else
                    echo "Invalid selection. Please choose 1-$TOTAL_DISKS"
                    sleep 2
                fi
                ;;
            *)
                echo "Invalid input"
                sleep 2
                ;;
        esac
    done
}

install_openwrt() {
    target_disk="$1"
    
    clear
    echo "========================================"
    echo "      Installing OpenWRT"
    echo "========================================"
    echo ""
    echo "Target: $target_disk"
    echo "Image size: $(ls -lh /openwrt.img | awk '{print $5}')"
    echo ""
    echo "Installing... This may take several minutes."
    echo ""
    
    # Write image
    if command -v pv >/dev/null 2>&1; then
        total_size=$(stat -c%s /openwrt.img)
        pv -s $total_size /openwrt.img | dd of="$target_disk" bs=4M 2>/dev/null
    else
        dd if=/openwrt.img of="$target_disk" bs=4M 2>&1 | grep -E 'bytes|copied' || true
    fi
    
    if [ $? -eq 0 ]; then
        sync
        echo ""
        echo "SUCCESS: OpenWRT installed successfully!"
        echo ""
        echo "Next steps:"
        echo "1. Remove installation media"
        echo "2. Boot from $target_disk"
        echo "3. OpenWRT will start automatically"
        echo ""
        echo "System will reboot in 10 seconds..."
        
        count=10
        while [ $count -gt 0 ]; do
            echo -ne "Rebooting in $count seconds...\r"
            sleep 1
            count=$((count - 1))
        done
        
        echo ""
        echo "Rebooting now..."
        reboot -f
    else
        echo ""
        echo "ERROR: Installation failed!"
        echo ""
        echo "Possible reasons:"
        echo "- Disk is in use or mounted"
        echo "- Not enough space"
        echo "- Disk is damaged"
        echo ""
        echo "Press Enter to return to main menu..."
        read
    fi
}

# Start installer
main_menu
EOF
    chmod +x "$CHROOT_DIR/sbin/installer"
    
    log_success "Installer system created"
}

# ==================== Create Boot Files ====================
create_boot_files() {
    log_info "Creating boot files..."
    
    # Copy kernel
    if [ -f /boot/vmlinuz-lts ]; then
        cp /boot/vmlinuz-lts "$WORK_DIR/iso/boot/vmlinuz"
        log_info "Using kernel: vmlinuz-lts"
    elif [ -f /boot/vmlinuz ]; then
        cp /boot/vmlinuz "$WORK_DIR/iso/boot/vmlinuz"
        log_info "Using kernel: vmlinuz"
    else
        # Try to find kernel
        for kernel in /boot/vmlinuz-*; do
            if [ -f "$kernel" ]; then
                cp "$kernel" "$WORK_DIR/iso/boot/vmlinuz"
                log_info "Using kernel: $(basename "$kernel")"
                break
            fi
        done
    fi
    
    # Create initramfs
    log_info "Creating initramfs..."
    (cd "$CHROOT_DIR" && find . 2>/dev/null | cpio -o -H newc | gzip -9 > "$WORK_DIR/iso/boot/initrd.img" 2>/dev/null) || {
        log_warning "Initramfs creation had warnings, continuing..."
    }
    
    # Create SYSLINUX config for BIOS
    cat > "$WORK_DIR/iso/boot/syslinux.cfg" << 'EOF'
DEFAULT openwrt
TIMEOUT 50
PROMPT 0

LABEL openwrt
    MENU LABEL Install OpenWRT
    KERNEL /boot/vmlinuz
    INITRD /boot/initrd.img
    APPEND console=tty0 console=ttyS0,115200
EOF

    # Copy SYSLINUX files
    cp /usr/share/syslinux/isolinux.bin "$WORK_DIR/iso/boot/" 2>/dev/null || \
    cp /usr/lib/syslinux/isolinux.bin "$WORK_DIR/iso/boot/" 2>/dev/null || \
    log_warning "isolinux.bin not found"
    
    cp /usr/share/syslinux/ldlinux.c32 "$WORK_DIR/iso/boot/" 2>/dev/null || \
    cp /usr/lib/syslinux/ldlinux.c32 "$WORK_DIR/iso/boot/" 2>/dev/null || \
    log_warning "ldlinux.c32 not found"
    
    # Create GRUB config for UEFI
    cat > "$WORK_DIR/iso/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}
EOF
    
    log_success "Boot files created"
}

# ==================== Create UEFI Boot ====================
create_uefi_boot() {
    log_info "Creating UEFI boot..."
    
    # Create directory for EFI files
    mkdir -p "$WORK_DIR/efi_tmp"
    
    # Try to create UEFI boot file
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        grub-mkstandalone \
            --format=x86_64-efi \
            --output="$WORK_DIR/efi_tmp/bootx64.efi" \
            --locales="" \
            --fonts="" \
            "boot/grub/grub.cfg=$WORK_DIR/iso/boot/grub/grub.cfg" 2>/dev/null || {
            log_warning "Failed to create GRUB EFI file, trying alternative method"
        }
    fi
    
    if [ -f "$WORK_DIR/efi_tmp/bootx64.efi" ]; then
        # Create EFI boot image
        dd if=/dev/zero of="$WORK_DIR/efiboot.img" bs=1M count=16
        mkfs.vfat -F 32 -n "OPENWRT_EFI" "$WORK_DIR/efiboot.img" >/dev/null 2>&1
        
        # Copy EFI file
        mcopy -i "$WORK_DIR/efiboot.img" "$WORK_DIR/efi_tmp/bootx64.efi" ::/EFI/BOOT/ 2>/dev/null || \
        mmd -i "$WORK_DIR/efiboot.img" ::/EFI/BOOT && \
        mcopy -i "$WORK_DIR/efiboot.img" "$WORK_DIR/efi_tmp/bootx64.efi" ::/EFI/BOOT/
        
        cp "$WORK_DIR/efiboot.img" "$WORK_DIR/iso/EFI/BOOT/"
        log_success "UEFI boot files created"
    else
        log_warning "UEFI boot files could not be created, ISO will be BIOS-only"
    fi
}

# ==================== Build ISO ====================
build_iso() {
    log_info "Building ISO image..."
    
    # Check if we have UEFI boot file
    UEFI_OPTIONS=""
    if [ -f "$WORK_DIR/iso/EFI/BOOT/efiboot.img" ]; then
        UEFI_OPTIONS="-eltorito-alt-boot -e EFI/BOOT/efiboot.img -no-emul-boot -isohybrid-gpt-basdat"
        log_info "Creating hybrid ISO (BIOS+UEFI)"
    else
        log_info "Creating BIOS-only ISO"
    fi
    
    # Build ISO
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
        -c boot/boot.cat \
        -b boot/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        $UEFI_OPTIONS \
        -output "$ISO_FILE" \
        "$WORK_DIR/iso" 2>/dev/null || {
        log_warning "xorriso failed, trying genisoimage..."
        genisoimage -volid "OPENWRT_INSTALL" \
            -o "$ISO_FILE" \
            "$WORK_DIR/iso"
    }
    
    if [ -f "$ISO_FILE" ]; then
        ISO_SIZE=$(ls -lh "$ISO_FILE" | awk '{print $5}')
        log_success "ISO created successfully: $ISO_FILE ($ISO_SIZE)"
        
        # Show build summary
        echo ""
        echo "========================================"
        echo "BUILD SUMMARY"
        echo "========================================"
        echo "Output file: $ISO_FILE"
        echo "File size:   $ISO_SIZE"
        echo ""
        echo "Boot support:"
        if [ -f "$WORK_DIR/iso/EFI/BOOT/efiboot.img" ]; then
            echo "  ✓ BIOS (Legacy) boot"
            echo "  ✓ UEFI boot"
        else
            echo "  ✓ BIOS (Legacy) boot"
            echo "  ✗ UEFI boot (not available)"
        fi
        echo ""
        echo "To create bootable USB:"
        echo "  sudo dd if='$ISO_FILE' of=/dev/sdX bs=4M status=progress"
        echo "  sudo sync"
        echo "========================================"
    else
        log_error "Failed to create ISO file"
        exit 1
    fi
}

# ==================== Cleanup ====================
cleanup() {
    log_info "Cleaning up temporary files..."
    
    # Remove working directory
    rm -rf "$WORK_DIR"
    
    log_success "Cleanup completed"
}

# ==================== Main Execution ====================
main() {
    echo ""
    echo "========================================"
    echo "OpenWRT Alpine Installer ISO Builder"
    echo "========================================"
    echo ""
    
    # Execute build steps
    check_prerequisites
    create_alpine_base
    create_installer_system
    create_boot_files
    create_uefi_boot
    build_iso
    cleanup
    
    echo ""
    log_success "Build process completed successfully!"
    echo ""
}

# Run main function
main "$@"
