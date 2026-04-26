# Amazon利润追踪系统

专业的亚马逊卖家利润管理系统，用于追踪每日销量和利润数据。

## 功能特性

### 核心功能
- **数据仪表盘** - 管理员查看全局数据统计
- **分组仪表盘** - 操作员查看所属组数据
- **产品型号看板** - 按产品型号查看销量和利润分析
- **销量数据管理** - 录入和管理每日销量数据（支持批量导入）
- **广告花费管理** - 管理广告费用和相关数据
- **利润测算配置** - 配置产品的利润计算参数（管理员）
- **用户运营组配置** - 管理用户和分组（管理员）

### 技术特点
- 单页应用，无需构建工具
- 使用 React (CDN) + Supabase
- 响应式设计，支持移动端
- 实时数据同步
- 完整的权限控制（管理员/操作员）

## 快速开始

### 1. 数据库设置

在 Supabase SQL Editor 中运行 `schema.sql` 文件：

```bash
# 登录 Supabase Dashboard
# 进入 SQL Editor
# 复制 schema.sql 内容并执行
```

### 2. 创建用户

在 Supabase Authentication 中创建用户：

1. 进入 Supabase Dashboard > Authentication > Users
2. 点击 "Add User"
3. 输入邮箱和密码
4. 用户首次登录后会自动在 `users` 表中创建记录

### 3. 部署应用

#### 方式一：本地运行
```bash
# 直接在浏览器中打开 index.html
open index.html
```

#### 方式二：使用简单 HTTP 服务器
```bash
# Python 3
python3 -m http.server 8000

# Node.js
npx serve .

# 然后访问 http://localhost:8000
```

#### 方式三：部署到静态托管
- **Vercel**: 拖拽文件夹到 Vercel
- **Netlify**: 拖拽文件夹到 Netlify
- **GitHub Pages**: 推送到 GitHub 仓库并启用 Pages
- **Cloudflare Pages**: 连接 Git 仓库或直接上传

## 使用说明

### 利润计算公式

```
净价 = 前台价格 × (1 - 折扣率)
佣金 = 净价 × 佣金率
广告费 = 净价 × 广告率
售后费用 = 净价 × 售后率

线上成本 = 佣金 + 广告费 + 仓储费 + 售后费用 + 尾程费
线下成本 = 采购成本 + 头程物流

剩余毛利 = 净价 - 线上成本 - 线下成本
```

### 销量录入流程

1. **配置利润参数**（管理员）
   - 进入"利润测算配置"
   - 添加 ASIN 及其利润计算参数
   - 系统自动计算"剩余毛利"

2. **录入销量数据**
   - 进入"销量数据管理"
   - 点击"录入数据"
   - 选择 ASIN-国家（自动填充利润）
   - 输入销量
   - 系统自动计算 ASIN 利润

3. **批量录入**
   - 点击"批量录入"
   - 粘贴格式：`ASIN 国家 销量`（每行一条）
   - 例如：
     ```
     B0GCCML5FP  US  25
     B0HDDML6GQ  CA  10
     ```
   - 系统自动匹配配置并锁定利润

### 广告费用管理

1. 进入"广告花费管理"
2. 添加每日广告数据：
   - 日期
   - 产品型号
   - 国家
   - 广告费用
   - 广告销量 / 总销量
   - LD/BD 费用
   - 类目排名

### 用户权限

**管理员 (admin)**
- 查看所有数据
- 管理利润配置
- 管理用户和分组
- 所有操作员权限

**操作员 (operator)**
- 查看所属组数据
- 录入销量数据
- 管理广告费用
- 查看产品看板

## 数据库表结构

### users - 用户表
- `id`: UUID (主键)
- `email`: 邮箱
- `name`: 姓名
- `role`: 角色 (admin/operator)
- `group_name`: 运营组 (一组/二组/三组)

### profit_config - 利润配置表
- `asin_country`: ASIN-国家 (唯一键)
- `asin`: ASIN
- `country`: 国家 (US/CA/AU)
- `product_model`: 产品型号
- `operator_group`: 运营组
- `list_price`: 前台价格
- `discount_rate`: 折扣率
- `platform_commission_rate`: 佣金率
- `ad_cost_rate`: 广告率
- `shipping_cost`: 尾程费
- `storage_cost`: 仓储费
- `after_sale_rate`: 售后率
- `purchase_cost`: 采购成本
- `freight_cost`: 头程物流

### sales_record - 销量记录表
- `asin_country`: ASIN-国家
- `record_date`: 记录日期
- `sales_volume`: 销量
- `locked_profit`: 锁定利润（录入时从配置表获取）
- `asin_profit`: ASIN利润（自动计算）

### ad_expense - 广告费用表
- `record_date`: 日期
- `product_model`: 产品型号
- `country`: 国家
- `ad_cost`: 广告费用
- `ad_sales`: 广告销量
- `total_sales`: 总销量
- `ld_bd_cost`: LD/BD费用
- `category_rank`: 类目排名

## 配置说明

### Supabase 配置

在 `index.html` 中修改以下配置：

```javascript
const SUPABASE_URL = 'https://your-project.supabase.co';
const SUPABASE_KEY = 'your-anon-key';
```

### 行级安全策略 (RLS)

数据库已配置 RLS 策略：
- 用户只能读取自己的信息
- 管理员可以管理所有数据
- 操作员可以读取所有数据，但只能管理特定表

## 常见问题

### Q: 如何重置密码？
A: 在 Supabase Dashboard > Authentication > Users 中重置用户密码

### Q: 如何修改已录入的销量数据？
A: 在"销量数据管理"中点击"编辑"按钮，修改后保存

### Q: 锁定利润是什么？
A: 录入销量时，系统会从利润配置表获取当前的剩余毛利并锁定，确保历史数据不受未来价格变动影响

### Q: 如何导出数据？
A: 可以在 Supabase Dashboard 中导出 CSV，或使用 Supabase API 获取数据

## 技术栈

- **前端**: React 18 (CDN)
- **数据库**: Supabase (PostgreSQL)
- **图表**: Chart.js 4
- **样式**: 原生 CSS
- **构建**: 无需构建工具

## 浏览器支持

- Chrome/Edge 90+
- Firefox 88+
- Safari 14+
- 移动端浏览器

## 许可证

MIT License

## 支持

如有问题，请联系系统管理员。
