# OpenWRT 安装ISO自动构建

自动构建OpenWRT安装ISO的GitHub Actions工作流。

## 特性

- ✅ 自动下载最新OpenWRT镜像
- ✅ 双引导支持 (BIOS + UEFI)
- ✅ 交互式安装界面
- ✅ 自动GitHub Releases发布
- ✅ 支持手动触发和定时构建

## 使用方法

### 1. 使用GitHub Actions自动构建

1. Fork此仓库
2. 在Actions页面启用工作流
3. 推送到main分支自动构建

### 2. 手动构建

```bash
# 克隆仓库
git clone https://github.com/yourname/openwrt-installer-iso.git
cd openwrt-installer-iso

# 放置OpenWRT镜像 (可选)
cp your-openwrt.img assets/openwrt.img

# 本地构建
chmod +x scripts/*
./scripts/build-iso.sh
