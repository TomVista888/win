-- ============================================================
-- 来财啦利润计算系统 — 数据库结构
-- ============================================================
-- 从 Supabase 生产库导出并整理，核实日期：2026-08-31
-- Supabase project ref: heluodmvrwmnwxrtogmc
--
-- 这份文件描述的是【当前线上状态】。
-- 后续变更请在 db/migrations/ 下新建迁移文件，并同步更新本文件。
--
-- RLS 策略章节反映 001 + 002 迁移执行后的状态（2026-09-03）。
--    以后再改策略，记得同步更新本文件。
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

create or replace function public.get_user_role()
  returns text
  language sql
  stable
  security definer
  set search_path to 'public'
as $$
  select role from public.users where id = auth.uid();
$$;

-- 当前用户是否是某个产品型号的负责人
create or replace function public.owns_model(m text)
  returns boolean
  language sql
  stable
  security definer
  set search_path to 'public'
as $$
  select exists (
    select 1 from public.model_owner
    where product_model = m and owner_id = auth.uid()
  );
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
  role        text not null default 'member',
  group_name  text,
  created_at  timestamptz default now(),
  constraint users_role_check       check (role in ('admin', 'leader', 'member')),
  constraint users_group_name_check check (group_name in ('一组', '二组', '三组'))
);
-- 角色：admin 全部数据+用户管理 / leader 本组全部 / member 只看指派给自己的型号
-- ⚠️ 要新增「四组」必须先改 users_group_name_check，否则插不进去


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
-- model_owner — 产品型号的负责人（002 新增）
-- ------------------------------------------------------------
-- 一个型号一个负责人（主键即约束）。没有负责人的型号 = 全组共有：
-- 组长和管理员看得到，组员看不到。
-- 组员的可见范围完全由这张表决定。
create table public.model_owner (
  product_model text primary key,
  owner_id      uuid not null references public.users(id) on delete cascade,
  created_at    timestamptz default now()
);

create index idx_model_owner_owner on public.model_owner (owner_id);


-- ------------------------------------------------------------
-- 外键：除 model_owner.owner_id 外，其余一个都没有
-- ------------------------------------------------------------
-- 现状是完全靠前端保证引用完整性：
--   users.id             ⇸ auth.users(id)
--   sales_record.asin_country ⇸ profit_config.asin_country
--   ad_expense.product_model  ⇸ profit_config.product_model
-- 影响：可以插入配置表里不存在的 ASIN 销量记录（前端有校验，数据库没有）。
-- 是否补外键待定 —— 补之前必须先清理孤儿数据，否则加约束会失败。


-- ============================================================
-- RLS 策略（当前线上状态，001 + 002 迁移均已于 2026-09-03 执行）
-- ============================================================
-- 全部策略 roles = {authenticated}，不含 anon —— 数据未对公网开放。
-- 口径：admin 全部；leader 本组全部；member 只看指派给自己的型号（且不能改利润配置）。
--
-- sales_record 和 ad_expense 表内没有 operator_group 字段，归属靠反查 profit_config：
--   sales_record.asin_country  → profit_config.asin_country  → operator_group
--   ad_expense.product_model   → profit_config.product_model → operator_group
--   （ad_expense 按 product_model 匹配，与前端 filterAdsByScope 口径一致）
--
-- 前端的 filterSalesByScope / filterAdsByScope / getVisibleConfigs 是二次过滤，
-- 便于展示，但**不是安全边界** —— 真正的隔离在这里。

-- users（001 未改动）
create policy "Admins can manage users"      on public.users for all    to authenticated using (is_admin()) with check (is_admin());
create policy "Admins can read all users"    on public.users for select to authenticated using (is_admin());
create policy "Users can create own profile" on public.users for insert to authenticated with check (auth.uid() = id);
create policy "Users can read own profile"   on public.users for select to authenticated using (auth.uid() = id);
create policy "Users can update own profile" on public.users for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

-- users：组长要能看到本组成员，否则指派型号负责人时选不出人
create policy "users leader read own group" on public.users
  for select to authenticated
  using (get_user_role() = 'leader' and group_name = get_user_group());

-- profit_config：组长可读写本组；组员只读自己负责的型号，无写权限
create policy "profit_config admin all" on public.profit_config
  for all to authenticated using (is_admin()) with check (is_admin());
create policy "profit_config leader own group" on public.profit_config
  for all to authenticated
  using (get_user_role() = 'leader' and operator_group = get_user_group())
  with check (get_user_role() = 'leader' and operator_group = get_user_group());
create policy "profit_config member read own models" on public.profit_config
  for select to authenticated
  using (get_user_role() = 'member' and owns_model(product_model));

-- sales_record
create policy "sales_record admin all" on public.sales_record
  for all to authenticated using (is_admin()) with check (is_admin());
create policy "sales_record leader own group" on public.sales_record
  for all to authenticated
  using (get_user_role() = 'leader' and exists (
    select 1 from public.profit_config pc
    where pc.asin_country = sales_record.asin_country
      and pc.operator_group = get_user_group()))
  with check (get_user_role() = 'leader' and exists (
    select 1 from public.profit_config pc
    where pc.asin_country = sales_record.asin_country
      and pc.operator_group = get_user_group()));
create policy "sales_record member own models" on public.sales_record
  for all to authenticated
  using (get_user_role() = 'member' and exists (
    select 1 from public.profit_config pc
    where pc.asin_country = sales_record.asin_country
      and public.owns_model(pc.product_model)))
  with check (get_user_role() = 'member' and exists (
    select 1 from public.profit_config pc
    where pc.asin_country = sales_record.asin_country
      and public.owns_model(pc.product_model)));

-- ad_expense
create policy "ad_expense admin all" on public.ad_expense
  for all to authenticated using (is_admin()) with check (is_admin());
create policy "ad_expense leader own group" on public.ad_expense
  for all to authenticated
  using (get_user_role() = 'leader' and exists (
    select 1 from public.profit_config pc
    where pc.product_model = ad_expense.product_model
      and pc.operator_group = get_user_group()))
  with check (get_user_role() = 'leader' and exists (
    select 1 from public.profit_config pc
    where pc.product_model = ad_expense.product_model
      and pc.operator_group = get_user_group()));
create policy "ad_expense member own models" on public.ad_expense
  for all to authenticated
  using (get_user_role() = 'member' and public.owns_model(ad_expense.product_model))
  with check (get_user_role() = 'member' and public.owns_model(ad_expense.product_model));

-- model_owner
create policy "model_owner admin all" on public.model_owner
  for all to authenticated using (is_admin()) with check (is_admin());
create policy "model_owner leader own group" on public.model_owner
  for all to authenticated
  using (get_user_role() = 'leader' and exists (
    select 1 from public.profit_config pc
    where pc.product_model = model_owner.product_model
      and pc.operator_group = get_user_group()))
  with check (get_user_role() = 'leader' and exists (
    select 1 from public.profit_config pc
    where pc.product_model = model_owner.product_model
      and pc.operator_group = get_user_group()));
create policy "model_owner member read own" on public.model_owner
  for select to authenticated using (owner_id = auth.uid());


-- ------------------------------------------------------------
-- 索引：RLS 的 EXISTS 子查询每行读取都会执行，缺索引会拖慢仪表盘
-- ------------------------------------------------------------
create index if not exists idx_profit_config_asin_country  on public.profit_config (asin_country);
create index if not exists idx_profit_config_product_model on public.profit_config (product_model);
create index if not exists idx_sales_record_asin_country   on public.sales_record  (asin_country);
create index if not exists idx_sales_record_record_date    on public.sales_record  (record_date);
create index if not exists idx_ad_expense_product_model    on public.ad_expense    (product_model);
create index if not exists idx_ad_expense_record_date      on public.ad_expense    (record_date);
