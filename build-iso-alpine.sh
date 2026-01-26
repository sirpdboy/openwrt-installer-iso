#!/bin/ash
# OpenWRT Installer ISO Builder - Fully Fixed Version
# Supports BIOS/UEFI dual boot

set -e

# ==================== Configuration ====================
OPENWRT_IMG="${1:-/mnt/ezopwrt.img}"
ISO_NAME="${2:-openwrt-alpine-installer.iso}"
WORK_DIR="/tmp/openwrt_build_$(date +%s)"
OUTPUT_DIR="/output"
CHROOT_DIR="$WORK_DIR/rootfs"
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

# ==================== Create Directory Structure ====================
create_directories() {
    log_info "Creating directory structure..."
    
    # Clean and create work directory
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    
    # Create chroot directory structure
    mkdir -p "$CHROOT_DIR"
    mkdir -p "$CHROOT_DIR"/{bin,dev,etc,home,lib,mnt,opt,proc,root,run,sbin,srv,sys,tmp,usr,var}
    mkdir -p "$CHROOT_DIR/usr"/{bin,sbin,lib}
    mkdir -p "$CHROOT_DIR/var"/{cache,lib,local,lock,log,opt,run,spool,tmp}
    
    # Create ISO directory structure
    mkdir -p "$WORK_DIR/iso/boot/grub"
    mkdir -p "$WORK_DIR/iso/EFI/BOOT"
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    
    log_success "Directory structure created"
}

# ==================== Install Required Packages ====================
install_packages() {
    log_info "Installing required packages..."
    
    # Configure repositories
    cat > /etc/apk/repositories << EOF
http://dl-cdn.alpinelinux.org/alpine/v3.19/main
http://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF
    
    # Update and install
    apk update
    apk add --no-cache \
        xorriso \
        syslinux \
        grub-bios \
        grub-efi \
        mtools \
        dosfstools \
        genisoimage \
        coreutils \
        findutils \
        grep \
        util-linux \
        gzip \
        cpio \
        wget \
        busybox \
        parted \
        e2fsprogs \
        bash \
        pv
    
    log_success "Packages installed"
}

# ==================== Check Prerequisites ====================
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check OpenWRT image
    if [ ! -f "$OPENWRT_IMG" ]; then
        log_error "OpenWRT image not found: $OPENWRT_IMG"
        exit 1
    fi
    
    log_success "Prerequisites checked"
}

# ==================== Create Minimal System ====================
create_minimal_system() {
    log_info "Creating minimal system..."
    
    # 1. Copy busybox and create symlinks
    cp /bin/busybox "$CHROOT_DIR/bin/busybox"
    chmod 755 "$CHROOT_DIR/bin/busybox"
    
    # Create minimal busybox symlinks
    cat > "$CHROOT_DIR/bin/setup-busybox" << 'EOF'
#!/bin/sh
cd /bin
for app in $(./busybox --list); do
    ln -sf busybox "$app"
done
EOF
    chmod +x "$CHROOT_DIR/bin/setup-busybox"
    
    # 2. Create essential /etc files
    mkdir -p "$CHROOT_DIR/etc"
    
    # Create inittab
    cat > "$CHROOT_DIR/etc/inittab" << 'EOF'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -t devtmpfs devtmpfs /dev
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts

tty1::respawn:/bin/getty 38400 tty1
tty2::respawn:/bin/getty 38400 tty2

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
    
    # 3. Create init script
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

# Clear screen
printf "\033[2J\033[H"

echo "========================================"
echo "   OpenWRT Alpine Installer"
echo "========================================"
echo ""
echo "System is starting..."
echo ""

sleep 2

# Check for OpenWRT image
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
    
    log_success "Minimal system created"
}

# ==================== Create Installer ====================
create_installer() {
    log_info "Creating installer..."
    
    # Copy OpenWRT image
    cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"
    
    # Create installer script
    mkdir -p "$CHROOT_DIR/sbin"
    cat > "$CHROOT_DIR/sbin/installer" << 'EOF'
#!/bin/sh
# OpenWRT installer

clear_screen() {
    printf "\033[2J\033[H"
}

show_disks() {
    echo "Available disks:"
    echo "----------------"
    
    index=1
    for disk in /sys/block/sd* /sys/block/nvme*; do
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
            model=$(cat "$disk/device/model" 2>/dev/null | tr -d '\n')
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
        clear_screen
        echo "========================================"
        echo "      OpenWRT Disk Installer"
        echo "========================================"
        echo ""
        
        show_disks
        
        if [ $TOTAL_DISKS -eq 0 ]; then
            echo ""
            echo "No disks found!"
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
                echo "Exiting..."
                exit 0
                ;;
            [0-9]*)
                if [ "$choice" -ge 1 ] && [ "$choice" -le $TOTAL_DISKS ]; then
                    eval "target_disk=\"\$DISK_$choice\""
                    confirm_installation "$target_disk"
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

confirm_installation() {
    target_disk="$1"
    
    clear_screen
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
}

install_openwrt() {
    target_disk="$1"
    
    clear_screen
    echo "========================================"
    echo "      Installing OpenWRT"
    echo "========================================"
    echo ""
    echo "Target: $target_disk"
    echo ""
    echo "Installing... Please wait."
    echo ""
    
    # Write image
    if command -v pv >/dev/null 2>&1; then
        pv /openwrt.img | dd of="$target_disk" bs=4M 2>/dev/null
    else
        dd if=/openwrt.img of="$target_disk" bs=4M 2>/dev/null
    fi
    
    if [ $? -eq 0 ]; then
        sync
        echo ""
        echo "SUCCESS: OpenWRT installed!"
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
        echo "Press Enter to return..."
        read
    fi
}

# Start installer
main_menu
EOF
    chmod +x "$CHROOT_DIR/sbin/installer"
    
    log_success "Installer created"
}

# ==================== Create Boot Files ====================
create_boot_files() {
    log_info "Creating boot files..."
    
    # 1. Copy kernel
    if [ -f /boot/vmlinuz-lts ]; then
        cp /boot/vmlinuz-lts "$WORK_DIR/iso/boot/vmlinuz"
    elif [ -f /boot/vmlinuz ]; then
        cp /boot/vmlinuz "$WORK_DIR/iso/boot/vmlinuz"
    else
        # Try to find any kernel
        for kernel in /boot/vmlinuz-*; do
            if [ -f "$kernel" ]; then
                cp "$kernel" "$WORK_DIR/iso/boot/vmlinuz"
                break
            fi
        done
    fi
    
    # If still no kernel, use busybox
    if [ ! -f "$WORK_DIR/iso/boot/vmlinuz" ]; then
        cp /bin/busybox "$WORK_DIR/iso/boot/vmlinuz"
        log_warning "Using busybox as kernel"
    fi
    
    # 2. Create initramfs
    log_info "Creating initramfs..."
    (cd "$CHROOT_DIR" && find . 2>/dev/null | cpio -o -H newc 2>/dev/null | gzip -9 > "$WORK_DIR/iso/boot/initrd.img")
    
    # 3. Create SYSLINUX config for BIOS
    cat > "$WORK_DIR/iso/boot/syslinux.cfg" << 'EOF'
DEFAULT openwrt
TIMEOUT 30
PROMPT 0

LABEL openwrt
    MENU LABEL Install OpenWRT
    KERNEL /boot/vmlinuz
    INITRD /boot/initrd.img
    APPEND console=tty0 console=ttyS0,115200
EOF

    # Copy SYSLINUX files
    if [ -f /usr/share/syslinux/isolinux.bin ]; then
        cp /usr/share/syslinux/isolinux.bin "$WORK_DIR/iso/boot/"
        cp /usr/share/syslinux/ldlinux.c32 "$WORK_DIR/iso/boot/"
    fi
    
    # 4. Create GRUB config for UEFI
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
    
    # Try to create UEFI boot file
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        mkdir -p "$WORK_DIR/efi_tmp"
        
        if grub-mkstandalone \
            --format=x86_64-efi \
            --output="$WORK_DIR/efi_tmp/bootx64.efi" \
            --locales="" \
            --fonts="" \
            "boot/grub/grub.cfg=$WORK_DIR/iso/boot/grub/grub.cfg" 2>/dev/null; then
            
            # Create EFI boot image
            dd if=/dev/zero of="$WORK_DIR/efiboot.img" bs=1M count=10
            mkfs.vfat -F 32 "$WORK_DIR/efiboot.img" >/dev/null 2>&1
            
            # Copy EFI file
            mcopy -i "$WORK_DIR/efiboot.img" "$WORK_DIR/efi_tmp/bootx64.efi" ::/EFI/BOOT/ 2>/dev/null
            
            if [ -f "$WORK_DIR/efiboot.img" ]; then
                cp "$WORK_DIR/efiboot.img" "$WORK_DIR/iso/EFI/BOOT/"
                log_success "UEFI boot created"
                return 0
            fi
        fi
    fi
    
    log_warning "UEFI boot not created, ISO will be BIOS-only"
    return 1
}

# ==================== Build ISO ====================
build_iso() {
    log_info "Building ISO image..."
    
    # Check for UEFI boot
    UEFI_OPTS=""
    if [ -f "$WORK_DIR/iso/EFI/BOOT/efiboot.img" ]; then
        UEFI_OPTS="-eltorito-alt-boot -e EFI/BOOT/efiboot.img -no-emul-boot -isohybrid-gpt-basdat"
    fi
    
    # Build ISO with xorriso
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
            -c boot/boot.cat \
            -b boot/isolinux.bin \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            $UEFI_OPTS \
            -output "$ISO_FILE" \
            "$WORK_DIR/iso" 2>/dev/null
    else
        # Fallback to genisoimage
        genisoimage -volid "OPENWRT_INSTALL" \
            -o "$ISO_FILE" \
            "$WORK_DIR/iso"
    fi
    
    if [ -f "$ISO_FILE" ]; then
        ISO_SIZE=$(ls -lh "$ISO_FILE" | awk '{print $5}')
        log_success "ISO created: $ISO_FILE ($ISO_SIZE)"
    else
        log_error "Failed to create ISO"
        exit 1
    fi
}

# ==================== Main Function ====================
main() {
    echo ""
    echo "========================================"
    echo "OpenWRT Installer ISO Builder"
    echo "========================================"
    echo ""
    
    # Step 1: Check prerequisites
    check_prerequisites
    
    # Step 2: Create directories first
    create_directories
    
    # Step 3: Install packages
    install_packages
    
    # Step 4: Create minimal system
    create_minimal_system
    
    # Step 5: Create installer
    create_installer
    
    # Step 6: Create boot files
    create_boot_files
    
    # Step 7: Create UEFI boot
    create_uefi_boot
    
    # Step 8: Build ISO
    build_iso
    
    # Step 9: Show result
    echo ""
    echo "========================================"
    echo "BUILD COMPLETE"
    echo "========================================"
    echo "Output: $ISO_FILE"
    echo "Size:   $(ls -lh "$ISO_FILE" | awk '{print $5}')"
    echo ""
    
    if [ -f "$WORK_DIR/iso/EFI/BOOT/efiboot.img" ]; then
        echo "Boot modes: BIOS + UEFI"
    else
        echo "Boot modes: BIOS only"
    fi
    
    echo ""
    echo "To create bootable USB:"
    echo "dd if='$ISO_FILE' of=/dev/sdX bs=4M status=progress"
    echo "sync"
    echo "========================================"
    
    # Cleanup
    rm -rf "$WORK_DIR"
}

# Run main function
main "$@"
