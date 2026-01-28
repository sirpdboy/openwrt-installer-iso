# 使用指定版本的Alpine作为基础镜像
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

LABEL maintainer="OpenWRT ISO Builder"
LABEL description="用于构建支持BIOS/UEFI双引导的OpenWRT安装ISO"

# 更新包索引并安装构建工具
RUN apk update && apk add --no-cache \
    bash \
    curl \
    wget \
    xorriso \
    mtools \
    dosfstools \
    grub \
    grub-efi \
    syslinux \
    syslinux-efi \
    parted \
    e2fsprogs \
    e2fsprogs-extra \
    util-linux \
    coreutils \
    findutils \
    grep \
    sed \
    gzip \
    tar \
    file \
    fdisk \
    gptfdisk \
    jq \
    gawk \
    p7zip \
    cdrtools \
    squashfs-tools \
    coreutils-sort \
    && rm -rf /var/cache/apk/*

# 创建必要的目录结构
RUN mkdir -p /work /output /tmp/iso

# 复制构建脚本
COPY scripts/build-iso-alpine.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/build-iso-alpine.sh

# 复制include目录（如果存在）
COPY scripts/include/ /usr/local/include/ 2>/dev/null || \
    mkdir -p /usr/local/include && echo "#!/bin/sh" > /usr/local/include/init.sh && chmod +x /usr/local/include/init.sh

# 设置工作目录
WORKDIR /work

# 设置入口点
ENTRYPOINT ["/usr/local/bin/build-iso-alpine.sh"]
