## 访问数：![hello](https://views.whatilearened.today/views/github/sirpdboy/deplives.svg)[![](https://img.shields.io/badge/TG群-点击加入-FFFFFF.svg)](https://t.me/joinchat/AAAAAEpRF88NfOK5vBXGBQ)

# OpenWRT 安装ISO自动构建

它是一个基于Debian Live系统的img镜像安装器。采用github action构建打包。目前实现了在x86-64设备上 快速安装openwrt的功能。 
![1](https://https://github.com/sirpdboy/openwrt-installer-iso)

# OpenWRT Installer ISO Builder

Convert OpenWRT disk images to bootable auto-installer ISOs with a simple GitHub Action.

自动构建OpenWRT安装ISO的GitHub Actions工作流。

## Features

- 🚀 Convert any OpenWRT IMG to bootable ISO
- 💾 Supports both BIOS and UEFI boot
- 🎯 Automatic installer with disk selection
- 🔧 Simple three-parameter interface
- 🐳 Docker-based isolated build environment

## Quick Start


## 使用方法

### 1. 使用GitHub Actions自动构建

- 1. Fork此仓库
- 2. 在Actions页面启用工作流
- 3. 推送到main分支自动构建

### 2. 手动构建

```

# 1. 克隆或创建项目
git clone https://github.com/sirpdboy/openwrt-installer-iso.git
cd openwrt-installer-iso

chmod +x build.sh scripts/*.sh

./build.sh

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

### GitHub Actions

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
```

### Clone the repository

```
git clone https://github.com/sirpdboy/openwrt-installer-iso.git

cd openwrt-installer-iso

# Make scripts executable

chmod +x dockerrun.sh

# Build ISO
./dockerrun.sh ./openwrt.img ./output openwrt-autoinstall.iso

```

### Direct Docker Usage

```

# Build Docker image
docker build -t openwrt-iso-builder .

# Run build
docker run --rm --privileged \
  -v ./openwrt.img:/mnt/ezopwrt.img:ro \
  -v ./output:/output \
  openwrt-iso-builder


```

### Parameter	Description	Default

- INPUT_IMG	Path to OpenWRT IMG file	/mnt/openwrt.img
- OUTPUT_DIR	Output directory for ISO	/output
- OUTPUT_ISO_NAME	Name of output ISO file	openwrt-autoinstall.iso

### How It Works

- action.yml - GitHub Action interface definition

- dockerrun.sh - Handles Docker setup and parameter passing

- Dockerfile - Defines the build environment

- build.sh - Runs inside container to build ISO

### Project Structure

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
- https://github.com/wukongdaily/img-installer


## Star History

[![Star History Chart](https://github.com/sirpdboy/openwrt-installer-iso)](https://github.com/sirpdboy/openwrt-installer-iso)




## 使用与授权相关说明
 
- 本人开源的所有源码，任何引用需注明本处出处，如需修改二次发布必告之本人，未经许可不得做于任何商用用途。


# My other project

- 路由安全看门狗 ：https://github.com/sirpdboy/luci-app-watchdog
- 网络速度测试 ：https://github.com/sirpdboy/luci-app-netspeedtest
- 计划任务插件（原定时设置） : https://github.com/sirpdboy/luci-app-taskplan
- 关机功能插件 : https://github.com/sirpdboy/luci-app-poweroffdevice
- opentopd主题 : https://github.com/sirpdboy/luci-theme-opentopd
- kucat酷猫主题: https://github.com/sirpdboy/luci-theme-kucat
- kucat酷猫主题设置工具: https://github.com/sirpdboy/luci-app-kucat-config
- NFT版上网时间控制插件: https://github.com/sirpdboy/luci-app-timecontrol
- 家长控制: https://github.com/sirpdboy/luci-theme-parentcontrol
- 定时限速: https://github.com/sirpdboy/luci-app-eqosplus
- 系统高级设置 : https://github.com/sirpdboy/luci-app-advanced
- ddns-go动态域名: https://github.com/sirpdboy/luci-app-ddns-go
- 进阶设置（系统高级设置+主题设置kucat/agron/opentopd）: https://github.com/sirpdboy/luci-app-advancedplus
- 网络设置向导: https://github.com/sirpdboy/luci-app-netwizard
- 一键分区扩容: https://github.com/sirpdboy/luci-app-partexp
- lukcy大吉: https://github.com/sirpdboy/luci-app-lukcy


## 捐助

![screenshots](doc/说明3.jpg)

|     <img src="https://img.shields.io/badge/-支付宝-F5F5F5.svg" href="#赞助支持本项目-" height="25" alt="图飞了"/>  |  <img src="https://img.shields.io/badge/-微信-F5F5F5.svg" height="25" alt="图飞了" href="#赞助支持本项目-"/>  | 
| :-----------------: | :-------------: |
![xm1](doc/支付宝.png) | ![xm1](doc/微信.png) |
