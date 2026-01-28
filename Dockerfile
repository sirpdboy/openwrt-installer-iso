# 使用指定版本的Alpine作为基础镜像
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

LABEL maintainer="OpenWRT ISO Builder"
LABEL description="用于构建支持BIOS/UEFI双引导的OpenWRT安装ISO"

# 安装构建工具
RUN apk add --no-cache --no-scripts \
    bash \
    curl \
    wget \
    xorriso \
    mtools \
    dosfstools \
    grub-efi \
    grub-bios \
    syslinux \
    syslinux-bios \
    squashfs-tools \
    parted \
    e2fsprogs \
    util-linux \
    coreutils \
    findutils \
    grep \
    sed \
    gzip \
    tar \
    file \
    sfdisk \
    fdisk \
    gptfdisk \
    coreutils-sort \
    jq \
    gawk

# 创建必要的目录结构
RUN mkdir -p /work /output /tmp/iso /tmp/rootfs /tmp/efi /tmp/bios

# 复制构建脚本
COPY scripts/build-iso-alpine.sh /usr/local/bin/
COPY scripts/include/ /usr/local/include/

# 设置执行权限
RUN chmod +x /usr/local/bin/build-iso-alpine.sh && \
    find /usr/local/include -type f -name "*.sh" -exec chmod +x {} \;

# 设置工作目录
WORKDIR /work

# 设置入口点
ENTRYPOINT ["/usr/local/bin/build-iso-alpine.sh"]
