-- db/tables/fixed_asset_history.sql
-- FA-HIST-1:固定资产台账的变更留痕,只增不改(形状取自 sales_order_history)。
--
-- NOTE: introduced by db/migrations/2026-09-20-fahist1-fixed-asset-history.sql.
-- First-run script (plain CREATEs).
--
-- ★★【这张表的写入口只有一个:基表 fixed_assets 上的 AFTER 触发器】★★
--   不在 7 支写函数里逐支写 INSERT —— 那份名单在三份文档上错过两次
--   (算进了根本不写这张表的 depreciate_fixed_assets,又漏掉了动 cost_base 的
--    record_expense / reverse_expense)。**一张表上的触发器不会漏掉第八个写入者。**
--
-- ★★【那支触发器【不提任何一个列名】,而这是一条硬约束,不是风格】★★
--   db/fixtures/120 的 F5(d)① 扫全库函数体,要求 planned_in_service_date 这个名字
--   只许出现在 set_asset_planned_in_service 一支里 —— 而**触发器函数的 prokind
--   也是 'f'**,照样被扫。于是触发器用 to_jsonb 现算差集、运行时拼出 old_/new_
--   键名,再由 jsonb_populate_record 落进下面这些【带类型的】成对列。
--   ☞ **db/fixtures/120 因此一个字节都没有改。**
--
-- ⚠ jsonb_populate_record 会【静默丢掉】没有对应列的键。db/fixtures/201 因此配了
--   一条「成对齐全」判据:fixed_assets 的每一列都必须在本表有 old_/new_ 两列。

CREATE TABLE public.fixed_asset_history (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fixed_asset_id   uuid NOT NULL REFERENCES public.fixed_assets (id),
    -- 【只有两个取值,而这是【量】出来的,不是省事】线上 8 条写语句里,
    -- INSERT 两条、UPDATE 六条、DELETE 零条。触发器不提列名,所以它【分不出】
    -- 也【不该分出】"这是一次投用还是一次设计划" —— 那件事由 changed_columns
    -- 这一列的【数据】回答,不由函数的【文本】回答。
    -- ⚠ 【没有 'deleted'】:硬删被 guard_fixed_assets_no_hard_delete 拦死,
    --    一个任何路径都产不出来的取值,写在 CHECK 清单里就是一句谎。
    change_type      text NOT NULL CHECK (change_type IN ('created','updated')),
    -- 这一次动了哪几列。**这是屏幕的索引**,也是"哪一列被改过几次"的答案。
    changed_columns  text[] NOT NULL,
    changed_at       timestamptz NOT NULL DEFAULT now(),
    changed_by       uuid DEFAULT auth.uid(),
    changed_by_kind  text NOT NULL CHECK (changed_by_kind IN ('user','no_session')),

    -- ═══ 23 对,一个不落 ═══════════════════════════════════════════════════
    -- 【为什么连 id / created_at / created_by 这种永不改动的列也配一对】
    -- 因为"每一列都有一对"是一条【没有例外的】规矩,而一条带例外的规矩需要
    -- 一份豁免名单 —— 而豁免名单会烂(fixture 120 F5(d) 正是为这件事重写过一次)。
    -- ★ 而它顺带买到一样东西:'created' 那一行的 new_* 侧【全部填满】,
    --   于是"这台机器出生时是什么样"单看留痕就答得出来。
    old_id                        uuid,        new_id                        uuid,
    old_code                      text,        new_code                      text,
    old_description               text,        new_description               text,
    old_category                  text,        new_category                  text,
    old_acquisition_date          date,        new_acquisition_date          date,
    old_in_service_date           date,        new_in_service_date           date,
    old_cost_ccy                  numeric,     new_cost_ccy                  numeric,
    old_currency                  text,        new_currency                  text,
    old_fx_rate                   numeric,     new_fx_rate                   numeric,
    old_cost_base                 numeric,     new_cost_base                 numeric,
    old_useful_life_months        integer,     new_useful_life_months        integer,
    old_residual_base             numeric,     new_residual_base             numeric,
    old_depreciation_account_code text,        new_depreciation_account_code text,
    old_status                    text,        new_status                    text,
    old_disposal_date             date,        new_disposal_date             date,
    old_disposal_proceeds_base    numeric,     new_disposal_proceeds_base    numeric,
    old_disposal_journal_id       uuid,        new_disposal_journal_id       uuid,
    old_expense_id                uuid,        new_expense_id                uuid,
    old_notes                     text,        new_notes                     text,
    old_created_at                timestamptz, new_created_at                timestamptz,
    old_created_by                uuid,        new_created_by                uuid,
    old_planned_in_service_date   date,        new_planned_in_service_date   date,
    old_acceptance_date           date,        new_acceptance_date           date
);

COMMENT ON TABLE public.fixed_asset_history IS
    'FA-HIST-1:固定资产台账的变更留痕,只增不改(形状取自 sales_order_history —— 成对的、带类型的列)。
【写入口只有一个:基表上的 AFTER 触发器 trg_fixed_assets_history】。不在 7 支写函数里逐支写 INSERT —— 那份名单在三份文档上错过两次(把不写这张表的 depreciate_fixed_assets 算了进去,又漏掉了动 cost_base 的 record_expense / reverse_expense)。一张表上的触发器不会漏掉第八个写入者。
★【那支触发器【不提任何一个列名】,而这是一条硬约束,不是风格】fixtures/120 的 F5(d)① 扫全库函数体,要求 planned_in_service_date 这个名字只许出现在一支具名函数里;触发器函数的 prokind 也是 f,照样被扫。于是本刀让触发器用 to_jsonb 现算差集、运行时拼出 old_/new_ 键名,再由 jsonb_populate_record 落进带类型的列 —— fixtures/120 因此【一个字节都没改】。
⚠ jsonb_populate_record 会静默丢掉没有对应列的键,所以 fixtures/201 配了一条「成对齐全」判据:fixed_assets 的每一列都必须在本表有 old_/new_ 两列。加第 24 列而忘了这里,那条判据当场红。
【不回填】本表落地之前的改动没有记录,那不是「没有改过」—— 屏幕的空状态照直说这一句。';

COMMENT ON COLUMN public.fixed_asset_history.change_type IS
    'FA-HIST-1:只有 created / updated 两个取值,而这是【量】出来的。触发器不提列名(见表注),所以它分不出也不该分出「这是投用还是设计划」—— 那件事由 changed_columns 的【数据】回答,不由函数的【文本】回答。★ 若由文本回答,就等于让一条规则去【读】那个计划日来决定一行历史长什么样,而那正是 fixtures/120 守的那句承诺要拦的形状。⚠ 没有 deleted:硬删被 guard_fixed_assets_no_hard_delete 拦死,一个任何路径都产不出来的取值写进 CHECK 就是一句谎。';

COMMENT ON COLUMN public.fixed_asset_history.changed_columns IS
    'FA-HIST-1:这一次动了哪几列(列名本身,按字母序)。**屏幕据此决定渲染哪几对**,所以它不是冗余:46 列里哪一对有内容,靠读这一列一次答完,而不是在 TS 里比 46 个 NULL。它也是「哪一列被改过几次」的答案。
【created 那一行是全部 23 个列名】—— 整行是新的,这是实话;屏幕对 created 另画一种(出生快照),不画 23 行 diff。
【永不为空】一次什么都没改的 UPDATE 不写行(见触发器),所以空数组在本表里不存在。';

COMMENT ON COLUMN public.fixed_asset_history.changed_by IS
    'FA-HIST-1:auth.uid() —— 登录账号(auth 空间),与 fixed_assets.created_by 同一族,也与全库 11 张留痕里的 8 张同一族。
【SECURITY DEFINER 动不了它】auth.uid() 读的是会话 GUC(request.jwt.claims ->> ''sub''),不是 current_user;DEFINER 换的是角色。sales_order_history 就是靠这一条工作的(它的 changed_by DEFAULT auth.uid(),唯一写入者是 SECURITY DEFINER 触发器)。
【它可以是 NULL,而那一种【有名字】】见 changed_by_kind —— 一个沉默的 NULL 读起来像「不知道是谁」,而真相是一句说得出口的话。';

COMMENT ON COLUMN public.fixed_asset_history.changed_by_kind IS
    'FA-HIST-1:这一行的「谁」属于哪一种。''user'' = 有登录会话(changed_by 是那个账号);''no_session'' = auth.uid() 为 NULL,也就是【一个不经登录的数据库直连会话】(psql / Management API / 迁移)。
★★【为什么不叫 ''system''】★★ 线上【没有任何系统写入者】:pg_cron 不在这个库里(实测 6 个扩展),而唯一一支作业形状的函数 depreciate_fixed_assets 根本不写 fixed_assets(它只写 fixed_asset_depreciation)。叫它 ''system'' 是给一个不存在的主体起名字,而那个名字会在三个月后被读成「例行作业改的,不用查」。
【它 NOT NULL,而 changed_by 可空】—— 这正是这一列存在的全部理由:缺席必须被【命名】,不许由一个 NULL 去暗示。';

COMMENT ON COLUMN public.fixed_asset_history.old_id IS
    'FA-HIST-1:【它永远等于 new_id,而它仍然在】。本表的规矩是「fixed_assets 的每一列都有一对」,没有例外 —— 一条带例外的规矩需要一份豁免名单,而豁免名单会烂(fixtures/120 F5(d) 为这件事重写过一次)。fixtures/201 的「成对齐全」判据也因此不必带例外。';

CREATE INDEX idx_fixed_asset_history_asset
    ON public.fixed_asset_history (fixed_asset_id, changed_at DESC);

CREATE TRIGGER trg_fixed_asset_history_append_only
    BEFORE UPDATE OR DELETE ON public.fixed_asset_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_fixed_asset_history_append_only();

-- ★★【anon 一个字节都碰不到 —— 而这一句是【实测】之后补上的,不是抄来的】★★
--   线上 public 上有【两套】默认权限,它们给的东西不一样:
--     · supabase_admin 建的表 → postgres + anon + authenticated + service_role
--     · **postgres 建的表   → postgres + authenticated + service_role(没有 anon)**
--   db/apply_migration.sh 走的是直连 psql,身份是 **postgres** —— 于是本表落到线上
--   时【本来就没有】 anon 的授权(实测:authenticated / postgres / service_role 三个)。
--   而本地重建的 prelude 复刻的是【前一套】,于是重建出来的表多了 anon,
--   镜像与线上对不上(FA-HIST-1 的整门 exit 1 抓到的就是这一处)。
--   ☞ 两边取齐,取的是【严的那一边】:显式 REVOKE,让重建也长成线上的样子。
--     **不是反过来给线上补一条 anon 授权** —— 为了让一次比对变绿而放宽权限,
--     方向就反了;那也正是 db/anon-grants-baseline.tsv 那句「只许缩小」的意思。
--   ⚠ 留痕本来也轮不到 anon:本表唯一的策略是 `TO authenticated`。这一句是
--     第二道,不是唯一一道 —— 两道都要,授权与策略各挡一层。
REVOKE ALL ON public.fixed_asset_history FROM anon;

ALTER TABLE public.fixed_asset_history ENABLE ROW LEVEL SECURITY;

-- 留痕【没有 INSERT/UPDATE/DELETE 策略】:唯一写入口是属主权限的触发器
-- (同 sales_order_history / approval_log:留痕不该有第二个写法)。
-- ★ 读的门与基表【同一个】—— fixed_assets 的策略也是 module.finance.view。
--   两道门取同一个权限码,于是"这里零行"在屏幕上就真的只有一个意思。
CREATE POLICY "fixed_asset_history select by permission" ON public.fixed_asset_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
