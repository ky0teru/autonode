> [!NOTE]
> 本文档基于 v1 版安装脚本，可能已过时。请参阅[最新 README](../README.md)。

*⚠️ 此翻译由自动工具生成，可能存在不准确之处。原始文档以英文为准。*

# 🚀 Remnanode 自动安装脚本

一个自动化的 Bash 脚本，用于部署 Remnanode，并配置 Nginx 代理、所选 Web 服务和 Cloudflare WARP 集成。

## 📋 脚本功能

该脚本从头到尾完全配置服务器，执行以下步骤：

1. **基础设施：** 安装 Docker Engine 和 Docker Compose。
2. **SSL 证书：** 安装 `acme.sh` 并通过 **Let's Encrypt** (独立模式) 颁发证书。
3. **Nginx 代理：** 配置代理服务器（端口 `9443`），提供安全的 HTTPS 访问。
4. **Remnanode：** 安装节点，并自动替换您的 `SECRET_KEY` 和 SSL 证书路径。
5. **安全性：** 配置防火墙 (`ufw`) — 仅打开必要的端口。
6. **Cloudflare WARP：** 下载 WARP 客户端安装程序。

---

## 🌍 其他语言

- [English](../README.md)
- [Русский](README_RU.md)

## 🛠 前提条件

- **操作系统：** Ubuntu 22.04+ 或 Debian 11+。
- **域名：** 您的 A 记录必须指向服务器的 IP。
- **权限：** 以 **root** 或使用 sudo 运行。

## 🚀 安装说明

1. 克隆仓库：
  ```bash
   git clone https://github.com/x1roko/node-setup.git
  ```
2. 进入项目文件夹：
  ```bash
   cd node-setup
  ```
3. 授予执行权限：
  ```bash
   chmod +x install.sh
  ```
4. 运行安装：
  ```bash
   ./install.sh
  ```

## ⌨️ 输入参数

脚本运行时会提示输入：

1. **邮箱** (用于 SSL 注册)。
2. **域名** (例如 `node.domain.com`)。
3. **SECRET_KEY** (来自 Remnawave 控制面板)。
4. **服务选择** (输入编号或按 Enter 随机选择)。

## 📂 项目结构

- `/opt/remnanode/` — 节点配置。
- `/opt/remnanode/nginx/` — Nginx 配置和 SSL 密钥。
- `/opt/[服务名称]/` — 所选 Web 服务的文件。

## ⚠️ 使用的端口


| 端口    | 服务                            |
| ----- | ----------------------------- |
| 443   | xray (或自定义配置)                 |
| 9443  | Web 界面 (HTTPS)                |
| 2222  | Remnanode 节点端口                |
| 40000 | Cloudflare WARP SOCKS5 (无需开放) |