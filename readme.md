# Arch + Hyprland 虚拟机一键安装脚本

这是一个用于 **Arch Linux 虚拟机** 的一键安装脚本，目标是在最短时间内搭建一个：

- 可用的 Hyprland 桌面环境
- 完整中文输入法支持
- 已安装 Chrome 和微信
- 适合学习、体验和日常轻度使用

本项目**不修改内核、不做危险操作**，适合直接放在 GitHub 使用。

---

## 功能说明

脚本会自动完成以下内容：

### 桌面与系统
- Hyprland（Wayland 平铺窗口管理器）
- Waybar（状态栏）
- Wofi（应用启动器）
- Kitty（终端）
- Thunar（文件管理器）
- SDDM（登录管理器）

### 中文支持
- fcitx5 输入法框架
- Rime 中文输入法
- 系统语言设置为 `zh_CN.UTF-8`

### 常用软件
- Google Chrome（AUR 方式安装）
- 微信（Flatpak / Flathub 官方源）

### 基础环境
- NetworkManager（网络）
- PipeWire（音频）
- 常用字体（含中文与 Emoji）

---

## 使用前要求

请确认以下条件全部满足：

- 已完成 **Arch Linux 基础安装**
- 系统可以正常联网
- 当前用户是 **普通用户（非 root）**
- 当前用户拥有 `sudo` 权限
- 系统已安装 `curl`

⚠️ **不要在 root 用户下运行脚本**

---

## 一键安装（推荐方式）

在 Arch 虚拟机中，直接执行以下**单行命令**：

```bash
curl -fsSL https://raw.githubusercontent.com/louisong1021-ux/Hyprland/main/install.sh
