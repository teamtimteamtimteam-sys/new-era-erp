-- db/tables/finance_settings_history.sql
-- 审批策略的【只增不改】变更史(APR-1,pricing_formula_history 的形状)。
--
-- 【为什么它不是 approval_log 的一支】approval_log 的主体是
-- (subject_type, subject_id),而 subject_id 是一个指向【单据行】的 uuid;
-- finance_settings 是一张单行表,没有那样的 id。硬塞进去只有两条路:编一个假的
-- subject_id,或者给那个九值枚举加一个【不是单据】的取值 —— 两者都是把一次
-- 【策略变更】伪装成一次【对某张单据的决定】。APR-0 §2.4 逐条量过:库里 14 张
-- history/log 表【全部是逐单据的】,没有任何一张接得住配置类的变更。
--
-- 【为什么是 RPC 写,不是触发器写】与 pricing_formula_history 相反,这里【有】
-- 一个唯一的写入口:set_approvals_policy()。而这四列的直连写由
-- guard_approvals_policy_write 按名拒绝,所以"想写才写"在这里不成立 ——
-- 能走到写的只有那一条路。
--
-- ★【它【不】记属主直接改库的那几次】★ 守卫拦不住 postgres(没有任何东西拦得住),
-- 所以一次迁移或一次手改仍然写得动那四列,而这里不会有行。**空白好过编造** ——
-- 同 pricing_formula_history「触发器之前的编辑没有行」。线上那一行
-- (false · finance · cfo · 1000)正是这样来的,所以本表在 APR-1 之后是【空的】,
-- 而那不是一个缺陷。
--
-- 【读的门取 action.manage_permissions】与【谁改得了它】同一个码。两道门同码,
-- 于是"这里零行"在屏幕上只有一个意思。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr1-the-approvals-switch-gets-a-door.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.finance_settings_history (
    id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    old_approvals_enabled         boolean,
    new_approvals_enabled         boolean,
    old_approval_level1_role_code text,
    new_approval_level1_role_code text,
    old_approval_level2_role_code text,
    new_approval_level2_role_code text,
    old_approval_threshold_base   numeric,
    new_approval_threshold_base   numeric,
    changed_at                    timestamptz NOT NULL DEFAULT now(),
    changed_by                    uuid
);

CREATE INDEX idx_finance_settings_history_changed
    ON public.finance_settings_history (changed_at DESC);

COMMENT ON TABLE public.finance_settings_history IS
    '审批策略的只增不改变更史(APR-1,pricing_formula_history 的形状)。谁、什么时候、四列各从什么改到什么。★ 唯一的写入者是 set_approvals_policy() —— 与 approval_log 同一条规矩:留痕不该有第二个写法,所以本表没有 INSERT 策略。★ 本表【不记】迁移或属主直接改库的那些变更:那些写得进四列(守卫不拦属主),但它们不经 RPC,于是这里没有行。空白好过编造 —— 同 pricing_formula_history「触发器之前的编辑没有行」。读的门取 action.manage_permissions,与【谁改得了它】同一个码。';

-- 历史本身不许被改写 —— 否则"留痕"只是摆设
-- (函数体在 db/functions/guard_finance_settings_history_append_only.sql)
CREATE TRIGGER trg_finance_settings_history_append_only
    BEFORE UPDATE OR DELETE ON public.finance_settings_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_finance_settings_history_append_only();

-- ★★【anon 一个字节都碰不到】★★ 与 fixed_asset_history 逐字同一条,连理由都一样,
--   而本刀【自己又撞了一次】—— 所以照抄不是偷懒,是这条规矩确实还没有被自动化:
--   线上 public 上有【两套】默认权限,给的东西不一样:
--     · supabase_admin 建的表 → postgres + anon + authenticated + service_role
--     · **postgres 建的表   → postgres + authenticated + service_role(没有 anon)**
--   db/apply_migration.sh 走直连 psql,身份是 postgres —— 于是本表落到线上时
--   【本来就没有】 anon 授权(实测 2026-09-22:authenticated / postgres / service_role
--   三个,与 fixed_asset_history 逐字相同;而 approval_log / pricing_formula_history
--   这些更早的表【有】 anon —— 那是旧的那一套留下的)。
--   而本地重建的 prelude 复刻的是【前一套】,于是重建出来的表多了 anon。
--   ☞ 两边取齐,取【严的那一边】:显式 REVOKE,让重建长成线上的样子 ——
--     **不是反过来给线上补一条 anon 授权**,那方向就反了。
--   ☞ 同理:本表【不】进 db/anon-grants-baseline.tsv。那份基线记的是"anon 够得着的
--     东西",而 anon 够不着它;往里加一行就是把基线【放大】,而那份文件只许缩小。
REVOKE ALL ON public.finance_settings_history FROM anon;

ALTER TABLE public.finance_settings_history ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是属主权限的 RPC。
CREATE POLICY "finance_settings_history select by permission"
    ON public.finance_settings_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('action.manage_permissions'::text));
