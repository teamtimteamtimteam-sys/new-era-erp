-- db/tables/supplier_scorecard_reviews.sql
-- MES-8a(2026-10-16,MES-0 Q77 · Q78 · Q91;MES-8 Step 0 Q2 · Q3 · Q4 · Q5 · Q6,Tim):【一次供应商评审 —— 只追加】。
--   评分卡的计数是【现算】的(supplier_scorecard_measures,按供应商与一个窗口);一次评审是一条【抄下来】的记录:
--     measures        那一刻算出的计数(整份 jsonb,包括"not compared"与只显示不计分的等级超标);
--     weights · grade_lines · grade_caps   那一刻生效的 V23 / V24(整份抄;空着就是 null);
--     score · grade   由抄下的权重与线算出来的分与等级;V23 空着时两者都是 null,not_graded_reason = 'V23_NOT_SET'
--                     (页面读"Not graded — V23 not set"),不触发任何采购单上的效果。
--   窗口由评审人输入(window_from / window_to,必填,不晚于今天)—— 什么都不替他选(Q4)。
--   【更正 = 一次新的评审,引用旧的,写明理由】(Q2):corrects_review_id + correction_reason 同进同出;一次评审只能被更正一次
--   (UNIQUE —— 要再改,就更正那一次更正);被更正的那一次就是"已被取代",采购单的效果读【最近一次没有被取代的】评审。
--   "最近"按 seq(bigserial)排 —— 不按 recorded_at:now() 是事务开始的时刻,同一笔事务里的两行一模一样(AGENTS.md「取最新那一行」)。
--   写入只走 record_supplier_review(SECURITY DEFINER,action.supplier_review);改与删对谁都按名拒(SUPPLIER_REVIEW_IMMUTABLE)。
--   读 module.suppliers.view(Q91:分数跟着供应商的查看码)。没有金额,没有遮蔽的列。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.supplier_scorecard_reviews (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq                bigserial NOT NULL UNIQUE,
    supplier_id        uuid NOT NULL REFERENCES public.suppliers (id),
    window_from        date NOT NULL,
    window_to          date NOT NULL,
    measures           jsonb NOT NULL CHECK (jsonb_typeof(measures) = 'object'),
    weights            jsonb,
    grade_lines        jsonb,
    grade_caps         jsonb,
    score              numeric,
    grade              text,
    not_graded_reason  text CHECK (not_graded_reason IS NULL OR not_graded_reason IN ('V23_NOT_SET')),
    note               text,
    corrects_review_id uuid UNIQUE REFERENCES public.supplier_scorecard_reviews (id),
    correction_reason  text,
    recorded_at        timestamptz NOT NULL DEFAULT now(),
    recorded_by        uuid DEFAULT auth.uid(),
    CONSTRAINT supplier_scorecard_reviews_window CHECK (window_to >= window_from),
    -- 有等级 ⇔ 有分 ⇔ 有权重与线;没有等级就必须说为什么
    CONSTRAINT supplier_scorecard_reviews_graded_shape CHECK (
        (grade IS NOT NULL AND score IS NOT NULL AND weights IS NOT NULL AND grade_lines IS NOT NULL AND not_graded_reason IS NULL)
        OR (grade IS NULL AND score IS NULL AND weights IS NULL AND grade_lines IS NULL AND not_graded_reason IS NOT NULL)),
    CONSTRAINT supplier_scorecard_reviews_correction_shape CHECK (
        (corrects_review_id IS NULL) = (correction_reason IS NULL)
        AND (correction_reason IS NULL OR btrim(correction_reason) <> '')),
    CONSTRAINT supplier_scorecard_reviews_not_self CHECK (corrects_review_id IS DISTINCT FROM id)
);

COMMENT ON TABLE public.supplier_scorecard_reviews IS
    'MES-8a:一次供应商评审(只追加)。计数现算;评审把那一刻的计数、生效的 V23 权重与等级线、V24 上限与抽样、以及由此得到的分与等级【抄下来】(Q2)。V23 空着 → 等级 null,not_graded_reason V23_NOT_SET("Not graded — V23 not set"),不触发采购单效果。窗口由评审人输入(Q4)。更正 = 新的一次,引用旧的、写理由;被引用的那一次已被取代。采购单读最近一次(按 seq)没被取代的评审。写只经 record_supplier_review(action.supplier_review);读 module.suppliers.view。';
COMMENT ON COLUMN public.supplier_scorecard_reviews.seq IS
    '先后:bigserial。"最近一次"按它排 —— recorded_at 是事务开始的时刻,同一笔事务里的两行相同,排不出先后。';
COMMENT ON COLUMN public.supplier_scorecard_reviews.measures IS
    '那一刻 supplier_scorecard_measures(supplier, window_from, window_to) 的整份返回 —— 每一项的计数、它比过了多少、"not compared" 多少;等级超标只显示、不计分(CONTRACT-1)。';
COMMENT ON COLUMN public.supplier_scorecard_reviews.grade_caps IS
    '那一刻的 V24(整份)。采购单的预付警告与收货页的抽样建议读【这一份】里本次等级那一格 —— 不读今天的设定。';

CREATE INDEX supplier_scorecard_reviews_supplier ON public.supplier_scorecard_reviews (supplier_id, seq DESC);

CREATE TRIGGER trg_supplier_scorecard_reviews_immutable
    BEFORE UPDATE OR DELETE ON public.supplier_scorecard_reviews
    FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_scorecard_review_write();

ALTER TABLE public.supplier_scorecard_reviews ENABLE ROW LEVEL SECURITY;
-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是 record_supplier_review(属主权限)。
CREATE POLICY "supplier_scorecard_reviews select by permission" ON public.supplier_scorecard_reviews
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
GRANT SELECT ON public.supplier_scorecard_reviews TO authenticated;
REVOKE ALL ON public.supplier_scorecard_reviews FROM anon;
