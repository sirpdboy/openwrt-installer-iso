FROM debian:buster-slim

# 设置环境变量
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# 安装必要工具
RUN apt-get update && \
    apt-get install -y \
        debootstrap \
        squashfs-tools \
        xorriso \
        isolinux \
        syslinux \
        syslinux-common \
        grub-pc-bin \
        grub-efi-amd64-bin \
        mtools \
        dosfstools \
        parted \
        wget \
        curl \
        gnupg \
        dialog \
        live-boot \
        live-boot-initramfs-tools \
        pv \
        file \
        gdisk \
        cifs-utils \
        nfs-common \
        ntfs-3g \
        open-vm-tools \
        ca-certificates \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 复制构建脚本
COPY build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/build.sh

# 设置工作目录
WORKDIR /build

# 创建必要目录
RUN mkdir -p /mnt /output

# 设置入口点
ENTRYPOINT ["/usr/local/bin/build.sh"]
