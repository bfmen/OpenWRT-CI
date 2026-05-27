# dae 配置 UI 设计文档 v2

**日期**: 2026-05-27（v2 改版于实测后）
**项目**: ysuolmai/luci-app-dae
**目标**: 替换原始文本编辑器为结构化表单 UI，正确表达 dae 的 group 概念

> **v2 改了什么**：v1 漏掉了 dae 最关键的 **group** 概念，导致表单生成的配置实际无法用（routing 规则的 action 不能直接是订阅名 / 节点名）。v2 把 group 升为一等公民，并修正若干默认行为。

---

## 背景：dae 的四层模型

dae 配置自上而下是四层依赖：

```
订阅 (subscription) + 手动节点 (node)
   ↓ 合并成全局节点池
group { ... }  ← v1 漏掉的一层
   ↓ filter 挑节点 + policy 决定怎么选一个
routing { ... }  ← action 写 group 名（不是订阅 / 节点名）
```

不定义 group 就没法用订阅。dae 不像 Clash 让你直接在订阅里选节点，它要的答案是 **"用哪个 group（出口）"**。

---

## 用户类型与设计目标

- **A. 极简党**（80%）：贴一个订阅、保存、能上网，看到「默认代理组」字样但不用动它
- **B. 分流党**（15%）：想 Netflix 走美国 / 国内直连 / 其他走代理，需要多个 group
- **C. 控制党**（5%）：想看订阅里有什么节点、必要时手动钉一个特定节点
- **D. 高级党**：直接文本模式编辑，UI 不阻碍

UI 围绕 A 类设计、对 B/C 友好、对 D 不挡路。

---

## 实现方案

**纯客户端 JS 解析 + 后端 shell 脚本拉订阅**：

- `dae-parser.js`：dae DSL 的 parse / serialize（在 LuCI 浏览器和 Node.js 测试里都跑）
- `config.js`：UI 主体（Tab、表单、状态同步）
- `list-nodes.sh`：路由器后端脚本，wget 订阅 URL → base64 解码 → 解析节点 → JSON 输出

---

## UI 整体结构

### Tab 切换（顶部，3 个）

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  表单模式 ●  │  │  所有节点    │  │  文本模式    │   ← 活动的高亮
└─────────────┘  └─────────────┘  └─────────────┘
```

**样式实现要求（v2 新增）**：

v1 用了 `<ul class="cbi-tabmenu"><li class="cbi-tab">` 结构，但 LuCI 这套类在没有 form.Map 配合时渲染像一行小字，用户分不清那是按钮还是说明文字。

v2 改用 LuCI 现成的 `cbi-button` 系列类（保证跟主题一致）：

```html
<div class="cbi-tabcontainer" style="margin-bottom:1em">
  <button class="btn cbi-button cbi-button-action">表单模式</button>
  <button class="btn cbi-button">文本模式</button>
</div>
```

- 活动 tab：`class="btn cbi-button cbi-button-action"`（带主色，明显）
- 不活动 tab：`class="btn cbi-button"`（中性灰）
- 切换时只改 `cbi-button-action` 这个类的存在与否
- 按钮间距用 margin / gap，看起来像两个并排按钮而不是文字

~~v1 设计 3 个 tab（含【所有节点】），v2 取消：节点查看下沉到订阅行内展开。~~
**修正**：v2 第一稿曾把【所有节点】tab 砍掉，但导致「手动添加节点」入口被埋（折叠区块里），新手找不到。最终决定 3 个 tab 恢复 + 【所有节点】tab 集中负责"看节点 + 加手动节点"两件事。表单模式里取消独立的"节点（手动）"区块。

---

## 表单模式 · 各区块

### 1. 订阅（subscription）

```
名称          URL                        操作
my_sub        https://...                [删除]
my_sub2       https://...                [删除]
[+ 添加订阅]
```

- **名称**：只允许字母 / 数字 / 下划线
- 加订阅时**自动加入默认 group**（见下文 §3）
- **节点查看 / 刷新**：去【所有节点】tab（顶部按钮）

> v2 第一稿曾在订阅每行加【获取节点】按钮 + 行内展开节点列表。终稿改为集中到【所有节点】tab——避免订阅区块越来越拥挤，节点查看是低频操作。

### 2. ~~节点（手动 node）~~ — 已取消

手动节点的添加和查看统一到【所有节点】tab。表单模式不再有此独立区块。  
数据上仍然对应 dae 配置的 `node { ... }` 段——只是 UI 入口变了。

### 3. 代理组（group）—— v2 新增主区块

#### 默认行为

- 表单第一次加载（无配置时）UI 已经有一个组卡片
- 组名：`proxy`（用户可改）
- 使用订阅：跟随订阅自动勾选（加新订阅自动勾入）
- 排除节点名包含：`ExpireAt`
- 策略：自动选最快（dae 实际 = `min_moving_avg`）

#### 卡片布局

```
╔══ 组：proxy（主组）═════════════════════════════╗
║                                                ║
║ 名称：     [ proxy             ]                ║
║                                                ║
║ 使用订阅： ☑ my_sub  ☑ my_sub2  ☐ another      ║
║ 使用手动节点： ☐ node1                          ║
║                                                ║
║ 排除节点名包含： [ ExpireAt              ]      ║
║                 （逗号分隔多个）                  ║
║                                                ║
║ 策略：    [ 自动选最快                     ▼ ]  ║
║                                                ║
║ [删除此组]  ← 默认 proxy 不可删，灰掉            ║
╚════════════════════════════════════════════════╝

[+ 添加分流组]
```

#### 策略下拉（中文化）

| UI 显示 | dae 真实值 | 含义 |
|---------|-----------|------|
| 自动选最快（推荐） | `min_moving_avg` | 近 N 次延迟移动平均最小 |
| 随机 | `random` | 每次连接随机选一个 |
| 手动选一个节点 | (拼装) | 选了之后下面再出一行让你选具体节点 |

选「手动选一个节点」时，下方追加一行：

```
指定节点：[ HK_01 (from my_sub)              ▼ ]
```

- 下拉数据源：cache 文件 `/tmp/dae-nodes-cache.json`
- 显示格式：`<节点名> (from <订阅名>)`
- 选中后 UI 生成的配置形态：
  - `filter: name(选中节点)` （组里只有这一个节点）
  - `policy: min_moving_avg`
  - 不用 `policy: fixed(N)`（避免索引漂移问题）
- cache 为空时下拉显示「请先在订阅那里点【获取节点】」

#### 多 group

- 「+ 添加分流组」按钮在最后一个组下面，不显眼
- 加新组卡片，默认名 `group2` / `group3`...，filter 默认全勾、policy 默认自动最快
- 后续删除：组卡右下角【删除此组】，proxy 主组的【删除】灰掉（防呆）

### 4. 路由规则（routing）

```
╔══ 路由规则 ═══════════════════════════════════════╗
║                                                  ║
║ 条件类型    条件值              动作       操作    ║
║ dip        geoip:private      direct   ↑↓ 删    ║
║ dip        geoip:cn           direct   ↑↓ 删    ║
║ domain     geosite:cn         direct   ↑↓ 删    ║
║ [+ 添加规则]                                     ║
║                                                  ║
║ Fallback   —                  proxy▼    —        ║
╚══════════════════════════════════════════════════╝
```

#### 默认值

无配置时预填这三条 + fallback。

#### 动作下拉

**来源（v2 修正）**：`['direct', 'block', ...所有 group 名]`

不再用订阅名 / 节点名（v1 错误）。group 改名后 routing 行动作下拉同步刷新。

#### 条件类型 / 值

不变。

### 5. DNS

不变（v1 设计保留）：上游服务器表 + 国内/国外 DNS 选择。

### 6. 全局设置 —— 默认折叠

不变。

---

## 所有节点 Tab

集中负责两件事：**看订阅里有哪些节点** + **手动添加 / 删除节点**。

### 布局

```
┌────────────────────────────────────────────────────────────────┐
│  [🔄 刷新订阅节点]   来源筛选: [ 全部 ▼ ]                       │
│                                                                │
│  ┌───────────┬───────┬────────────────────┬─────────┬────────┐ │
│  │ 节点名     │ 协议   │ 服务器:端口         │ 来源     │ 操作    │ │
│  ├───────────┼───────┼────────────────────┼─────────┼────────┤ │
│  │ HK_01     │ vmess │ 1.2.3.4:443        │ my_sub  │   —    │ │
│  │ HK_02     │ vmess │ 5.6.7.8:443        │ my_sub  │   —    │ │
│  │ US_01     │ ss    │ 9.10.11.12:8388    │ my_sub2 │   —    │ │
│  │ myhome    │ ss    │ home.ddns.net:8388 │ 手动     │ [删除] │ │
│  └───────────┴───────┴────────────────────┴─────────┴────────┘ │
│                                                                │
│  [+ 添加手动节点]                                                │
└────────────────────────────────────────────────────────────────┘
```

### 行为

| 元素 | 行为 |
|------|------|
| **【🔄 刷新订阅节点】** | 对每个订阅调 `list-nodes.sh` 拉取、解析、合并写入 cache，重渲染表格 |
| **来源筛选** | 下拉选项：全部 / `<每个订阅名>` / 手动；只过滤显示 |
| **订阅节点行** | 只读（操作列为 —）；表头下方按来源分组排列 |
| **手动节点行** | 操作列有【删除】，删了从 `config.node` 中移除 |
| **【+ 添加手动节点】** | 在表格底部追加一个可编辑行：名称 + 节点 URI 两个输入框，名称满足 `[\w]+` 才能保存 |

### 数据流

- 表格数据源 = `/tmp/dae-nodes-cache.json`（订阅节点）+ 当前 `config.node`（手动节点）
- 手动加 / 删 → 立即修改内存里的 `config.node`，但**不立即写盘**——等用户点保存才统一写 `/etc/dae/config.dae`
- 「刷新订阅节点」只动 cache 文件，不动 `/etc/dae/config.dae`

### 入页时拉不拉？

不拉。直接读已有 cache（可能是空的，第一次访问就什么都不显示）。用户点【刷新】才拉。

但**保存配置后**会**静默后台**拉所有订阅（见 §自动行为），所以一般操作过几次后 cache 都不会空。

---

## 节点列表（cache 机制）

### 文件：`/tmp/dae-nodes-cache.json`

```json
{
  "updated_at": 1748358000,
  "subscriptions": {
    "my_sub": [
      {"name": "HK_01", "protocol": "vmess", "server": "1.2.3.4", "port": 443},
      {"name": "US_01", "protocol": "ss",    "server": "5.6.7.8", "port": 8388}
    ],
    "my_sub2": [...]
  },
  "manual_nodes": [
    {"name": "node1", "protocol": "ss", "server": "home.example", "port": 8388}
  ]
}
```

### 拉取触发

| 触发点 | 行为 |
|--------|------|
| 用户点【所有节点】tab 顶部【🔄 刷新订阅节点】 | 对每个订阅调 `list-nodes.sh single`、合并写 cache、重渲染表格 |
| 用户保存配置后 | 后台静默拉**所有**订阅，更新 cache，不阻塞保存，失败不报错 |
| 进入页面 / 切到【所有节点】tab | 不主动拉，直接读现有 cache 渲染 |

### 后端脚本：`/usr/lib/luci-app-dae/list-nodes.sh`

```bash
#!/bin/sh
# Usage:
#   list-nodes.sh single <sub_name> <url>   → 拉单条订阅，更新 cache
#   list-nodes.sh all                       → 读 /etc/dae/config.dae 拉所有订阅
# 输出：写到 /tmp/dae-nodes-cache.json，并 stdout 输出 JSON

# 实现：
# 1. wget URL → 原始内容
# 2. 尝试 base64 -d（多数订阅是 base64 编码的 URI 列表）
# 3. 按行分割，每行 grep 匹配 ^(ss|ssr|vmess|vless|trojan|tuic|hysteria2)://
# 4. 解析 URI：
#    - ss://       : base64 解码 user:pass@server:port 部分 + #fragment 为节点名
#    - vmess://    : base64 后是 JSON，含 add/port/ps（ps 就是节点名）
#    - vless/trojan/hysteria2/tuic: 标准 URI，URL fragment 为节点名
# 5. 输出 JSON 数组：[{name, protocol, server, port}]
# 6. 合并写入 cache 文件 /tmp/dae-nodes-cache.json
```

注：复杂格式（Clash YAML / SIP008）暂不支持，节点列表显示「不支持的订阅格式，请用文本模式」。

### 前端调用

```js
fs.exec_direct('/usr/lib/luci-app-dae/list-nodes.sh', ['single', 'my_sub', 'https://...'])
  .then(JSON.parse)
  .then(updateUI);
```

---

## 数据模型（DaeConfig v2）

```typescript
interface DaeConfig {
  global: { [key: string]: string }
  subscription: { [name: string]: url }
  node: { [name: string]: uri }
  groups: GroupDef[]                       // ← v2 新增
  routing: {
    rules: { condType, condValue, action }[]
    fallback: string
  }
  dns: {
    upstream: { [name: string]: url }
    domestic: string
    foreign:  string
    rawRouting: string                     // 非简化模板的原文保留
  }
  rawOther: string                         // 无法识别的块原样保留
}

interface GroupDef {
  name: string
  filter: {
    subscriptions: string[]                // 选了哪些订阅
    nodes:         string[]                // 选了哪些手动节点
    excludeKeywords: string[]              // 排除节点名包含
    namePin?: string                       // 手动选一个节点时填这里
  }
  policy: 'min_moving_avg' | 'random'      // namePin 时一律 min_moving_avg
}
```

---

## 解析器（dae-parser.js）

### parse(text) → DaeConfig

新增 `_parseGroup(content)`：

```
group {
    proxy {
        filter: subtag(my_sub) && !name(keyword: 'ExpireAt')
        policy: min_moving_avg
    }
    netflix {
        filter: subtag(my_sub2) && name(keyword: 'US')
        policy: min_moving_avg
    }
}
```

策略：
1. `_extractBlocks(content)` 拿到每个组子块
2. 每个子块逐行解析 `filter:` 和 `policy:` 行
3. **filter 语法精简版**：只识别 `subtag(...)`、`name(...)`、`name(keyword: '...')`、用 `&&` 连接、`!name(...)` 表示排除
4. 解析不出来（更复杂语法）→ 整个 group 原样保留到 `rawOther` 末尾，UI 用「自定义组（文本模式编辑）」占位卡片

### serialize(config) → text

新增 group 块输出。顺序：`global → subscription → node → dns → group → routing → rawOther`

（group 必须在 routing 之前定义，否则 dae 报错）

---

## 自动行为

| 触发 | 行为 |
|------|------|
| 第一次打开（无配置） | 渲染：1 个空 `proxy` 组（filter 空、policy 自动最快）+ 默认 routing 3 条 + DNS 默认模板；【所有节点】tab 为空 |
| 加第一个订阅 | UI 把 `proxy` 组的「使用订阅」勾上这个新订阅 |
| 加第 N 个订阅（N≥2） | 同样勾上（不弹问） |
| 删除订阅 | 从所有 group 的 filter.subscriptions 移除 |
| 添加新 group | 默认名 `groupN`，filter 全勾、policy 自动最快 |
| 改 group 名 | routing 表的 action 下拉同步刷新；routing 里如果指向该组，也跟着改 |
| 删除 group | routing 里指向该组的规则把 action 改成 `direct` 并弹一次警告 |
| 保存配置 | 写 `/etc/dae/config.dae` → 调 `/etc/init.d/dae hot_reload` → 后台静默拉所有订阅刷 cache |
| Text → Form 切换 | parse 失败 → 留在 Text + notification「配置文本有错误」 |
| Form → Text 切换 | 总能成功（serialize 不出错） |

---

## 错误处理

| 场景 | 处理 |
|------|------|
| 文本无法解析 | 表单尽力填充已能解析的部分；未识别块进 rawOther |
| 表单字段空（如 group 没勾任何订阅）| 保存时高亮该字段，阻止保存，弹提示 |
| 订阅名 / group 名重复 | 输入框变红、保存阻止 |
| 切到表单时文本有语法错误 | 不切，提示「文本格式有误，请先修正」 |
| 保存后 dae hot_reload 失败 | 配置已写入文件，弹 notification「dae 重载失败，详见日志 tab」，不回滚 |
| list-nodes.sh 拉订阅失败 | 行内展开显示错误「拉取失败：HTTP 404 / 解析失败 / ...」 |
| 订阅格式不支持（如 Clash YAML） | 显示「不支持的订阅格式，请用文本模式查看 dae 日志确认」 |

---

## 不在本次范围内

- 节点延迟测试（dae 自己后台测，UI 不显示）
- Clash YAML / SIP008 / SSD 等高级订阅格式解析（base64 URI 列表覆盖 90%+ 场景）
- DNS 高级自定义路由（保留 `rawRouting` 文本模式编辑）
- Group 的 `tcp_check_url` / `udp_check_dns` 等 per-group 覆写（用全局值）
- dae 的 `dial_mode` / `tls_implementation` 等高级 global 选项的表单（去文本模式）
- 配置版本管理 / 历史回滚

---

## 文件改动范围

```
luci-app-dae/
├── htdocs/luci-static/resources/view/dae/
│   ├── config.js          ← 大改：增加 group 区块、调整 routing action 下拉、订阅行【获取节点】、节点 cache 联动
│   └── dae-parser.js      ← 增加 _parseGroup / serialize group 块、调整字段 schema
├── root/usr/lib/luci-app-dae/    ← 新增目录
│   └── list-nodes.sh      ← 新增：拉订阅 + base64 + 解析
├── root/usr/share/rpcd/acl.d/luci-app-dae.json  ← 增加 exec 权限：/usr/lib/luci-app-dae/list-nodes.sh
├── po/templates/dae.pot   ← 补 i18n
├── po/zh_Hans/dae.po
└── tests/parser.test.js   ← 增加 group 块 parse/serialize/round-trip 测试
```

dae 主程序包不变。

---

## 升级影响

- DaeConfig 数据结构新增 `groups: GroupDef[]`
- v1 的 routing action 下拉来源（订阅名 + 节点名）→ v2 改成 group 名
- 用户原 v1 的存档配置：parse() 时 group 块为空 → UI 自动建一个 `proxy` 默认组 + 把原 routing 里出现的 action 名当做 group 引用展开
- PKG_VERSION 升到 `2026.05.27`（解决 opkg 不让降级到 1.2 的问题）
