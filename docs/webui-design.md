# WebUI 架构设计（IMP-04，P1-T5 前置）

> 目的：P1-T5 实现前定死模块 WebUI 架构，避免实现期失控。
> 约束来源：项目操作手册 INV-02/03/07、P0-T4 报告 `bridge_channel` 字段、手册 §472（写操作全走 bridgeCall）。
> 定位：§0 为已入库的 P0 现状基线，§1~§5 为 P1-T5 目标态设计；两者差集即 P1-T5 工作量。

## 0. P0 现状基线（webroot/ 已实现）

- 形态：`webroot/index.html` + `webroot/app.js`（IIFE，无框架、无构建步骤；KSU/APatch 管理器
  WebView 以 `file://` 加载；深色卡片风内联 CSS，无外部资源）。
- P0 页面 = 单探测页：Bridge Probe 卡片（`bridge_fetch`/`ksu_exec` 通道路径 + AGH 状态）+
  AGH Status 卡片 + 固定链接（AGH 管理 UI `http://127.0.0.1:3000`、bridge `/status`）。
  无 hash 路由、无写操作 —— 多页面与写操作分别是 P1-T5 / P1-T2 交付物。
- 探测通道优先级（P0-T2 契约）：
  1. `fetch('http://127.0.0.1:3001/status')` 成功 → `bridge_fetch=1`（aghbridge 已铺
     CORS `*` + OPTIONS 预检）；
  2. fetch 不可用 → `window.ksu.exec` 通道 curl/wget → `ksu_exec=1`；
  3. 双通道失败 → 渲染 BRIDGE_UNREACHABLE，页面只读降级（手册 §9），不阻塞渲染。
- 通道选择仅以 flag 记 `sessionStorage`（`AGHF_BRIDGE_FETCH`，INV-02）；probe 结果
  best-effort 写 `/data/adb/aghf/logs/probe.txt`（P0-T4 人工步骤读取，`fetch=1`/`ksu_exec=1`）。
- aghbridge P0 行为：`/exec` 只读白名单（`get_status`，无凭据；非白名单恒 403）；写类 action
  token 门控（`X-AGHF-Token` 缺失/错误 401，正确 501 —— 处理逻辑 P1-T2 落地）；token 内容
  永不返回调用方、不入日志（IMP-02）。

## 1. 技术形态（P1-T5 目标态，延续 P0 约定）

- 不引入框架/构建：仍 `index.html` + `app.js` 单文件；KSU/APatch 管理器 WebView 只认一个
  `file://` 入口。
- 多"页面"用单文件 hash 路由（`#status` / `#subs` / `#logs` / `#settings`），不用多 html。
- 样式沿用 P0 深色卡片风（`index.html` 内联 CSS），不加外部资源。

## 2. 数据通道（bridgeCall）

```
bridgeCall(action, args):
  1) fetch('http://127.0.0.1:3001/exec?action=' + action, {body, headers})
     - 写类 action 附带 X-AGHF-Token：fetch 通道拿不到 token 文件，
       由 ksu.exec 读 $AGHF_STATE/bridge_token（root 通道）注入请求头（INV-03，见 §4）
  2) fetch 失败/401 → 回退 ksu.exec('sh -c "..."', cb) 直跑模块脚本（root 通道）
  3) 双通道失败 → 只读模式提示（不阻塞渲染）
```

- P1-T2 起 aghbridge 白名单扩为 `get_status / start / stop / install / rollback / reload`
  （P0 即已 token 门控、返回 501；P1-T2 把 501 换成真实处理逻辑）。
- 通道选择记录沿用 `sessionStorage` flag（INV-02：仅 flag，不放用户数据）。

## 3. 页面与数据契约

| 页面 | 数据来源 | 写操作 | 解锁阶段 |
| --- | --- | --- | --- |
| `#status` | `/exec get_status` + `ctl.json`（P1-T1 状态机） | install / rollback / start / stop（bridgeCall 写类） | P1-T1 + P1-T2 |
| `#subs` | 订阅 API（aghbridge 代理 AGH 管理 API） | 订阅增删改 | P1-T3 |
| `#logs` | 查询日志接口（`recent_queries` 白名单扩项） | 无 | P3 |
| `#settings` | `module.prop` + `$AGHF_STATE` 快照 | 白名单过滤开关 | P1-T4 后 |

- 只读状态文件（`ctl.json`、`dns_snapshot_*.json`、`dnsresolver_mode` 标记、`verify_block.txt`）
  经 ksu.exec 通道读文件渲染；`config/state-schema.json` 是渲染前校验基准
  （P1-T1 补 RECONCILE 枚举后同步 schema）。

## 4. 降级模式（P0-T4 报告字段驱动）

- `bridge_channel == "none"` → **只读降级**（手册 §782）：仅渲染状态卡片 + "bridge 不可达"
  提示，隐藏全部写按钮；不阻塞页面加载。P0 现状页即此形态。
- `dnsresolver == "unavailable"`（A10+ 常态，见 README 工作模型）→ iptables-only 接管
  （手册 §785）：`#status` 隐藏 "DNSResolver 开关"，install/rollback 走 iptables-only 分支
  （P1-T1 状态机内）。
- `verify_dns == "degraded"` → 页面提示 DNS 验证为 nc 级（手册 P0-T4 节 9 / ON_FAILURE）。

## 5. 安全边界（INV 合规）

- INV-02：用户规则/订阅/统计一律走 aghbridge→AGH 存储；WebUI 不写 localStorage；
  sessionStorage 仅通道 flag。
- INV-03：AGH 管理密码（`$AGHF_STATE/agh_admin.cred`）与 bridge_token 均不硬编码、不进
  DOM 文本、不进日志；token 只经 ksu.exec（root）读取后随 `X-AGHF-Token` 请求头传递，
  页面内存瞬时持有。
- INV-07：打开 AGH 原生管理界面 = 链接到 `http://127.0.0.1:3000`（operator 手动登录，
  密码在 `agh_admin.cred`），模块 WebUI 不代存密码。
