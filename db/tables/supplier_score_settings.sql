-- db/tables/supplier_score_settings.sql
-- MES-8a(2026-10-16,MES-0 §5.1 V23 · V24 · Q77 · Q78 · Q93;MES-8 Step 0 Q2 · Q4 · Q5 · Q27,Tim):【供应商评分的设定 —— 单行】。
--   V23  weights             每一项计分的权重(一个计数 × 它的权重 = 那一项的扣分;合计就是这一次评审的分)。
--                            键是 supplier_scorecard_measures() 吐出来的 scored 那几项的名字,【一个都不能少,也不能多】,值是 ≥ 0 的数。
--        grade_lines         等级线,按分数从小到大:[{grade, max_score}, …];分 ≤ max_score 的第一条就是等级。
--                            【最后一条的 max_score 必须是 null】—— 它接住比所有线都高的分;于是任何一个分都有一个等级,不会落空。
--        review_window_days  多久评一次(天)。只驱动"该评了"的提醒(supplier_review_due,Q27):空着 = 那一支一行都不出。
--                            评审的窗口【永远由评审人自己输入】(Q4)—— 这个数不替他选窗口。
--   V24  grade_caps          每一个等级:{<grade>: {prepayment_cap_pct, sampling_level}}。
--                            prepayment_cap_pct 0–100:一张采购单的"下单时"付款超过它,create_purchase_order 给一条
--                            PREPAYMENT_ABOVE_GRADE_CAP 警告(Q5)—— 【从不拒绝】。sampling_level 是一句话的抽样建议,收货页上照原样显示,
--                            【不加任何一项必须的化验】(必须的化验是按物料的,没有按收货的那一层 —— 登记在 known-issues)。
--                            键必须是 grade_lines 里的等级。
--   【引导一律为空】(Q4):没有任何一个默认权重、默认等级线、默认上限。V23 空着时评审照记,等级读"Not graded — V23 not set",
--   不触发任何采购单上的效果。每一次评审把它【当时】的这一整行抄下来(Q2),所以改这一行永远不改写一次过去的评审。
--   由 action.supplier_review 经 set_supplier_score_settings 改;修改史在变更记录里(主语 supplier_score_settings,画在评分卡页)。
--   RUNTIME CONFIG:Tim 设一次,线上就与本文件不同 —— 那是系统在正常工作(quality_settings / safety_settings 的先例)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.supplier_score_settings (
    id                 boolean PRIMARY KEY DEFAULT true CHECK (id),
    weights            jsonb CHECK (weights IS NULL OR jsonb_typeof(weights) = 'object'),
    grade_lines        jsonb CHECK (grade_lines IS NULL OR jsonb_typeof(grade_lines) = 'array'),
    review_window_days integer CHECK (review_window_days IS NULL OR review_window_days > 0),
    grade_caps         jsonb CHECK (grade_caps IS NULL OR jsonb_typeof(grade_caps) = 'object'),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid DEFAULT auth.uid(),
    -- 权重与等级线同进同出:只有一半是没法评级的(一个分没有线,或者一条线没有分)
    CONSTRAINT supplier_score_settings_weights_with_lines CHECK ((weights IS NULL) = (grade_lines IS NULL)),
    -- 上限与抽样是按等级的,没有等级线就没有等级
    CONSTRAINT supplier_score_settings_caps_need_lines CHECK (grade_caps IS NULL OR grade_lines IS NOT NULL)
);

COMMENT ON TABLE public.supplier_score_settings IS
    'MES-8a:供应商评分的设定(单行)。V23 = weights(每一项计分的权重)· grade_lines(等级线,最后一条接住其余)· review_window_days(多久评一次,只驱动提醒);V24 = grade_caps(每一等级的预付上限 % 与抽样级别)。引导一律为空 —— 不猜任何一个权重或线(Q4)。每一次评审把整行抄走,所以改它不改写过去的评审。action.supplier_review 经 set_supplier_score_settings 改。';
COMMENT ON COLUMN public.supplier_score_settings.weights IS
    'V23:{<计分项>: 权重 ≥ 0} —— 键正好是 supplier_scorecard_measures() 的 scored 那几项。空 = Not yet set(评审读"Not graded — V23 not set")。';
COMMENT ON COLUMN public.supplier_score_settings.grade_lines IS
    'V23:[{grade, max_score}] 按 max_score 升序;最后一条 max_score 为 null(接住比所有线都高的分)。与 weights 同进同出。';
COMMENT ON COLUMN public.supplier_score_settings.review_window_days IS
    'V23:多久评一次(天)。空 = supplier_review_due 一行都不出(Q27)。评审的窗口永远由评审人输入。';
COMMENT ON COLUMN public.supplier_score_settings.grade_caps IS
    'V24:{<grade>: {prepayment_cap_pct 0–100, sampling_level 文本}}。上限只给警告(PREPAYMENT_ABOVE_GRADE_CAP),从不拒绝;抽样级别只是建议,不加必须的化验。';

INSERT INTO public.supplier_score_settings (id) VALUES (true);

CREATE TRIGGER trg_supplier_score_settings_updated_at
    BEFORE UPDATE ON public.supplier_score_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.supplier_score_settings ENABLE ROW LEVEL SECURITY;
-- 读:供应商查看码(评分卡页的设定面板、待补的值那一行)。写只经函数。
CREATE POLICY "supplier_score_settings select by permission" ON public.supplier_score_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
GRANT SELECT ON public.supplier_score_settings TO authenticated;
REVOKE ALL ON public.supplier_score_settings FROM anon;
