# 来财啦利润计算系统 — 项目说明

## 这是什么

亚马逊卖家的每日销量 / 广告 / 利润追踪系统。管理员看全局，运营按组看自己的数据。

- 线上地址：https://tomvista888.github.io/win/
- 仓库：https://github.com/TomVista888/win （Public）

## 架构

**整个应用就是一个文件 `index.html`（约 2500 行）**，没有构建步骤。

- React 18 UMD，**不用 JSX**，全部是 `React.createElement(...)`
- Chart.js 4.4.0 画图
- Supabase 做后端（Auth + PostgreSQL），项目 ref `heluodmvrwmnwxrtogmc`
- 部署：push 到 `main` → GitHub Pages 自动发布

> ⚠️ 改动 `main` 就是改线上。任何改动先开分支。

### 文件内的结构（按行号）

| 行 | 内容 |
|---|---|
| 12–138 | 全部 CSS（`<style>` 内联） |
| 146–149 | Supabase 客户端初始化 |
| 151–196 | 工具函数：格式化、日期、权限过滤、按日聚合 |
| 231–293 | **利润计算核心**：`calcRemainingProfit` / `calcProfitBreakdown` |
| 327 | `LoginPage` |
| 381 | `AppLayout`（侧边栏 + 顶栏 + 路由） |
| 466 | `DashboardPage`（管理员全局，也被分组仪表盘复用） |
| 672 | `GroupDashboardPage`（= DashboardPage scope='group'） |
| 679 | `ProductBoardPage` 产品型号看板 |
| 964 | `SalesManagementPage` + `SalesModal` + `SalesBulkModal` |
| 1349 | `AdExpenseManagementPage` + 两个 Modal |
| 1733 | `ProfitConfigPage` + 两个 Modal |
| 2258 | `UserConfigPage` + `UserModal` |
| 2487 | `App` 根组件 |

页面路由靠 `AppLayout` 里的 `page` state 切换，没有 URL router。

## 数据模型

4 张 Supabase 表：`users` / `profit_config` / `sales_record` / `ad_expense`。

**权威 DDL 见 [`db/schema.sql`](db/schema.sql)**，已从生产库核实（2026-08-31）。下面是速查摘要。

### profit_config — 利润测算配置（每个 ASIN-国家一行）
`id`(uuid) `asin_country` `asin` `country`(US/CA/AU) `product_model` `operator_group` — 均 NOT NULL
`list_price`(NOT NULL) `discount_rate`(0) `platform_commission_rate`(0.15) `ad_cost_rate`(0)
`shipping_cost`(尾程,0) `storage_cost`(仓储,0) `after_sale_rate`(0) `purchase_cost`(采购,0) `freight_cost`(头程,0)
`created_at` `updated_at`

⚠️ `net_price` / `commission_amount` / `ad_cost_amount` 是**冗余缓存列**（nullable，无默认值）。
`calcProfitBreakdown` 优先读它们，`calcRemainingProfit` 永远重算 → 缓存过期时两者会不一致。

### sales_record — 每日销量
`id`(uuid) `asin_country` `asin` `country` `record_date` `product_model` `sales_volume`(NOT NULL,默认0)
`locked_profit`(NOT NULL) — 录入时从配置表快照的单件毛利
`asin_profit` — **生成列** `GENERATED ALWAYS AS (sales_volume::numeric * locked_profit) STORED`，
不可写入，前端也从不写它。所有报表利润都源自这一列。
`created_at` `updated_at`（有 `update_updated_at_column()` 触发器）

唯一约束 `(asin_country, record_date)`，前端 upsert 的 `onConflict` 依赖它。

### ad_expense — 每日广告
`id`(uuid) `record_date` `product_model` `country` — 均 NOT NULL
`ad_cost`(0) `ad_sales`(0) `total_sales`(0) `ld_bd_cost`(0) `category_rank`(nullable) `created_at`

唯一约束 `(record_date, product_model, country)`，两处录入都用 upsert 对齐了它，不会重复累加。

### users
`id`(uuid，实际存 auth.uid()，但默认值是 `gen_random_uuid()`) `email` `name`
`role`(默认 'operator') `group_name`(nullable，一组/二组/三组) `created_at`

### 归属关系（重要）
`sales_record` 和 `ad_expense` **表内都没有 `operator_group` 字段**，分组归属靠反查：
- `sales_record.asin_country` → `profit_config.asin_country` → `operator_group`
- `ad_expense.product_model` → `profit_config.product_model` → `operator_group`

## 利润计算口径

```
净价     = list_price × (1 − discount_rate)
佣金     = 净价 × platform_commission_rate
广告费   = 净价 × ad_cost_rate          ← 预估值
售后费   = 净价 × after_sale_rate
线上成本 = 佣金 + 广告费 + storage_cost + 售后费 + shipping_cost
线下成本 = purchase_cost + freight_cost
剩余毛利 = 净价 − 线上成本 − 线下成本   ← 这就是 locked_profit
```

仪表盘的「周期总利润」：
```
总利润 = Σ sales_record.asin_profit − Σ (ad_expense.ad_cost + ad_expense.ld_bd_cost)
```

**锁定利润的意义**：录入销量当时把配置表的剩余毛利快照进 `locked_profit`，之后改价格不影响历史数据。

## 硬约定

### `ad_cost_rate` 必须保持为 0 ⚠️

`locked_profit` 的公式里已经按 `ad_cost_rate` 扣过一次**预估**广告费，而仪表盘算总利润时又减了一次
`ad_expense` 里的**实际**广告费：

```
总利润 = Σ asin_profit − Σ (ad_cost + ld_bd_cost)
```

业务上确认（2026-08-31）：**配置里广告率一律填 0**，靠 `ad_expense` 记实际广告费。
所以目前口径是对的。但只要有人在配置页把广告率填成非 0，那条 ASIN 的利润就会被**静默扣两次**，
报表上看不出任何异常。改动利润相关代码时务必守住这条。

### 权限口径：严格按组隔离

业务上确认（2026-08-31）：operator 只能看和改**自己组**的销量 / 广告 / 利润配置；admin 看全部。
隔离由 RLS 保证，见 `db/migrations/001_strict_group_isolation.sql`。
前端的 `filterSalesByScope` / `filterAdsByScope` / `getVisibleConfigs` 是二次过滤，**不是安全边界**。

## 已知待办

1. **RLS 修复未执行**：`db/migrations/001_strict_group_isolation.sql` 已写好但还没在 Supabase 上跑。
   在跑之前，`sales_record` / `ad_expense` 的所有操作策略都是 `USING(true)`，
   任何登录用户可读/改/删全部数据（仅限已登录用户，未对公网开放）。
2. **`profit_config` 的冗余缓存列**：`net_price` / `commission_amount` / `ad_cost_amount`
   与实时计算不一致时，配置页展示的毛利会和锁定利润对不上。要么删列全部实时算，要么加触发器维护。
3. **日期用 UTC**：`todayStr()` / `daysAgo()` 走 `toISOString()`。北京时间 00:00–08:00 之间，
   「当天总利润」会算成前一天的。
4. **`InlineChart` 用了 `React.createRef()`**（第 217 行）而不是 `useRef`，每次渲染都新建 ref。
   同文件的 `ChartCard` 是对的，这里是笔误，属于潜在 bug。
5. **没有任何外键**：引用完整性完全靠前端。补之前要先清理孤儿数据。
6. README 第 27 行让人运行 `schema.sql`，路径应改成 `db/schema.sql`。

## 开发约定

- **不要引入构建工具**，保持「打开 index.html 就能跑」
- 新增 UI 一律用 `React.createElement`，不要写 JSX（页面没有 Babel）
- 颜色用顶部 `:root` 里的 CSS 变量（`--primary` 等）
- 改动先开分支，不直接推 `main`
- 本地预览：`cd ~/GitHub/win && python3 -m http.server 8000`，浏览器开 http://localhost:8000
- 数据库结构有变更，同步更新 `db/schema.sql` 和本文件的数据模型章节
