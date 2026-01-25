## 访问数：![hello](https://views.whatilearened.today/views/github/sirpdboy/deplives.svg)[![](https://img.shields.io/badge/TG群-点击加入-FFFFFF.svg)](https://t.me/joinchat/AAAAAEpRF88NfOK5vBXGBQ)

# OpenWRT 安装ISO自动构建

它是一个基于Debian Live系统的img镜像安装器。采用github action构建打包。目前实现了在x86-64设备上 快速安装openwrt的功能。 
![1](https://https://github.com/sirpdboy/openwrt-installer-iso)

自动构建OpenWRT安装ISO的GitHub Actions工作流。

## 特性

- ✅ 双引导支持 (BIOS + UEFI)
- ✅ 交互式安装界面
- ✅ 自动GitHub Releases发布
- ✅ 支持手动触发和定时构建

## 使用方法

## 1. 使用GitHub Actions自动构建

- 1. Fork此仓库
- 2. 在Actions页面启用工作流
- 3. 推送到main分支自动构建

## 2. 手动构建

```

# 1. 克隆或创建项目
git clone https://github.com/sirpdboy/openwrt-installer-iso.git
cd openwrt-installer-iso


# 2. 创建上述文件结构

# 3. 给脚本权限
chmod +x build.sh scripts/*.sh

# 4. 运行构建

./build.sh

# 或者直接运行Docker命令
mkdir -p output assets

# 手动将ezopwrt.img放入assets/目录
docker run --privileged --rm \
  -v $(pwd)/output:/output \
  -v $(pwd)/scripts:/scripts:ro \
  -v $(pwd)/assets/ezopwrt.img:/mnt/ezopwrt.img \
  debian:bullseye-slim \
  /bin/bash -c "
  apt-get update && apt-get install -y xorriso isolinux syslinux-efi grub-pc-bin mtools dosfstools wget curl &&
  /scripts/build-iso.sh
  "

```

# OpenWRT Installer ISO Builder

Convert OpenWRT disk images to bootable auto-installer ISOs with a simple GitHub Action.

## Features

- 🚀 Convert any OpenWRT IMG to bootable ISO
- 💾 Supports both BIOS and UEFI boot
- 🎯 Automatic installer with disk selection
- 🔧 Simple three-parameter interface
- 🐳 Docker-based isolated build environment

## Quick Start

## GitHub Actions

```
name: Build OpenWRT ISO

on:
  workflow_dispatch:
    inputs:
      img_url:
        description: 'OpenWRT IMG URL'
        required: true

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - name: Download OpenWRT IMG
      run: |
        wget -O /tmp/openwrt.img "https://example.com/openwrt.img"
    
    - name: Build ISO
      uses: sirpdboy/openwrt-installer-iso@main
      with:
        INPUT_IMG: "/tmp/openwrt.img"
        OUTPUT_DIR: "./artifacts"
        OUTPUT_ISO_NAME: "my-openwrt-installer.iso"


# Clone the repository

git clone https://github.com/sirpdboy/openwrt-installer-iso.git

cd openwrt-installer-iso

# Make scripts executable

chmod +x dockerrun.sh

# Build ISO
./dockerrun.sh ./openwrt.img ./output openwrt-autoinstall.iso

```

## Direct Docker Usage

```

# Build Docker image
docker build -t openwrt-iso-builder .

# Run build
docker run --rm --privileged \
  -v ./openwrt.img:/mnt/ezopwrt.img:ro \
  -v ./output:/output \
  openwrt-iso-builder


```

## Parameter	Description	Default

- INPUT_IMG	Path to OpenWRT IMG file	/mnt/openwrt.img
- OUTPUT_DIR	Output directory for ISO	/output
- OUTPUT_ISO_NAME	Name of output ISO file	openwrt-autoinstall.iso

## How It Works

- action.yml - GitHub Action interface definition

- dockerrun.sh - Handles Docker setup and parameter passing

- Dockerfile - Defines the build environment

- build.sh - Runs inside container to build ISO

## Project Structure

```

openwrt-installer-iso/
├── action.yml          # GitHub Action definition
├── dockerrun.sh        # Docker runner script
├── Dockerfile          # Docker build configuration
├── build.sh            # ISO builder (runs in container)
├── README.md           # This file
└── LICENSE             # MIT License
Requirements
Docker (for local builds)

Git (for cloning)

Sufficient disk space (2GB+ recommended)

```

License

MIT License - see LICENSE file for details.



## 项目参考
- https://github.com/dpowers86/debian-live
- https://github.com/sirpdboy/openwrt/releases

## Star History

[![Star History Chart](https://github.com/sirpdboy/openwrt-installer-iso)](https://github.com/sirpdboy/openwrt-installer-iso)



## ❤️赞助作者 ⬇️⬇️
#### 项目开发不易 感谢您的支持鼓励。<br>
[![点击这里赞助我](https://img.shields.io/badge/点击这里赞助我-支持作者的项目-orange?logo=github)](https://github.com/sirpdboy/openwrt?tab=readme-ov-file#%E6%8D%90%E5%8A%A9) <br>
