# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

邻选（邻选社区团购）— 为小区团长打造的微信扫码下单工具。单文件 SPA（`order.html` ~5135 行） + Supabase PostgreSQL 后端（`supabase-schema.sql` ~1700 行）。零构建工具、零框架、零 npm 依赖，编辑即部署。

- **前端托管**：GitHub Pages（免费，全球 CDN）
- **数据库**：Supabase 免费层（500MB 存储/月，PostgreSQL）
- **安全模型**：SHA-256 密码哈希 + SECURITY DEFINER 函数 + RLS 策略 + RBAC 权限（super_admin / leader）
- **认证**：`admin_sessions` 表管理 session token，`require_admin(p_token)` 函数验证身份

## 核心文件职责

| 文件 | 行数 | 角色 |
|------|------|------|
| `order.html` | ~5135 | 完整前端应用：顾客下单端 + 团长后台 + 系统初始化 |
| `supabase-schema.sql` | ~1700 | 数据库完整定义：9 张表 + 40+ RPC 函数 + RLS + 索引 + 种子数据 |
| `landing.html` | - | 项目宣传/引导页，分享给其他团长 |
| `setup-guide.html` | - | 图文部署教程 |
| `admin-guide.html` | - | 团长操作手册 |
| `customer-guide.html` | - | 邻居下单指南 |
| `FULL-TEST-CHECKLIST.md` | - | 109 条功能测试用例全量清单 |

---

## order.html 架构详解

### URL 路由（hash-based）

```
默认 (# 或空) → 顾客下单端
#admin       → 团长后台管理
#setup       → 系统初始化（Supabase 连接配置）
```

路由通过 `window.addEventListener('hashchange', ...)` 和页面加载时的 `switchMode()` 驱动。

### 模块级全局状态（~2107-2116 行）

```js
let cart = {};                    // 购物车 { [`${productId}-${specName}`]: { productId, productName, specName, specPrice, quantity } }
let activeRoundId = null;         // 当前活跃轮次 ID（顾客端）
let customerRoundId = null;       // 顾客端选中的轮次 ID
let adminRoundId = null;          // 团长后台选中的轮次 ID
let adminProductRoundId = null;   // 商品管理页当前轮次 ID
let cachedProducts = [];          // 当前产品列表缓存
let cachedSummaryByProduct = {};  // 产品汇总统计 { [productId]: { qty, shareTotal, isSplitUnit, fillLabel, ... } }
let teamCountMap = new Map();     // 产品 → 队伍数映射
let _loadGen = 0;                 // loadCustomerProducts generation counter
let customerTeamProductIds = {};  // 顾客已加入队伍的产品 { [productId]: true }
```

重要：这些变量在 async 函数间共享。任何 async 函数在 await 间隙修改这些变量前必须确保没有竞态（见后文）。

### 顾客端关键函数

| 函数 | 行号 | 职责 |
|------|------|------|
| `loadCustomerProducts()` | ~2117 | 核心加载：获取轮次→产品→订单统计→顾客队伍→队伍计数→渲染商品列表 |
| `buildProductCardHtml(p, teamCountMap)` | ~2360 | 构建单张商品卡片 HTML（含组队按钮） |
| `refreshProduct(productId)` | ~2380 | 刷新单张商品卡片（购物车加减触发） |
| `updateCartItem(cartKey, delta)` | ~2406 | 购物车数量增减 |
| `selectSpec(productId, specName, ...)` | ~2392 | 选择/切换商品规格 |
| `submitOrder()` | ~2650 | 提交订单（含幂等保护、深拷贝购物车） |
| `lookupOrders()` | ~2926 | 顾客查/改订单 |
| `formatUnitLabel(unitQty, specName)` | ~1220 | 格式化单位标签（小数额→分数、普通→整数） |

### 团长端关键函数

| 函数 | 行号 | 职责 |
|------|------|------|
| `renderAdminTab(tab)` | ~3300 | 后台 Tab 路由（products/orders/summary/payment/settings） |
| `renderOrderManager()` | ~3339 | 订单汇总页（按人明细 + 砍单记录 + 售后申请 + 组队） |
| `renderPaymentSummary()` | ~3773 | 收款清单 |
| `buildProductSummary()` | ~1069 | 商品采购汇总（含组队商品 `hasShare`/`shareTotal` 处理） |
| `importRoundProducts()` | ~1486 | Excel 批量导入商品 |
| `exportRoundProducts()` | ~1430 | Excel 导出商品（含隐藏 JSON 列） |
| `loadProductTeams(pId)` | ~4876 | 组队详情弹窗（区分队长/队员按钮） |
| `adminBatchCancel()` | ~4363 | 批量砍单弹窗 |

### HTML/CSS 渲染辅助函数

| 函数 | 行号 | 用途 |
|------|------|------|
| `escHtml(str)` | ~4686 | HTML 实体转义：`&` `<` `>` `"` |
| `escAttr(str)` | ~4689 | 属性值转义：`&` `<` `>` `"` `'` |
| `toast(msg, type)` | ~4670 | 弹出式消息提示（替换式，新消息覆盖旧消息，2.5s 自动消失） |
| `formatQty(n)` | ~1164 | 数量格式化（toFixed(8)+去尾零，大数走 toLocaleString 兜底） |

### 数据流

```
顾客端:
  loadCustomerProducts()
    ├─ await sb.from('rounds')       → availableRounds
    ├─ await sb.from('products')     → cachedProducts
    ├─ await sb.rpc('get_round_order_stats') → cachedSummaryByProduct
    ├─ await sb.rpc('get_customer_teams')    → customerTeamProductIds
    └─ await sb.from('teams')        → teamCountMap
    └─ buildProductCardHtml() × N    → DOM

团长端:
  所有操作通过 adminRpc() 封装:
    function adminRpc(fn, params) {
      const token = localStorage.getItem('gbs_token');
      return sb.rpc(fn, { p_token: token, ...params });
    }
```

---

## supabase-schema.sql 架构详解

### 表结构

| 表 | 用途 | 关键列 |
|---|------|--------|
| `leaders` | 团长/管理员账号 | `id`, `username`, `password_hash`, `role`(super_admin/leader) |
| `rounds` | 团购轮次 | `id`, `name`, `leader_id`, `leader_name`, `is_active`, `cutoff_time`, `status` |
| `products` | 商品 | `id`, `round_id`, `name`, `specs`(JSONB), `tags`, `stock`, `is_active`, `is_team`, `image` |
| `orders` | 订单 | `id`, `round_id`, `customer_name`, `items`(JSONB), `total`, `status`, `note` |
| `teams` | 组队 | `id`, `round_id`, `product_id`, `initiator_name`, `target_qty`, `split_count`, `status`(active/filled/cancelled) |
| `team_members` | 队员 | `id`, `team_id`, `customer_name`, `spec_name`, `share_qty`, `reserved_qty` |
| `after_sales` | 售后申请 | `id`, `round_id`, `customer_name`, `content`, `images`(JSONB), `status`(unread/read/resolved) |
| `feedback` | 用户反馈 | `id`, `round_id`, `customer_name`, `content`, `images`(JSONB), `status` |
| `admin_sessions` | 管理员会话 | `leader_id`, `token`, `expires_at` |

### 权限控制三层模型

```
Layer 1: require_admin(p_token)
  → 查 admin_sessions 表，验证 token 有效性，返回 (leader_id, role)
  → 所有管理函数第一个调用

Layer 2: check_super_admin(role)
  → IF role <> 'super_admin' THEN RAISE EXCEPTION
  → 用于 leader 管理（增删团长、重置密码等）

Layer 3: check_round_owner(leader_id, role, round_id)
  → IF role = 'super_admin' THEN RETURN（直接放行）
  → 查 rounds.leader_id，校验是否属于该团长
  → 用于所有轮次级数据和修改操作
```

### 关键 SQL 函数分组

**认证与权限：**
- `require_admin(p_token)` → `RETURNS TABLE(leader_id UUID, role TEXT)` — 必须用 `RETURN QUERY`，不能用 `SELECT INTO` 给输出参数赋值
- `check_round_owner(p_leader_id, p_role, p_round_id)` — super_admin 直接绕行
- `check_super_admin(p_role)` — 仅 super_admin 可通过
- `register_leader(p_username, p_password_hash)` — 注册团长（无 p_plain_password）
- `admin_create_leader(p_token, p_username, p_password_hash)` — 超管创建团长
- `admin_list_leaders(p_token)` — 列出所有团长（不返回密码明文）
- `admin_reset_leader_password(p_token, p_leader_id, p_password_hash)` — 超管重置密码

**轮次管理：**
- `admin_create_round(p_token, p_name, p_cutoff_time, p_leader_name)` — leader_name 为空时自动取创建者 username
- `admin_update_round(p_token, p_id, ...)` — 修改轮次设置
- `admin_activate_round(p_token, p_id)` — 开团（状态→进行中）
- `admin_stop_round(p_token, p_id)` — 停止轮次
- `admin_delete_round(p_token, p_id)` — 删除 + 级联清理（after_sales→feedback→team_members→teams→orders→products→rounds）

**商品管理：**
- `admin_save_product(p_token, p_id, p_name, p_image, p_specs, p_tags, p_stock, p_is_active, p_round_id, p_is_team)` — 创建/更新商品。注意有 5 个 DROP 清理旧重载
- `admin_toggle_product(p_token, p_id, p_is_active)` — 上下架切换
- `admin_delete_product(p_token, p_id)` — 删除商品（取消 active+filled 队伍）

**订单核心：**
- `create_order(p_customer_name, p_items, p_note, p_total, p_round_id)` — 下单（含 FOR UPDATE 锁 + advisory lock 幂等保护）
- `lookup_orders(p_customer_name, p_round_id)` — 顾客查单
- `admin_get_orders(p_token, p_round_id)` — 团长查单（含 round_owner 校验）
- `cancel_order(p_order_id, p_customer_name)` — 顾客取消订单（组队订单同步清理队伍）
- `admin_cancel_order(p_token, p_order_id, p_note)` — 团长取消订单
- `admin_remove_order_items(p_token, p_customer_name, p_round_id, p_items_to_cancel, p_note)` — 原子砍单/部分砍单，全部砍完自动 SET status='cancelled'
- `admin_confirm_order_weight(p_token, p_order_id, p_actual_weight)` — 称重商品确认

**组队系统：**
- `create_team(p_round_id, p_product_id, ...)` — 创建队伍（含轮次状态 FOR UPDATE 检查 + is_team 校验）
- `join_team(p_team_id, ...)` — 加入队伍（ROUND(SUM(share_qty), 3) 拼满判断）
- `create_team_orders(p_team_id)` — 队伍满员自动生成订单（quantity=1每人一条，purchase_qty = share_qty，前端已预除 split_count）
- `get_product_teams(p_product_id, p_round_id)` — 查商品队伍列表
- `admin_get_teams(p_token, p_round_id)` — 团长端队伍视图（含 round_owner 校验）
- `cancel_team(p_team_id)` — 解散队伍（filled 状态同步取消关联的组队订单）

**订单统计与查询：**
- `get_round_order_stats(p_round_id)` — 按商品汇总采购量（区分称重份额和普通数量）
- `admin_get_cancelled_orders(p_token, p_round_id)` — 砍单记录
- `admin_get_after_sales(p_token, p_round_id)` — 售后列表
- `admin_get_feedback(p_token)` — 反馈列表（super_admin 看全部，leader 只看自己轮次）
- `admin_update_after_sales_status(p_token, p_id, p_status)` — 售后状态更新（含值校验）
- `admin_mark_feedback_read(p_token, p_id)` — 标记反馈已读

### 表级安全

- 所有表启用 RLS（`ALTER TABLE ... ENABLE ROW LEVEL SECURITY`）
- 顾客端通过 RPC 函数操作（策略通常为 `FOR INSERT/UPDATE/DELETE USING (true)` + SECURITY DEFINER）
- 函数全部用 `SECURITY DEFINER SET search_path = public`（56 处，含 plpgsql 和 sql）

### 索引

```sql
-- 主键索引（自动）
-- 外键查询索引
CREATE INDEX IF NOT EXISTS idx_after_sales_round ON after_sales (round_id);
CREATE INDEX IF NOT EXISTS idx_feedback_round ON feedback (round_id);
CREATE INDEX IF NOT EXISTS idx_teams_product_round_status ON teams (product_id, round_id, status);
-- round_id 单列索引建议后续补上（admin_get_teams 的 WHERE round_id IN (...) 查询）
```

---

## 部署

### SQL 部署
在 Supabase SQL Editor 中**全量执行** `supabase-schema.sql`。文件使用 `CREATE OR REPLACE` + `IF NOT EXISTS` 可重复安全执行。

### 前端部署
1. 在 GitHub 创建仓库
2. 上传所有 HTML 文件
3. Settings → Pages → Source: main 分支 → Save
4. 打开 `https://<username>.github.io/<repo>/`，在初始化页面填入 Supabase URL 和 Anon Key
5. 网址后加 `#admin` 注册/登录团长账号

### 历史手动操作
如果从旧版 schema 升级，需手动执行：
```sql
ALTER TABLE leaders DROP COLUMN IF EXISTS password_plain;
-- 2026-05-22: purchase_qty 历史数据修正已加入 supabase-schema.sql 末尾（quantity * unit_qty 重算）
```

---

## 开发注意事项

### JS 侧

**竞态保护（async 函数修改全局状态）：**
```js
let _loadGen = 0;
async function loadXxx() {
  const gen = ++_loadGen;
  const { data } = await someQuery();
  if (_loadGen !== gen) return;  // 过期调用，丢弃结果
  // ... 安全修改全局状态和 DOM
}
```
不可用 AbortController（不兼容 Supabase SDK），不可信手在 await 后直接写全局变量。

**读取 adminRoundId 快照：**
```js
function renderXxx() {
  const roundId = adminRoundId;  // 入口快照，防止渲染中用户切换轮次
  // ... 后续所有异步操作后用 roundId 而不是 adminRoundId
}
```
已应用此模式的函数：`renderOrderManager`、`renderPaymentSummary`、`batchStopAllRounds`、`batchActivateAllRounds`、`batchDeleteAllInactive`。

**XSS 防护：**
- HTML 文本内容：`escHtml(userData)` — 转义 `&` `<` `>` `"`
- HTML 属性值：`escAttr(userData)` — 转义 `&` `<` `>` `"` `'`
- 禁止未转义的用户/数据库数据直接插 innerHTML

**localStorage 安全：**
```js
try { localStorage.setItem(key, val); } catch(e) {}  // quota 满/隐私模式不炸页面
```
已在 `saveConfig`、`setSession`、登录流程、`saveTagOrder`、结算流程中应用。

**parseInt 规范：**
```js
parseInt(val, 10)  // 必须带 radix，禁止 parseInt(val) 裸调
```

**深拷贝购物车（提交前）：**
```js
submitting = true;
const frozenCart = JSON.parse(JSON.stringify(cart));  // 防止 await 间隙购物车被修改
```
JSON 深拷贝仅对纯基本类型对象安全（cart 只含 string/number），不适用于 Date/函数/循环引用。

**内存管理：**
- Set 只增不删会导致无限增长 → `cancellingOrders.delete(orderId)` 放在 `try...finally` 中
- 定时器 `stockPollTimer` 用 `clearInterval` 正确清理

### SQL 侧

**RETURNS TABLE 函数必须用 RETURN QUERY：**
```sql
-- 错误（不会返回任何行）
SELECT * INTO require_admin.leader_id, require_admin.role FROM ...;

-- 正确
RETURN QUERY SELECT s.leader_id, l.role FROM ...;
```

**TOCTOU 防护 — FOR UPDATE 行锁：**
```sql
SELECT * INTO v_round FROM rounds WHERE id = p_round_id AND is_active = true FOR UPDATE;
-- 锁住行直到事务结束，防止并发修改
```
应用位置：`create_order`、`create_team`、`join_team` 的轮次/商品检查。

**幂等保护 — Advisory Lock：**
```sql
PERFORM pg_advisory_xact_lock(hashtext(p_customer_name || ':' || p_round_id::text));
```
事务级锁，COMMIT/ROLLBACK 时自动释放。只串行化同一顾客+轮次组合。

**精度统一（组队份额）：**
```sql
-- share_qty 是 NUMERIC(10,8)，target_qty 是 NUMERIC(10,3)
-- 求和后必须 ROUND(SUM(share_qty), 3) 再与 target_qty 比较
SELECT COALESCE(ROUND(SUM(share_qty), 3), 0) INTO v_current FROM team_members WHERE team_id = p_team_id;
```

**FK 依赖链清理顺序：**
删除父记录前必须按依赖逆序清理子表：
```
after_sales → feedback(SET NULL) → team_members → teams → orders → products → rounds
```

**函数重载 DROP：**
修改参数列表的函数前必须 DROP 所有旧版本签名，漏掉任何一个会报 `Could not choose the best candidate function`。

**SECURITY DEFINER search_path：**
所有函数声明必须带 `SET search_path = public`（防御 CVE-2018-1058 搜索路径劫持）。

**查询函数权限校验：**
- 查询类函数加 `check_round_owner`（admin_get_* 系列 7 个已补）
- 写操作类函数加 `check_round_owner`
- 超管专属操作加 `check_super_admin`
- `check_round_owner` 内置 super_admin 绕行，不影响超管视角

### 已知死锁风险

`create_order`/`create_team`（锁顺序：rounds → products）和 `join_team`→`create_team_orders`（锁顺序：teams → products → rounds）加锁顺序相反。

- PostgreSQL 自动检测死锁，回滚其中一方（报 `deadlock detected`）
- 触发条件：同一轮次同一商品同时有人创建队伍/下单 + 另一个队伍刚好满员
- 概率低，后果可控（用户重试即可）

---

## 修复工作流

采用双 agent 模式：实施 → 独立审查。

```
Task ─→ Implementer Agent（改代码）─→ Reviewer Agent（独立验证）─→ ✅ / ❌
```

审查结论必须明确：**通过** 或 **有问题**（附具体描述）。

OpenSpec 变更管理（`openspec/changes/<name>/`）：
- `/opsx:propose <描述>` — 创建变更（自动生成 proposal/design/specs/tasks）
- `/opsx:apply [name]` — 执行 tasks.md 中的任务列表
- `/opsx:archive [name]` — 归档已完成变更

---

## 2026-05-22 组队商品采购量修复

### 问题1: purchase_qty 双重除法

**根因**：`create_team_orders` 对 `share_qty` 重复除以 `split_count`。

前端计算 `shareQty` 时已经除了 `split_count`：
```js
// order.html:5008
const shareQty = parseFloat(((targetQty / splitCount) * shareCount).toFixed(8));
// 例：1份分2份取1份 → shareQty = (1/2)*1 = 0.5  ← 已经是实际采购量
```

但 SQL 又除了一次：
```sql
-- 修复前 (supabase-schema.sql:1621)
'purchase_qty', ROUND(v_member.share_qty * v_team.target_qty / v_team.split_count, 6)
-- 例：0.5 * 1 / 2 = 0.25  ← 多除了一次！
```

**修复**：`purchase_qty` 直接用 `share_qty`（它本身就是采购量）。
```sql
'purchase_qty', ROUND(v_member.share_qty, 6),
```

**约定**：`team_members.share_qty` 存的就是实际采购量（前端预除过），SQL 层不应再除。

### 问题2: quantity 语义错位（份数 vs 购买件数）

**根因**：`create_team_orders` 把 `quantity` 设为份数（5/5 → quantity=5），但前端 10+ 处展示都把 `quantity` 当购买件数渲染。

**方案选择**：改 SQL 一行 vs 改前端 10+ 处 → 选 SQL。一劳永逸，且语义更正确（每人一条订单记录，quantity=1）。

**修复**：
```sql
-- 修复前
'quantity', ROUND(v_member.share_qty / (v_team.target_qty / v_team.split_count))::int,  -- 份数
-- 修复后
'quantity', 1,  -- 每人一条订单记录，实际采购量见 purchase_qty
```

**约定**：组队订单 quantity 恒为 1。份数信息保留在 `unit_qty`（每份量）和 `purchase_qty`（总采购量）。

### 历史数据修正

`supabase-schema.sql` 末尾新增 `DO $$ ... END $$` 块：
- 遍历所有 `note='[组队]'` 的订单
- 用 `quantity * unit_qty` 重算正确的 `purchase_qty`（两个字段原本就是对的）
- **不修改历史 quantity**（可能被部分砍单修改过）

### 影响范围（两个修复合计）

| 位置 | 之前 | 修复后 |
|------|------|--------|
| Excel 导出-折算采购数量 | 1/4, 1/9 | 1/2, 1/3 |
| 收款清单-商品行 | ×5（5/5时） | ×1 |
| 订单管理-取消弹窗 | max=5 | max=1 |
| 收款清单-按件均摊 | 比例失真 | 正确 |
| 拼满状态判断 | 可能误判 | 正确 |
| 砍单/取消-库存退回 | 退少了 | 正确 |

### 待办

- [ ] 部署 `create_team_orders` 到 Supabase SQL Editor
- [ ] 执行历史数据修正 DO 块
- [ ] `NOTIFY pgrst, 'reload schema'`
- [ ] `order.html` 无需修改（前端只读 display，SQL 源数据修了自动对）

---

## 项目记忆

跨会话上下文存储在 `~/.claude/projects/C--Users---/memory/project-community-group-buying.md`，包含：
- 2026-05-14~15 的 15 个原始问题修复
- 2026-05-15 gstack-review 全量审计的 10 严重 + 18 信息性问题修复
- 完整部署清单（SQL + 前端）
- 全部关键经验和技术教训
