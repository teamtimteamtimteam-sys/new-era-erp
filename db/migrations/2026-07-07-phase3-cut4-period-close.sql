-- db/migrations/2026-07-07-phase3-cut4-period-close.sql
-- Phase 3 cut 4: 月结关账日志(period_closes)+ close_period / reopen_period。
--
-- 关账 = 校验月末日 + 试算平衡后写入关账行,并把 finance_settings.locked_before
-- 推到 period_end + 1(期间锁在 post_journal_entry 内生效)。重开保留关账行
-- (审计),盖 reopened_at/by/reason 章,锁退回上一个仍有效关账的 period_end + 1
-- (没有则解除)。
--
-- 注意:period_end 唯一性用部分唯一索引(reopened_at IS NULL)而非全列 UNIQUE ——
-- 重开后修正再关同一期间必须能落第二行,历史行都保留;"活跃关账"每期间至多一条。
--
-- 期间锁语义沿用 cut 1:locked_before 之前(<)的分录日期拒绝。

BEGIN;

-- 1. 关账日志表 --------------------------------------------------------------

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

-- 守卫:只放行"重开盖章"(reopened_at/reason NULL→非空,reopened_by 原为 NULL;
-- auth.uid() 可能为 NULL,故不强求 NEW.reopened_by 非空),其余列逐列锁死
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

-- 2. 关账 --------------------------------------------------------------------
-- SECURITY INVOKER(默认):RLS 按调用者身份生效。
-- finance_settings 单行 FOR UPDATE 串行化并发关账/重开。

CREATE FUNCTION public.close_period(p_period_end date, p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $function$
DECLARE
    v_locked   date;
    v_count    integer;
    v_debits   numeric;
    v_credits  numeric;
    v_new_lock date;
BEGIN
    -- 必须是月末日
    IF p_period_end IS NULL
       OR p_period_end <> (date_trunc('month', p_period_end) + interval '1 month - 1 day')::date THEN
        RAISE EXCEPTION 'NOT_MONTH_END|%', COALESCE(p_period_end::text, '?');
    END IF;

    -- 串行化 + 不可重关已锁期间
    SELECT locked_before INTO v_locked FROM finance_settings WHERE id FOR UPDATE;
    IF v_locked IS NOT NULL AND p_period_end < v_locked THEN
        RAISE EXCEPTION 'ALREADY_CLOSED|%', v_locked;
    END IF;

    -- 截至 period_end 的全部分录:张数 + Σ借/Σ贷(关账即校验点)
    SELECT COUNT(DISTINCT jl.entry_id),
           round(COALESCE(SUM(jl.debit), 0), 2),
           round(COALESCE(SUM(jl.credit), 0), 2)
    INTO v_count, v_debits, v_credits
    FROM journal_lines jl
    JOIN journal_entries je ON je.id = jl.entry_id
    WHERE je.entry_date <= p_period_end;

    IF v_debits <> v_credits THEN
        RAISE EXCEPTION 'TRIAL_BALANCE_UNBALANCED|%|%', v_debits, v_credits;
    END IF;

    v_new_lock := p_period_end + 1;

    INSERT INTO period_closes (period_end, notes, entries_count, total_debits, total_credits)
    VALUES (p_period_end, p_notes, v_count, v_debits, v_credits);

    UPDATE finance_settings
    SET locked_before = v_new_lock, updated_by = auth.uid()
    WHERE id;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'locked_before', v_new_lock,
        'entries_count', v_count,
        'total_debits', v_debits,
        'total_credits', v_credits
    );
END;
$function$;

-- 3. 重开 --------------------------------------------------------------------
-- 盖章保留关账行;锁退回"更早的、仍有效关账"的 period_end + 1(没有则 NULL)。

CREATE FUNCTION public.reopen_period(p_period_end date, p_reason text)
RETURNS jsonb LANGUAGE plpgsql AS $function$
DECLARE
    v_close_id uuid;
    v_new_lock date;
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 与 close_period 同一把锁,串行化
    PERFORM 1 FROM finance_settings WHERE id FOR UPDATE;

    SELECT id INTO v_close_id
    FROM period_closes
    WHERE period_end = p_period_end AND reopened_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM period_closes WHERE period_end = p_period_end) THEN
            RAISE EXCEPTION 'ALREADY_REOPENED';
        END IF;
        RAISE EXCEPTION 'CLOSE_NOT_FOUND';
    END IF;

    UPDATE period_closes
    SET reopened_at = now(), reopened_by = auth.uid(), reopen_reason = btrim(p_reason)
    WHERE id = v_close_id;

    -- 更早的仍有效关账 → 其 period_end + 1;没有 → 解除锁定
    SELECT MAX(period_end) + 1 INTO v_new_lock
    FROM period_closes
    WHERE reopened_at IS NULL AND period_end < p_period_end;

    UPDATE finance_settings
    SET locked_before = v_new_lock, updated_by = auth.uid()
    WHERE id;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'locked_before', v_new_lock
    );
END;
$function$;

COMMIT;
