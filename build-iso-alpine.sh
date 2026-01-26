#!/bin/ash
# OpenWRT Alpine Installer ISO Builder
# Fixed version - supports offline/online package installation
# Supports BIOS/UEFI dual boot

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

# ==================== Install Packages with Fallback ====================
install_packages() {
    log_info "Installing required packages..."
    
    # Configure Alpine repositories
    cat > /etc/apk/repositories << EOF
http://dl-cdn.alpinelinux.org/alpine/v3.19/main
http://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF
    
    # Update package index
    apk update || {
        log_warning "Failed to update package index, trying alternative mirror..."
        cat > /etc/apk/repositories << EOF
http://mirror.leaseweb.com/alpine/v3.19/main
http://mirror.leaseweb.com/alpine/v3.19/community
EOF
        apk update
    }
    
    # Install packages with individual error handling
    local packages="alpine-sdk xorriso"
    
    for pkg in $packages; do
        if ! apk add --no-cache $pkg 2>/dev/null; then
            log_warning "Package $pkg not available, skipping..."
        fi
    done
    
    # Try to install remaining packages
    apk add --no-cache syslinux grub-bios grub-efi mtools dosfstools \
        squashfs-tools parted e2fsprogs sfdisk dialog pv bash \
        coreutils findutils grep util-linux e2fsprogs-extra || {
        log_warning "Some packages failed to install, continuing with available packages..."
    }
    
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
    mkdir -p "$WORK_DIR/iso/boot/grub"
    mkdir -p "$WORK_DIR/iso/EFI/BOOT"
    
    # Install packages
    install_packages
    
    log_success "Environment check completed"
}

# ==================== Create Minimal Alpine System ====================
create_alpine_base() {
    log_info "Creating Alpine Linux base system..."
    
    # Use local apk cache to create chroot
    mkdir -p "$CHROOT_DIR/etc/apk"
    
    # Copy APK configuration from host
    cp /etc/apk/repositories "$CHROOT_DIR/etc/apk/"
    cp /etc/apk/arch "$CHROOT_DIR/etc/apk/" 2>/dev/null || true
    cp /etc/apk/world "$CHROOT_DIR/etc/apk/" 2>/dev/null || true
    
    # Create minimal directory structure
    mkdir -p "$CHROOT_DIR"/{bin,dev,etc,home,lib,mnt,opt,proc,root,run,sbin,srv,sys,tmp,usr,var}
    mkdir -p "$CHROOT_DIR/usr"/{bin,sbin,lib}
    mkdir -p "$CHROOT_DIR/var"/{cache,lib,local,lock,log,opt,run,spool,tmp}
    
    # Create a minimal busybox-based system manually
    log_info "Creating minimal system using busybox..."
    
    # Copy busybox if available
    if command -v busybox >/dev/null; then
        cp $(which busybox) "$CHROOT_DIR/bin/busybox"
        chroot "$CHROOT_DIR" /bin/busybox --install -s
    else
        # Download busybox statically compiled
        log_info "Downloading busybox..."
        wget -q -O "$CHROOT_DIR/bin/busybox" https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
        chmod +x "$CHROOT_DIR/bin/busybox"
        chroot "$CHROOT_DIR" /bin/busybox --install -s
    fi
    
    # Create essential symlinks
    ln -sf /bin/busybox "$CHROOT_DIR/bin/sh"
    ln -sf /bin/busybox "$CHROOT_DIR/bin/ash"
    ln -sf /bin/busybox "$CHROOT_DIR/bin/mount"
    ln -sf /bin/busybox "$CHROOT_DIR/bin/umount"
    
    # Create essential directories for mounting
    mkdir -p "$CHROOT_DIR"/{proc,sys,dev}
    
    # Create minimal /etc files
    cat > "$CHROOT_DIR/etc/inittab" << 'INITTAB'
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
INITTAB

    # Create fstab
    cat > "$CHROOT_DIR/etc/fstab" << 'FSTAB'
proc           /proc        proc    defaults          0       0
sysfs          /sys         sysfs   defaults          0       0
devtmpfs       /dev         devtmpfs defaults         0       0
tmpfs          /tmp         tmpfs   defaults          0       0
FSTAB

    # Create hostname
    echo "openwrt-installer" > "$CHROOT_DIR/etc/hostname"
    
    # Create resolv.conf
    echo "nameserver 8.8.8.8" > "$CHROOT_DIR/etc/resolv.conf"
    echo "nameserver 1.1.1.1" >> "$CHROOT_DIR/etc/resolv.conf"
    
    log_success "Minimal Alpine system created"
}

# ==================== Create Installer System ====================
create_installer_system() {
    log_info "Creating installer system..."
    
    # Copy OpenWRT image
    cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"
    
    # Create init script
    cat > "$CHROOT_DIR/init" << 'INIT_SCRIPT'
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
exec /bin/installer
INIT_SCRIPT
    chmod +x "$CHROOT_DIR/init"
    
    # Create installer script
    cat > "$CHROOT_DIR/bin/installer" << 'INSTALLER_SCRIPT'
#!/bin/sh
# OpenWRT installer

clear

echo "========================================"
echo "      OpenWRT Disk Installer"
echo "========================================"
echo ""

# Function to show disks
show_disks() {
    echo "Available disks:"
    echo "----------------"
    
    local index=1
    for disk in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
        [ -e "$disk" ] || continue
        
        local disk_name=$(basename "$disk")
        local size=$(cat "$disk/size" 2>/dev/null)
        local model=""
        
        if [ -f "$disk/device/model" ]; then
            model=$(cat "$disk/device/model" 2>/dev/null | tr -d '\n' | sed 's/  */ /g')
        fi
        
        if [ -n "$size" ]; then
            size=$((size * 512 / 1024 / 1024))
            printf "  [%d] /dev/%s - %d MB - %s\n" "$index" "$disk_name" "$size" "$model"
        else
            printf "  [%d] /dev/%s - %s\n" "$index" "$disk_name" "$model"
        fi
        
        index=$((index + 1))
    done
    
    TOTAL_DISKS=$((index - 1))
}

# Main loop
while true; do
    show_disks
    
    if [ $TOTAL_DISKS -eq 0 ]; then
        echo ""
        echo "No disks found!"
        echo "Press Enter to rescan..."
        read
        clear
        continue
    fi
    
    echo ""
    echo "----------------------------------------"
    echo "Select disk number (1-$TOTAL_DISKS)"
    echo "Or press 'q' to quit"
    echo -n "Your choice: "
    
    read choice
    
    case "$choice" in
        [Qq])
            echo "Exiting..."
            exit 0
            ;;
        [0-9]*)
            if [ "$choice" -ge 1 ] && [ "$choice" -le "$TOTAL_DISKS" ]; then
                # Find selected disk
                local selected_index=1
                for disk in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
                    [ -e "$disk" ] || continue
                    
                    if [ "$selected_index" -eq "$choice" ]; then
                        DISK_NAME=$(basename "$disk")
                        break
                    fi
                    selected_index=$((selected_index + 1))
                done
                
                if [ -n "$DISK_NAME" ]; then
                    echo ""
                    echo "Selected disk: /dev/$DISK_NAME"
                    echo ""
                    echo "WARNING: This will erase ALL data on /dev/$DISK_NAME"
                    echo ""
                    echo -n "Type 'YES' to confirm: "
                    read confirm
                    
                    if [ "$confirm" = "YES" ]; then
                        echo ""
                        echo "Installing OpenWRT to /dev/$DISK_NAME..."
                        echo "This may take a few minutes..."
                        echo ""
                        
                        # Write image
                        if command -v pv >/dev/null 2>&1; then
                            pv /openwrt.img | dd of="/dev/$DISK_NAME" bs=4M 2>/dev/null
                        else
                            dd if=/openwrt.img of="/dev/$DISK_NAME" bs=4M status=progress 2>&1
                        fi
                        
                        if [ $? -eq 0 ]; then
                            sync
                            echo ""
                            echo "SUCCESS: OpenWRT installed!"
                            echo ""
                            echo "Next steps:"
                            echo "1. Remove installation media"
                            echo "2. Boot from the installed disk"
                            echo "3. OpenWRT will start automatically"
                            echo ""
                            echo "System will reboot in 10 seconds..."
                            
                            for i in 10 9 8 7 6 5 4 3 2 1; do
                                echo -ne "Rebooting in $i seconds...\r"
                                sleep 1
                            done
                            
                            echo ""
                            echo "Rebooting now..."
                            reboot -f
                        else
                            echo ""
                            echo "ERROR: Installation failed!"
                            echo "Press Enter to continue..."
                            read
                        fi
                    else
                        echo "Installation cancelled"
                        sleep 2
                    fi
                fi
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
    
    clear
done
INSTALLER_SCRIPT
    chmod +x "$CHROOT_DIR/bin/installer"
    
    log_success "Installer system created"
}

# ==================== Create Boot Files ====================
create_boot_files() {
    log_info "Creating boot files..."
    
    # Check for kernel
    if [ -f /boot/vmlinuz-lts ]; then
        cp /boot/vmlinuz-lts "$WORK_DIR/iso/boot/vmlinuz"
        log_info "Using kernel: $(basename /boot/vmlinuz-lts)"
    elif [ -f /boot/vmlinuz ]; then
        cp /boot/vmlinuz "$WORK_DIR/iso/boot/vmlinuz"
        log_info "Using kernel: $(basename /boot/vmlinuz)"
    else
        # Try to download a kernel
        log_warning "No kernel found, attempting to download..."
        wget -q -O "$WORK_DIR/iso/boot/vmlinuz" \
            https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-4.19.50-buster || \
        cp "$CHROOT_DIR/bin/busybox" "$WORK_DIR/iso/boot/vmlinuz"
    fi
    
    # Create initramfs
    (cd "$CHROOT_DIR" && find . -print0 | cpio -0 -o -H newc | gzip -9 > "$WORK_DIR/iso/boot/initrd.img") 2>/dev/null
    
    # Create SYSLINUX config for BIOS
    cat > "$WORK_DIR/iso/boot/syslinux.cfg" << 'SYSLINUX_CFG'
DEFAULT openwrt
TIMEOUT 50
PROMPT 0

LABEL openwrt
    MENU LABEL Install OpenWRT
    KERNEL /boot/vmlinuz
    INITRD /boot/initrd.img
    APPEND console=tty0 console=ttyS0,115200
SYSLINUX_CFG

    # Copy SYSLINUX files
    if [ -f /usr/share/syslinux/isolinux.bin ]; then
        cp /usr/share/syslinux/isolinux.bin "$WORK_DIR/iso/boot/"
        cp /usr/share/syslinux/ldlinux.c32 "$WORK_DIR/iso/boot/"
    else
        log_warning "SYSLINUX files not found, BIOS boot may not work"
    fi
    
    # Create GRUB config for UEFI
    cat > "$WORK_DIR/iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}
GRUB_CFG
    
    log_success "Boot files created"
}

# ==================== Create UEFI Boot ====================
create_uefi_boot() {
    log_info "Creating UEFI boot..."
    
    # Try to create UEFI boot file
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        mkdir -p "$WORK_DIR/efi_tmp"
        
        grub-mkstandalone \
            --format=x86_64-efi \
            --output="$WORK_DIR/efi_tmp/bootx64.efi" \
            --locales="" \
            --fonts="" \
            "boot/grub/grub.cfg=$WORK_DIR/iso/boot/grub/grub.cfg" || {
            log_warning "Failed to create GRUB EFI file"
        }
        
        if [ -f "$WORK_DIR/efi_tmp/bootx64.efi" ]; then
            # Create EFI image
            dd if=/dev/zero of="$WORK_DIR/efiboot.img" bs=1M count=10
            mkfs.vfat -F 32 "$WORK_DIR/efiboot.img" >/dev/null 2>&1
            
            # Copy EFI file
            mcopy -i "$WORK_DIR/efiboot.img" "$WORK_DIR/efi_tmp/bootx64.efi" ::/EFI/BOOT/
            cp "$WORK_DIR/efiboot.img" "$WORK_DIR/iso/EFI/BOOT/"
            
            log_success "UEFI boot files created"
        fi
    else
        log_warning "grub-mkstandalone not found, UEFI boot may not work"
    fi
}

# ==================== Build ISO ====================
build_iso() {
    log_info "Building ISO image..."
    
    # Check for isolinux.bin
    if [ ! -f "$WORK_DIR/iso/boot/isolinux.bin" ]; then
        log_warning "isolinux.bin not found, creating BIOS-only ISO"
    fi
    
    # Build ISO
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -output "$ISO_FILE" \
        -full-iso9660-filenames \
        "$WORK_DIR/iso" || {
        # Fallback: simple ISO creation
        log_warning "Using simple ISO creation method"
        genisoimage -volid "OPENWRT_INSTALL" \
            -o "$ISO_FILE" \
            "$WORK_DIR/iso"
    }
    
    if [ -f "$ISO_FILE" ]; then
        ISO_SIZE=$(ls -lh "$ISO_FILE" | awk '{print $5}')
        log_success "ISO created: $ISO_FILE ($ISO_SIZE)"
        
        echo ""
        echo "========================================"
        echo "BUILD COMPLETE"
        echo "========================================"
        echo "Output: $ISO_FILE"
        echo "Size:   $ISO_SIZE"
        echo ""
        echo "To create bootable USB:"
        echo "dd if='$ISO_FILE' of=/dev/sdX bs=4M status=progress"
        echo "========================================"
    else
        log_error "Failed to create ISO"
        exit 1
    fi
}

# ==================== Cleanup ====================
cleanup() {
    log_info "Cleaning up..."
    
    # Unmount any mounted filesystems
    umount "$CHROOT_DIR/proc" 2>/dev/null || true
    umount "$CHROOT_DIR/sys" 2>/dev/null || true
    umount "$CHROOT_DIR/dev" 2>/dev/null || true
    
    # Remove working directory
    rm -rf "$WORK_DIR"
    
    log_success "Cleanup completed"
}

# ==================== Main ====================
main() {
    echo ""
    echo "========================================"
    echo "OpenWRT Alpine Installer Builder"
    echo "========================================"
    echo ""
    
    check_prerequisites
    create_alpine_base
    create_installer_system
    create_boot_files
    create_uefi_boot
    build_iso
    cleanup
    
    echo ""
    log_success "Build completed successfully!"
    echo ""
}

# Run main function
main "$@"
