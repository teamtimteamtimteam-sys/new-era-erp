-- db/tables/fixed_asset_depreciation_anchors.sql
-- CAPEX-1:**折旧的锚点 —— 一次「会计估计变更」从哪个月起、按什么摊。**
--
-- ★★【这张表存在的全部理由:让【过去的月份】变成一个存下来的常数】★★
--   月度例程的算术是【累计目标 − 已提】:
--       target = LEAST(成本−残值, (成本−残值)/年限月数 × 在役月数)
--       delta  = target − Σ 已提
--   于是【把 cost_base 抬高一分钱,每一个已经过去的月份的目标都跟着抬高】,
--   整笔补提当场落在本期 —— 而那正是 4.7 明令禁止的回溯补charge。
--
--   本表把那段过去【冻成一个数】:`pre_anchor_target_base`。锚定之后,
--   目标 = 那个常数 + 只从锚点往后算的那一段。**过去的月份不再被任何算术
--   重新推导** —— 它们已经是一个存下来的标量,而不是一个可以被新成本重算的表达式。
--   这是本刀防住回溯补提的【结构性】做法,不是一句约束。
--
-- ★【为什么是【自己一张表】,而不是 fixed_assets 上的三个列】★
--   一次资本化是一次【会计估计变更】,而估计变更天然是一串,不是一个当前值。
--   写在资产表上就得覆盖,于是这串历史没了 —— 而审计要看的正是这串。
--
-- ★【为什么【不】挂在 fixed_asset_cost_entries 上】★
--   那张表已经记着每一笔成本追加,挂上去看似免费。但"哪一个锚点对本期有效"
--   会变成一次【取最新那一行】,而它只能按 created_at 排 —— 那是【事务时刻】,
--   同一笔事务里的两行完全相同,破平局只剩随机 uuid。
--   **那正是 AGING-1 栽过的那个坑**(同一份数据两次运行两个答案),
--   而 AGENTS.md 为它写着一条明规矩:先问这张表排不排得出先后。
--   所以本表用【业务日期】排:effective_from,并且 (asset_id, effective_from) 唯一。
--   「本期适用哪个锚点」= effective_from ≤ 期末 里最大的那一个 —— 由业务选的日子
--   决定,不由写入时刻决定。
--
-- 【只可追加】一次估计变更是一件发生过的事。写错了就再加一个锚点,不改旧行。
-- 写入只走 record_expense 的资本化分支(SECURITY DEFINER);这里只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-29-capex1-capitalising-onto-a-running-machine.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.fixed_asset_depreciation_anchors (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id               uuid NOT NULL REFERENCES public.fixed_assets (id) ON DELETE RESTRICT,
    -- 【本锚点从哪个月起生效】—— 恒为某个月的 1 号。资本化落在哪个月,
    -- 就从那个月起按新费率摊(月度例程只在月末被调用,所以"从这个月起"
    -- 就是"这个月末那一次开始用新算术")。
    effective_from         date NOT NULL,
    -- ★【锚点之前那一段的累计目标 —— 一个【存下来的常数】】★
    --   它【不是】"当时已经提了多少",而是"按锚点【之前】那套算术,
    --   到锚点前一天为止【应当】累计多少"。两者的区别在欠提时显形:
    --   欠着的那几期仍然要按【旧费率】补上(delta = target − 已提 会自动做到),
    --   而不该被卷进新费率里摊掉。
    pre_anchor_target_base numeric NOT NULL CHECK (pre_anchor_target_base >= 0),
    -- 【从本锚点起还要摊几个月】按天折算,所以是 numeric 不是 integer。
    remaining_months       numeric NOT NULL CHECK (remaining_months > 0),
    -- 触发它的那一笔资本化(以及那条维修记录)。两者都可空是【刻意的】:
    -- 将来的「使用年限重估」也会落一个锚点,而那一次没有钱经手。
    expense_id             uuid REFERENCES public.expenses (id),
    maintenance_id         uuid REFERENCES public.equipment_maintenance (id),
    -- 为什么变。资本化那一路的理由抄自维修记录(那里有一条 CHECK 逼它非空)。
    reason                 text NOT NULL CHECK (btrim(reason) <> ''),
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    CONSTRAINT fixed_asset_depreciation_anchors_month_is_first
        CHECK (effective_from = date_trunc('month', effective_from)::date),
    -- 一个资产在同一个生效月只能有一个锚点 —— 否则"本期适用哪一个"又回到
    -- 按写入时刻破平局,而那正是本表刻意躲开的那件事。
    CONSTRAINT fixed_asset_depreciation_anchors_one_per_month
        UNIQUE (asset_id, effective_from)
);

CREATE INDEX idx_fa_depr_anchors_asset ON public.fixed_asset_depreciation_anchors (asset_id, effective_from DESC);

-- 只可追加:一次估计变更是一件发生过的事,改它等于改写历史。
CREATE OR REPLACE FUNCTION public.guard_depreciation_anchor_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'DEPRECIATION_ANCHOR_IMMUTABLE|%',
        COALESCE(OLD.id::text, NEW.id::text);
END;
$function$;

CREATE TRIGGER trg_fa_depr_anchors_append_only
    BEFORE UPDATE OR DELETE ON public.fixed_asset_depreciation_anchors
    FOR EACH ROW EXECUTE FUNCTION public.guard_depreciation_anchor_append_only();

ALTER TABLE public.fixed_asset_depreciation_anchors ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fa depreciation anchors select by permission"
    ON public.fixed_asset_depreciation_anchors
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

COMMENT ON TABLE public.fixed_asset_depreciation_anchors IS
    'CAPEX-1:折旧的锚点 —— 一次会计估计变更从哪个月起、按什么摊。**它把"过去的月份"冻成一个存下来的常数(pre_anchor_target_base)**,于是抬高成本不再能把过去每一个月的目标一起抬高(4.7 明令禁止的回溯补提)。【自己一张表而不是资产上的三个列】:估计变更天然是一串;【不挂在 fixed_asset_cost_entries 上】:那样"哪个锚点有效"会变成按 created_at 的取最新一行,而那是事务时刻 + 随机 uuid 破平局 —— AGING-1 栽过的坑。这里按业务日期 effective_from 排,(asset_id, effective_from) 唯一。';

COMMENT ON COLUMN public.fixed_asset_depreciation_anchors.pre_anchor_target_base IS
    'CAPEX-1:按锚点【之前】那套算术,到锚点前一天为止【应当】累计的折旧。**不是"当时已经提了多少"** —— 两者在欠提时不同:欠着的那几期要按旧费率补上(delta = target − 已提 自动做到),不该被卷进新费率里摊掉。它是一个【常数】,而这正是过去的月份不再被重新推导的原因。';
