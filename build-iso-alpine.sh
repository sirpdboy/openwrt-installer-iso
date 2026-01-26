#!/bin/ash
# Minimal OpenWRT Installer ISO Builder
# Pure English, no special characters

set -e

# Configuration
IMG="$1"
ISO="${2:-openwrt-installer.iso}"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check input
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
    echo "Usage: $0 <openwrt-image> [output.iso]"
    echo "Example: $0 openwrt.img installer.iso"
    exit 1
fi

echo "========================================"
echo "OpenWRT Installer ISO Builder"
echo "========================================"
echo ""

info "Installing required packages..."
apk add --no-cache xorriso syslinux grub-bios grub-efi mtools dosfstools

WORKDIR="/tmp/build_$$"
mkdir -p "$WORKDIR/iso/boot/grub"

info "Creating boot structure..."

# Create simple initrd with installer
mkdir -p "$WORKDIR/initrd"
cat > "$WORKDIR/initrd/init" << 'EOF'
#!/bin/sh
# Minimal installer init script

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "Starting OpenWRT installer..."
echo ""

if [ ! -f /openwrt.img ]; then
    echo "ERROR: OpenWRT image not found"
    echo "Image should be at /openwrt.img"
    echo ""
    echo "Press Enter for shell..."
    read
    exec /bin/sh
fi

# Show disks
echo "Available disks:"
ls -la /dev/sd* 2>/dev/null | grep -v '[0-9]$' || echo "No disks found"
echo ""

echo -n "Enter target disk (e.g., sda): "
read disk

if [ -z "$disk" ]; then
    echo "No disk selected"
    exit 1
fi

echo ""
echo "WARNING: This will erase /dev/$disk"
echo -n "Type YES to continue: "
read confirm

if [ "$confirm" != "YES" ]; then
    echo "Cancelled"
    exit 1
fi

echo "Installing OpenWRT to /dev/$disk..."
dd if=/openwrt.img of=/dev/$disk bs=4M

if [ $? -eq 0 ]; then
    echo "SUCCESS: Installation complete"
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot -f
else
    echo "ERROR: Installation failed"
    echo "Press Enter to retry..."
    read
fi
EOF
chmod +x "$WORKDIR/initrd/init"

# Create initrd
(cd "$WORKDIR/initrd" && find . | cpio -o -H newc | gzip > "$WORKDIR/iso/boot/initrd.img")

# Copy kernel from current system or use default
cp /boot/vmlinuz-lts "$WORKDIR/iso/boot/vmlinuz" 2>/dev/null || true

# Copy OpenWRT image
cp "$IMG" "$WORKDIR/iso/openwrt.img"

# Create SYSLINUX config
cat > "$WORKDIR/iso/boot/syslinux.cfg" << EOF
DEFAULT install
TIMEOUT 50
PROMPT 0

LABEL install
    MENU LABEL Install OpenWRT
    KERNEL /boot/vmlinuz
    INITRD /boot/initrd.img
    APPEND console=tty0 console=ttyS0,115200
EOF

cp /usr/share/syslinux/isolinux.bin "$WORKDIR/iso/boot/"
cp /usr/share/syslinux/ldlinux.c32 "$WORKDIR/iso/boot/"

# Create GRUB config
cat > "$WORKDIR/iso/boot/grub/grub.cfg" << EOF
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}
EOF

# Create UEFI boot
grub-mkstandalone -o "$WORKDIR/iso/EFI/BOOT/bootx64.efi" -O x86_64-efi "boot/grub/grub.cfg=$WORKDIR/iso/boot/grub/grub.cfg"

# Build ISO
info "Building ISO..."
xorriso -as mkisofs \
    -volid "OPENWRT_INSTALL" \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
    -c boot/boot.cat \
    -b boot/isolinux.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/BOOT/bootx64.efi \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "$ISO" \
    "$WORKDIR/iso"

success "ISO created: $ISO"
echo "Size: $(ls -lh "$ISO" | awk '{print $5}')"

# Cleanup
rm -rf "$WORKDIR"

echo ""
echo "To create bootable USB:"
echo "dd if=\"$ISO\" of=/dev/sdX bs=4M status=progress && sync"
echo ""
