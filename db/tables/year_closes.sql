-- db/tables/year_closes.sql
-- 年结日志(FIN-23)。一行 = 一次年结;重开盖章留痕,行保留(审计)。
-- 【仍有效】(reopened_at IS NULL)的年结驱动 post_journal_entry 的 YEAR_CLOSED 闸 ——
-- 与 locked_before 无关的第二道防线:月级 reopen_period 退锁穿不透已结年度。
-- IMMUTABLE:守卫触发器只放行"重开盖章"(reopened_at NULL→非空,同一动作记下
-- 冲销分录),其余列锁死,禁 DELETE。写入只经 SECURITY DEFINER 函数。
--
-- NOTE: introduced by db/migrations/2026-08-06-fin23-year-end-close.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.year_closes (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    year_end            date NOT NULL,
    closing_journal_id  uuid NOT NULL REFERENCES public.journal_entries (id),
    net_result          numeric NOT NULL,   -- 贷方为正 = 盈利
    notes               text,
    closed_at           timestamptz NOT NULL DEFAULT now(),
    closed_by           uuid,
    reopened_at         timestamptz,
    reopened_by         uuid,
    reopen_reason       text,
    reversal_journal_id uuid REFERENCES public.journal_entries (id)
);

COMMENT ON TABLE public.year_closes IS
    '年结日志(FIN-23)。一行 = 一次年结;重开盖 reopened_* 章并记冲销分录,行保留(审计)。【仍有效】(reopened_at IS NULL)的年结驱动 post_journal_entry 的 YEAR_CLOSED 闸 —— 与 locked_before 无关的第二道防线,月级 reopen_period 退锁穿不透它。';

CREATE UNIQUE INDEX idx_year_closes_active ON public.year_closes (year_end) WHERE reopened_at IS NULL;

-- IMMUTABLE:只放行"重开盖章"这一种 UPDATE(reopened_at NULL→非空,同一动作里
-- 记下冲销分录),其余列锁死;禁 DELETE。period_closes 同款。
CREATE OR REPLACE FUNCTION public.reject_year_close_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'YEAR_CLOSE_IMMUTABLE';
    END IF;
    IF OLD.reopened_at IS NULL AND NEW.reopened_at IS NOT NULL
       AND NEW.year_end = OLD.year_end
       AND NEW.closing_journal_id = OLD.closing_journal_id
       AND NEW.net_result = OLD.net_result
       AND NEW.closed_at = OLD.closed_at
       AND NEW.reopen_reason IS NOT NULL THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'YEAR_CLOSE_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_year_closes_immutable
    BEFORE UPDATE OR DELETE ON public.year_closes
    FOR EACH ROW EXECUTE FUNCTION public.reject_year_close_mutation();

ALTER TABLE public.year_closes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "year_closes select by permission" ON public.year_closes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
-- 写入只经 SECURITY DEFINER 函数;不开 INSERT/UPDATE/DELETE 策略。
