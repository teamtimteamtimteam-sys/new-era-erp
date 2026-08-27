-- db/tables/cash_forecasts.sql
-- CASHFLOW-1：某一周冻下来的那一份 13 周现金预测（KPI T1 的偏差拿它做基准）。
--
-- NOTE: introduced by db/migrations/2026-08-28-cashflow1-expected-dates-and-13-week-forecast.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.cash_forecasts (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code              text NOT NULL UNIQUE,
    week_start        date NOT NULL,
    horizon_weeks     integer NOT NULL DEFAULT 13 CHECK (horizon_weeks > 0),
    opening           jsonb NOT NULL,   -- 每个现金账户一项,各按【自己的币种】
    buckets           jsonb NOT NULL,   -- (币种 × 周) 的进/出/净/期末
    lines             jsonb NOT NULL,   -- 明细,每行带 source 与 confidence
    undated           jsonb NOT NULL,   -- 有钱、没有日期的那些(预测看不见的部分)
    promises_memo     jsonb NOT NULL,   -- 客户承诺:【备查,不计入合计】
    buffer            jsonb NOT NULL,   -- 每币种的固定 OPEX 与覆盖月数
    base_currency     text NOT NULL REFERENCES public.currencies (code),
    frozen_at         timestamptz NOT NULL DEFAULT now(),
    frozen_by         uuid,
    superseded_at     timestamptz,
    superseded_by     uuid REFERENCES public.cash_forecasts (id),
    superseded_reason text,
    CONSTRAINT cash_forecasts_supersede_shape
        CHECK ((superseded_at IS NULL) = (superseded_by IS NULL))
);

COMMENT ON TABLE public.cash_forecasts IS
    'CASHFLOW-1:某一周冻下来的那一份 13 周现金预测。【为什么要冻】KPI T1 量的是「未来 4 周的预测偏差 ±10% 以内」—— 偏差要拿【过去那一份】去比,只在内存里算的预测那个指标无从度量。这是这个仓库冻结形状的第四次(gst_return_boxes / bank_reconciliations / customer_statements)。【冻到明细】与 STATEMENT-1 同一条:偏差分析问的是"哪一行动了",冻合计答不出。【重出是新的一行】同一周再冻一次 = 新行 + 旧行落 superseded_at 与必填理由,旧的不删 —— 它正是偏差要比的那个基准,覆盖掉就把度量本身毁了。【为什么没有本位币合计这一列】实测今天 USD 折不出 SGD(FX_RATE_MISSING),所以合计【按币种】存在 buckets 里;一个跨币种的合计只在每个币种都有汇率时才谈得上,而那件事由读的人在页面上看到"有没有"。';

CREATE INDEX idx_cash_forecasts_week ON public.cash_forecasts (week_start DESC);

ALTER TABLE public.cash_forecasts ENABLE ROW LEVEL SECURITY;

-- 没有 INSERT/UPDATE/DELETE 策略:唯一写入口是 freeze_cash_forecast(属主权限)
CREATE POLICY "cash_forecasts select by permission" ON public.cash_forecasts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
