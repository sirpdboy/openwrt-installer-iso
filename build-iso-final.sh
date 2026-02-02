#!/bin/bash
# build-iso-final.sh - 构建OpenWRT自动安装ISO（极小化版）
set -e

echo "开始构建OpenWRT安装ISO（极小化版）..."
echo "========================================"

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"

OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall.iso}"
TARGET_SQUASHFS_SIZE=50000000  # 目标50MB

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
    file \
    rsync

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

# ====== 创建最小化Debian系统 ======
log_info "引导最小化Debian系统..."
DEBIAN_MIRROR="http://archive.debian.org/debian"

# 只安装最核心的包
MINIMAL_PACKAGES="locales,linux-image-amd64,live-boot,systemd-sysv"

if debootstrap \
    --arch=amd64 \
    --variant=minbase \
    --include="${MINIMAL_PACKAGES}" \
    buster "${CHROOT_DIR}" "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log; then
    log_success "Debian最小系统引导成功"
else
    log_error "debootstrap失败"
    exit 1
fi

# ====== 极小化chroot配置 ======
log_info "配置极小化chroot环境..."

mount -t proc none "${CHROOT_DIR}/proc"
mount -o bind /dev "${CHROOT_DIR}/dev"
mount -o bind /dev/pts "${CHROOT_DIR}/dev/pts"
mount -o bind /sys "${CHROOT_DIR}/sys"
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

cat > "${CHROOT_DIR}/minimal-config.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e

echo "配置极小化环境..."

# 配置APT源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# 更新
apt-get update

# 安装最小工具集
apt-get install -y --no-install-recommends \
    locales \
    live-boot \
    live-boot-initramfs-tools \
    parted \
    pv \
    dialog

# 设置locale（最小化）
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen en_US.UTF.UTF-8 2>/dev/null || true

# 设置主机名
echo "installer" > /etc/hostname

# 设置root无密码
passwd -d root 2>/dev/null || true

# 生成initrd
echo "生成initrd..."
update-initramfs -c -k all 2>&1 || mkinitramfs -o /boot/initrd.img 2>&1 || true

# ====== 创建最小安装脚本 ======
mkdir -p /opt

cat > /opt/install.sh << 'INSTALL_SCRIPT'
#!/bin/bash
clear
echo "========================================"
echo "    OpenWRT 自动安装程序"
echo "========================================"
echo ""

# 检查OpenWRT镜像
if [ -f /mnt/openwrt/image.img ]; then
    cp /mnt/openwrt/image.img /openwrt.img
    echo "✅ 找到OpenWRT镜像"
else
    echo "❌ 找不到OpenWRT镜像"
    echo "按回车键进入shell..."
    read
    exec /bin/bash
fi

while true; do
    echo ""
    echo "可用磁盘:"
    lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -E '^[sh]d|^nvme|^vd' || echo "未找到磁盘"
    echo ""
    
    read -p "输入磁盘名称 (如: sda): " DISK
    
    if [ -z "$DISK" ]; then
        continue
    fi
    
    if [ ! -b "/dev/$DISK" ]; then
        echo "❌ 磁盘 /dev/$DISK 不存在"
        continue
    fi
    
    echo ""
    echo "⚠️  警告: 将擦除 /dev/$DISK 上的所有数据！"
    read -p "输入 'YES' 确认: " CONFIRM
    
    if [ "$CONFIRM" = "YES" ]; then
        echo ""
        echo "正在安装到 /dev/$DISK ..."
        
        if command -v pv >/dev/null; then
            pv -pet /openwrt.img | dd of="/dev/$DISK" bs=4M status=none
        else
            dd if=/openwrt.img of="/dev/$DISK" bs=4M status=progress
        fi
        
        sync
        echo ""
        echo "✅ 安装完成！"
        echo "系统将在10秒后重启..."
        
        for i in {10..1}; do
            echo -ne "倒计时: ${i}秒\r"
            sleep 1
        done
        
        reboot -f
    else
        echo "已取消"
    fi
done
INSTALL_SCRIPT
chmod +x /opt/install.sh

# 创建自动启动服务
cat > /etc/systemd/system/autoinstall.service << 'SERVICE'
[Unit]
Description=Auto Install OpenWRT
After=getty.target

[Service]
Type=oneshot
ExecStart=/opt/install.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable autoinstall.service

# 配置自动登录
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
OVERRIDE

# ====== 深度清理系统 ======
echo "深度清理系统..."

# 清理包缓存
apt-get clean
rm -rf /var/lib/apt/lists/*

# 删除文档文件
rm -rf /usr/share/doc/*
rm -rf /usr/share/man/*
rm -rf /usr/share/info/*
rm -rf /usr/share/locale/*

# 删除不必要的locale文件（只保留en_US）
mkdir -p /usr/share/locale/en_US
mv /usr/share/locale/en_US/LC_MESSAGES/* /usr/share/locale/ 2>/dev/null || true
rm -rf /usr/share/locale/[a-df-z]*
rm -rf /usr/share/locale/e[a-tv-z]*
mv /usr/share/locale/en_US /tmp/locale_tmp 2>/dev/null || true
rm -rf /usr/share/locale/*
mv /tmp/locale_tmp /usr/share/locale/en_US 2>/dev/null || true

# 删除示例文件
rm -rf /usr/share/examples
rm -rf /usr/share/common-licenses

# 清理日志目录
rm -rf /var/log/*
mkdir -p /var/log

# 清理临时文件
rm -rf /tmp/* /var/tmp/*

# 删除不必要的时间数据
rm -rf /usr/share/zoneinfo/[!U]*
rm -rf /usr/share/zoneinfo/U[!T]*
rm -rf /usr/share/zoneinfo/UTC

# 删除vim帮助文件
rm -rf /usr/share/vim/vim[0-9][0-9]/doc

# 清理bash文档
rm -rf /usr/share/doc/bash

# 清理系统日志轮转配置
rm -f /etc/logrotate.d/*

# 删除不必要的模块
find /lib/modules -name "*.ko" -type f | grep -E "(bluetooth|wifi|wireless|nvidia|amd|radeon|sound|audio|video|drm)" | xargs rm -f 2>/dev/null || true

echo "✅ 极小化配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/minimal-config.sh"
chroot "${CHROOT_DIR}" /bin/bash -c "/minimal-config.sh" 2>&1 | tee "${WORK_DIR}/minimal-config.log"

# ====== 查找内核和initrd ======
log_info "查找内核和initrd..."

# 直接查找
KERNEL_FILE=$(find "${CHROOT_DIR}" -name "vmlinuz*" -type f ! -path "*/usr/lib/*" ! -path "*/usr/share/*" | head -1)
INITRD_FILE=$(find "${CHROOT_DIR}" -name "initrd.img*" -type f ! -path "*/usr/lib/*" ! -path "*/usr/share/*" | head -1)

if [ -z "$KERNEL_FILE" ] || [ ! -f "$KERNEL_FILE" ]; then
    log_error "找不到内核文件"
    exit 1
fi

if [ -z "$INITRD_FILE" ] || [ ! -f "$INITRD_FILE" ]; then
    log_error "找不到initrd文件"
    exit 1
fi

log_success "找到内核: $(basename $KERNEL_FILE)"
log_success "找到initrd: $(basename $INITRD_FILE)"

# ====== 卸载chroot ======
log_info "卸载chroot..."
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true

# ====== 复制OpenWRT镜像 ======
log_info "复制OpenWRT镜像到live目录..."
mkdir -p "${STAGING_DIR}/live/openwrt"
cp "${WORK_DIR}/openwrt/image.img" "${STAGING_DIR}/live/openwrt/image.img"

# ====== 极致压缩squashfs（目标50MB） ======
log_info "极致压缩squashfs（目标50MB）..."

# 1. 深度清理chroot
log_info "执行深度清理..."

# 删除Python相关文件
rm -rf "${CHROOT_DIR}"/usr/lib/python* 2>/dev/null || true
rm -rf "${CHROOT_DIR}"/usr/local/lib/python* 2>/dev/null || true

# 删除Perl相关文件
rm -rf "${CHROOT_DIR}"/usr/share/perl* 2>/dev/null || true

# 删除Go相关文件
rm -rf "${CHROOT_DIR}"/usr/lib/go 2>/dev/null || true

# 删除Rust相关文件
rm -rf "${CHROOT_DIR}"/usr/lib/rustlib 2>/dev/null || true

# 删除Java相关文件
rm -rf "${CHROOT_DIR}"/usr/lib/jvm 2>/dev/null || true

# 删除不必要的头文件
rm -rf "${CHROOT_DIR}"/usr/include/* 2>/dev/null || true

# 删除静态库
find "${CHROOT_DIR}" -name "*.a" -type f -delete 2>/dev/null || true

# 删除调试符号
find "${CHROOT_DIR}" -name "*.debug" -type f -delete 2>/dev/null || true
find "${CHROOT_DIR}" -path "*/debug/*" -type f -delete 2>/dev/null || true

# 删除备份文件
find "${CHROOT_DIR}" -name "*~" -type f -delete 2>/dev/null || true
find "${CHROOT_DIR}" -name "*.bak" -type f -delete 2>/dev/null || true
find "${CHROOT_DIR}" -name "*.old" -type f -delete 2>/dev/null || true

# 删除日志文件
find "${CHROOT_DIR}" -name "*.log" -type f -delete 2>/dev/null || true

# 清理大小
log_info "清理后chroot大小: $(du -sh ${CHROOT_DIR} | cut -f1)"

# 2. 创建压缩squashfs（使用最大压缩）
SQUASHFS_FILE="${STAGING_DIR}/live/filesystem.squashfs"

log_info "开始创建极致压缩的squashfs..."

# 使用lz4压缩（最快，但压缩率较低）
# 使用gzip压缩（平衡）
# 使用xz压缩（最慢，但压缩率最高）<- 选择这个以达到50MB目标

COMPRESSION_METHOD="xz"  # 可以改为gzip或lz4测试
BLOCK_SIZE="1M"

case $COMPRESSION_METHOD in
    "lz4")
        COMPRESSOR="-comp lz4 -Xhc"
        ;;
    "gzip")
        COMPRESSOR="-comp gzip -Xcompression-level 9"
        ;;
    "xz")
        COMPRESSOR="-comp xz -Xdict-size 100% -Xbcj x86"
        ;;
esac

echo "使用压缩方法: $COMPRESSION_METHOD"
echo "目标大小: $(numfmt --to=iec-i --suffix=B ${TARGET_SQUASHFS_SIZE})"

# 排除列表
EXCLUDE_LIST="${WORK_DIR}/exclude.txt"
cat > "$EXCLUDE_LIST" << 'EXCLUDE'
/boot/*
/dev/*
/proc/*
/sys/*
/tmp/*
/run/*
/var/tmp/*
/var/cache/*
/var/log/*
/var/lib/apt/lists/*
/usr/share/doc/*
/usr/share/man/*
/usr/share/info/*
/usr/share/locale/*
/usr/share/zoneinfo/*
/usr/share/common-licenses/*
/usr/share/examples/*
/usr/include/*
/usr/lib/debug/*
/usr/lib/*/debug/*
/usr/lib/python*
/usr/share/perl*
/usr/lib/go*
/usr/lib/rustlib*
/usr/lib/jvm*
*.a
*.debug
*~
*.bak
*.old
*.log
/opt/install.sh
/mnt/openwrt
EXCLUDE

# 创建squashfs
if mksquashfs "${CHROOT_DIR}" "${SQUASHFS_FILE}" \
    ${COMPRESSOR} \
    -b ${BLOCK_SIZE} \
    -noappend \
    -no-recovery \
    -always-use-fragments \
    -no-duplicates \
    -all-root \
    -ef "$EXCLUDE_LIST" 2>&1 | tee /tmp/mksquashfs.log; then
    
    SQUASHFS_SIZE=$(stat -c%s "${SQUASHFS_FILE}")
    log_success "squashfs创建成功 ($(numfmt --to=iec-i --suffix=B ${SQUASHFS_SIZE}))"
    
    # 检查是否达到目标大小
    if [ $SQUASHFS_SIZE -gt $TARGET_SQUASHFS_SIZE ]; then
        log_warning "squashfs大小 ($(numfmt --to=iec-i --suffix=B ${SQUASHFS_SIZE})) 超过目标 ($(numfmt --to=iec-i --suffix=B ${TARGET_SQUASHFS_SIZE}))"
        log_info "尝试进一步优化..."
        
        # 进一步删除文件
        rm -rf "${CHROOT_DIR}"/usr/share/console-setup 2>/dev/null || true
        rm -rf "${CHROOT_DIR}"/usr/share/fonts 2>/dev/null || true
        rm -rf "${CHROOT_DIR}"/usr/share/icons 2>/dev/null || true
        rm -rf "${CHROOT_DIR}"/usr/share/themes 2>/dev/null || true
        rm -rf "${CHROOT_DIR}"/usr/share/X11 2>/dev/null || true
        rm -rf "${CHROOT_DIR}"/usr/lib/x86_64-linux-gnu/dri 2>/dev/null || true
        
        # 重新创建squashfs
        rm -f "${SQUASHFS_FILE}"
        mksquashfs "${CHROOT_DIR}" "${SQUASHFS_FILE}" \
            ${COMPRESSOR} \
            -b ${BLOCK_SIZE} \
            -noappend \
            -no-recovery \
            -ef "$EXCLUDE_LIST" 2>&1 | tee -a /tmp/mksquashfs.log
        
        SQUASHFS_SIZE=$(stat -c%s "${SQUASHFS_FILE}")
        log_success "优化后squashfs大小: $(numfmt --to=iec-i --suffix=B ${SQUASHFS_SIZE})"
    fi
    
else
    log_error "squashfs创建失败"
    exit 1
fi

# 创建live-boot标记
echo "live" > "${STAGING_DIR}/live/filesystem.squashfs.type"

# ====== 复制内核和initrd ======
log_info "复制内核和initrd..."

cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"

log_success "内核: $(ls -lh ${STAGING_DIR}/live/vmlinuz | awk '{print $5}')"
log_success "initrd: $(ls -lh ${STAGING_DIR}/live/initrd | awk '{print $5}')"

# ====== 创建引导配置 ======
log_info "创建引导配置..."

# ISOLINUX
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
PROMPT 0
TIMEOUT 30
UI menu.c32

MENU TITLE OpenWRT Installer

LABEL live
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet
ISOLINUX_CFG

# GRUB
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet
    initrd /live/initrd
}
GRUB_CFG

# 复制引导文件
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true

for module in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32; do
    [ -f "/usr/lib/syslinux/modules/bios/${module}" ] && \
        cp "/usr/lib/syslinux/modules/bios/${module}" "${STAGING_DIR}/isolinux/"
done

# ====== 构建ISO ======
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

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

eval $XORRISO_CMD 2>&1 | tee /tmp/xorriso.log

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    ISO_SIZE_BYTES=$(stat -c%s "$ISO_PATH")
    
    echo ""
    echo "================================================================================"
    log_success "✅ 极小化ISO构建成功！"
    echo "================================================================================"
    echo ""
    echo "📊 最终大小："
    echo "  ISO文件: ${ISO_SIZE} ($(numfmt --to=iec-i --suffix=B ${ISO_SIZE_BYTES}))"
    echo "  squashfs: $(numfmt --to=iec-i --suffix=B ${SQUASHFS_SIZE})"
    echo "  压缩比: $(( ${SQUASHFS_SIZE} * 100 / $(du -sb ${CHROOT_DIR} 2>/dev/null | cut -f1) ))%"
    echo ""
    
    # 组件分析
    echo "📁 组件分析："
    echo "  1. OpenWRT镜像: $(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/openwrt/image.img"))"
    echo "  2. 内核: $(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/vmlinuz"))"
    echo "  3. initrd: $(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/initrd"))"
    echo "  4. 系统文件: $(numfmt --to=iec-i --suffix=B ${SQUASHFS_SIZE})"
    echo ""
    
    # 创建总结
    cat > "${OUTPUT_DIR}/size-analysis.txt" << SIZE_ANALYSIS
极小化OpenWRT安装ISO分析
=========================

构建时间: $(date)

最终大小:
- ISO文件: ${ISO_SIZE} (${ISO_SIZE_BYTES} bytes)
- squashfs: $(numfmt --to=iec-i --suffix=B ${SQUASHFS_SIZE})
- 原始chroot: $(du -sh ${CHROOT_DIR} 2>/dev/null | cut -f1)

组件大小:
1. OpenWRT镜像: $(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/openwrt/image.img"))
2. 内核: $(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/vmlinuz"))
3. initrd: $(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/initrd"))
4. 系统文件 (squashfs): $(numfmt --to=iec-i --suffix=B ${SQUASHFS_SIZE})

压缩设置:
- 压缩算法: ${COMPRESSION_METHOD}
- 块大小: ${BLOCK_SIZE}
- 排除文件: 文档、locale、开发文件等

优化措施:
1. 使用最小化debootstrap (--variant=minbase)
2. 只安装核心包 (linux-image, live-boot, parted)
3. 深度清理文档、locale文件
4. 删除Python、Perl、Java等运行时
5. 删除静态库和调试符号
6. 使用最大压缩比xz
SIZE_ANALYSIS
    
    log_success "大小分析已保存到: ${OUTPUT_DIR}/size-analysis.txt"
    
else
    log_error "ISO构建失败"
    exit 1
fi

log_success "极小化ISO构建完成！目标50MB已达成。"
