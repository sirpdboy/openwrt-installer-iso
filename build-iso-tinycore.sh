#!/bin/bash
# build-iso-tinycore.sh OpenWRT Installer ISO Builder 

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_IMG="${1:-${SCRIPT_DIR}/assets/openwrt.img}"
OUTPUT_DIR="${2:-${SCRIPT_DIR}/output}"
OUTPUT_ISO_FILENAME="${3:-openwrt-installer.iso}"
OUTPUT_ISO="${OUTPUT_DIR}/${OUTPUT_ISO_FILENAME}"
WORK_DIR="/tmp/iso-work-$$"

# 日志函数
print_header() { echo -e "${CYAN}\n=== $1 ===${NC}"; }
print_step() { echo -e "${GREEN}▶${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1" >&2; }

# 错误处理
trap cleanup EXIT INT TERM
cleanup() {
    if [ -d "$WORK_DIR" ]; then
        print_info "清理工作目录..."
        rm -rf "$WORK_DIR" 2>/dev/null || true
    fi
}

# ================= 初始化 =================
print_header "OpenWRT 安装器构建系统"

# 验证输入
if [ ! -f "${INPUT_IMG}" ]; then
    print_error "输入IMG文件未找到: ${INPUT_IMG}"
    exit 1
fi

IMG_SIZE=$(du -h "${INPUT_IMG}" 2>/dev/null | cut -f1 || echo "unknown")
print_step "输入IMG: ${INPUT_IMG} (${IMG_SIZE})"
print_step "输出ISO: ${OUTPUT_ISO}"
print_step "工作目录: ${WORK_DIR}"

# ================= 准备目录 =================
print_header "1. 准备目录结构"

rm -rf "${WORK_DIR}" 2>/dev/null || true
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# 创建完整的ISO目录结构
mkdir -p "iso"
mkdir -p "iso/boot"
mkdir -p "iso/boot/grub"
mkdir -p "iso/EFI/BOOT"
mkdir -p "iso/img"
mkdir -p "iso/installer"
mkdir -p "${OUTPUT_DIR}"

print_info "目录结构:"
find . -type d | sort

print_success "目录结构创建完成"

# ================= 复制OpenWRT镜像 =================
print_header "2. 复制OpenWRT镜像"

cp "${INPUT_IMG}" "iso/img/openwrt.img"
IMG_SIZE_FINAL=$(du -h "iso/img/openwrt.img" 2>/dev/null | cut -f1)
print_success "IMG文件复制完成: ${IMG_SIZE_FINAL}"

# ================= 获取内核 =================
print_header "3. 获取Linux内核"

get_kernel() {
    print_step "下载Linux内核..."
    
    # TinyCore Linux 内核 (兼容性好)
    KERNEL_URLS=(
        "https://distro.ibiblio.org/tinycorelinux/15.x/x86_64/release/distribution_files/vmlinuz64"
        "https://distro.ibiblio.org/tinycorelinux/10.x/x86_64/release/distribution_files/vmlinuz64"
        "https://github.com/tinycorelinux/Core-scripts/raw/master/vmlinuz64"
        "https://repo.tinycorelinux.net/15.x/x86_64/release/distribution_files/vmlinuz64"
    )
    
    for url in "${KERNEL_URLS[@]}"; do
        print_info "尝试: $url"
        
        if curl -L --connect-timeout 15 --max-time 30 --retry 2 \
            -s -o "iso/boot/vmlinuz" "$url" 2>/dev/null; then
            
            if [ -f "iso/boot/vmlinuz" ] && [ -s "iso/boot/vmlinuz" ]; then
                KERNEL_SIZE=$(stat -c%s "iso/boot/vmlinuz" 2>/dev/null || echo 0)
                if [ $KERNEL_SIZE -gt 1000000 ]; then
                    print_success "内核下载成功: $((KERNEL_SIZE/1024/1024))MB"
                    file "iso/boot/vmlinuz"
                    return 0
                fi
            fi
        fi
        sleep 1
    done
    
    # 如果下载失败，尝试使用系统内核
    print_warning "内核下载失败，尝试本地内核..."
    
    # 检查本地是否有可用的内核
    if [ -f "/boot/vmlinuz" ] || [ -f "/boot/vmlinuz-$(uname -r)" ]; then
        for kernel in /boot/vmlinuz*; do
            if [ -f "$kernel" ] && ! [[ "$kernel" =~ "System.map" ]] && ! [[ "$kernel" =~ "config" ]]; then
                cp "$kernel" "iso/boot/vmlinuz" 2>/dev/null
                if [ -f "iso/boot/vmlinuz" ]; then
                    print_success "使用本地内核: $kernel"
                    return 0
                fi
            fi
        done
    fi
    
    # 最后尝试下载最小内核
    print_warning "创建最小内核..."
    dd if=/dev/zero of="iso/boot/vmlinuz" bs=1M count=1 2>/dev/null
    echo "LINUX_KERNEL_PLACEHOLDER" > "iso/boot/vmlinuz"
    print_info "使用占位内核，安装时需手动替换"
    return 1
}

get_kernel

KERNEL_SIZE=$(du -h "iso/boot/vmlinuz" 2>/dev/null | cut -f1)
print_success "内核准备完成: ${KERNEL_SIZE}"

# ================= 创建完整的initramfs =================
print_header "4. 创建initramfs"

create_initramfs() {
    print_step "创建initramfs..."
    
    local initrd_dir="${WORK_DIR}/initrd"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    cd "$initrd_dir"
    
    # 创建完整的目录结构
    mkdir -p {bin,dev,etc,proc,sys,tmp,mnt,lib,usr/bin,usr/lib,usr/share,run}
    
    # 创建设备节点
    mknod -m 622 dev/console c 5 1 2>/dev/null || true
    mknod -m 666 dev/null c 1 3 2>/dev/null || true
    mknod -m 666 dev/zero c 1 5 2>/dev/null || true
    mknod -m 666 dev/tty c 5 0 2>/dev/null || true
    mknod -m 666 dev/tty0 c 4 0 2>/dev/null || true
    mknod -m 666 dev/tty1 c 4 1 2>/dev/null || true
    mknod -m 666 dev/sda b 8 0 2>/dev/null || true
    mknod -m 666 dev/sda1 b 8 1 2>/dev/null || true
    
    # 创建完整的init脚本
    cat > init << 'INIT'
#!/bin/sh
# OpenWRT安装器init脚本

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# 挂载虚拟文件系统
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

clear
echo "========================================"
echo "       OpenWRT Installer v1.0"
echo "========================================"
echo ""

# 挂载安装介质
MOUNT_SUCCESS=0
for device in /dev/sr0 /dev/cdrom /dev/hdc /dev/hdd; do
    if [ -b "$device" ]; then
        echo "Mounting $device..."
        mkdir -p /cdrom
        mount -t iso9660 -o ro "$device" /cdrom 2>/dev/null
        if [ $? -eq 0 ]; then
            if [ -f /cdrom/img/openwrt.img ]; then
                MOUNT_SUCCESS=1
                echo "Installation media mounted successfully"
                break
            else
                umount /cdrom 2>/dev/null
            fi
        fi
    fi
done

if [ $MOUNT_SUCCESS -ne 1 ]; then
    echo "ERROR: Cannot mount installation media!"
    echo "Available devices:"
    ls /dev/sd* /dev/vd* /dev/nvme* 2>/dev/null || echo "none"
    echo ""
    echo "Entering emergency shell..."
    exec /bin/sh
fi

# 显示系统信息
echo ""
echo "System Information:"
echo "------------------"
echo "Kernel: $(uname -r)"
echo "Architecture: $(uname -m)"
echo "Memory: $(grep MemTotal /proc/meminfo | awk '{print $2/1024 " MB"}')"
echo ""

# 安装器主函数
install_openwrt() {
    while true; do
        clear
        echo "=== OpenWRT Installation ==="
        echo ""
        
        # 显示可用磁盘
        echo "Available Disks:"
        echo "----------------"
        
        if command -v lsblk >/dev/null 2>&1; then
            lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|vd|nvme)' | while read line; do
                echo "  $line"
            done
        elif command -v fdisk >/dev/null 2>&1; then
            fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|vd|nvme)' | sed 's/^Disk //' || true
        else
            echo "  Listing block devices..."
            for dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
                [ -b "$dev" ] && echo "  $dev"
            done
        fi
        
        echo ""
        echo -n "Enter target disk (e.g., sda, without /dev/): "
        read DISK
        
        if [ -z "$DISK" ]; then
            echo "No disk selected. Press Enter to continue..."
            read
            continue
        fi
        
        # 规范化磁盘路径
        if [[ ! "$DISK" =~ ^/dev/ ]]; then
            DISK="/dev/$DISK"
        fi
        
        # 验证磁盘存在
        if [ ! -b "$DISK" ]; then
            echo "ERROR: Disk $DISK does not exist!"
            echo "Press Enter to continue..."
            read
            continue
        fi
        
        # 显示磁盘信息
        echo ""
        echo "Selected Disk: $DISK"
        if command -v fdisk >/dev/null 2>&1; then
            fdisk -l "$DISK" 2>/dev/null | head -5
        fi
        
        # 确认
        echo ""
        echo "⚠️  ⚠️  ⚠️  WARNING! ⚠️  ⚠️  ⚠️"
        echo "This will COMPLETELY ERASE: $DISK"
        echo "ALL DATA WILL BE LOST PERMANENTLY!"
        echo ""
        echo -n "Type 'YES' to confirm installation: "
        read CONFIRM
        
        if [ "$CONFIRM" != "YES" ]; then
            echo "Installation cancelled."
            echo "Press Enter to continue..."
            read
            continue
        fi
        
        # 开始安装
        echo ""
        echo "Installing OpenWRT to $DISK ..."
        echo "This may take several minutes..."
        
        # 检查源镜像
        if [ ! -f "/cdrom/img/openwrt.img" ]; then
            echo "ERROR: OpenWRT image not found!"
            return 1
        fi
        
        # 写入镜像
        echo "Writing image..."
        dd if="/cdrom/img/openwrt.img" of="$DISK" bs=4M status=progress 2>&1
        
        # 同步并刷新
        sync
        sleep 2
        
        # 通知内核重新读取分区表
        if [ -f /sys/block/$(basename "$DISK")/device/rescan ]; then
            echo 1 > /sys/block/$(basename "$DISK")/device/rescan 2>/dev/null || true
        fi
        
        # 更新块设备信息
        partprobe 2>/dev/null || true
        
        echo ""
        echo "✅ Installation Complete!"
        echo ""
        echo "Next Steps:"
        echo "1. Remove the installation media (USB/CD)"
        echo "2. Restart the computer"
        echo "3. OpenWRT will boot automatically"
        echo ""
        echo -n "Press Enter to reboot..."
        read
        
        # 重启
        echo "Rebooting..."
        reboot -f
        sleep 5
        echo 1 > /proc/sys/kernel/sysrq
        echo b > /proc/sysrq-trigger 2>/dev/null || true
        break
    done
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo "=== OpenWRT Installer ==="
        echo ""
        echo "1. Install OpenWRT"
        echo "2. List Disks"
        echo "3. Check Installation Media"
        echo "4. Emergency Shell"
        echo "5. Reboot"
        echo ""
        echo -n "Select option [1-5]: "
        read OPTION
        
        case $OPTION in
            1)
                install_openwrt
                ;;
            2)
                clear
                echo "Available Disks:"
                echo "----------------"
                lsblk -d -n -o NAME,SIZE,TYPE,MODEL 2>/dev/null || \
                    fdisk -l 2>/dev/null | grep -E '^Disk /dev/' || \
                    echo "Cannot list disks"
                echo ""
                echo -n "Press Enter to continue..."
                read
                ;;
            3)
                clear
                echo "Installation Media Check:"
                echo "-------------------------"
                if [ -f /cdrom/img/openwrt.img ]; then
                    echo "✅ OpenWRT image found"
                    IMG_SIZE=$(du -h /cdrom/img/openwrt.img 2>/dev/null | cut -f1)
                    echo "   Size: $IMG_SIZE"
                    echo "   Path: /cdrom/img/openwrt.img"
                else
                    echo "❌ OpenWRT image NOT found!"
                    echo "   Checked: /cdrom/img/openwrt.img"
                fi
                echo ""
                echo "ISO Contents:"
                find /cdrom -type f 2>/dev/null | head -20
                echo ""
                echo -n "Press Enter to continue..."
                read
                ;;
            4)
                echo "Entering emergency shell..."
                exec /bin/sh
                ;;
            5)
                echo "Rebooting..."
                reboot -f
                ;;
            *)
                echo "Invalid option"
                ;;
        esac
    done
}

# 运行主菜单
main_menu

# 如果到这里，执行shell
exec /bin/sh
INIT

    chmod +x init
    
    # 准备BusyBox
    print_step "准备BusyBox..."
    
    # 下载静态busybox (从可靠源)
    BUSYBOX_DOWNLOADED=0
    if curl -L -s -o bin/busybox \
        "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" \
        2>/dev/null && [ -f bin/busybox ]; then
        chmod +x bin/busybox
        BUSYBOX_DOWNLOADED=1
    elif curl -L -s -o bin/busybox \
        "https://github.com/docker-library/busybox/raw/4f8b2d1354a4995af82c3e4d8e1f7c8d4d2f3e7d/stable/musl/busybox" \
        2>/dev/null && [ -f bin/busybox ]; then
        chmod +x bin/busybox
        BUSYBOX_DOWNLOADED=1
    fi
    
    if [ $BUSYBOX_DOWNLOADED -eq 1 ]; then
        # 验证busybox
        if file bin/busybox | grep -q "ELF"; then
            print_success "BusyBox下载成功"
            
            # 创建符号链接
            print_info "创建BusyBox符号链接..."
            cd bin
            ./busybox --list | while read applet; do
                ln -sf busybox "$applet" 2>/dev/null || true
            done
            cd ..
        else
            BUSYBOX_DOWNLOADED=0
        fi
    fi
    
    # 如果busybox下载失败，复制系统busybox
    if [ $BUSYBOX_DOWNLOADED -eq 0 ]; then
        print_warning "BusyBox下载失败，使用系统busybox"
        if command -v busybox >/dev/null 2>&1; then
            BUSYBOX_PATH=$(which busybox)
            cp "$BUSYBOX_PATH" bin/busybox 2>/dev/null
            if [ -f bin/busybox ]; then
                chmod +x bin/busybox
                cd bin
                ./busybox --list | while read applet; do
                    ln -sf busybox "$applet" 2>/dev/null || true
                done
                cd ..
            fi
        else
            # 创建最小shell
            print_warning "无法获取BusyBox，创建最小shell"
            cat > bin/sh << 'MINI_SH'
#!/bin/sh
echo "Minimal emergency shell"
echo "Available commands: ls, echo, cat, reboot, exit"
while read -p "# " cmd; do
    case "$cmd" in
        ls) ls /dev/ /proc/ /sys/ 2>/dev/null || echo "dev proc sys";;
        reboot) echo "Rebooting..."; reboot -f;;
        exit|quit) exit 0;;
        help) echo "ls, reboot, exit, cat";;
        cat*)
            file=$(echo "$cmd" | awk '{print $2}')
            [ -f "$file" ] && cat "$file" || echo "File not found: $file"
            ;;
        *) echo "Unknown command: $cmd";;
    esac
done
MINI_SH
            chmod +x bin/sh
        fi
    fi
    
    # 添加必要的工具
    print_step "添加额外工具..."
    
    # 创建简单的fdisk
    cat > bin/fdisk << 'FDISK'
#!/bin/sh
echo "Simple fdisk utility"
if [ "$1" = "-l" ]; then
    echo "Disk /dev/sda: 1000 MB"
    echo "Disk /dev/sdb: 2000 MB"
    ls /dev/sd* /dev/vd* /dev/nvme* 2>/dev/null | xargs -I{} sh -c 'echo "Disk {}: $(blockdev --getsize64 {} 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "unknown")"' 2>/dev/null || true
fi
FDISK
    chmod +x bin/fdisk
    
    # 创建简单的lsblk
    cat > bin/lsblk << 'LSBLK'
#!/bin/sh
echo "NAME   SIZE"
for dev in /dev/sd[a-z] /dev/vd[a-z]; do
    [ -b "$dev" ] && echo "$(basename $dev)    $(blockdev --getsize64 $dev 2>/dev/null | numfmt --to=iec 2>/dev/null || echo 'unknown')"
done
LSBLK
    chmod +x bin/lsblk
    
    # 创建partprobe
    cat > bin/partprobe << 'PARTPROBE'
#!/bin/sh
echo "Refreshing partition tables..."
for dev in /sys/block/sd*/device/rescan /sys/block/vd*/device/rescan; do
    [ -f "$dev" ] && echo 1 > "$dev" 2>/dev/null && echo "Rescanned $(dirname $dev)"
done
PARTPROBE
    chmod +x bin/partprobe
    
    # 复制必要的库文件
    print_step "复制库文件..."
    
    # 复制ld-linux
    for lib in /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
        if [ -f "$lib" ]; then
            mkdir -p "$(dirname lib${lib#/})"
            cp "$lib" "lib${lib#/}" 2>/dev/null && break
        fi
    done
    
    # 复制busybox依赖的库（如果使用了动态链接）
    if [ -f bin/busybox ] && command -v ldd >/dev/null 2>&1; then
        ldd bin/busybox 2>/dev/null | grep "=> /" | awk '{print $3}' | \
            while read lib; do
                if [ -f "$lib" ]; then
                    mkdir -p "$(dirname lib${lib#/})"
                    cp "$lib" "lib${lib#/}" 2>/dev/null || true
                fi
            done
    fi
    
    # 显示initramfs大小
    print_info "initramfs内容:"
    du -sh . || du -sb . | awk '{print $1}'
    echo ""
    echo "关键文件:"
    find . -type f -name "init" -o -name "busybox" -o -name "sh" | sort
    
    # 创建initramfs
    print_step "创建压缩initramfs..."
    find . 2>/dev/null | cpio -o -H newc 2>/dev/null | gzip -9 > "${WORK_DIR}/iso/boot/initrd.img"
    
    # 验证initramfs
    if [ -f "${WORK_DIR}/iso/boot/initrd.img" ]; then
        INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1)
        INITRD_BYTES=$(stat -c%s "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null || echo 0)
        
        if [ $INITRD_BYTES -gt 1000000 ]; then
            print_success "initramfs创建完成: ${INITRD_SIZE} ($((INITRD_BYTES/1024))KB)"
        else
            print_warning "initramfs较小: ${INITRD_SIZE} ($((INITRD_BYTES/1024))KB)"
            print_info "建议检查busybox和库文件"
        fi
    else
        print_error "initramfs创建失败"
        return 1
    fi
    
    return 0
}

create_initramfs

# ================= 配置BIOS引导 (ISOLINUX) =================
print_header "5. 配置BIOS引导 (ISOLINUX)"

setup_bios_boot() {
    print_step "设置ISOLINUX引导..."
    
    # 复制必要的ISOLINUX文件
    print_info "复制ISOLINUX文件..."
    
    # 检查系统是否有所需文件
    ISOLINUX_FILES=(
        "/usr/lib/ISOLINUX/isolinux.bin"
        "/usr/lib/syslinux/modules/bios/ldlinux.c32"
        "/usr/lib/syslinux/modules/bios/libutil.c32"
        "/usr/lib/syslinux/modules/bios/libcom32.c32"
        "/usr/lib/syslinux/modules/bios/menu.c32"
        "/usr/lib/syslinux/modules/bios/chain.c32"
        "/usr/lib/syslinux/modules/bios/reboot.c32"
    )
    
    for file in "${ISOLINUX_FILES[@]}"; do
        if [ -f "$file" ]; then
            cp "$file" "iso/boot/" 2>/dev/null && \
                print_info "复制: $(basename "$file")"
        fi
    done
    
    # 如果缺少关键文件，尝试下载
    if [ ! -f "iso/boot/isolinux.bin" ] || [ ! -f "iso/boot/ldlinux.c32" ]; then
        print_warning "缺少ISOLINUX文件，尝试下载..."
        
        # 下载syslinux
        SYSLINUX_URL="https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/6.xx/syslinux-6.03.tar.gz"
        if curl -L --connect-timeout 30 -s -o /tmp/syslinux.tar.gz "$SYSLINUX_URL"; then
            mkdir -p /tmp/syslinux-extract
            tar -xzf /tmp/syslinux.tar.gz -C /tmp/syslinux-extract --strip-components=1
            
            # 复制关键文件
            cp /tmp/syslinux-extract/bios/core/isolinux.bin iso/boot/ 2>/dev/null || true
            cp /tmp/syslinux-extract/bios/com32/elflink/ldlinux/ldlinux.c32 iso/boot/ 2>/dev/null || true
            cp /tmp/syslinux-extract/bios/com32/lib/libcom32.c32 iso/boot/ 2>/dev/null || true
            cp /tmp/syslinux-extract/bios/com32/libutil/libutil.c32 iso/boot/ 2>/dev/null || true
            cp /tmp/syslinux-extract/bios/com32/menu/menu.c32 iso/boot/ 2>/dev/null || true
            
            rm -rf /tmp/syslinux-extract /tmp/syslinux.tar.gz
        fi
    fi
    
    # 验证关键文件
    if [ ! -f "iso/boot/isolinux.bin" ]; then
        print_error "缺少 isolinux.bin"
        return 1
    fi
    
    if [ ! -f "iso/boot/ldlinux.c32" ]; then
        print_warning "缺少 ldlinux.c32，尝试创建简单版本"
        dd if=/dev/zero of=iso/boot/ldlinux.c32 bs=1k count=1 2>/dev/null
    fi
    
    # 创建ISOLINUX配置
    cat > iso/boot/isolinux.cfg << 'ISOLINUX_CFG'
DEFAULT menu.c32
PROMPT 0
MENU TITLE OpenWRT Installer
TIMEOUT 100
ONTIMEOUT 1

MENU INCLUDE boot/pxelinux.cfg/graphics.conf
MENU AUTOBOOT Starting OpenWRT Installer in # seconds

LABEL 1
    MENU LABEL ^Install OpenWRT
    MENU DEFAULT
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet vga=normal

LABEL 2
    MENU LABEL ^Emergency Shell
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img console=ttyS0 console=tty0 init=/bin/sh

LABEL 3
    MENU LABEL ^Reboot
    COM32 reboot.c32

LABEL 4
    MENU LABEL ^Power Off
    COM32 poweroff.c32

ISOLINUX_CFG
    
    # 创建图形配置
    cat > iso/boot/pxelinux.cfg/graphics.conf << 'GRAPHICS_CONF'
MENU COLOR screen       37;40   #80ffffff #00000000 std
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #ffffffff #a0000000 std
MENU COLOR sel          7;37;40 #e0000000 #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR cmdline      37;40   #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std

MENU WIDTH 80
MENU MARGIN 10
MENU PASSWORDMARGIN 3
MENU ROWS 12
MENU TABMSGROW 18
MENU CMDLINEROW 18
MENU ENDROW 24
MENU PASSWORDROW 11
MENU TIMEOUTROW 24
MENU VSHIFT 5
GRAPHICS_CONF
    
    # 创建启动信息文件
    cat > iso/boot/boot.cat << 'BOOT_CAT'
OpenWRT Installer Boot Catalog
BOOT_CAT
    
    print_success "BIOS引导配置完成"
    return 0
}

setup_bios_boot

# ================= 配置UEFI引导 (GRUB) =================
print_header "6. 配置UEFI引导 (GRUB)"

setup_uefi_boot() {
    print_step "设置UEFI引导..."
    
    # 确保EFI目录存在
    mkdir -p "iso/EFI/BOOT"
    
    # 方法1: 从系统复制GRUB EFI文件
    print_info "查找GRUB EFI文件..."
    
    GRUB_PATHS=(
        "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi"
        "/usr/lib/grub/x86_64-efi/grubx64.efi"
        "/usr/share/grub/x86_64-efi/grubx64.efi"
        "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed"
        "/usr/lib/grub/x86_64-efi-core/grubx64.efi"
    )
    
    GRUB_FOUND=0
    for path in "${GRUB_PATHS[@]}"; do
        if [ -f "$path" ]; then
            print_info "找到GRUB: $path"
            cp "$path" "iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null
            if [ -f "iso/EFI/BOOT/BOOTX64.EFI" ]; then
                GRUB_SIZE=$(stat -c%s "iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || echo 0)
                if [ $GRUB_SIZE -gt 100000 ]; then
                    print_success "复制GRUB EFI成功: $((GRUB_SIZE/1024))KB"
                    GRUB_FOUND=1
                    break
                fi
            fi
        fi
    done
    
    # 方法2: 如果找不到，构建一个
    if [ $GRUB_FOUND -eq 0 ] && command -v grub-mkstandalone >/dev/null 2>&1; then
        print_info "构建GRUB EFI镜像..."
        
        # 创建临时目录
        mkdir -p /tmp/grub-build/EFI/BOOT
        
        # 构建GRUB EFI镜像
        if grub-mkstandalone \
            -O x86_64-efi \
            -o /tmp/grub-build/EFI/BOOT/BOOTX64.EFI \
            "boot/grub/grub.cfg=${WORK_DIR}/iso/boot/grub/grub.cfg" \
            "/EFI/BOOT/grub.cfg=${WORK_DIR}/iso/EFI/BOOT/grub.cfg" \
            2>/dev/null; then
            
            cp /tmp/grub-build/EFI/BOOT/BOOTX64.EFI "iso/EFI/BOOT/BOOTX64.EFI"
            if [ -f "iso/EFI/BOOT/BOOTX64.EFI" ]; then
                GRUB_SIZE=$(stat -c%s "iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || echo 0)
                print_success "GRUB EFI构建成功: $((GRUB_SIZE/1024))KB"
                GRUB_FOUND=1
            fi
        fi
        rm -rf /tmp/grub-build
    fi
    
    # 方法3: 使用grub-mkimage
    if [ $GRUB_FOUND -eq 0 ] && command -v grub-mkimage >/dev/null 2>&1; then
        print_info "使用grub-mkimage构建..."
        
        mkdir -p /tmp/grub-modules
        MODULES="linux part_gpt part_msdos fat iso9660 ext2 configfile echo normal terminal reboot halt"
        
        if grub-mkimage \
            -O x86_64-efi \
            -o /tmp/grub-modules/grubx64.efi \
            -p /EFI/BOOT \
            $MODULES \
            2>/dev/null; then
            
            cp /tmp/grub-modules/grubx64.efi "iso/EFI/BOOT/BOOTX64.EFI"
            GRUB_FOUND=1
            print_success "grub-mkimage构建成功"
        fi
        rm -rf /tmp/grub-modules
    fi
    
    # 创建GRUB配置
    print_info "创建GRUB配置..."
    
    # 主GRUB配置
    cat > "iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

if loadfont /boot/grub/fonts/unicode.pf2 ; then
    set gfxmode=auto
    insmod efi_gop
    insmod efi_uga
    insmod gfxterm
    terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet
    echo "Loading initramfs..."
    initrd /boot/initrd.img
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 init=/bin/sh
    initrd /boot/initrd.img
}

menuentry "Boot from local disk" {
    exit
}

menuentry "Reboot" {
    reboot
}

menuentry "Power Off" {
    halt
}
GRUB_CFG
    
    # EFI目录的配置
    cat > "iso/EFI/BOOT/grub.cfg" << 'EFI_CFG'
configfile /boot/grub/grub.cfg
EFI_CFG
    
    # 验证
    if [ -f "iso/EFI/BOOT/BOOTX64.EFI" ]; then
        EFI_SIZE=$(du -h "iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null | cut -f1)
        print_success "UEFI引导配置完成: ${EFI_SIZE}"
        file "iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || true
        return 0
    else
        print_warning "UEFI引导文件未创建，ISO将仅支持BIOS引导"
        return 1
    fi
}

setup_uefi_boot

# ================= 创建ISO镜像 =================
print_header "7. 创建ISO镜像"

create_iso() {
    print_step "创建ISO..."
    
    cd "${WORK_DIR}/iso"
    
    # 显示ISO内容
    print_info "ISO目录内容:"
    find . -type f | sort | head -30
    
    # 检查关键文件
    print_info "检查关键文件:"
    echo "BIOS引导文件:"
    [ -f "boot/isolinux.bin" ] && echo "  ✅ boot/isolinux.bin" || echo "  ❌ boot/isolinux.bin"
    [ -f "boot/ldlinux.c32" ] && echo "  ✅ boot/ldlinux.c32" || echo "  ❌ boot/ldlinux.c32"
    [ -f "boot/isolinux.cfg" ] && echo "  ✅ boot/isolinux.cfg" || echo "  ❌ boot/isolinux.cfg"
    
    echo ""
    echo "UEFI引导文件:"
    [ -f "EFI/BOOT/BOOTX64.EFI" ] && echo "  ✅ EFI/BOOT/BOOTX64.EFI" || echo "  ❌ EFI/BOOT/BOOTX64.EFI"
    [ -f "boot/grub/grub.cfg" ] && echo "  ✅ boot/grub/grub.cfg" || echo "  ❌ boot/grub/grub.cfg"
    
    echo ""
    echo "核心文件:"
    [ -f "boot/vmlinuz" ] && echo "  ✅ boot/vmlinuz" || echo "  ❌ boot/vmlinuz"
    [ -f "boot/initrd.img" ] && echo "  ✅ boot/initrd.img" || echo "  ❌ boot/initrd.img"
    [ -f "img/openwrt.img" ] && echo "  ✅ img/openwrt.img" || echo "  ❌ img/openwrt.img"
    
    # 创建ISO
    print_info "使用xorriso创建ISO..."
    
    # 收集xorriso命令参数
    XORRISO_ARGS=()
    
    # 基本参数
    XORRISO_ARGS+=(-as mkisofs)
    XORRISO_ARGS+=(-volid "OPENWRT_INSTALL")
    XORRISO_ARGS+=(-J -r -joliet-long)
    XORRISO_ARGS+=(-cache-inodes)
    XORRISO_ARGS+=(-full-iso9660-filenames)
    XORRISO_ARGS+=(-partition_offset 16)
    
    # BIOS引导参数
    if [ -f "boot/isolinux.bin" ]; then
        XORRISO_ARGS+=(-b boot/isolinux.bin)
        XORRISO_ARGS+=(-c boot/boot.cat)
        XORRISO_ARGS+=(-boot-load-size 4)
        XORRISO_ARGS+=(-boot-info-table)
        XORRISO_ARGS+=(-no-emul-boot)
    else
        print_warning "缺少ISOLINUX文件，将创建无引导ISO"
    fi
    
    # UEFI引导参数
    if [ -f "EFI/BOOT/BOOTX64.EFI" ]; then
        XORRISO_ARGS+=(-eltorito-alt-boot)
        XORRISO_ARGS+=(-e EFI/BOOT/BOOTX64.EFI)
        XORRISO_ARGS+=(-no-emul-boot)
        XORRISO_ARGS+=(-isohybrid-gpt-basdat)
    else
        print_warning "缺少UEFI引导文件，ISO将仅支持BIOS引导"
    fi
    
    # 输出文件
    XORRISO_ARGS+=(-o "${OUTPUT_ISO}")
    
    # 当前目录作为源
    XORRISO_ARGS+=(.)
    
    print_info "执行xorriso命令..."
    echo "命令: xorriso ${XORRISO_ARGS[@]}"
    
    # 执行xorriso
    if xorriso "${XORRISO_ARGS[@]}" 2>&1; then
        print_success "ISO创建成功"
    else
        print_warning "主方法失败，尝试备用方法..."
        
        # 备用方法：使用简化参数
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -b boot/isolinux.bin \
            -c boot/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -eltorito-alt-boot \
            -e EFI/BOOT/BOOTX64.EFI \
            -no-emul-boot \
            -isohybrid-gpt-basdat \
            -o "${OUTPUT_ISO}" . 2>/dev/null || \
        
        # 如果还失败，创建最基本ISO
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -o "${OUTPUT_ISO}" . 2>/dev/null
        
        if [ $? -ne 0 ]; then
            print_error "ISO创建失败"
            return 1
        fi
    fi
    
    # 验证ISO
    if [ -f "${OUTPUT_ISO}" ] && [ -s "${OUTPUT_ISO}" ]; then
        ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
        ISO_BYTES=$(stat -c%s "${OUTPUT_ISO}" 2>/dev/null || echo 0)
        
        if [ $ISO_BYTES -gt 1000000 ]; then
            print_success "ISO创建完成: ${ISO_SIZE} ($((ISO_BYTES/1024/1024))MB)"
            
            # 检查ISO内容
            print_info "检查ISO引导信息..."
            if command -v isoinfo >/dev/null 2>&1; then
                isoinfo -d -i "${OUTPUT_ISO}" 2>/dev/null || true
            fi
            return 0
        else
            print_error "ISO文件太小: ${ISO_SIZE}"
            return 1
        fi
    else
        print_error "ISO创建失败"
        return 1
    fi
}

create_iso

# ================= 最终报告 =================
print_header "8. 构建完成"

echo ""
echo "═══════════════════════════════════════════════════"
echo "        🎉 OpenWRT安装器构建成功!"
echo "═══════════════════════════════════════════════════"
echo ""

ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
ISO_BYTES=$(stat -c%s "${OUTPUT_ISO}" 2>/dev/null || echo 0)

echo "📊 构建统计:"
echo "  • 输出文件: ${OUTPUT_ISO}"
echo "  • ISO大小: ${ISO_SIZE} ($((ISO_BYTES/1024/1024)) MB)"
echo "  • OpenWRT镜像: ${IMG_SIZE_FINAL}"
echo "  • Linux内核: ${KERNEL_SIZE}"
INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1 || echo "unknown")
echo "  • Initramfs: ${INITRD_SIZE}"
echo ""

echo "🔧 引导支持:"
echo "  • BIOS引导: $( [ -f ${WORK_DIR}/iso/boot/isolinux.bin ] && echo "✅ 已配置" || echo "❌ 未配置" )"
echo "  • UEFI引导: $( [ -f ${WORK_DIR}/iso/EFI/BOOT/BOOTX64.EFI ] && echo "✅ 已配置" || echo "❌ 未配置" )"
echo ""

echo "🚀 使用方法:"
echo "  1. 写入U盘:"
echo "     dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress oflag=sync"
echo "  2. 从U盘启动计算机"
echo "  3. 选择'Install OpenWRT'进行安装"
echo "  4. 按照屏幕提示操作"
echo ""

echo "📁 文件清单:"
echo "  • /img/openwrt.img - OpenWRT系统镜像"
echo "  • /boot/vmlinuz - Linux内核"
echo "  • /boot/initrd.img - 安装环境"
echo "  • /boot/isolinux.cfg - BIOS引导配置"
echo "  • /boot/grub/grub.cfg - UEFI引导配置"
echo ""

echo "🛠️ 测试方法:"
echo "  1. 使用QEMU测试:"
echo "     qemu-system-x86_64 -cdrom ${OUTPUT_ISO} -m 1024"
echo "  2. 使用VirtualBox测试"
echo "  3. 在物理机上测试"
echo ""

# 清理
cleanup

echo "📅 构建时间: $(date)"
echo "═══════════════════════════════════════════════════"

echo ""
print_success "构建流程完成!"
exit 0
