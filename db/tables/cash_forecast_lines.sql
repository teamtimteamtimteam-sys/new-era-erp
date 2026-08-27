-- db/tables/cash_forecast_lines.sql
-- CASHFLOW-1：预测里手工录入的那一半；非 once 的那些同时是 KPI T2 的固定 OPEX 集合。
--
-- NOTE: introduced by db/migrations/2026-08-28-cashflow1-expected-dates-and-13-week-forecast.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.cash_forecast_lines (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    label       text NOT NULL,
    direction   text NOT NULL CHECK (direction IN ('in', 'out')),
    amount_ccy  numeric NOT NULL CHECK (amount_ccy > 0),
    currency    text NOT NULL REFERENCES public.currencies (code),
    cadence     text NOT NULL CHECK (cadence IN ('once','weekly','monthly','quarterly','annual')),
    -- 【第一次发生的日子:必填,绝不默认】AGENTS.md 那条 —— 一个决定这笔钱
    -- 落在哪一周的日期,给它 CURRENT_DATE 默认值就是奖励留空。
    start_date  date NOT NULL,
    end_date    date,
    notes       text,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid,
    CONSTRAINT cash_forecast_lines_window CHECK (end_date IS NULL OR end_date >= start_date)
);

COMMENT ON TABLE public.cash_forecast_lines IS
    'CASHFLOW-1:预测里【手工录入】的那一半 —— 租金、保险、一笔已知的一次性支出。给定实测(AP 一个日期都没有、经常性成本一张表都没有),这一半不是补充,它是预测能不能用的前提。【一张表,两个用途】cadence 带一个 once:非 once 的行就是【固定 OPEX 集合】,KPI T2 的「≥3 个月固定 OPEX」量的正是它;once 的行是已知的一次性。分两张表要维护两处"我们还要付什么";加一个 is_fixed_opex 标志要与 cadence 保持一致,而两个必须保持一致的字段最后总会不一致。【它在预测里的 confidence 永远是 manual】—— 既不是合同约定的日子,也不是有主的估计,而屏幕上必须看得出这个区别。start_date 必填、不默认。';

CREATE INDEX idx_cash_forecast_lines_active ON public.cash_forecast_lines (is_active, start_date);

ALTER TABLE public.cash_forecast_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "cash_forecast_lines select by permission" ON public.cash_forecast_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
CREATE POLICY "cash_forecast_lines write by permission" ON public.cash_forecast_lines
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.finance.edit'::text))
    WITH CHECK (has_permission('module.finance.edit'::text));
