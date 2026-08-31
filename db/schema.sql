-- ============================================================
-- 来财啦利润计算系统 — 数据库结构
-- ============================================================
-- 从 Supabase 生产库导出并整理，核实日期：2026-08-31
-- Supabase project ref: heluodmvrwmnwxrtogmc
--
-- 这份文件描述的是【当前线上状态】。
-- 后续变更请在 db/migrations/ 下新建迁移文件，并同步更新本文件。
--
-- ⚠️ 注意：本文件反映的 RLS 策略是【修复前】的状态。
--    001_strict_group_isolation.sql 执行后，策略部分需要同步更新。
-- ============================================================


-- ------------------------------------------------------------
-- 权限辅助函数
-- ------------------------------------------------------------
-- 两个都是 SECURITY DEFINER + 锁定 search_path，写法规范：
--   - SECURITY DEFINER 绕过 users 表自身的 RLS，避免策略递归
--   - SET search_path 防止 search_path 劫持提权

create or replace function public.is_admin()
  returns boolean
  language sql
  stable
  security definer
  set search_path to 'public'
as $$
  select exists (
    select 1 from public.users where id = auth.uid() and role = 'admin'
  );
$$;

create or replace function public.get_user_group()
  returns text
  language sql
  stable
  security definer
  set search_path to 'public'
as $$
  select group_name from public.users where id = auth.uid();
$$;


-- ------------------------------------------------------------
-- users — 用户与运营组
-- ------------------------------------------------------------
-- id 存的是 auth.users.id（登录时由前端显式写入）。
-- ⚠️ 默认值 gen_random_uuid() 具有误导性，且没有指向 auth.users 的外键，
--    Supabase 里删除 auth 用户会在这里留下孤儿行。
create table public.users (
  id          uuid primary key default gen_random_uuid(),
  email       text not null unique,
  name        text not null,
  role        text not null default 'operator',   -- 'admin' | 'operator'
  group_name  text,                               -- 一组 / 二组 / 三组
  created_at  timestamptz default now()
);


-- ------------------------------------------------------------
-- profit_config — 利润测算配置（每个 ASIN-国家一行）
-- ------------------------------------------------------------
create table public.profit_config (
  id                        uuid primary key default gen_random_uuid(),
  asin_country              text not null unique,  -- 'B0XXXXXXXX-US'
  asin                      text not null,
  country                   text not null,         -- US / CA / AU
  product_model             text not null,
  operator_group            text not null,         -- 分组归属的唯一来源
  list_price                numeric not null,      -- 前台价格
  discount_rate             numeric default 0,     -- 折扣率
  net_price                 numeric,               -- ⚠️ 冗余缓存列，见下方说明
  platform_commission_rate  numeric default 0.15,  -- 平台佣金率
  commission_amount         numeric,               -- ⚠️ 冗余缓存列
  ad_cost_rate              numeric default 0,     -- ⚠️ 业务约定必须保持 0，见下方说明
  ad_cost_amount            numeric,               -- ⚠️ 冗余缓存列
  shipping_cost             numeric default 0,     -- 尾程费
  storage_cost              numeric default 0,     -- 仓储费
  after_sale_rate           numeric default 0,     -- 售后率
  purchase_cost             numeric default 0,     -- 采购成本
  freight_cost              numeric default 0,     -- 头程物流
  created_at                timestamptz default now(),
  updated_at                timestamptz default now()
);

-- ⚠️ net_price / commission_amount / ad_cost_amount 是冗余缓存列：
--    前端 calcProfitBreakdown() 优先读它们，calcRemainingProfit() 永远重算。
--    缓存过期时，配置页展示的毛利会和录入销量时锁定的毛利对不上。
--
-- ⚠️ ad_cost_rate 业务约定必须为 0：
--    locked_profit 的公式里已按 ad_cost_rate 扣过一次"预估"广告费，
--    而仪表盘算总利润时又减了一次 ad_expense 里的"实际"广告费。
--    填非 0 会导致该 ASIN 利润被静默扣两次，报表上看不出异常。


-- ------------------------------------------------------------
-- sales_record — 每日销量
-- ------------------------------------------------------------
create table public.sales_record (
  id             uuid primary key default gen_random_uuid(),
  asin_country   text not null,
  asin           text not null,
  country        text not null,
  record_date    date not null,
  product_model  text not null,
  sales_volume   integer not null default 0,
  locked_profit  numeric not null,   -- 录入时从 profit_config 快照的单件毛利
  -- 生成列：不可写入，前端也确实从不写它
  asin_profit    numeric generated always as ((sales_volume)::numeric * locked_profit) stored,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now(),
  unique (asin_country, record_date)   -- 前端 upsert onConflict 依赖此约束
);

create trigger update_sales_record_updated_at
  before update on public.sales_record
  for each row execute function update_updated_at_column();

-- 注：profit_config 也有 updated_at 字段，但未确认是否挂了同样的触发器。


-- ------------------------------------------------------------
-- ad_expense — 每日广告花费
-- ------------------------------------------------------------
create table public.ad_expense (
  id             uuid primary key default gen_random_uuid(),
  record_date    date not null,
  product_model  text not null,
  country        text not null,
  ad_cost        numeric default 0,
  ad_sales       integer default 0,   -- 广告出单量
  total_sales    integer default 0,   -- 总出单量
  ld_bd_cost     numeric default 0,   -- LD/BD 秒杀费用
  category_rank  integer,             -- 小类排名
  created_at     timestamptz default now(),
  unique (record_date, product_model, country)   -- 前端 upsert onConflict 依赖此约束
);


-- ------------------------------------------------------------
-- 外键：目前一个都没有
-- ------------------------------------------------------------
-- 现状是完全靠前端保证引用完整性：
--   users.id             ⇸ auth.users(id)
--   sales_record.asin_country ⇸ profit_config.asin_country
--   ad_expense.product_model  ⇸ profit_config.product_model
-- 影响：可以插入配置表里不存在的 ASIN 销量记录（前端有校验，数据库没有）。
-- 是否补外键待定 —— 补之前必须先清理孤儿数据，否则加约束会失败。


-- ============================================================
-- RLS 策略（修复前的现状，2026-08-31）
-- ============================================================
-- 全部策略的 roles 都是 {authenticated}，不含 anon —— 数据未对公网开放。
--
-- users         ✅ 隔离正确：自己只能读改自己，admin 通过 is_admin() 管全部
-- profit_config ⚠️ 写正确（限本组），但 SELECT 是 true —— 所有运营能看到全部
--                  产品的采购成本和真实毛利
-- sales_record  🔴 四个操作全是 true —— 任何登录用户可读/改/删全部数据
-- ad_expense    🔴 同上
--
-- 前端的 filterSalesByScope / filterAdsByScope / getVisibleConfigs 只是二次过滤，
-- 不构成安全边界（F12 或直接调 Supabase API 即可绕过）。
--
-- 修复见 db/migrations/001_strict_group_isolation.sql

-- users
create policy "Admins can manage users"      on public.users for all    to authenticated using (is_admin()) with check (is_admin());
create policy "Admins can read all users"    on public.users for select to authenticated using (is_admin());
create policy "Users can create own profile" on public.users for insert to authenticated with check (auth.uid() = id);
create policy "Users can read own profile"   on public.users for select to authenticated using (auth.uid() = id);
create policy "Users can update own profile" on public.users for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

-- profit_config
create policy "Admins can manage profit_config"              on public.profit_config for all    to authenticated using (is_admin()) with check (is_admin());
create policy "All authenticated can read profit_config"     on public.profit_config for select to authenticated using (true);
create policy "Operators can insert own group profit_config" on public.profit_config for insert to authenticated with check (operator_group = get_user_group());
create policy "Operators can update own group profit_config" on public.profit_config for update to authenticated using (operator_group = get_user_group()) with check (operator_group = get_user_group());
create policy "Operators can delete own group profit_config" on public.profit_config for delete to authenticated using (operator_group = get_user_group());

-- sales_record
create policy "All authenticated can read sales_record" on public.sales_record for select to authenticated using (true);
create policy "Authenticated can insert sales_record"   on public.sales_record for insert to authenticated with check (true);
create policy "Authenticated can update sales_record"   on public.sales_record for update to authenticated using (true) with check (true);
create policy "Authenticated can delete sales_record"   on public.sales_record for delete to authenticated using (true);

-- ad_expense
create policy "All authenticated can read ad_expense" on public.ad_expense for select to authenticated using (true);
create policy "Authenticated can manage ad_expense"   on public.ad_expense for all    to authenticated using (true) with check (true);
