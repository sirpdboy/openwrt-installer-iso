#!/bin/bash
# build-iso-final.sh - 构建OpenWRT自动安装ISO（修复initrd问题版）
set -e

echo "开始构建OpenWRT安装ISO..."
echo "========================================"

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"

OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall.iso}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查必要文件
log_info "检查必要文件..."
if [ ! -f "${OPENWRT_IMG}" ]; then
    log_error "找不到OpenWRT镜像: ${OPENWRT_IMG}"
    exit 1
fi
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
deb http://archive.debian.org/debian-security buster/updates main
EOF
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具
log_info "安装构建工具..."
apt-get update
apt-get -y install \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
    syslinux-common \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    wget \
    curl \
    live-boot \
    live-boot-initramfs-tools \
    pv \
    kpartx \
    file

# 创建目录结构
log_info "创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${WORK_DIR}/tmp"

# 复制OpenWRT镜像
log_info "复制OpenWRT镜像..."
mkdir -p "${WORK_DIR}/openwrt"
cp "${OPENWRT_IMG}" "${WORK_DIR}/openwrt/image.img"
OPENWRT_SIZE=$(stat -c%s "${WORK_DIR}/openwrt/image.img")
log_success "OpenWRT镜像已复制 ($(numfmt --to=iec-i --suffix=B ${OPENWRT_SIZE}))"

# ====== 简化debootstrap过程 ======
log_info "引导最小Debian系统..."
DEBIAN_MIRROR="http://archive.debian.org/debian"

if debootstrap \
    --arch=amd64 \
    --variant=minbase \
    --include=locales,linux-image-amd64,live-boot,systemd-sysv,ssh \
    buster "${CHROOT_DIR}" "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log; then
    log_success "Debian系统引导成功"
else
    log_error "debootstrap失败"
    exit 1
fi

# ====== 简化chroot配置 ======
log_info "配置chroot环境..."

# 挂载必要的文件系统
mount -t proc none "${CHROOT_DIR}/proc"
mount -o bind /dev "${CHROOT_DIR}/dev"
mount -o bind /dev/pts "${CHROOT_DIR}/dev/pts"
mount -o bind /sys "${CHROOT_DIR}/sys"

# 复制resolv.conf
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

# 创建简化的chroot配置脚本
cat > "${CHROOT_DIR}/configure.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e

echo "配置安装环境..."

# 配置APT源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# 更新并安装必要工具
apt-get update
apt-get install -y --no-install-recommends \
    locales \
    live-boot \
    live-boot-initramfs-tools \
    parted \
    ssh \
    dialog \
    pv

# 生成initrd
echo "生成initrd..."
update-initramfs -c -k all 2>/dev/null || true

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 设置root无密码
passwd -d root 2>/dev/null || true

# 创建安装脚本
mkdir -p /opt
cat > /opt/install-openwrt.sh << 'INSTALL'
#!/bin/bash
clear
echo "OpenWRT自动安装程序"
echo "===================="
echo ""
echo "检测到OpenWRT镜像"
echo ""

while true; do
    echo "可用磁盘:"
    lsblk -d -n -o NAME,SIZE 2>/dev/null || echo "未检测到磁盘"
    echo ""
    read -p "输入目标磁盘 (例如: sda): " DISK
    
    if [ -b "/dev/$DISK" ]; then
        echo ""
        echo "⚠️  警告: 将擦除 /dev/$DISK 上的所有数据！"
        read -p "输入 'YES' 确认: " CONFIRM
        
        if [ "$CONFIRM" = "YES" ]; then
            echo "正在安装到 /dev/$DISK..."
            if command -v pv >/dev/null; then
                pv /openwrt.img | dd of="/dev/$DISK" bs=4M
            else
                dd if=/openwrt.img of="/dev/$DISK" bs=4M status=progress
            fi
            sync
            echo "安装完成！"
            echo "按任意键重启..."
            read
            reboot
        fi
    else
        echo "磁盘 /dev/$DISK 不存在"
    fi
done
INSTALL
chmod +x /opt/install-openwrt.sh

# 创建自动启动
cat > /etc/systemd/system/installer.service << 'SERVICE'
[Unit]
Description=OpenWRT Installer
After=getty.target

[Service]
Type=oneshot
ExecStart=/opt/install-openwrt.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable installer.service

# 配置自动登录
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
OVERRIDE

echo "配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/configure.sh"
chroot "${CHROOT_DIR}" /bin/bash -c "/configure.sh" 2>&1 | tee "${WORK_DIR}/configure.log"

# ====== 修复：正确查找内核和initrd文件 ======
log_info "查找内核和initrd文件..."

# 方法1：直接使用已知路径
KERNEL_FILE=""
INITRD_FILE=""

# 查找内核（明确指定路径模式）
if [ -f "${CHROOT_DIR}/boot/vmlinuz-4.19.0-21-amd64" ]; then
    KERNEL_FILE="${CHROOT_DIR}/boot/vmlinuz-4.19.0-21-amd64"
elif [ -f "${CHROOT_DIR}/boot/vmlinuz" ]; then
    KERNEL_FILE="${CHROOT_DIR}/boot/vmlinuz"
else
    # 查找所有vmlinuz文件，排除特定目录
    KERNEL_CANDIDATES=$(find "${CHROOT_DIR}" -type f -name "vmlinuz*" ! -path "*/usr/lib/*" ! -path "*/usr/share/*" ! -path "*/lib/modules/*")
    if [ -n "$KERNEL_CANDIDATES" ]; then
        KERNEL_FILE=$(echo "$KERNEL_CANDIDATES" | head -1)
    fi
fi

# 查找initrd（只查找真正的initrd镜像）
if [ -f "${CHROOT_DIR}/boot/initrd.img-4.19.0-21-amd64" ]; then
    INITRD_FILE="${CHROOT_DIR}/boot/initrd.img-4.19.0-21-amd64"
elif [ -f "${CHROOT_DIR}/boot/initrd.img" ]; then
    INITRD_FILE="${CHROOT_DIR}/boot/initrd.img"
else
    # 查找所有initrd.img文件（只匹配initrd.img*模式）
    INITRD_CANDIDATES=$(find "${CHROOT_DIR}" -type f -name "initrd.img*" ! -path "*/usr/lib/*" ! -path "*/usr/share/*")
    
    # 进一步筛选：检查文件类型（initrd通常是压缩文件）
    REAL_INITRD_CANDIDATES=""
    for candidate in $INITRD_CANDIDATES; do
        # 使用file命令检查文件类型
        if file "$candidate" | grep -q "compressed data"; then
            REAL_INITRD_CANDIDATES="$REAL_INITRD_CANDIDATES $candidate"
        elif file "$candidate" | grep -q "gzip compressed"; then
            REAL_INITRD_CANDIDATES="$REAL_INITRD_CANDIDATES $candidate"
        elif file "$candidate" | grep -q "xz compressed"; then
            REAL_INITRD_CANDIDATES="$REAL_INITRD_CANDIDATES $candidate"
        fi
    done
    
    if [ -n "$REAL_INITRD_CANDIDATES" ]; then
        INITRD_FILE=$(echo "$REAL_INITRD_CANDIDATES" | head -1)
    fi
fi

# 验证文件
if [ -z "$KERNEL_FILE" ] || [ ! -f "$KERNEL_FILE" ]; then
    log_error "找不到内核文件！"
    log_info "在${CHROOT_DIR}中搜索vmlinuz文件："
    find "${CHROOT_DIR}" -name "vmlinuz*" -type f 2>/dev/null
    exit 1
fi

if [ -z "$INITRD_FILE" ] || [ ! -f "$INITRD_FILE" ]; then
    log_error "找不到initrd文件！"
    log_info "在${CHROOT_DIR}中搜索initrd文件："
    find "${CHROOT_DIR}" -name "initrd*" -type f 2>/dev/null
    log_info "尝试生成initrd..."
    
    # 在chroot中生成initrd
    chroot "${CHROOT_DIR}" /bin/bash -c "update-initramfs -c -k all" 2>&1 | tee /tmp/initrd.log
    
    # 重新查找
    if [ -f "${CHROOT_DIR}/boot/initrd.img-4.19.0-21-amd64" ]; then
        INITRD_FILE="${CHROOT_DIR}/boot/initrd.img-4.19.0-21-amd64"
    elif [ -f "${CHROOT_DIR}/boot/initrd.img" ]; then
        INITRD_FILE="${CHROOT_DIR}/boot/initrd.img"
    else
        log_error "无法生成或找到initrd文件"
        exit 1
    fi
fi

log_success "找到内核: $(basename $KERNEL_FILE) ($(numfmt --to=iec-i --suffix=B $(stat -c%s "$KERNEL_FILE")))"
log_success "找到initrd: $(basename $INITRD_FILE) ($(numfmt --to=iec-i --suffix=B $(stat -c%s "$INITRD_FILE")))"

# 显示文件信息确认
log_info "文件类型验证："
file "$KERNEL_FILE"
file "$INITRD_FILE"

# 卸载chroot
log_info "卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true

# ====== 复制OpenWRT镜像 ======
log_info "复制OpenWRT镜像到live目录..."
mkdir -p "${STAGING_DIR}/live/openwrt"
cp "${WORK_DIR}/openwrt/image.img" "${STAGING_DIR}/live/openwrt/image.img"

# ====== 创建squashfs ======
log_info "创建squashfs文件系统..."

# 先清理不需要的目录
rm -rf "${CHROOT_DIR}/usr/share/doc" \
       "${CHROOT_DIR}/usr/share/man" \
       "${CHROOT_DIR}/usr/share/info" \
       "${CHROOT_DIR}/var/lib/apt/lists/*" \
       "${CHROOT_DIR}/var/cache/apt/*" \
       "${CHROOT_DIR}/tmp/*" \
       "${CHROOT_DIR}/var/tmp/*" 2>/dev/null || true

SQUASHFS_FILE="${STAGING_DIR}/live/filesystem.squashfs"

if mksquashfs "${CHROOT_DIR}" "${SQUASHFS_FILE}" \
    -comp xz \
    -b 1M \
    -noappend \
    -no-recovery \
    -e boot \
    -e dev \
    -e proc \
    -e sys \
    -e tmp \
    -e run 2>&1 | tee /tmp/mksquashfs.log; then
    
    SQUASHFS_SIZE=$(stat -c%s "${SQUASHFS_FILE}")
    log_success "squashfs创建成功 ($(numfmt --to=iec-i --suffix=B ${SQUASHFS_SIZE}))"
else
    log_error "squashfs创建失败"
    exit 1
fi

echo "live" > "${STAGING_DIR}/live/filesystem.squashfs.type"

# ====== 复制内核和initrd ======
log_info "复制内核和initrd到live目录..."

# 复制内核
cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
log_success "内核复制: $(basename $KERNEL_FILE) -> vmlinuz"

# 复制initrd
cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
log_success "initrd复制: $(basename $INITRD_FILE) -> initrd"

# 验证复制
log_info "验证复制的文件："
ls -lh "${STAGING_DIR}/live/vmlinuz"
ls -lh "${STAGING_DIR}/live/initrd"
file "${STAGING_DIR}/live/vmlinuz"
file "${STAGING_DIR}/live/initrd"

# ====== 创建引导配置 ======
log_info "创建引导配置..."

# ISOLINUX配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Auto Installer

LABEL live
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet
ISOLINUX_CFG

# GRUB配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet
    initrd /live/initrd
}
GRUB_CFG

# 复制引导文件
log_info "复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 复制必要的模块
for module in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32; do
    if [ -f "/usr/lib/syslinux/modules/bios/${module}" ]; then
        cp "/usr/lib/syslinux/modules/bios/${module}" "${STAGING_DIR}/isolinux/"
    elif [ -f "/usr/share/syslinux/${module}" ]; then
        cp "/usr/share/syslinux/${module}" "${STAGING_DIR}/isolinux/"
    fi
done

# ====== 创建UEFI引导 ======
log_info "创建UEFI引导..."

# 创建GRUB EFI文件
if command -v grub-mkstandalone >/dev/null 2>&1; then
    mkdir -p "${WORK_DIR}/grub-efi"
    
    cat > "${WORK_DIR}/grub-efi/grub.cfg" << 'GRUB_EFI_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet
    initrd /live/initrd
}
GRUB_EFI_CFG
    
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="${WORK_DIR}/grub-efi/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=${WORK_DIR}/grub-efi/grub.cfg" 2>&1 | tee /tmp/grub.log; then
        
        # 创建EFI映像
        EFI_SIZE=$(( $(stat -c%s "${WORK_DIR}/grub-efi/bootx64.efi") + 1048576 ))
        
        dd if=/dev/zero of="${STAGING_DIR}/EFI/boot/efiboot.img" bs=1 count=0 seek=${EFI_SIZE}
        mkfs.vfat -F 32 "${STAGING_DIR}/EFI/boot/efiboot.img" >/dev/null 2>&1 || true
        
        # 复制EFI文件
        if command -v mcopy >/dev/null 2>&1; then
            mcopy -i "${STAGING_DIR}/EFI/boot/efiboot.img" \
                "${WORK_DIR}/grub-efi/bootx64.efi" ::/EFI/BOOT/BOOTX64.EFI && \
            log_success "UEFI引导文件创建完成"
        else
            log_warning "mtools不可用，跳过UEFI引导"
            rm -f "${STAGING_DIR}/EFI/boot/efiboot.img"
        fi
    else
        log_warning "GRUB EFI文件生成失败"
    fi
fi

# ====== 构建ISO镜像 ======
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# 基础命令
XORRISO_CMD="xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid 'OPENWRT_INSTALL' \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -output '${ISO_PATH}' \
    '${STAGING_DIR}'"

# 添加UEFI引导（如果存在）
if [ -f "${STAGING_DIR}/EFI/boot/efiboot.img" ]; then
    XORRISO_CMD="${XORRISO_CMD} \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot"
fi

# 执行构建
echo "执行: $XORRISO_CMD"
eval $XORRISO_CMD 2>&1 | tee /tmp/xorriso.log

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    ISO_SIZE_BYTES=$(stat -c%s "$ISO_PATH")
    
    echo ""
    echo "================================================================================"
    log_success "✅ ISO构建成功！"
    echo "================================================================================"
    echo ""
    echo "📊 构建信息："
    echo "  文件: ${ISO_NAME}"
    echo "  大小: ${ISO_SIZE} ($(numfmt --to=iec-i --suffix=B ${ISO_SIZE_BYTES}))"
    echo "  位置: ${ISO_PATH}"
    echo ""
    echo "📁 包含内容："
    echo "  内核: vmlinuz ($(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/vmlinuz")))"
    echo "  initrd: initrd ($(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/initrd")))"
    echo "  squashfs: filesystem.squashfs ($(numfmt --to=iec-i --suffix=B $(stat -c%s "${SQUASHFS_FILE}")))"
    echo "  OpenWRT镜像: $(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/openwrt/image.img")))"
    echo ""
    
    # 创建构建信息文件
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO
===========================
构建时间: $(date)
ISO文件: ${ISO_NAME}
文件大小: ${ISO_SIZE} (${ISO_SIZE_BYTES} bytes)
内核: $(basename $KERNEL_FILE)
initrd: $(basename $INITRD_FILE)
支持引导: BIOS $( [ -f "${STAGING_DIR}/EFI/boot/efiboot.img" ] && echo "+ UEFI" )

使用方法:
  1. 刻录到U盘: sudo dd if=${ISO_NAME} of=/dev/sdX bs=4M status=progress
  2. 从U盘启动计算机
  3. 系统将自动启动安装程序
  4. 选择目标磁盘并确认安装

警告: 安装会完全擦除目标磁盘上的所有数据！
BUILD_INFO
    
    log_success "构建信息已保存到: ${OUTPUT_DIR}/build-info.txt"
    echo ""
    echo "🎉 构建完成！"
    
else
    log_error "ISO构建失败"
    echo "错误日志:"
    tail -20 /tmp/xorriso.log
    exit 1
fi

log_success "所有步骤完成！"
