FROM alpine:3.20

# Method 1: Install packages BEFORE creating triggers directory
RUN echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories

# Create fake triggers directory to prevent real triggers from running
RUN mkdir -p /etc/apk/scripts.fake && \
    rm -rf /etc/apk/scripts && \
    ln -sf /etc/apk/scripts.fake /etc/apk/scripts

# Install packages with --no-scripts to avoid triggers
RUN apk update && \
    apk add --no-scripts --no-cache \
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
        coreutils \
        findutils \
        grep \
        util-linux

# Now install syslinux and grub separately with force
RUN apk add --no-scripts --no-cache --force syslinux && \
    apk add --no-scripts --no-cache --force grub grub-efi

# Verify installation
RUN which xorriso && which mkfs.vfat && which mcopy && which cpio

# Copy build script
COPY build-openwrt-alpine-iso.sh /usr/local/bin/build-iso
RUN chmod +x /usr/local/bin/build-iso

# Create directories
RUN mkdir -p /build /output

WORKDIR /build
VOLUME /output

ENTRYPOINT ["/usr/local/bin/build-iso"]
