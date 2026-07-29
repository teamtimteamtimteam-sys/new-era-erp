-- db/tables/period_closes.sql
-- 月结关账日志:每次关账一行(截至 period_end 的分录张数 + Σ借/Σ贷快照)。
-- 关账入口 close_period:校验月末日 + 试算平衡后落行,并把
-- finance_settings.locked_before 推到 period_end + 1(期间锁语义:< locked_before
-- 的分录日期拒绝)。重开入口 reopen_period:行保留(审计),盖 reopened_at/by/reason
-- 章,锁退回更早仍有效关账的 period_end + 1(没有则解除)。
-- IMMUTABLE:守卫触发器只放行"重开盖章"(reopened_at/reason NULL→非空,
-- reopened_by 原为 NULL;auth.uid() 可为 NULL 故不强求非空),其余列锁死,禁 DELETE。
-- 活跃关账唯一性用部分唯一索引(reopened_at IS NULL)—— 重开后修正再关同一期间
-- 落第二行,历史行都保留。
--
-- NOTE: introduced by db/migrations/2026-07-07-phase3-cut4-period-close.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.period_closes (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    period_end     date NOT NULL,           -- 被关期间的最后一天(月末)
    closed_at      timestamptz NOT NULL DEFAULT now(),
    closed_by      uuid DEFAULT auth.uid(),
    notes          text,
    entries_count  integer NOT NULL,        -- 截至 period_end 的分录张数
    total_debits   numeric NOT NULL,        -- 截至 period_end 的 Σ借
    total_credits  numeric NOT NULL,        -- 截至 period_end 的 Σ贷
    reopened_at    timestamptz,
    reopened_by    uuid,
    reopen_reason  text
);

-- 活跃(未重开)关账每期间至多一条;重开后的历史行不占位
CREATE UNIQUE INDEX idx_period_closes_active_period
    ON public.period_closes (period_end) WHERE reopened_at IS NULL;

-- 守卫:只放行"重开盖章",其余列逐列锁死
CREATE OR REPLACE FUNCTION public.guard_period_close_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'CLOSE_IMMUTABLE';
    END IF;
    IF NEW.id               IS DISTINCT FROM OLD.id
       OR NEW.period_end       IS DISTINCT FROM OLD.period_end
       OR NEW.closed_at        IS DISTINCT FROM OLD.closed_at
       OR NEW.closed_by        IS DISTINCT FROM OLD.closed_by
       OR NEW.notes            IS DISTINCT FROM OLD.notes
       OR NEW.entries_count    IS DISTINCT FROM OLD.entries_count
       OR NEW.total_debits     IS DISTINCT FROM OLD.total_debits
       OR NEW.total_credits    IS DISTINCT FROM OLD.total_credits
    THEN
        RAISE EXCEPTION 'CLOSE_IMMUTABLE';
    END IF;
    IF NOT (OLD.reopened_at IS NULL AND NEW.reopened_at IS NOT NULL
            AND OLD.reopened_by IS NULL
            AND OLD.reopen_reason IS NULL AND NEW.reopen_reason IS NOT NULL) THEN
        RAISE EXCEPTION 'CLOSE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_period_closes_immutable
    BEFORE UPDATE OR DELETE ON public.period_closes
    FOR EACH ROW EXECUTE FUNCTION public.guard_period_close_mutation();

ALTER TABLE public.period_closes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on period_closes"
    ON public.period_closes FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on period_closes"
    ON public.period_closes FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "authenticated update on period_closes"
    ON public.period_closes FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
