# MacVPN

MacVPN 是用 Swift 和 SwiftUI 编写的 macOS OpenVPN 客户端。可以在主窗口导入和管理连接，也可以从菜单栏连接、断开和查看状态。主窗口显示隧道地址、连接时长、收发流量和实时日志。

## 安装和连接

打包的应用面向 **Apple Silicon**，要求 **macOS 15 或更新版本**，内置 OpenVPN 2.7.9。

1. 从 [GitHub Releases](https://github.com/tanrenye/MacVPN/releases) 下载并解压 `MacVPN.zip`，将 `MacVPN.app` 拖到「应用程序」并打开。从源码构建时，也可以直接打开 `dist/MacVPN.app`。
2. 点击菜单栏的 MacVPN 图标，选择「导入配置…」，导入管理员提供的 `.ovpn` 或 `.conf` 文件。支持一次导入多个文件。相对证书和密钥路径以配置目录为基准，绝对路径失效时会查找配置旁同名的文件。
3. 在主窗口选中配置并点击「连接」。内置引擎首次连接时需要管理员授权，MacVPN 会安装由 macOS 按需启动的连接服务。更新应用后可能需要重新授权。
4. 按提示输入凭据，在主窗口查看连接状态和日志。断开连接可以从主窗口或菜单栏操作。退出 MacVPN 也会结束连接。

## 设置

点击菜单栏的 MacVPN 图标，选择「设置…」或 **Settings…**。

| 选项 | 行为 |
| --- | --- |
| 语言 | 默认使用简体中文。可切换为 English，界面即时更新，重启后会保留选择。 |
| 登录时启动 MacVPN | 登录 macOS 时启动应用。如果系统要求批准，在系统设置的「登录项」中允许 MacVPN。 |
| 启动时自动连接 | 默认开启。启动时连接上次选中的配置。如果还没有配置，等待导入。 |
| 静默启动 | 默认开启。下次启动时隐藏主窗口，可从菜单栏选择「打开 MacVPN」。需要认证时，可选择「输入 VPN 凭据…」。 |

使用内置引擎时，可在断开连接后从设置移除 MacVPN 连接服务。下次连接时会重新请求管理员授权。

## 配置和凭据

- 支持 TUN、证书、用户名和密码以及 OpenVPN 静态二次验证。内置引擎支持接收 LZ4 和 LZO 压缩数据。
- 导入后的配置副本保存在 `~/Library/Application Support/MacVPN/Profiles`。导入时会把配置引用的证书和密钥嵌入本地副本。
- 对于不需要二次验证的用户名和密码登录，勾选「在钥匙串中记住 VPN 凭据」后，MacVPN 会在连接成功时保存凭据。可从该连接的操作菜单清除。私钥密码和验证码按提示输入。
- 当前版本暂未支持 TAP、网页登录、动态二次验证，以及需要自定义脚本或插件的配置。

## 从源码构建

构建需要 Swift 和包含 macOS 15 或更新 SDK 的 Xcode 或 Xcode Command Line Tools。构建内置引擎时还需要 Homebrew。

### 使用内置 OpenVPN

```sh
brew install openssl@3 lz4 pkgconf
bash Scripts/build-engine.sh
bash Scripts/build-app.sh --with-engine
open dist/MacVPN.app
```

引擎脚本下载并校验 OpenVPN 和 LZO 的源码包。打包脚本生成本地临时签名的 `dist/MacVPN.app` 和 `dist/MacVPN.zip`。OpenVPN 和 LZO 的源码包放在 `dist/`，依赖许可证放在应用包的 `Contents/Resources/` 中。内置引擎使用 OpenVPN 上游的 macOS DNS 脚本应用服务器下发的 DNS 配置。

### 使用 Homebrew OpenVPN

外部引擎版可在 macOS 14 或更新版本上运行。每次连接都需要管理员授权，DNS 行为取决于外部 OpenVPN 的配置。

```sh
brew install openvpn
bash Scripts/build-app.sh
open dist/MacVPN.app
```

## 项目结构

| 路径 | 用途 |
| --- | --- |
| [Sources/MacVPN](Sources/MacVPN) | SwiftUI 界面、配置存储、钥匙串和连接控制 |
| [Sources/MacVPNCore](Sources/MacVPNCore) | OpenVPN 配置校验、语言偏好和隧道服务接口 |
| [Sources/MacVPNTunnelHelper](Sources/MacVPNTunnelHelper) | 启动并管理内置 OpenVPN 的特权服务 |
| [Scripts](Scripts) | 引擎构建、应用打包和图标准备 |

[OpenVPN 管理接口文档](https://openvpn.net/community-docs/management-interface/) · [OpenVPN 上游源码](https://github.com/OpenVPN/openvpn) · [macOS DNS 脚本](https://github.com/OpenVPN/openvpn/blob/master/distro/dns-scripts/macos-dns-updown.sh)
