#!/bin/ash
# OpenWRT Alpine Installer ISO Builder
# Supports BIOS/UEFI dual boot
# Based on Alpine Linux

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

# ==================== Check Prerequisites ====================
check_prerequisites() {
    log_info "Checking dependencies and input files..."
    
    # Check OpenWRT image
    if [ ! -f "$OPENWRT_IMG" ]; then
        log_error "OpenWRT image not found: $OPENWRT_IMG"
        exit 1
    fi
    
    # Install required tools
    apk add --no-cache alpine-sdk xorriso syslinux grub grub-efi mtools dosfstools \
        squashfs-tools parted e2fsprogs pv dialog coreutils findutils grep
    
    # Create working directories
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR" "$CHROOT_DIR" "$OUTPUT_DIR"
    mkdir -p "$WORK_DIR/iso/boot/grub"
    mkdir -p "$WORK_DIR/iso/EFI/BOOT"
    
    log_success "Environment check completed"
}

# ==================== Create Alpine Base System ====================
create_alpine_base() {
    log_info "Creating Alpine Linux base system..."
    
    # Set Alpine repositories
    cat > /etc/apk/repositories << EOF
http://dl-cdn.alpinelinux.org/alpine/v3.19/main
http://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF
    
    # Create minimal system using apk
    apk --root "$CHROOT_DIR" --initdb add alpine-base busybox \
        syslinux grub-bios grub-efi dosfstools mtools parted \
        e2fsprogs sfdisk bash dialog pv
    
    # Create basic directory structure
    mkdir -p "$CHROOT_DIR"/{dev,proc,sys,tmp,run,var}
    mount -t proc proc "$CHROOT_DIR/proc"
    mount -t sysfs sysfs "$CHROOT_DIR/sys"
    mount -o bind /dev "$CHROOT_DIR/dev"
    
    # Configure system
    cat > "$CHROOT_DIR/etc/inittab" << 'INITTAB'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Set up a couple of getty's
tty1::respawn:/sbin/getty 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
tty4::respawn:/sbin/getty 38400 tty4
tty5::respawn:/sbin/getty 38400 tty5
tty6::respawn:/sbin/getty 38400 tty6

# Put a getty on the serial port
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100

# Stuff to do before rebooting
::shutdown:/sbin/openrc shutdown
INITTAB

    # Configure network
    cat > "$CHROOT_DIR/etc/network/interfaces" << 'NETWORK'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NETWORK

    # Configure DNS
    echo "nameserver 8.8.8.8" > "$CHROOT_DIR/etc/resolv.conf"
    echo "nameserver 1.1.1.1" >> "$CHROOT_DIR/etc/resolv.conf"
    
    log_success "Alpine base system created"
}

# ==================== Create Installer System ====================
create_installer_system() {
    log_info "Creating installer system..."
    
    # Copy OpenWRT image
    cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"
    
    # Create init script
    cat > "$CHROOT_DIR/sbin/init" << 'INIT_SCRIPT'
#!/bin/ash
# Alpine init script for OpenWRT installer

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

# Setup console
echo "Setting up console..."
exec < /dev/tty1 > /dev/tty1 2>&1
chvt 1

# Show welcome message
clear
echo "========================================================"
echo "    OpenWRT Alpine Installer System"
echo "    Supports BIOS and UEFI dual boot"
echo "========================================================"
echo ""
echo "System starting up, please wait..."
echo ""

sleep 2

# Check OpenWRT image
if [ ! -f "/openwrt.img" ]; then
    clear
    echo ""
    echo "ERROR: OpenWRT image not found"
    echo ""
    echo "Image file should be at: /openwrt.img"
    echo ""
    echo "Press Enter to enter shell..."
    read
    exec /bin/ash
fi

# Start installer
exec /sbin/openwrt-installer
INIT_SCRIPT
    chmod +x "$CHROOT_DIR/sbin/init"
    
    # Create OpenWRT installer script
    cat > "$CHROOT_DIR/sbin/openwrt-installer" << 'INSTALLER_SCRIPT'
#!/bin/ash
# OpenWRT installer main script

# Clear screen
clear

# Show header
show_header() {
    clear
    echo "========================================================"
    echo "            OpenWRT Alpine Installer"
    echo "========================================================"
    echo ""
}

# Get disk list
get_disks() {
    show_header
    echo "Scanning available disks..."
    echo ""
    
    local index=1
    for disk in /sys/block/*; do
        local disk_name=$(basename "$disk")
        
        # Exclude virtual devices
        case "$disk_name" in
            loop*|ram*|fd*|sr*)
                continue
                ;;
        esac
        
        # Get disk info
        if [ -f "$disk/device/model" ]; then
            local model=$(cat "$disk/device/model" 2>/dev/null | tr -d '\n')
        else
            local model="Unknown"
        fi
        
        local size=$(cat "$disk/size" 2>/dev/null)
        if [ -n "$size" ]; then
            size=$((size * 512 / 1024 / 1024 / 1024))
            size="${size}GB"
        else
            size="Unknown"
        fi
        
        echo "  [$index] /dev/$disk_name - $size - $model"
        eval "DISK_$index=\"/dev/$disk_name\""
        index=$((index + 1))
    done
    
    TOTAL_DISKS=$((index - 1))
}

# Install OpenWRT
install_openwrt() {
    local target_disk="$1"
    
    show_header
    echo "Target disk: $target_disk"
    echo "Image size: $(ls -lh /openwrt.img | awk '{print $5}')"
    echo ""
    echo "WARNING: This will ERASE ALL DATA on $target_disk!"
    echo ""
    echo "Please confirm:"
    echo "1. You have backed up important data"
    echo "2. The target disk is correct"
    echo ""
    
    echo -n "Type 'YES' to continue: "
    read confirm
    
    if [ "$confirm" != "YES" ]; then
        echo "Installation cancelled"
        sleep 2
        return 1
    fi
    
    # Start installation
    clear
    show_header
    echo "Installing OpenWRT to $target_disk ..."
    echo "This may take several minutes. Please wait..."
    echo ""
    
    # Write image using dd
    if command -v pv >/dev/null 2>&1; then
        # Use pv for progress
        total_size=$(stat -c%s /openwrt.img)
        pv -s $total_size /openwrt.img | dd of="$target_disk" bs=4M 2>/dev/null
    else
        # Simple progress display
        echo "Writing image..."
        dd if=/openwrt.img of="$target_disk" bs=4M status=progress 2>&1
    fi
    
    # Check result
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
        
        # Countdown reboot
        echo "System will reboot in 10 seconds..."
        for i in $(seq 10 -1 1); do
            echo -ne "Rebooting in ${i} seconds...\r"
            sleep 1
        done
        
        echo -e "\nRebooting now..."
        reboot -f
    else
        echo ""
        echo "ERROR: Installation failed!"
        echo ""
        echo "Possible reasons:"
        echo "1. Disk may be mounted or in use"
        echo "2. Not enough disk space"
        echo "3. Disk is damaged"
        echo ""
        echo "Press Enter to return..."
        read
    fi
}

# Main loop
main_menu() {
    while true; do
        get_disks
        
        if [ $TOTAL_DISKS -eq 0 ]; then
            echo ""
            echo "ERROR: No disks detected!"
            echo ""
            echo "Press Enter to rescan..."
            read
            continue
        fi
        
        echo ""
        echo "--------------------------------------------------------"
        echo "Select target disk (1-$TOTAL_DISKS):"
        echo -n "Enter disk number or 'q' to quit: "
        read choice
        
        case "$choice" in
            [Qq])
                echo "Exiting installer"
                exec /bin/ash
                ;;
            [0-9]*)
                if [ "$choice" -ge 1 ] && [ "$choice" -le "$TOTAL_DISKS" ]; then
                    eval "target_disk=\"\$DISK_$choice\""
                    install_openwrt "$target_disk"
                else
                    echo "Invalid selection"
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

# Start main menu
main_menu
INSTALLER_SCRIPT
    chmod +x "$CHROOT_DIR/sbin/openwrt-installer"
    
    # Create fstab
    cat > "$CHROOT_DIR/etc/fstab" << 'FSTAB'
tmpfs           /tmp            tmpfs   defaults        0       0
tmpfs           /var/log        tmpfs   defaults        0       0
tmpfs           /var/tmp        tmpfs   defaults        0       0
FSTAB
    
    # Cleanup unnecessary files
    rm -rf "$CHROOT_DIR/var/cache/apk/*"
    
    log_success "Installer system created"
}

# ==================== Create Boot Configuration ====================
create_boot_config() {
    log_info "Creating boot configuration..."
    
    # 1. Copy kernel
    cp "$CHROOT_DIR/boot/vmlinuz-lts" "$WORK_DIR/iso/boot/vmlinuz"
    
    # Create simple init script
    cat > "$CHROOT_DIR/init" << 'MINI_INIT'
#!/bin/sh
# Minimal init for OpenWRT installer

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Run installer
exec /sbin/openwrt-installer
MINI_INIT
    chmod +x "$CHROOT_DIR/init"
    
    # Create simple initramfs
    (cd "$CHROOT_DIR" && find . | cpio -o -H newc | gzip -9 > "$WORK_DIR/iso/boot/initrd.img") 2>/dev/null
    
    # 2. Create SYSLINUX config (BIOS boot)
    cat > "$WORK_DIR/iso/boot/syslinux.cfg" << 'SYSLINUX_CFG'
DEFAULT openwrt
TIMEOUT 50
PROMPT 0

LABEL openwrt
    MENU LABEL Install OpenWRT (BIOS)
    KERNEL /boot/vmlinuz
    INITRD /boot/initrd.img
    APPEND console=tty0 console=ttyS0,115200
SYSLINUX_CFG

    # Copy SYSLINUX files
    cp /usr/share/syslinux/isolinux.bin "$WORK_DIR/iso/boot/"
    cp /usr/share/syslinux/ldlinux.c32 "$WORK_DIR/iso/boot/"
    cp /usr/share/syslinux/libutil.c32 "$WORK_DIR/iso/boot/"
    cp /usr/share/syslinux/menu.c32 "$WORK_DIR/iso/boot/"
    
    # 3. Create GRUB config (UEFI boot)
    cat > "$WORK_DIR/iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (UEFI)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}
GRUB_CFG

    log_success "Boot configuration created"
}

# ==================== Create UEFI Boot Files ====================
create_uefi_boot() {
    log_info "Creating UEFI boot files..."
    
    # Create EFI directory structure
    mkdir -p "$WORK_DIR/efi/EFI/BOOT"
    
    # Create UEFI boot file using grub-mkimage
    grub-mkimage \
        -o "$WORK_DIR/efi/EFI/BOOT/bootx64.efi" \
        -p /boot/grub \
        -O x86_64-efi \
        boot linux search normal configfile part_gpt part_msdos fat ext2 iso9660
    
    # Copy GRUB modules
    mkdir -p "$WORK_DIR/efi/boot/grub/x86_64-efi"
    cp -r /usr/lib/grub/x86_64-efi/* "$WORK_DIR/efi/boot/grub/x86_64-efi/" 2>/dev/null || true
    
    # Copy grub.cfg to EFI partition
    cp "$WORK_DIR/iso/boot/grub/grub.cfg" "$WORK_DIR/efi/boot/grub/"
    
    # Create EFI boot image
    dd if=/dev/zero of="$WORK_DIR/efiboot.img" bs=1M count=32
    mkfs.vfat -F 32 "$WORK_DIR/efiboot.img"
    
    # Mount and copy files
    mount_point="$WORK_DIR/efi_mount"
    mkdir -p "$mount_point"
    
    # Try to mount
    mount -o loop "$WORK_DIR/efiboot.img" "$mount_point" 2>/dev/null || {
        # If mount fails, use mcopy
        mcopy -i "$WORK_DIR/efiboot.img" -s "$WORK_DIR/efi/EFI" ::
        mcopy -i "$WORK_DIR/efiboot.img" -s "$WORK_DIR/efi/boot" ::
    } && {
        # If mount successful, copy directly
        cp -r "$WORK_DIR/efi/EFI" "$mount_point/"
        cp -r "$WORK_DIR/efi/boot" "$mount_point/"
        umount "$mount_point"
    }
    
    # Cleanup mount point
    rm -rf "$mount_point"
    
    # Copy to ISO directory
    cp "$WORK_DIR/efiboot.img" "$WORK_DIR/iso/EFI/BOOT/"
    
    log_success "UEFI boot files created"
}

# ==================== Build ISO Image ====================
build_iso() {
    log_info "Building ISO image..."
    
    # Create ISO
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
        -c boot/boot.cat \
        -b boot/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/BOOT/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output "$ISO_FILE" \
        "$WORK_DIR/iso"
    
    # Check if ISO was created successfully
    if [ -f "$ISO_FILE" ]; then
        ISO_SIZE=$(ls -lh "$ISO_FILE" | awk '{print $5}')
        log_success "SUCCESS: ISO created: $ISO_FILE ($ISO_SIZE)"
        
        # Show build information
        echo ""
        echo "========================================================"
        echo "OpenWRT Alpine Installer ISO Build Complete"
        echo "========================================================"
        echo ""
        echo "Output file: $ISO_FILE"
        echo "File size: $ISO_SIZE"
        echo ""
        echo "Boot support:"
        echo "  - BIOS (Legacy) boot"
        echo "  - UEFI boot"
        echo ""
        echo "Usage:"
        echo "  1. Create bootable USB:"
        echo "     dd if=\"$ISO_FILE\" of=/dev/sdX bs=4M status=progress"
        echo "  2. Boot from USB"
        echo "  3. Select Install OpenWRT"
        echo "  4. Choose target disk"
        echo "  5. Wait for installation to complete"
        echo ""
        echo "WARNING: Installation will erase all data on target disk!"
        echo "========================================================"
    else
        log_error "ISO creation failed"
        exit 1
    fi
}

# ==================== Cleanup ====================
cleanup() {
    log_info "Cleaning up temporary files..."
    
    # Unmount chroot directories
    umount "$CHROOT_DIR/proc" 2>/dev/null || true
    umount "$CHROOT_DIR/sys" 2>/dev/null || true
    umount "$CHROOT_DIR/dev" 2>/dev/null || true
    
    # Remove working directory
    rm -rf "$WORK_DIR"
    
    log_success "Cleanup completed"
}

# ==================== Main Execution Flow ====================
main() {
    echo ""
    echo "========================================================"
    echo "    OpenWRT Alpine Installer ISO Builder"
    echo "    Supports BIOS and UEFI dual boot"
    echo "========================================================"
    echo ""
    
    # Execute all steps
    check_prerequisites
    create_alpine_base
    create_installer_system
    create_boot_config
    create_uefi_boot
    build_iso
    cleanup
    
    echo ""
    log_success "ALL build tasks completed successfully!"
    echo ""
}

# Execute main function
main "$@"
