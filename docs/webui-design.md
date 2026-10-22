# WebUI 架构设计（IMP-04，P1-T5 前置）

> 目的：P1-T5 之前定死模块 WebUI 的架构，避免实现期失控。
> 约束来源：项目操作手册 INV-02/03/07、P0-T4 `bridge_channel`、手册 §472（写操作全走 bridgeCall）。

## 1. 技术形态（延续 P0 约定）

- 无框架、无构建步骤：`webroot/index.html` + `app.js`（IIFE），KSU/APatch WebView 直接 `file://` 加载。
- 多"页面"用单文件 hash 路由（`#status` / `#subs` / `#logs`），不用多 html（模块管理器 WebView 只认一个入口）。
- 样式沿用 P0 深色卡片风格（`index.html` 内联 CSS），不加外部资源。

## 2. 数据通道（bridgeCall）

```
bridgeCall(action, args):
  1) fetch('http://127.0.0.1:3001/exec?action=' + action, {body, headers})
     - 写类 action 附带 X-AGHF-Token（P0 起由 ksu.exec 读 $AGHF_STATE/bridge_token 注入，
       fetch 通道本身拿不到 token 文件 → 见 §4）
  2) fetch 失败/401 → 回退 ksu.exec('sh -c "..."', cb) 直跑模块脚本（root 通道）
  3) 两通道均失败 → 只读模式提示（不阻塞渲染）
```

- P0 已铺 CORS（`Access-Control-Allow-Origin: *`）与 OPTIONS 预检；P1-T2 起 aghbridge
  白名单扩为 `get_status / start / stop / install / rollback / reload`。
- 通道选择记录沿用 `sessionStorage`（INV-02：仅 flag，不放用户数据）。

## 3. 页面与数据契约

| 页面 | 数据来源 | 写操作 |
| --- | --- | --- |
| `#status` | `/exec get_status` + `ctl.json`（P1-T1 状态机） | install / rollback / start / stop（bridgeCall 写类） |
| `#subs` | P1-T3 订阅 API（aghbridge 代理 AGH 管理 API） | 订阅增删改（P1-T3） |
| `#logs` | P3-T5 查询日志接口（`recent_queries` 白名单扩项） | 无 |
| `#settings` | `module.prop` + `$AGHF_STATE` 快照 | 白名单过滤开关（P1-T4 后） |

- 只读状态文件（`ctl.json`、`dns_snapshot_*.json`）由 ksu.exec 通道读文件渲染；
  `state-schema.json` 是渲染前校验基准（P1-T1 补 RECONCILE 枚举后同步）。

## 4. 降级模式（由 P0-T4 报告字段驱动）

- `bridge_channel == "none"` → **只读降级**（手册 §782）：页面仅渲染状态卡片 +
  "bridge 不可达"提示，隐藏全部写按钮；不阻塞页面加载。
- `dnsresolver == "unavailable"` → 纯 iptables 接管（手册 §785）：`#status` 隐藏
  "DNSResolver 开关"，install/rollback 走 iptables-only 路径（P1-T1 状态机内分支）。

## 5. 安全边界（INV 合规）

- INV-02：用户规则/订阅/统计一律走 aghbridge→AGH 存储，WebUI 不写 localStorage/sessionStorage
  （sessionStorage 仅通道 flag）。
- INV-03：AGH 管理密码/bridge_token 均不硬编码、不进 DOM 文本、不进日志；
  token 只经 ksu.exec（root）读取后随请求头传递，页面内存瞬时持有。
- INV-07：打开 AGH 原生管理界面 = 链接到 `http://127.0.0.1:3000`（operator 手动登录），
  模块 WebUI 不代存密码。
