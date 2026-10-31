# AdGuardHomeFree

一个基于 **AdGuard Home** 的**系统级 DNS 去广告**模块，支持 **Magisk / KernelSU / APatch** 三类 root 框架。

模块通过 `iptables` 把设备的 DNS 查询（IPv4 + IPv6，TCP/UDP 53）重定向到本地
AdGuard Home 实例，由 AdGuard Home 完成广告/跟踪域名拦截与转发。默认内置
阿里云/腾讯 DoH 上游，无需 root 之外任何额外配置即可生效。

---

## 特性

- **全栈去广告**：DNS 层拦截广告与跟踪域名，同时接管本机与热点客户端流量。
- **IPv4 + IPv6**：`iptables` 与 `ip6tables` 双栈接管，避免 IPv6 DNS 旁路。
- **三种框架**：Magisk、KernelSU、APatch 均兼容。
- **自动构建**：GitHub Actions 从 AdGuard Home 官方 Release 拉取最新二进制并打包。
- **进程守护**：内置看门狗，异常退出后有限次自动重启，超限后自动回滚 DNS 接管。
- **WebUI**：提供模块状态查看、启动/停止、跳转管理台的内置页面。

## 安装

1. 从 [Releases](https://github.com/YuyuAww/AdGuardHomeFree/releases) 下载
   `AdGuardHomeFree-<版本>-module.zip`。
2. 在 Magisk Manager / KernelSU Manager / APatch 中安装该 ZIP。
3. 重启设备。

> 更新：直接安装新版本 ZIP 即可，`/data/adb/agh/AdGuardHome.yaml` 中的用户配置会被保留。

## 默认配置

| 项 | 值 |
|---|---|
| DNS 监听端口 | `5591`（0.0.0.0 / ::） |
| Web 管理台 | `http://127.0.0.1:3000` |
| 控制台 API | `http://127.0.0.1:5592`（WebUI 状态/启停） |
| 运行时目录 | `/data/adb/agh`（配置、日志、运行锁） |
| 上游 DNS | 阿里云 `https://dns.alidns.com/dns-query`、腾讯 `https://doh.pub/dns-query` |
| Bootstrap DNS | `223.5.5.5`、`119.29.29.29` |

配置、日志、规则在首次安装时从模块模板初始化；此后修改配置请编辑
`/data/adb/agh/AdGuardHome.yaml` 并重启模块（或调用控制台 API 重启）。

> **首次访问管理台**：由于未预置管理员账号，首次打开 `http://127.0.0.1:3000`
> 会进入 AdGuard Home 初始化向导，设置管理员密码即可。DNS 过滤在设置前后均生效。

## 模块目录结构

```
AdGuardHomeFree/
├─ module.prop          # 模块元信息（含 update 自动更新源）
├─ customize.sh         # 安装/更新入口：初始化运行时目录、回填配置
├─ post-fs-data.sh      # /data 挂载后早期准备
├─ service.sh           # 启动 AdGuardHome、接管 DNS、拉起看门狗与 WebUI
├─ uninstall.sh         # 卸载清理（停止进程、清 iptables、删除数据）
├─ sepolicy.rule        # SELinux 补充策略
├─ update.json          # Magisk 模块管理器自动更新清单
├─ bin/
│  ├─ AdGuardHome       # AdGuard Home 可执行文件（CI 下载，不入库）
│  └─ AdGuardHome.yaml  # 默认配置模板
├─ scripts/
│  ├─ common.sh         # 公共函数/常量（端口、日志、进程管理）
│  ├─ iptables.sh       # IPv4/IPv6 DNS 重定向（apply/clear）
│  ├─ watchdog.sh       # 主进程守护
│  ├─ control.sh        # 控制动作（status/start/stop/restart）+ busybox httpd 控制台
│  └─ api.cgi           # httpd CGI 薄封装，委托给 control.sh
└─ webroot/
   └─ index.html        # 模块 WebUI 页面（KSU/APatch 桥接 + 浏览器兜底）
```

## 本地构建

需要 PowerShell 5.1 或 7+ 与 `tar`（Windows 10 1803+ 自带）。有两种方式：

**方式一：自动下载二进制并打包**

```powershell
# 解析 GitHub latest release 并下载 arm64 二进制
./build.ps1 -DownloadBinary

# 指定 AdGuard Home 版本
./build.ps1 -AghVersion v0.107.55 -DownloadBinary

# 32 位 ARM 设备
./build.ps1 -DownloadBinary -Arch arm
```

**方式二：手动放置二进制**

将对应架构的 `AdGuardHome` 可执行文件放到 `bin/AdGuardHome`（gitignore 已忽略，
不会提交），再运行：

```powershell
./build.ps1 -AghVersion local
```

产物输出到 `dist/AdGuardHomeFree-<版本>-module.zip`。

## CI 自动构建

`.github/workflows/build-and-package.yml` 在推送/PR 时：

1. 解析最新 AdGuard Home 版本（或 `workflow_dispatch` 传入 `agh_version`）。
2. 下载并校验 arm64 二进制（ELF 检查）。
3. 静态语法检查所有 shell 脚本（`sh -n`）、规范化行尾为 LF。
4. 打包模块 ZIP，上传为 artifact，并在 `push` 到主分支时创建/更新 GitHub Release。

> 多架构：默认仅构建 `arm64`（绝大多数 Android 设备）。如需 `arm`/`amd64`，
> 可在 workflow 中扩展 `matrix` 或本地 `-Arch` 指定。

## WebUI 与自动更新

- **WebUI**：KernelSU / APatch 会在管理器的 WebView 中加载 `webroot/index.html`
  （origin 为 `https://mui.kernelsu.org`）；页面通过管理器注入的 `ksu` JS 桥以
  root 执行 `scripts/control.sh status|start|stop|restart` 并解析输出。该环境为
  https，`fetch("http://127.0.0.1:*")` 会被当作混合内容阻止，因此**不要**用 fetch
  调本地服务。Magisk 无内置 WebUI；作为兜底，模块自带 `busybox httpd` 控制台
  服务（`http://127.0.0.1:5592`），可在任意浏览器打开使用完整控制台。
- **自动更新**：`module.prop` 用的是 `updateJson=`（不是 `update`），指向
  `https://github.com/YuyuAww/AdGuardHomeFree/releases/latest/download/update.json`
  —— 最新 Release 的资产，**不是**仓库里的静态文件（仓库那份只是模板，CI 每次
  发布会用 `module.prop` 的 version/versionCode 重新生成同源副本；若指向 main，
  versionCode 永不变化，模块管理器会一直判定「已是最新」）。模块管理器可据它检测
  新版本；发布时把 `AdGuardHomeFree-module.zip`（无版本号）与带版本号 ZIP
  一并作为 Release 资产，`releases/latest/download/AdGuardHomeFree-module.zip`
  即最新包。

## 常见问题

**安装后没有去广告效果？**
- 确认模块已启用并重启设备；查看 `/data/adb/agh/logs/module.log`。
- 检查 `AdGuardHome` 进程与 5591 端口：`busybox netstat -tln | grep 5591`。
- 部分应用走 IPv6 且设备无 `ip6tables`，此时 IPv6 DNS 不经过过滤（可接受或
  关闭应用 IPv6）。

**修改配置后如何生效？**
- 用 root 终端直接重启模块进程：
  `sh /data/adb/modules/adguardhomefree/scripts/control.sh restart`
- 或打开控制台 `http://127.0.0.1:5592`，填入访问令牌后点「重启」。
- 注意：模块**没有** `/api/restart` 这类 REST 路由（旧文档写错了，按它操作必然 404）。
  控制台只有一个入口：`/cgi-bin/api.cgi?action=status|start|stop|restart`，
  其中 `start/stop/restart` 需要令牌（`/data/adb/agh/run/api.token`，仅 root 可读），
  可用 `X-Auth-Token` 请求头或 `&t=<token>` 参数传入。

**如何完全卸载？**
- 在模块管理器中移除；`uninstall.sh` 会停止进程、清除 iptables 规则并删除
  `/data/adb/agh`。

## 许可证

- 模块脚本、打包脚本、配置模板、WebUI 页面：**Apache License 2.0**（见 `LICENSE`）。
- 随模块分发的 **AdGuard Home** 二进制：**GPLv3**（见 `NOTICE`，源码见
  <https://github.com/AdguardTeam/AdGuardHome>）。
