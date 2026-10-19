# AdGuardHomeFree

KernelSU / APatch 模块：在 Android 上以 systemless 方式运行 AdGuard Home（arm64），通过
DNSResolver（`cmd netd resolver setnetdns`）+ nat REDIRECT iptables 双路接管本机 DNS，
WebUI 桥接通道（`aghbridge`）供模块页打开 AGH 管理界面。

设计契约见 `项目操作手册.md`（仓库内忽略、随包发布），Phase 0 实现进度：

| 阶段 | 任务 | 状态 |
| --- | --- | --- |
| P0-T1 | 模块骨架 + rootenv 探测 | 已实现（本地），设备侧验收待跑 |
| P0-T2 | aghbridge 最小控制桥 + WebUI 探测 | 已实现（本地），设备侧验收待跑 |
| P0-T3 | DNSResolver + iptables 最小接管事务 | 已实现（本地），设备侧验收待跑 |
| P0-T4 | 验收报告 | 设备侧脚本 `scripts/phase0_accept.sh`，需在真机（KSU 与 APatch 各一遍）执行 |

## 目录结构

```
module.prop / customize.sh / service.sh / post-fs-data.sh / supervise.sh / uninstall.sh
common/    logger.sh rootenv.sh iptables.sh dnsresolver.sh aghfctl.sh   # 全部可 source
webroot/   index.html app.js                                            # 模块 WebUI
config/    AdGuardHome.yaml.template state-schema.json
src/aghbridge/  Go 源码（gen-hash 子命令 + /status + /exec 最小白名单）
bin/       AdGuardHome (v0.107.79 arm64)  aghbridge (交叉编译产物)
scripts/   phase0_accept.sh (设备侧 P0-T4 验收)
```

数据目录固定为 `/data/adb/aghf/{data,logs,run,state}`（§1.1），日志 1MiB 滚动。

## 设计偏差（用户决策）

- **不捆绑 busybox**（用户指示 2026-10-19）：KSU/APatch 管理器均不自带 busybox 二进制，
  手册 P0-T1 的 `bin/busybox` 产物取消。`rootenv` 按 模块捆绑 → 管理器 → toybox → `none`
  的顺序探测，`none` 时 P0-T3 的 VERIFY_DNS 降级为 `toybox nc` + 进程存活检查，
  P0-T4 报告 `verify_dns` 记为 `degraded`。

## 构建 aghbridge（本机）

```
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "-s -w" -o bin/aghbridge ./src/aghbridge
```

本机工具链位于 `tools/go`（go1.27.2，已 .gitignore）；`go.mod` 依赖
`golang.org/x/crypto`（bcrypt，gen-hash 用）。

## 设备侧验收（P0-T4）

1. 将本目录安装为 KernelSU 或 APatch 模块并重启；
2. WebView 打开模块页，手动把 probe 结果写入 `/data/adb/aghf/logs/probe.txt`（`fetch=1` 或 `ksu_exec=1`）；
3. Wi-Fi 下执行 `sh /data/adb/modules/AdGuardHomeFree/scripts/phase0_accept.sh wifi`；
4. 切移动数据再执行一遍 `... mobile`；
5. 报告输出到 `/data/adb/aghf/logs/phase0_report.json`，`blockers` 为空或仅含可接受降级项即通过。
