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

> 行号会随改动漂移。变动较大时用 `grep -nE "^function [A-Z]" index.html` 重新定位。

| 行 | 内容 |
|---|---|
| 12–154 | 全部 CSS（`<style>` 内联），含 `.profit-table` 冻结列规则 |
| 162–165 | Supabase 客户端初始化 |
| 170–194 | **站点日期**：`SITE_TZ` / `siteDateStr` / `shiftDate` / `latestFullDay` / `daysAgo` |
| **196–202** | **角色判断**：`roleIsAdmin` / `roleIsLeader` / `roleIsMember` / `canEditConfig` / `roleLabel` |
| 204–251 | 工具函数：格式化、权限过滤、按日聚合 |
| 286–348 | **利润计算核心**：`calcRemainingProfit` / `calcProfitBreakdown` |
| 382 | `LoginPage` |
| 436 | `AppLayout`（侧边栏 + 顶栏 + 路由） |
| 528 | `DashboardPage`（管理员全局，也被分组仪表盘复用） |
| 735 | `GroupDashboardPage`（= DashboardPage scope='group'） |
| 742 | `ProductBoardPage` 产品型号看板 |
| 1027 | `SalesManagementPage` + `SalesModal`(1148) + `SalesBulkModal`(1262) |
| 1412 | `AdExpenseManagementPage` + `AdExpenseBulkModal`(1561) + `AdExpenseModal`(1716) |
| 1831 | `ProfitConfigPage` + `ProfitConfigBulkModal`(2060) + `ProfitConfigModal`(2222) |
| **2393** | **`ModelOwnerPage` 型号负责人指派** |
| 2519 | `UserConfigPage` + `UserModal`(2630) |
| 2749 | `App` 根组件 |

页面路由靠 `AppLayout` 里的 `page` state 切换，没有 URL router。

## 数据模型

5 张 Supabase 表：`users` / `profit_config` / `sales_record` / `ad_expense` / `model_owner`。

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

### `record_date` 存的是【美国站日期】⚠️

不是北京日期。业务流程：美国站的某一天要等到北京时间次日 15:00（夏令时）/ 16:00（冬令时）
才跑完，团队在北京时间当天 15:00 之后录入**美国前一天**的完整数据。

所以代码里没有「今天」这个概念，只有 `latestFullDay()` —— 最新的完整数据日
= 站点当前日期减一天，也就是实际该录入、该统计的那一天。
录入弹窗默认值、各统计区间的结束日、`daysAgo(n)` 的基准，全部走它。

**不要用 `new Date()` 或 `toISOString()` 直接取日期**，那拿到的是 UTC 或浏览器本地日期，
两者都不等于站点日期。时区换算一律走 `siteDateStr()` / `shiftDate()`
（用 `Intl.DateTimeFormat` + `America/Los_Angeles`，夏令时自动切换，不需要手工维护）。

### 产品型号只能来自 `profit_config`

`product_model` 是纯文本、没有主表也没有外键，全靠录入端把关。曾经因为
两个运营对同一个产品用了 `T808` 和 `808` 两种写法，63 条广告记录（$562.96）
两个月不属于任何运营组，管理员和运营看到的广告费总额一直对不上，系统全程没报过警。

现有的三层防护，**新增任何涉及型号的录入口都要照做**：

1. 广告费录入（单条/批量）只能从 `profit_config` 已有型号中选，不许手输
2. 校验对管理员同样生效，不要用 `isAdmin ||` 短路跳过
3. 广告花费管理页有孤儿自检警告条，发现型号不在配置中就提示

利润配置页是型号的源头，必须允许新建，所以那里是输入框 + `datalist` 自动补全，
不是下拉。

### `450` / `450CA` 是两个产品，不要合并

`450CA` 和 `716CA` 的 ASIN 与 `450` / `716` **100% 重叠**，只是加拿大站的 listing。
看起来像是 T808 那种同物异名，**但这是有意为之**（业务确认，2026-09-03）：
报表里就是要把美国站和加拿大站当作两个独立产品看。

看到 ASIN 重叠不要自作主张合并。真要合并的话唯一约束不会冲突
（CA 的记录 country='CA'，US 的是 'US'），但那会改变报表口径。

### 权限口径：三级角色

| 角色 | 可见范围 | 能改什么 |
|---|---|---|
| `admin` 管理员 | 全部数据 | 全部 + 用户管理 |
| `leader` 组长 | 本组全部 | 本组的销量 / 广告 / 利润配置 |
| `member` 组员 | **只看指派给自己的产品型号** | 销量 / 广告；**利润配置只读** |

组员的范围由 `model_owner` 表决定（型号 → 负责人，一对一）。**没有负责人的型号 = 全组共有**：
组长和管理员看得到，组员看不到。指派入口在「型号负责人」页面（管理员/组长可见）。

隔离全部由 RLS 保证，两次迁移都已在生产库执行（2026-09-03）：
`001_strict_group_isolation.sql`（按组隔离）、`002_leader_member_roles.sql`（三级角色）。

前端只用 `roleIsAdmin` / `roleIsLeader` / `roleIsMember` / `canEditConfig` 决定按钮显示，
`filterSalesByScope` / `filterAdsByScope` / `getVisibleConfigs` 是二次过滤——
**都不是安全边界**，真正的隔离在 RLS。

`roleIsLeader` 把历史值 `'operator'` 也算作组长，是 002 迁移窗口期的兼容；库里现已无此值。

## 用户管理：界面上做不了，走 admin API

`UserConfigPage` 只能改角色和运营组，**不能真正增删账号**：

- **没有「添加用户」按钮**。`UserModal` 里创建用户的代码是写好的，但它调
  `sb.auth.admin.createUser()` —— 那是 Admin API，必须 service_role 密钥。
  前端拿的是 anon key，调用必然 403。而把 service_role 放进公开前端等于把
  数据库完全控制权公开，所以只能这样。
- **「删除」是假删除** ⚠️：只删 `users` 表的行，`auth.users` 里的账号还在，
  被删的人用原密码照样能登录；登录后 `LoginPage`（约 365 行）发现没档案，
  还会自动给他重建一个 operator 档案。RLS 下他 `group_name` 为空看不到数据，
  但账号并未吊销。

现行做法：用 service_role 密钥直接调 admin API（凭证见 `tools/backup.py` 的说明）。
新增用户走 `POST /auth/v1/invite` 发邀请邮件，由本人自己设密码 —— 密码不经任何
第三方之手；再往 `users` 表插一行档案（`id` 必须等于 auth 用户的 id）。

要让管理员能在界面上自助增删，需要部署 Supabase Edge Function：service_role
存服务端 secrets，函数先校验调用者是 admin 再操作。团队规模小时不划算，暂缓。

## 已知待办

1. **`profit_config` 的冗余缓存列**：`net_price` / `commission_amount` / `ad_cost_amount`
   与实时计算不一致时，配置页展示的毛利会和锁定利润对不上。目前前端从不写这三列
   （一直是 NULL，所以实际不会触发），但列还在。要么删列，要么加触发器维护。
2. **没有任何外键**：引用完整性完全靠前端（现已有三层录入端防护，见上）。
   孤儿数据已清零，现在补外键的时机是合适的。
3. **Supabase 免费版无自动备份**：动数据结构或批量改删前，先跑 `python3 tools/backup.py`。
4. README 第 27 行让人运行 `schema.sql`，路径应改成 `db/schema.sql`。

已完成：
- `InlineChart` 的 `createRef` 笔误、日期口径改按美国站时区（2026-08-31）
- 利润配置表三项易用性改进、冻结列（2026-08-31）
- T808 同物异名清理 + 三层录入防护（2026-09-03）
- **RLS 严格按组隔离已执行**（2026-09-03，见 `db/migrations/001_strict_group_isolation.sql`）

## 开发约定

- **不要引入构建工具**，保持「打开 index.html 就能跑」
- **`.main-content` 的 `min-width:0` 不能删**。它是 flex 子项，去掉后宽表格会把整个页面
  撑宽，`.table-wrap` 不再内部滚动，利润配置的冻结列会直接失效（sticky 相对最近的
  滚动祖先定位，那个祖先必须真的在滚）
- 表格类的改动要在**完整祖先链**下验证（`app-layout > main-content > page-content >
  card > table-wrap > table`）。脱离 flex 布局单独测一张表，测不出上面这类问题
- 新增 UI 一律用 `React.createElement`，不要写 JSX（页面没有 Babel）
- 颜色用顶部 `:root` 里的 CSS 变量（`--primary` 等）
- 改动先开分支，不直接推 `main`
- 本地预览：`cd ~/GitHub/win && python3 -m http.server 8000`，浏览器开 http://localhost:8000
  （这样打开会连**生产 Supabase**，登录后看到的是真实数据，改动要当心）
- **验证 UI 改动用 `python3 tools/mock-preview.py --serve`**：把 Supabase 客户端换成内存桩，
  免登录、不碰生产库，跑的仍是真实组件树 / 真实 CSS / 真实祖先层级。
  假数据里预埋了 T808 孤儿广告记录，可直接验证「型号不在配置中」的警告条。
  改假数据就编辑脚本里的 `DB` 常量
- 数据库结构有变更，同步更新 `db/schema.sql` 和本文件的数据模型章节
