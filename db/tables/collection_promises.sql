-- db/tables/collection_promises.sql
-- CHASE-1：客户承诺的一笔钱 + 一个日子 —— 催收里唯一有牙齿的东西。
--
-- NOTE: introduced by db/migrations/2026-08-27-chase1-collection-records.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.collection_promises (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    chase_id             uuid NOT NULL UNIQUE REFERENCES public.collection_chases (id) ON DELETE RESTRICT,
    -- 【客户是用某个币种承诺的 —— 那才是事实】
    promised_amount_ccy  numeric NOT NULL CHECK (promised_amount_ccy > 0),
    currency             text NOT NULL REFERENCES public.currencies (code),
    -- ★【本位币等值按【催收当天】折算,不是按承诺日】★
    -- 承诺日在【未来】,那一天的汇率不存在。按承诺日折算 = 每一个承诺都会被
    -- FX_RATE_MISSING 拒掉;而随便取一个就是 THE FX RULE 明令禁止的"编一个汇率"。
    -- 所以口径是:承诺【做出】的那一天的 tt_buy(收款侧,与 record_payment 同侧)。
    fx_rate              numeric NOT NULL CHECK (fx_rate > 0),
    promised_amount_base numeric NOT NULL,
    promised_date        date NOT NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid,
    -- ══ 结局:一个承诺【必须能被了结】,否则仪表盘上那一支永远清不掉 ══════
    outcome              text CHECK (outcome IN ('kept', 'broken', 'renegotiated', 'cancelled')),
    outcome_note         text,
    outcome_recorded_at  timestamptz,
    outcome_recorded_by  uuid,
    CONSTRAINT collection_promises_outcome_shape
        CHECK ((outcome IS NULL) = (outcome_recorded_at IS NULL))
);

COMMENT ON TABLE public.collection_promises IS
    'CHASE-1:客户承诺的【一笔钱 + 一个日子】—— 催收里唯一有牙齿的东西,也是唯一值得报表的东西。【为什么自成一张表】一个承诺有催收记录没有的生命周期:做出 → 兑现/毁掉/重新谈/取消。写成催收行上的两个可空列,就得在一条不可变的记录上改状态 —— 要么破坏不可变,要么根本没地方说"这个承诺兑现了"。【一次对话一个承诺】UNIQUE(chase_id):分期是几个承诺,来自几次对话。【币种】客户是用某个币种承诺的,那才是事实;本位币等值按【催收当天】的 tt_buy 折算 —— 不是按承诺日,因为承诺日在未来、那天的汇率不存在,按它折算等于每个承诺都被 FX_RATE_MISSING 拒掉,而随便取一个正是 THE FX RULE 禁止的编造。【没有自己的 superseded 列】一个承诺活不活着,看它那条催收活不活着 —— 两份状态会各说各话。【结局必须记得下来】一个清不掉的告警会教会人忽略告警,这个仓库为此付过账(hr_alerts.system_start_not_set 曾是一个 hr 角色永远清不掉的假警报)。';

COMMENT ON COLUMN public.collection_promises.outcome IS
    'kept=钱按约到了 · broken=到期没到 · renegotiated=又谈了一次(新的承诺在新的催收里)· cancelled=这个承诺作废(例如单据本身被冲销)。【由人记,不由机器猜】—— 自动按"余额下降了"判兑现,会在一笔无关的付款到账时悄悄把一个没兑现的承诺标成兑现。机器提供的是【证据】(collection_promise_status.received_since_base),判断是人的。记下之后不可改:它是一件关于世界的事实。';

CREATE INDEX idx_collection_promises_open
    ON public.collection_promises (promised_date)
    WHERE outcome IS NULL;

ALTER TABLE public.collection_promises ENABLE ROW LEVEL SECURITY;

CREATE POLICY "collection_promises select by permission" ON public.collection_promises
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
