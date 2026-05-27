# dae 配置前端 UI 设计文档

**日期**: 2026-05-27  
**项目**: luci-app-dae（路由器 LuCI 界面）  
**目标**: 替换原始文本编辑器为结构化表单 UI，降低 dae 配置门槛

---

## 背景

dae 使用自定义 DSL 格式的配置文件（`/etc/dae/config.dae`）。现有 `luci-app-dae` 的 Config 页只提供纯文本编辑器，小白用户很难上手。本设计在保留文本编辑器的同时，新增结构化表单 UI，两者双向同步。

---

## 实现方案

**方案 A：客户端 JS 解析**，纯前端实现，不修改路由器后端。

- 在 `config.js` 里实现 dae DSL 的解析（`parse`）和序列化（`serialize`）
- 表单 UI 和文本编辑器共享同一份文件内容
- 不增加后端脚本，不影响固件体积

---

## 文件改动范围

只修改 `package/luci-app-dae/` 下的文件：

```
package/luci-app-dae/
  htdocs/luci-static/resources/view/dae/
    config.js          ← 主要改动：加 Tab 切换 + 表单 UI
    dae-parser.js      ← 新增：dae DSL 解析器
  po/templates/dae.pot ← 补充新 i18n key
  po/zh_Hans/dae.po   ← 补充中文翻译
```

---

## UI 结构

### Tab 切换

Config 页顶部增加两个 Tab：

```
┌──────────┬──────────┐
│  表单模式  │  文本模式  │
└──────────┴──────────┘
```

- 点击「文本模式」：调用 `serialize(formData)`，将表单数据写入文本编辑器内容，再展示文本编辑器
- 点击「表单模式」：调用 `parse(text)`，将文本内容解析为结构化数据，填入表单
- **保存按钮共用**：无论哪个 Tab 激活，保存的都是当前 Tab 对应的内容（文本 or 表单序列化结果）

---

## 表单区块设计

### 1. 订阅（subscription {}）

表格形式，每行一条订阅：

| 名称 | 订阅 URL | 操作 |
|------|----------|------|
| `my_sub` | `https://...` | 删除 |
| ＋ 添加订阅 | | |

- 名称：只允许字母、数字、下划线
- URL：文本输入框，无格式校验（dae 自己会验证）

### 2. 节点（node {}）

表格形式，每行一个手动节点 URI：

| 名称 | 节点 URI（ss:// / vmess:// / trojan:// 等） | 操作 |
|------|---------------------------------------------|------|
| `node1` | `ss://...` | 删除 |
| ＋ 添加节点 | | |

- 此区块默认**折叠**（使用订阅的用户通常不需要手动填节点）

### 3. 路由规则（routing {}）

可排序的规则列表，每行一条：

| 条件类型 | 条件值 | 动作 | 操作 |
|----------|--------|------|------|
| `domain` | `geosite:cn` | `direct` | ↑↓ 删除 |
| `dip` | `geoip:cn` | `direct` | ↑↓ 删除 |
| `dip` | `geoip:private` | `direct` | ↑↓ 删除 |
| ＋ 添加规则 | | | |
| **fallback** | — | `my_proxy` ▼ | — |

**条件类型下拉选项**：
- `domain` — 域名匹配（支持 `geosite:xxx` / 直接域名）
- `dip` — 目标 IP（支持 `geoip:xxx` / CIDR）
- `sip` — 源 IP
- `pname` — 进程名（本机流量）
- `l4proto` — 协议（tcp/udp）
- `port` — 目标端口

**动作下拉选项**：根据已配置的订阅名称 + 节点名称动态生成，加上固定选项 `direct` / `block`

**fallback**：单独一行，下拉框选择动作（不可删除、不可排序）

### 4. DNS

#### 4.1 上游服务器（dns.upstream {}）

| 名称 | URL | 操作 |
|------|-----|------|
| `alidns` | `udp://223.5.5.5:53` | 删除 |
| `googledns` | `tcp+udp://8.8.8.8:53` | 删除 |
| ＋ 添加上游 | | |

URL 格式提示：支持 `udp://`、`tcp://`、`tcp+udp://`、`https://`（DoH）、`tls://`（DoT）

#### 4.2 DNS 路由（简化）

两个下拉框：

```
国内 DNS：[ alidns ▼ ]
国外 DNS：[ googledns ▼ ]
```

选项来自 4.1 已定义的上游服务器名称。

实际生成的 dns.routing 逻辑（固定模板）：
```
request {
  qname(geosite:cn) -> <国内DNS>
  fallback: <国外DNS>
}
response {
  upstream(<国外DNS>) -> accept
  !qname(geosite:cn) -> <国外DNS>
  fallback: accept
}
```

> 高级 DNS 路由规则（自定义 request/response 规则）不在表单里暴露，保留文本模式编辑。

### 5. 全局设置（global {}）——折叠

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `log-level` | `info` | 下拉：error / warn / info / debug / trace |
| `lan-interface` | `br-lan` | 文本输入 |
| `wan-interface` | `eth1` | 文本输入 |
| `allow-insecure` | `false` | 开关 |
| `auto-config-kernel-parameter` | `true` | 开关 |

---

## 解析器设计（dae-parser.js）

### parse(text) → DaeConfig

```
DaeConfig {
  global:       { [key]: value }
  subscription: { [name]: url }
  node:         { [name]: uri }
  routing: {
    rules: [ { condType, condValue, action } ]
    fallback: string
  }
  dns: {
    upstream:  { [name]: url }
    domestic:  string   // upstream name
    foreign:   string   // upstream name
    rawRouting: string  // 非标准路由规则保留原文
  }
  rawOther: string  // 无法解析的块，原样保留
}
```

解析策略：
1. 按 `blockName {` 分割顶层块
2. subscription / node 块：用 `name: "url"` 正则提取 key-value
3. routing 块：逐行解析，`-> ` 分割条件和动作，识别 `fallback:`
4. dns 块：提取 upstream key-value；routing 子块尝试匹配简化模板，失败则存入 `rawRouting`
5. global 块：逐行提取 `key: value`
6. 无法识别的块 → 存入 `rawOther`，序列化时原样输出

### serialize(config) → string

按固定顺序输出：`global` → `subscription` → `node` → `dns` → `routing`

保留 `rawOther` 在末尾原样输出，保证不丢失用户的自定义内容。

---

## 错误处理

| 场景 | 处理方式 |
|------|----------|
| 文本内容无法解析 | 切换到表单时显示警告「配置包含无法解析的内容，部分字段可能为空」，仍然尽力填充可解析的部分 |
| 表单有空的必填项 | 保存时高亮提示，阻止提交 |
| 名称重复（订阅/节点） | 实时校验，输入框变红 |
| 切换 Tab 时文本有语法错误 | 提示「文本格式有误，请先修正再切换到表单模式」 |

---

## 不在本次范围内

- 从订阅 URL 拉取并展示节点列表（需要后端配合）
- 复杂的自定义 DNS routing 规则编辑器
- 代理组（group {}）管理
- 配置文件版本管理 / 历史记录
