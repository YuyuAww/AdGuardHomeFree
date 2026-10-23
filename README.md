# AdGuardHomeFree

KernelSU / APatch 模块：在 Android 上以 systemless 方式运行 AdGuard Home（v0.107.79，arm64），
把本机 DNS 劫持到 AGH（主通道：nat REDIRECT iptables），WebUI 桥接通道（`aghbridge`）
供模块页查看状态并打开 AGH 管理界面。

设计契约：`项目操作手册.md`（仓库内 gitignore、随模块包发布）；本文与代码中的
`INV-xx` / `IMP-xx` / 手册 `§xx` 引用均指向该文档。

## Phase 0 进度

| 阶段 | 任务 | 状态 |
| --- | --- | --- |
| P0-T1 | 模块骨架 + rootenv 探测 | 已实现（本地），设备侧验收待跑 |
| P0-T2 | aghbridge 最小控制桥 + WebUI 探测 | 已实现（本地），设备侧验收待跑 |
| P0-T3 | DNSResolver + iptables 最小接管事务 | 已实现（本地），设备侧验收待跑 |
| P0-T4 | 验收报告 | 设备侧脚本 `scripts/phase0_accept.sh`，需在真机（KSU 与 APatch 各一遍）执行；`DNSRESOLVER_UNAVAILABLE` 为可接受降级项（A10+ 常态） |

P1~P3 未实现（写 API、订阅代理、监控主循环、IPv6/日志查询），见「后续阶段」。

## 工作模型（2026-10 现状）

DNS 劫持两路（netd 命令面的源码级考证见 `common/dnsresolver.sh` 头部注释）：

1. **iptables nat REDIRECT（主通道，所有目标机型可用）**：`AGHF_OUTPUT` /
   `AGHF_PREROUTING` 两条 AGH 自有链把 UDP/TCP :53 重定向到 `127.0.0.1:5353`
   （AGH `dns.port`）。只动 AGH 自有规则，不碰系统链（最小足迹 INV）。
2. **netd resolver 覆盖（仅 O/P 代目标机）**：`cmd netd resolver setnetdns <netid> "" 127.0.0.1`。
   **netd 的 `resolver` NDC 命令族自 Android 10 起已被移除**（AOSP NdcDispatcher 源码核验，
   调研 dump 在 `.research/`），因此现实中的 KSU/APatch 目标（A11+）该步必然失败：
   `aghfctl install` 降级为 iptables-only 模式（exit 0 + 写 `$AGHF_STATE/dnsresolver_mode`
   标记；rollback 见标记跳过 resolver restore），P0-T4 报告
   `DNSRESOLVER_UNAVAILABLE` 可接受；per-netId binder 接管排 P1-T1。
   `getnetdns` 从未是 NDC 命令，读回走 `dumpsys connectivity` 的 `DnsAddresses` 行
   （格式漂移容忍，盲快照）。

固有约束：只能劫持明文 DNS（:53）。走私有 DNS（DoT/DoH，直连 :443）的应用绕过本模块
（iptables 方案固有约束，手册 §9 降级条目）。

## 目录结构

```
module.prop / customize.sh / service.sh / post-fs-data.sh / uninstall.sh
common/    logger.sh rootenv.sh iptables.sh dnsresolver.sh aghfctl.sh supervise.sh
           # 前五个带 LIB 开关可 source（xxx_LIB=1 抑制 CLI main）；supervise.sh 是 exec 型
           # P0-T1 占位，监控主循环 P2-T5 落地
webroot/   index.html app.js                # 模块 WebUI（P0 探测页）
config/    AdGuardHome.yaml.template state-schema.json
src/aghbridge/  main.go go.mod go.sum        # 控制桥 Go 源码（gen-hash 子命令 + /status + /exec 白名单 + 写类 token 门）
bin/       AdGuardHome (v0.107.79 arm64) aghbridge (CI 交叉编译产物)
scripts/   phase0_accept.sh                  # 设备侧 P0-T4 验收
```

数据目录固定为 `/data/adb/aghf/{data,logs,run,state}`（手册 §1.1）；`aghf.log`
超 1MiB 滚动为 `aghf.log.1`。

## 版本锁定（IMP-06）

- **AdGuardHome `v0.107.79`（arm64）**，双 sha256 钉版（GitHub Actions 构建时校验）：
  - tarball `AdGuardHome_linux_arm64.tar.gz` = `3f7893c18e8aaadc456d0452839190561c306ca95175a2254958be80a769c1ae`
  - 解压后二进制 `bin/AdGuardHome` = `64a9b6fc6269247f1973cddbf285aa6ce866d11bd29546b0f4135ba31d2283c8`
- 升级 AGH：更新 `.github/workflows/build-release.yml` 的 `AGH_VERSION` 与两个 sha256，
  重新打 tag 发布；`bin/AdGuardHome` 由 CI 覆盖，不手工提交二进制漂移。
- `aghbridge` 每次从 `src/aghbridge` 构建（go.mod 钉 `go 1.24` +
  `golang.org/x/crypto v0.31.0`，依赖仅 bcrypt）。
- CI：push main → 构建 + 校验 + 上传 zip artifact；打 tag `v*` → 另发 GitHub Release。
  INV-10：只出 arm64 产物。

## AGH 配置（config/AdGuardHome.yaml.template）

基线 = v0.107.79 默认 config 形态的 P0 最小子集，与二进制内 yaml 标签逐一核验一致：

- 首装由 customize.sh 注入：32 位 hex 随机 admin 密码 → `aghbridge gen-hash`（bcrypt）→
  sed 替换 `__AGHF_ADMIN_HASH__`；明文密码存 `$AGHF_STATE/agh_admin.cred`（600，root only，
  永不回显进日志）；同时生成 bridge token `$AGHF_STATE/bridge_token`（600）。
- **.79 schema 无 `web:` 段**（unmarshal 静默丢弃）；Web UI 由顶层
  `http.address: "127.0.0.1:3000"` 固定（AGH 默认 0.0.0.0:3000 会把管理界面暴露到设备网络）。
  `auth_attempts` / `block_auth_min` 在 .79 为顶层键；`filters` 不写 `id: -1`。
- **防回环规则**（手册 P0-T3 STEP 7）：模块把全机 :53 重定向进 AGH，明文 :53 上游会被自身
  sinkhole 捕获形成自回环 → `dns.upstream_dns` 用 DoH 端点
  （`https://223.5.5.5/dns-query`、`https://doh.pub/dns-query`），`bootstrap_dns` 用明文 IP
  （解析 DoH 域名/过滤器 URL；bootstrap 查询同样经 sinkhole、由 AGH 经 DoH 转发，不成环）。
  service.sh 导出 `SSL_CERT_DIR` 供 DoH TLS 校验。

## 控制桥 aghbridge（IMP-02 认证边界）

- 监听 `127.0.0.1:3001`；CORS `Access-Control-Allow-Origin: *` + OPTIONS 预检，
  供 KSU/APatch WebView 从 `file://` 页面调用。
- `GET /status` → `{"agh_running":bool,"impl":"kernelsu|apatch|unknown"}`。
- `GET|POST /exec`：P0 白名单只读（`get_status`，无需凭据；非白名单 action 恒 403，
  与手册 P0-T2 验收命令一致）。写类 action（`start/stop/install/rollback/reload`）
  现在即被 token 门控：`X-AGHF-Token` 需匹配 `$AGHF_STATE/bridge_token` →
  缺失/错误 401，正确 501（P0 无处理逻辑，P1-T2 落地）。token 文件内容永不返回调用方、不入日志。

## 设计偏差（用户决策）

- **不捆绑 busybox**（用户指示 m00128，2026-10-19）：KSU/APatch 管理器均不自带 busybox，
  手册 P0-T1 的 `bin/busybox` 产物取消。rootenv 按 模块捆绑 → 管理器 → toybox → `none`
  顺序探测；P0 镜像上 `none` 是正常状态。`none` 时 P0-T3 VERIFY_DNS 降级为
  `toybox nc` + 进程存活检查，P0-T4 报告 `verify_dns=degraded`。
  **边界**：设备既无 busybox 也无 toybox 时，VERIFY_DNS 按设计无法运行（P0-T3 STEP 7
  契约）——报告 degraded/fail 属文档化边界，不算 bug。

## 2026-10 修复（静态检查轮，未提交）

1. **yaml 防回环 + .79 schema + netd 降级**：上游改 DoH + bootstrap 明文 IP；按 .79 schema
   修正配置键位置；netd resolver 命令族 A10+ 已移除 → install 降级 iptables-only +
   `dnsresolver_mode` 标记（上文各节）。
2. **iptables 拆除退出码契约**（`common/iptables.sh`）：`ipt_remove` 仅在「规则存在但删除失败」
   时置非零 rc；规则已不在 = 无操作 rc 0。rollback 的 exit 60（手册 §1.4）因此真正可达。
3. **快照服务器解析**（`common/dnsresolver.sh`）：只读 dns_snapshot 的 `"servers"` 数组；
   旧实现对全文件 grep 十六进制串，误匹配 JSON 分隔符等 token，restore 可能喂 bogus 服务器。
4. **phase0_accept 跟系统 iptables 二进制**（`scripts/phase0_accept.sh`）：链检查改用
   `$AGHF_IPTABLES`（iptables-legacy-only 设备上不再假报 ROLLBACK_FAIL）。

## 安装与使用（设备侧）

1. 把本目录安装为 KernelSU 或 APatch 模块并重启：
   - `customize.sh`（安装期，root）：建数据目录、首装生成配置/密码/bridge token；
   - `post-fs-data.sh`（早期启动）：rootenv 探测 + 写 `probe_kv.txt` 记录（INV-06：
     此阶段只探测，不启动 AGH、不动 iptables）；
   - `service.sh`（启动完成）：等 `sys.boot_completed`（≤120s），setsid 启动
     `bin/AdGuardHome` 与 `bin/aghbridge`，跑 supervise.sh 占位；探测失败只记日志、
     不重启循环。
2. 模块页（WebView）：Bridge Probe 卡片渲染 `bridge_fetch` / `ksu_exec` 通道路径与
   AGH 状态；把 probe 结果手动写入 `/data/adb/aghf/logs/probe.txt`（`fetch=1` 或
   `ksu_exec=1`）供 P0-T4 报告读取。
3. DNS 接管（P0 为 operator 驱动，经 aghfctl 事务）：
   ```sh /data/adb/modules/AdGuardHomeFree/common/aghfctl.sh install|rollback|status```
   事务序：netid → 快照（INV-09：改动前必快照）→ iptables install → setnetdns（A10+ 预期
   失败即降级）→ VERIFY_DNS → VERIFY_BLOCK（非阻塞）。退出码（手册 §1.4）：0 成功（含
   iptables-only 降级）、21 verify-dns、30 iptables install、40 快照失败、41 无活动网络、
   60 rollback 步骤错误、10 rootenv 探测失败。
4. AGH 管理界面：浏览器/WebView 打开 `http://127.0.0.1:3000`，用
   `$AGHF_STATE/agh_admin.cred` 的密码登录（INV-07：模块 WebUI 不代存密码）。
5. 卸载：`uninstall.sh` 先跑 aghfctl rollback（恢复 resolver / 删 AGHF 链 / 清快照，
   降级模式跳过 restore），再杀 AGH/bridge 进程；`/data/adb/aghf` 用户配置保留。

## 设备侧验收（P0-T4）

1. 模块安装并重启；WebView 写 `probe.txt`（见上）；
2. Wi-Fi 下 `sh /data/adb/modules/AdGuardHomeFree/scripts/phase0_accept.sh wifi`；
3. 切移动数据再跑一遍 `... mobile`；
4. 报告 → `/data/adb/aghf/logs/phase0_report.json`；`blockers` 为空、或仅含可接受
   降级项（`DNSRESOLVER_UNAVAILABLE`、`BRIDGE_CHANNEL_NONE` → 手册 §9 降级路径）即通过。

## 本机构建 aghbridge

```
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "-s -w" -o bin/aghbridge ./src/aghbridge
```

本机工具链在 `tools/go`（go1.27.2，gitignore）；脚本与源码强制 LF（`.gitattributes`，
Android /system/bin/sh 不接受 CRLF）。

## 验证状态（2026-10 静态复核）

- **已验证**：11 个 shell 脚本静态检查；`go vet`/`gofmt`；yaml 模板与二进制 yaml 标签
  一致性；`bin/AdGuardHome` sha256 与 CI 钉版一致；aghbridge 重建产物与已提交二进制
  功能等价（同尺寸、同特征串，字节差为构建非确定性）。
- **推断（未上机）**：A10+ 降级行为、iptables-legacy 路径。
- **未验证**：全部设备侧行为 —— P0-T4 验收未跑，是可用性最后闸门。

## 后续阶段

| 阶段 | 内容 | 现状 |
| --- | --- | --- |
| P1-T1 | per-netId resolver binder 接管 + 状态机（RECONCILE） | 未实现 |
| P1-T2 | aghbridge 写类 action（start/stop/install/rollback/reload） | token 门已布，返回 501 |
| P1-T3 | 订阅管理 API 代理（AGH 管理 API） | 未实现 |
| P1-T5 | WebUI 多页面（hash 路由，设计见 `docs/webui-design.md`） | 未实现 |
| P2-T5 | 监控主循环（AGH 存活 + 规则自愈） | supervise.sh 占位 |
| P3 | IPv6 nat 链（`AGHF_IP6TABLES` 已导出）/ 日志查询（`recent_queries`） | 未实现 |
