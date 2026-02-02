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
    rsync \
    upx

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
MINIMAL_PACKAGES="locales,linux-image-amd64,live-boot,systemd-sysv,parted,pv,dialog"

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

# 安装最小工具集（已经通过debootstrap安装了）
# 只安装缺失的
apt-get install -y --no-install-recommends \
    locales \
    live-boot \
    live-boot-initramfs-tools

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

# 等待网络
echo "等待网络连接..."
for i in {1..20}; do
    if ping -c1 -W1 8.8.8.8 &>/dev/null; then
        echo "网络就绪"
        break
    fi
    sleep 1
done

# 检查OpenWRT镜像
if [ -f /mnt/openwrt/image.img ]; then
    cp /mnt/openwrt/image.img /openwrt.img
    echo "✅ 找到OpenWRT镜像"
    echo "大小: $(ls -lh /openwrt.img | awk '{print $5}')"
else
    echo "❌ 找不到OpenWRT镜像"
    echo "按回车键进入shell..."
    read
    exec /bin/bash
fi

while true; do
    echo ""
    echo "可用磁盘:"
    lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^[sh]d|^nvme|^vd' || echo "未找到磁盘"
    echo ""
    
    read -p "输入磁盘名称 (如: sda): " DISK
    
    if [ -z "$DISK" ]; then
        continue
    fi
    
    if [ ! -b "/dev/$DISK" ]; then
        echo "❌ 磁盘 /dev/$DISK 不存在"
        continue
    fi
    
    # 显示磁盘信息
    echo ""
    echo "磁盘信息 /dev/$DISK:"
    fdisk -l "/dev/$DISK" 2>/dev/null | head -10
    
    echo ""
    echo "⚠️ ⚠️ ⚠️  警告: 将擦除 /dev/$DISK 上的所有数据！ ⚠️ ⚠️ ⚠️"
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
Conflicts=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/opt/install.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes

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
Type=idle
OVERRIDE

# 配置SSH允许root登录（可选）
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PermitEmptyPasswords yes" >> /etc/ssh/sshd_config
systemctl enable ssh

echo "✅ 基本配置完成"
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
    # 尝试标准位置
    if [ -f "${CHROOT_DIR}/boot/vmlinuz" ]; then
        KERNEL_FILE="${CHROOT_DIR}/boot/vmlinuz"
    else
        exit 1
    fi
fi

if [ -z "$INITRD_FILE" ] || [ ! -f "$INITRD_FILE" ]; then
    log_error "找不到initrd文件"
    # 尝试标准位置
    if [ -f "${CHROOT_DIR}/boot/initrd.img" ]; then
        INITRD_FILE="${CHROOT_DIR}/boot/initrd.img"
    else
        # 在chroot中生成
        chroot "${CHROOT_DIR}" /bin/bash -c "update-initramfs -c -k all" 2>&1 | tee /tmp/make-initrd.log
        INITRD_FILE=$(find "${CHROOT_DIR}" -name "initrd.img*" -type f | head -1)
        if [ ! -f "$INITRD_FILE" ]; then
            exit 1
        fi
    fi
fi

log_success "找到内核: $(basename $KERNEL_FILE) ($(numfmt --to=iec-i --suffix=B $(stat -c%s "$KERNEL_FILE")))"
log_success "找到initrd: $(basename $INITRD_FILE) ($(numfmt --to=iec-i --suffix=B $(stat -c%s "$INITRD_FILE")))"

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

# ====== 深度清理chroot以实现50MB目标 ======
log_info "执行深度清理以减小squashfs大小..."

# 1. 删除所有文档和手册
rm -rf "${CHROOT_DIR}/usr/share/doc" "${CHROOT_DIR}/usr/share/man" "${CHROOT_DIR}/usr/share/info"
mkdir -p "${CHROOT_DIR}/usr/share/doc" "${CHROOT_DIR}/usr/share/man" "${CHROOT_DIR}/usr/share/info"

# 2. 删除所有非英语locale
find "${CHROOT_DIR}/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name 'en*' -exec rm -rf {} + 2>/dev/null || true
# 只保留最基本的en_US locale文件
find "${CHROOT_DIR}/usr/share/locale" -type f ! -name '*.mo' -delete 2>/dev/null || true

# 3. 删除时区数据（只保留UTC）
rm -rf "${CHROOT_DIR}/usr/share/zoneinfo" 2>/dev/null || true
mkdir -p "${CHROOT_DIR}/usr/share/zoneinfo/posix"
echo "UTC" > "${CHROOT_DIR}/usr/share/zoneinfo/UTC"
ln -sf ../UTC "${CHROOT_DIR}/usr/share/zoneinfo/posix/UTC" 2>/dev/null || true

# 4. 删除字体
rm -rf "${CHROOT_DIR}/usr/share/fonts" 2>/dev/null || true

# 5. 删除terminfo数据库（只保留linux和xterm）
rm -rf "${CHROOT_DIR}/usr/share/terminfo" 2>/dev/null || true
mkdir -p "${CHROOT_DIR}/usr/share/terminfo/l" "${CHROOT_DIR}/usr/share/terminfo/x"
touch "${CHROOT_DIR}/usr/share/terminfo/l/linux"
touch "${CHROOT_DIR}/usr/share/terminfo/x/xterm"

# 6. 删除内核模块中的不必要驱动
KERNEL_MODULES_DIR="${CHROOT_DIR}/lib/modules"
if [ -d "$KERNEL_MODULES_DIR" ]; then
    # 保留基本驱动：文件系统、USB、SCSI、NVME
    KERNEL_VERSION=$(ls "$KERNEL_MODULES_DIR" | head -1)
    MODULES_PATH="${KERNEL_MODULES_DIR}/${KERNEL_VERSION}/kernel"
    
    # 删除无线、蓝牙、声音、视频等驱动
    for dir in drivers/net/wireless drivers/bluetooth drivers/media drivers/gpu sound; do
        rm -rf "${MODULES_PATH}/${dir}" 2>/dev/null || true
    done
    
    # 保留必要驱动
    KEEP_MODULES="ext4 fat vfat ntfs exfat usb-storage usbhid ehci-pci ohci-pci uhci-hcd xhci-pci sd_mod sr_mod scsi_mod ata_generic ahci nvme loop isofs squashfs overlay"
    
    # 查找并删除不必要的.ko文件
    find "${KERNEL_MODULES_DIR}" -name "*.ko" -type f | while read ko; do
        keep=0
        for module in $KEEP_MODULES; do
            if [[ "$ko" == *"/${module}.ko" ]] || [[ "$ko" == *"/${module}/"* ]]; then
                keep=1
                break
            fi
        done
        if [ $keep -eq 0 ]; then
            rm -f "$ko" 2>/dev/null || true
        fi
    done
fi

# 7. 删除Python、Perl、Ruby等运行时
rm -rf "${CHROOT_DIR}/usr/lib/python"* "${CHROOT_DIR}/usr/lib/python"* 2>/dev/null || true
rm -rf "${CHROOT_DIR}/usr/share/python"* 2>/dev/null || true
rm -rf "${CHROOT_DIR}/usr/lib/perl"* "${CHROOT_DIR}/usr/share/perl"* 2>/dev/null || true
rm -rf "${CHROOT_DIR}/usr/lib/ruby" "${CHROOT_DIR}/usr/share/ruby" 2>/dev/null || true

# 8. 删除静态库和开发文件
find "${CHROOT_DIR}" -name "*.a" -type f -delete 2>/dev/null || true
find "${CHROOT_DIR}" -name "*.la" -type f -delete 2>/dev/null || true
rm -rf "${CHROOT_DIR}/usr/include" 2>/dev/null || true
mkdir -p "${CHROOT_DIR}/usr/include"

# 9. 使用upx压缩二进制文件
log_info "使用upx压缩二进制文件..."
if command -v upx >/dev/null 2>&1; then
    # 压缩较大的二进制文件
    for binary in "${CHROOT_DIR}/bin/"* "${CHROOT_DIR}/usr/bin/"* "${CHROOT_DIR}/sbin/"* "${CHROOT_DIR}/usr/sbin/"*; do
        if [ -f "$binary" ] && [ -x "$binary" ]; then
            # 检查文件类型
            if file "$binary" | grep -q "ELF.*executable"; then
                # 检查文件大小（只压缩较大的文件）
                size=$(stat -c%s "$binary" 2>/dev/null || echo 0)
                if [ $size -gt 100000 ]; then  # 大于100KB
                    upx --best "$binary" 2>/dev/null || true
                fi
            fi
        fi
    done
fi

# 10. 删除缓存和临时文件
rm -rf "${CHROOT_DIR}/var/cache/apt" "${CHROOT_DIR}/var/lib/apt/lists"
rm -rf "${CHROOT_DIR}/tmp"/* "${CHROOT_DIR}/var/tmp"/*
mkdir -p "${CHROOT_DIR}/tmp" "${CHROOT_DIR}/var/tmp"

# 11. 删除日志文件
rm -rf "${CHROOT_DIR}/var/log"/*
mkdir -p "${CHROOT_DIR}/var/log"

# 检查清理后的大小
CLEANED_SIZE=$(du -sb "${CHROOT_DIR}" | cut -f1)
log_info "深度清理后chroot大小: $(numfmt --to=iec-i --suffix=B ${CLEANED_SIZE})"

# ====== 创建极致压缩的squashfs ======
log_info "创建极致压缩的squashfs（目标50MB）..."
SQUASHFS_FILE="${STAGING_DIR}/live/filesystem.squashfs"

# 创建排除列表
EXCLUDE_FILE="${WORK_DIR}/exclude.list"
cat > "$EXCLUDE_FILE" << 'EXCLUDE_EOF'
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
/usr/share/locale/*/*
/usr/share/locale/[a-df-z]*
/usr/share/locale/e[a-tv-z]*
/usr/share/zoneinfo/[!U]*
/usr/share/zoneinfo/posix
/usr/share/fonts/*
/usr/share/terminfo/*
/usr/share/X11/*
/usr/share/backgrounds/*
/usr/include/*
/usr/lib/debug/*
/usr/lib/*/debug/*
/usr/lib/pkgconfig/*
/usr/share/pkgconfig/*
/usr/lib/python*
/usr/share/python*
/usr/lib/perl*
/usr/share/perl*
/usr/lib/ruby*
/usr/share/ruby*
*.a
*.la
*.debug
*~
*.bak
*.old
*.log
/mnt/openwrt
/opt/install.sh
EXCLUDE_EOF

# 尝试不同的压缩方法找到最小的大小
COMPRESSION_METHODS=("xz" "gzip" "lz4")
BEST_SIZE=999999999
BEST_METHOD=""

for METHOD in "${COMPRESSION_METHODS[@]}"; do
    log_info "测试压缩方法: $METHOD"
    
    TEST_FILE="${WORK_DIR}/test-${METHOD}.squashfs"
    
    case $METHOD in
        "xz")
            COMP_OPTS="-comp xz -Xdict-size 100% -Xbcj x86"
            BLOCK_SIZE="1M"
            ;;
        "gzip")
            COMP_OPTS="-comp gzip -Xcompression-level 9"
            BLOCK_SIZE="512K"
            ;;
        "lz4")
            COMP_OPTS="-comp lz4 -Xhc"
            BLOCK_SIZE="1M"
            ;;
    esac
    
    if mksquashfs "${CHROOT_DIR}" "${TEST_FILE}" \
        ${COMP_OPTS} \
        -b ${BLOCK_SIZE} \
        -noappend \
        -no-recovery \
        -always-use-fragments \
        -no-duplicates \
        -all-root \
        -ef "$EXCLUDE_FILE" 2>&1 >/dev/null; then
        
        SIZE=$(stat -c%s "${TEST_FILE}")
        log_info "$METHOD 压缩后大小: $(numfmt --to=iec-i --suffix=B ${SIZE})"
        
        if [ $SIZE -lt $BEST_SIZE ]; then
            BEST_SIZE=$SIZE
            BEST_METHOD=$METHOD
            cp "${TEST_FILE}" "${SQUASHFS_FILE}"
        fi
    fi
done

log_success "最佳压缩方法: ${BEST_METHOD}, 大小: $(numfmt --to=iec-i --suffix=B ${BEST_SIZE})"

# 如果还是太大，尝试更小的块大小
if [ $BEST_SIZE -gt 55000000 ]; then  # 如果大于55MB
    log_info "大小仍较大，尝试更激进的压缩..."
    
    # 使用256K块大小
    mksquashfs "${CHROOT_DIR}" "${SQUASHFS_FILE}" \
        -comp xz -Xdict-size 100% \
        -b 256K \
        -noappend \
        -no-recovery \
        -always-use-fragments \
        -no-duplicates \
        -all-root \
        -ef "$EXCLUDE_FILE" 2>&1 | tee /tmp/squashfs-final.log
    
    FINAL_SIZE=$(stat -c%s "${SQUASHFS_FILE}")
    log_success "最终squashfs大小: $(numfmt --to=iec-i --suffix=B ${FINAL_SIZE})"
else
    FINAL_SIZE=$BEST_SIZE
fi

# 创建live-boot标记
echo "live" > "${STAGING_DIR}/live/filesystem.squashfs.type"

# ====== 复制内核和initrd ======
log_info "复制内核和initrd..."

cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"

log_success "内核: vmlinuz ($(ls -lh ${STAGING_DIR}/live/vmlinuz | awk '{print $5}'))"
log_success "initrd: initrd ($(ls -lh ${STAGING_DIR}/live/initrd | awk '{print $5}'))"

# 验证文件
log_info "验证文件类型:"
file "${STAGING_DIR}/live/vmlinuz"
file "${STAGING_DIR}/live/initrd"

# ====== 创建引导配置 ======
log_info "创建引导配置..."

# 1. ISOLINUX配置
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
  TEXT HELP
  Automatically install OpenWRT to disk
  ENDTEXT

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet single
  TEXT HELP
  Start rescue shell for troubleshooting
  ENDTEXT
ISOLINUX_CFG

# 2. GRUB配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live components quiet single
    initrd /live/initrd
}
GRUB_CFG

# 复制引导文件
log_info "复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 复制必要的syslinux模块
for module in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32; do
    if [ -f "/usr/lib/syslinux/modules/bios/${module}" ]; then
        cp "/usr/lib/syslinux/modules/bios/${module}" "${STAGING_DIR}/isolinux/"
    elif [ -f "/usr/share/syslinux/${module}" ]; then
        cp "/usr/share/syslinux/${module}" "${STAGING_DIR}/isolinux/"
    fi
done

# ====== 创建UEFI引导 ======
log_info "创建UEFI引导..."

if command -v grub-mkstandalone >/dev/null 2>&1; then
    mkdir -p "${WORK_DIR}/grub-efi"
    
    # 创建简单的GRUB配置
    cat > "${WORK_DIR}/grub-efi/grub.cfg" << 'GRUB_EFI_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet
    initrd /live/initrd
}
GRUB_EFI_CFG
    
    # 生成EFI文件
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
                "${WORK_DIR}/grub-efi/bootx64.efi" ::/EFI/BOOT/BOOTX64.EFI 2>/dev/null && \
            log_success "UEFI引导文件创建完成"
        else
            log_warning "mtools不可用，跳过UEFI引导复制"
            rm -f "${STAGING_DIR}/EFI/boot/efiboot.img"
        fi
    else
        log_warning "GRUB EFI文件生成失败，跳过UEFI引导"
    fi
fi

# ====== 构建ISO镜像 ======
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# 基础xorriso命令
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

# 如果有EFI引导，添加参数
if [ -f "${STAGING_DIR}/EFI/boot/efiboot.img" ]; then
    XORRISO_CMD="${XORRISO_CMD} \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot"
fi

# 执行构建
log_info "执行构建命令..."
eval $XORRISO_CMD 2>&1 | tee /tmp/xorriso.log

# ====== 验证和输出结果 ======
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    ISO_SIZE_BYTES=$(stat -c%s "$ISO_PATH")
    
    echo ""
    echo "================================================================================"
    log_success "✅ ISO构建成功！"
    echo "================================================================================"
    echo ""
    echo "📊 构建摘要："
    echo "  ISO文件: ${ISO_NAME}"
    echo "  总大小: ${ISO_SIZE} ($(numfmt --to=iec-i --suffix=B ${ISO_SIZE_BYTES}))"
    echo "  squashfs: $(numfmt --to=iec-i --suffix=B ${FINAL_SIZE})"
    echo "  压缩方法: ${BEST_METHOD}"
    echo "  块大小: ${BLOCK_SIZE}"
    echo ""
    
    # 显示压缩统计
    ORIGINAL_SIZE=$(du -sb "${CHROOT_DIR}" 2>/dev/null | cut -f1 || echo 0)
    if [ $ORIGINAL_SIZE -gt 0 ]; then
        COMPRESSION_RATIO=$(( ${FINAL_SIZE} * 100 / $ORIGINAL_SIZE ))
        echo "📈 压缩统计："
        echo "  原始大小: $(numfmt --to=iec-i --suffix=B ${ORIGINAL_SIZE})"
        echo "  压缩后: $(numfmt --to=iec-i --suffix=B ${FINAL_SIZE})"
        echo "  压缩比: ${COMPRESSION_RATIO}%"
        echo ""
    fi
    
    # 检查是否达到50MB目标
    if [ $FINAL_SIZE -le 55000000 ]; then
        log_success "🎉 成功！squashfs大小控制在50MB左右"
    else
        log_warning "⚠️  squashfs大小为$(numfmt --to=iec-i --suffix=B ${FINAL_SIZE})，略超50MB目标"
    fi
    
    # 创建构建信息文件
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO (极小化版)
=======================================
构建时间: $(date)
ISO文件: ${ISO_NAME}
总大小: ${ISO_SIZE} (${ISO_SIZE_BYTES} bytes)

组件大小:
- OpenWRT镜像: $(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/openwrt/image.img"))
- 内核: $(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/vmlinuz"))
- initrd: $(numfmt --to=iec-i --suffix=B $(stat -c%s "${STAGING_DIR}/live/initrd"))
- 系统文件 (squashfs): $(numfmt --to=iec-i --suffix=B ${FINAL_SIZE})

压缩设置:
- 最佳压缩方法: ${BEST_METHOD}
- 块大小: ${BLOCK_SIZE}
- 目标大小: 50MB

支持引导: BIOS $( [ -f "${STAGING_DIR}/EFI/boot/efiboot.img" ] && echo "+ UEFI" )

使用方法:
1. 刻录到U盘: sudo dd if=${ISO_NAME} of=/dev/sdX bs=4M status=progress
2. 从U盘启动计算机
3. 系统将自动启动安装程序
4. 选择目标磁盘并输入'YES'确认安装
5. 等待安装完成自动重启

警告: 安装会完全擦除目标磁盘上的所有数据！
BUILD_INFO
    
    log_success "构建信息已保存到: ${OUTPUT_DIR}/build-info.txt"
    
    echo ""
    echo "🚀 ISO已准备好，可以用于安装OpenWRT！"
    
else
    log_error "ISO构建失败"
    echo "错误日志:"
    tail -20 /tmp/xorriso.log
    exit 1
fi

log_success "所有步骤完成！"
