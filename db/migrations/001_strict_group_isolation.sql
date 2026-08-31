-- ============================================================
-- 001 严格按组隔离 (RLS 修复)
-- ============================================================
-- 背景：sales_record 和 ad_expense 原本四个操作全是 USING(true)，
--       任何登录用户都能读/改/删所有组的数据。前端的按组过滤只是视觉效果。
--       profit_config 的读也是 true，采购成本对所有运营可见。
--
-- 目标：admin 看全部；operator 只能看和改自己组的数据。
--
-- 归属关系（sales_record / ad_expense 表内都没有 operator_group 字段）：
--   sales_record.asin_country   -> profit_config.asin_country   -> operator_group
--   ad_expense.product_model    -> profit_config.product_model  -> operator_group
--   （按 product_model 匹配，与前端 filterAdsByScope 的口径保持一致）
--
-- ⚠️ 执行前必须先跑下面的「前置检查」，全部通过再执行正文。
-- ⚠️ 建议先在 Supabase 上开个分支/备份再执行。
-- ============================================================


-- ------------------------------------------------------------
-- 前置检查 1：is_admin() / get_user_group() 必须是 SECURITY DEFINER
-- ------------------------------------------------------------
-- 否则 users 表上的 "Admins can read all users" 策略调用 is_admin()
-- 会再次触发 users 的 RLS，导致无限递归。
--
-- ✅ 已于 2026-08-31 核实：两个函数 prosecdef 均为 true，本项检查通过。
--    复查用：
--    select proname, prosecdef from pg_proc
--    where proname in ('is_admin', 'get_user_group');


-- ------------------------------------------------------------
-- 前置检查 2：确认没有"无主"数据
-- ------------------------------------------------------------
-- 收紧后，profit_config 里匹配不上的 sales_record / ad_expense
-- 会对所有 operator 不可见（admin 仍可见）。先看看有多少。
-- 期望：两个 count 都是 0；不为 0 要先决定怎么处理这些孤儿数据。
select count(*) as orphan_sales from public.sales_record s
where not exists (select 1 from public.profit_config pc
                  where pc.asin_country = s.asin_country);

select count(*) as orphan_ads from public.ad_expense a
where not exists (select 1 from public.profit_config pc
                  where pc.product_model = a.product_model);


-- ------------------------------------------------------------
-- 前置检查 3：同一个产品型号有没有跨组
-- ------------------------------------------------------------
-- ad_expense 按 product_model 反查组，如果一个型号属于多个组，
-- 这些型号的广告数据会对多个组同时可见。
-- 期望：0 行
select product_model, count(distinct operator_group) as grp_cnt,
       string_agg(distinct operator_group, ', ') as groups
from public.profit_config
group by product_model
having count(distinct operator_group) > 1;


-- ============================================================
-- 正文：从这里开始是实际修改
-- ============================================================
begin;

-- 确保 RLS 是开着的（幂等）
alter table public.sales_record  enable row level security;
alter table public.ad_expense    enable row level security;
alter table public.profit_config enable row level security;
alter table public.users         enable row level security;


-- ------------------------------------------------------------
-- sales_record
-- ------------------------------------------------------------
drop policy if exists "All authenticated can read sales_record" on public.sales_record;
drop policy if exists "Authenticated can insert sales_record"   on public.sales_record;
drop policy if exists "Authenticated can update sales_record"   on public.sales_record;
drop policy if exists "Authenticated can delete sales_record"   on public.sales_record;

create policy "sales_record admin all" on public.sales_record
  for all to authenticated
  using (is_admin()) with check (is_admin());

create policy "sales_record operator own group" on public.sales_record
  for all to authenticated
  using (
    exists (select 1 from public.profit_config pc
            where pc.asin_country = sales_record.asin_country
              and pc.operator_group = get_user_group())
  )
  with check (
    exists (select 1 from public.profit_config pc
            where pc.asin_country = sales_record.asin_country
              and pc.operator_group = get_user_group())
  );


-- ------------------------------------------------------------
-- ad_expense
-- ------------------------------------------------------------
drop policy if exists "All authenticated can read ad_expense" on public.ad_expense;
drop policy if exists "Authenticated can manage ad_expense"   on public.ad_expense;

create policy "ad_expense admin all" on public.ad_expense
  for all to authenticated
  using (is_admin()) with check (is_admin());

create policy "ad_expense operator own group" on public.ad_expense
  for all to authenticated
  using (
    exists (select 1 from public.profit_config pc
            where pc.product_model = ad_expense.product_model
              and pc.operator_group = get_user_group())
  )
  with check (
    exists (select 1 from public.profit_config pc
            where pc.product_model = ad_expense.product_model
              and pc.operator_group = get_user_group())
  );


-- ------------------------------------------------------------
-- profit_config：读也收紧到本组（写策略本来就是对的，只重建以绑定 authenticated 角色）
-- ------------------------------------------------------------
drop policy if exists "All authenticated can read profit_config"     on public.profit_config;
drop policy if exists "Operators can insert own group profit_config" on public.profit_config;
drop policy if exists "Operators can update own group profit_config" on public.profit_config;
drop policy if exists "Operators can delete own group profit_config" on public.profit_config;
drop policy if exists "Admins can manage profit_config"              on public.profit_config;

create policy "profit_config admin all" on public.profit_config
  for all to authenticated
  using (is_admin()) with check (is_admin());

create policy "profit_config operator own group" on public.profit_config
  for all to authenticated
  using (operator_group = get_user_group())
  with check (operator_group = get_user_group());


-- ------------------------------------------------------------
-- 索引：RLS 的 EXISTS 子查询在每行读取时都会跑，没有索引会拖慢整个仪表盘
-- ------------------------------------------------------------
create index if not exists idx_profit_config_asin_country  on public.profit_config (asin_country);
create index if not exists idx_profit_config_product_model on public.profit_config (product_model);
create index if not exists idx_sales_record_asin_country   on public.sales_record  (asin_country);
create index if not exists idx_sales_record_record_date    on public.sales_record  (record_date);
create index if not exists idx_ad_expense_product_model    on public.ad_expense    (product_model);
create index if not exists idx_ad_expense_record_date      on public.ad_expense    (record_date);

commit;


-- ============================================================
-- 执行后验证
-- ============================================================
-- 1. 期望：不再有任何 qual = 'true' 的策略
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies where schemaname = 'public'
order by tablename, policyname;

-- 2. 用一个 operator 账号登录系统，确认：
--    - 分组仪表盘、销量管理、广告管理 都还能正常显示自己组的数据
--    - 利润测算配置 只剩自己组的 ASIN
--    - 浏览器控制台跑 await sb.from('sales_record').select('*')
--      → 只应返回自己组的记录，不再是全表
-- 3. 用 admin 账号登录，确认数据仪表盘的总数没有变化
