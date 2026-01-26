#!/bin/bash
# docker-build.sh - Build ISO directly without container package issues

set -e

echo "Building OpenWRT ISO with Alpine in Docker..."
echo "============================================="

# Check input
IMG="$1"
ISO="${2:-openwrt-installer.iso}"

if [ ! -f "$IMG" ]; then
    echo "Usage: $0 <openwrt.img> [output.iso]"
    exit 1
fi

echo "Input: $IMG ($(ls -lh "$IMG" | awk '{print $5}'))"
echo "Output: $ISO"
echo ""

# Use Alpine container but install packages manually
echo "1. Starting Alpine container..."
docker run --rm -it \
    -v "$(pwd)/$IMG:/build/openwrt.img:ro" \
    -v "$(pwd):/output" \
    alpine:3.20 \
    sh -c "
        # Set up repositories
        echo 'http://dl-cdn.alpinelinux.org/alpine/v3.20/main' > /etc/apk/repositories
        echo 'http://dl-cdn.alpinelinux.org/alpine/v3.20/community' >> /etc/apk/repositories
        
        # Update
        apk update
        
        # Install packages without triggers
        echo '2. Installing packages...'
        apk add --no-cache \
            bash \
            xorriso \
            mtools \
            dosfstools \
            gzip \
            cpio \
            wget \
            curl \
            parted \
            e2fsprogs \
            pv \
            dialog \
            linux-lts \
            kmod \
            busybox \
            coreutils
        
        # Try to install syslinux and grub (may have warnings)
        echo '3. Installing boot loaders...'
        apk add --no-cache syslinux 2>/dev/null || echo 'syslinux warning'
        apk add --no-cache grub grub-efi 2>/dev/null || echo 'grub warning'
        
        echo '4. Running build script...'
        
        # Create and run build script
        cat > /tmp/build.sh << 'BUILD_EOF'
#!/bin/sh
set -e

echo 'Starting build...'
WORK_DIR=\"/tmp/build_\$(date +%s)\"
mkdir -p \"\$WORK_DIR\"
cd \"\$WORK_DIR\"

# Get kernel
cp /boot/vmlinuz-lts \"\$WORK_DIR/vmlinuz\" 2>/dev/null || cp /boot/vmlinuz \"\$WORK_DIR/vmlinuz\"

# Create ISO structure
mkdir -p iso/{isolinux,boot,EFI/BOOT}
mkdir -p iso/boot/grub

# Copy files
cp /build/openwrt.img iso/
cp \"\$WORK_DIR/vmlinuz\" iso/boot/

# Create simple init script
mkdir -p initrd
cat > initrd/init << 'INIT'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
echo ''
echo 'OpenWRT Installer'
echo ''
[ -f /openwrt.img ] || {
    echo 'Error: No image'
    exec /bin/sh
}
echo 'Disks:'
ls /dev/sd* 2>/dev/null | grep -v '[0-9]\$' || echo 'None'
echo ''
echo -n 'Disk (e.g., sda): '
read disk
[ -z \"\$disk\" ] && exit 1
echo 'Erase /dev/\$disk? (YES): '
read confirm
[ \"\$confirm\" = 'YES' ] || exit 1
echo 'Installing...'
dd if=/openwrt.img of=/dev/\$disk bs=4M 2>/dev/null
if [ \$? -eq 0 ]; then
    echo 'Done!'
    sleep 3
    reboot -f
else
    echo 'Failed!'
    sleep 5
fi
INIT
chmod +x initrd/init

# Create initramfs
cd initrd && find . | cpio -H newc -o 2>/dev/null | gzip > ../iso/boot/initrd.img
cd ..

# BIOS boot
cat > iso/isolinux/isolinux.cfg << 'CFG'
DEFAULT install
TIMEOUT 10
PROMPT 0
LABEL install
    MENU LABEL Install OpenWRT
    KERNEL /boot/vmlinuz
    INITRD /boot/initrd.img
    APPEND console=tty0
CFG

cp /usr/share/syslinux/isolinux.bin iso/isolinux/ 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin iso/isolinux/ 2>/dev/null || true

# UEFI boot (simple)
cat > iso/boot/grub/grub.cfg << 'GRUB'
set timeout=5
menuentry 'Install OpenWRT' {
    linux /boot/vmlinuz console=tty0
    initrd /boot/initrd.img
}
GRUB

# Build ISO
xorriso -as mkisofs \\
    -volid 'OPENWRT_INST' \\
    -o /output/$ISO \\
    -c 'isolinux/boot.cat' \\
    -b 'isolinux/isolinux.bin' \\
    -no-emul-boot \\
    -boot-load-size 4 \\
    -boot-info-table \\
    iso

echo ''
echo 'Build complete!'
echo 'ISO: /output/$ISO'
echo 'Size: \$(ls -lh /output/$ISO | awk \"{print \\\$5}\")'
BUILD_EOF
        
chmod +x /tmp/build.sh
        /tmp/build.sh
    "

echo ""
echo "══════════════════════════════════════════════════════════"
echo "Build completed!"
echo "ISO: $ISO"
echo "Size: $(ls -lh "$ISO" | awk '{print $5}')"
echo ""
echo "To test:"
echo "  qemu-system-x86_64 -cdrom $ISO -m 512"
echo "══════════════════════════════════════════════════════════"
