-- ============================================================
-- 002 组长 / 组员 三级角色
-- ============================================================
-- 背景：原本只有 admin / operator 两级，同组的人看到的数据完全一样。
--       实际分工是按产品型号到人的（T808 事件就是两个 ASIN 换人负责导致的），
--       但系统里没有这个概念。
--
-- 新的角色口径（业务确认 2026-09-03）：
--   admin   管理员  全部数据 + 用户管理
--   leader  组长    本组全部数据（= 原 operator 的行为）
--   member  组员    只看自己负责的产品型号；能录销量/广告，不能改利润配置
--
-- 迁移策略：现有 operator 一律转 leader，保证没有人突然少看到数据；
--           再把该降级的人单独降为 member。反过来做会有人被直接锁在门外。
--
-- ⚠️ 执行前先跑一次备份：python3 tools/backup.py
-- ⚠️ 整段一次执行，不要分段（begin/commit 保证原子性）
-- ============================================================


-- ------------------------------------------------------------
-- 前置检查：users.role 上的既存 check 约束
-- ------------------------------------------------------------
-- ✅ 已于 2026-09-03 查明：
--    users_role_check        CHECK (role = ANY (ARRAY['admin','operator']))
--    users_group_name_check  CHECK (group_name = ANY (ARRAY['一组','二组','三组']))
--
-- users_role_check 只允许 admin/operator，不先删掉的话正文第一条 update
-- 就会失败。group_name 那条不受影响，保持原样。
--
-- 复查用：
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--   where conrelid = 'public.users'::regclass and contype = 'c';


-- ============================================================
-- 正文
-- ============================================================
begin;

-- ------------------------------------------------------------
-- 1. 角色升级为三级
-- ------------------------------------------------------------
-- 旧约束只允许 admin/operator，必须先删，否则下面的 update 会被它拒绝
alter table public.users drop constraint users_role_check;

update public.users set role = 'leader' where role = 'operator';

-- 按业务分工降级（2026-09-03 确认）
update public.users set role = 'member' where email = 'chenwei@onenicehome.com';

alter table public.users
  add constraint users_role_check check (role in ('admin', 'leader', 'member'));


-- ------------------------------------------------------------
-- 2. 型号负责人
-- ------------------------------------------------------------
-- 一个型号一个负责人（主键即约束）。没有负责人的型号 = 全组共有：
-- 组长看得到，组员看不到。
create table if not exists public.model_owner (
  product_model text primary key,
  owner_id      uuid not null references public.users(id) on delete cascade,
  created_at    timestamptz default now()
);

create index if not exists idx_model_owner_owner on public.model_owner (owner_id);

alter table public.model_owner enable row level security;


-- ------------------------------------------------------------
-- 3. 辅助函数
-- ------------------------------------------------------------
-- 与 is_admin / get_user_group 同样是 SECURITY DEFINER + 锁 search_path：
-- 绕过 users 自身的 RLS，避免策略递归。
create or replace function public.get_user_role()
  returns text
  language sql
  stable
  security definer
  set search_path to 'public'
as $$
  select role from public.users where id = auth.uid();
$$;

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
-- 4. RLS：把 001 里的 operator 策略换成 leader + member 两条
-- ------------------------------------------------------------

-- ---- profit_config ----
-- 组长可读写本组；组员只读自己负责的型号，没有写权限
drop policy if exists "profit_config operator own group" on public.profit_config;

create policy "profit_config leader own group" on public.profit_config
  for all to authenticated
  using (get_user_role() = 'leader' and operator_group = get_user_group())
  with check (get_user_role() = 'leader' and operator_group = get_user_group());

create policy "profit_config member read own models" on public.profit_config
  for select to authenticated
  using (get_user_role() = 'member' and owns_model(product_model));


-- ---- sales_record ----
-- 归属一律经 profit_config 反查，不依赖 sales_record.product_model 这个
-- 冗余副本（T808 证明过它会漂）
drop policy if exists "sales_record operator own group" on public.sales_record;

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


-- ---- ad_expense ----
drop policy if exists "ad_expense operator own group" on public.ad_expense;

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


-- ---- model_owner 自己的策略 ----
create policy "model_owner admin all" on public.model_owner
  for all to authenticated
  using (is_admin()) with check (is_admin());

-- 组长只能给本组的型号指派负责人
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
  for select to authenticated
  using (owner_id = auth.uid());


-- ---- users：组长要能看到本组成员，否则指派负责人时选不出人 ----
create policy "users leader read own group" on public.users
  for select to authenticated
  using (get_user_role() = 'leader' and group_name = get_user_group());

commit;


-- ============================================================
-- 执行后验证
-- ============================================================
-- 1. 角色分布：应为 admin 1、leader 2、member 1
select role, count(*), string_agg(name, ', ' order by name) as 成员
from public.users group by role order by role;

-- 2. 策略总览：不应再有任何提到 operator 的旧策略
select tablename, policyname, cmd, qual
from pg_policies where schemaname = 'public'
order by tablename, policyname;

-- 3. 上手测试
--    组长 xuqianrong / ouyangzhu 登录 → 各页面应与之前完全一致
--    组员 chenwei 登录 → 因为还没分配型号，应看到空数据 + 明确提示
--    给 chenwei 分配一个型号后再登录 → 只看得到那个型号的数据
