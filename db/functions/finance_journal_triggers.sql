-- db/functions/finance_journal_triggers.sql
-- cut 2a auto-journal engine — cost-entry journaling triggers + helpers.
-- 成本录入/调整/软删即入账(借 5xxx / 贷 2200,负数翻边);科目映射 fin_cost_account;
-- 行对构造 fin_cost_lines(录入/冲销共用)。规格原写"两个 AFTER UPDATE 触发器"
-- (改额/软删),同一 UPDATE 可能双重命中 —— 合并为一个 UPDATE 触发器内分支(软删优先)。
-- 硬 DELETE 不入账(应用只走软删)。PERIOD_LOCKED 从 post_journal_entry 直接抛出。
--
-- NOTE: introduced by db/migrations/2026-07-06-phase3-cut2a-auto-journal.sql.

CREATE OR REPLACE FUNCTION public.fin_cost_account(p_cost_type text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE p_cost_type
        WHEN 'labour'          THEN '5100'
        WHEN 'electricity'     THEN '5110'
        WHEN 'gas'             THEN '5120'
        WHEN 'depreciation'    THEN '5130'
        WHEN 'consumables'     THEN '5140'
        WHEN 'waste_treatment' THEN '5150'
        ELSE '5190'  -- 'other' 及未知值兜底
    END;
$function$


CREATE OR REPLACE FUNCTION public.fin_cost_lines(p_cost_type text, p_amount numeric, p_reverse boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT CASE WHEN (p_amount > 0) <> p_reverse THEN
        jsonb_build_array(
            jsonb_build_object('account_code', fin_cost_account(p_cost_type), 'side', 'debit',  'currency', 'USD', 'amount_ccy', abs(p_amount)),
            jsonb_build_object('account_code', '2200',                        'side', 'credit', 'currency', 'USD', 'amount_ccy', abs(p_amount)))
    ELSE
        jsonb_build_array(
            jsonb_build_object('account_code', '2200',                        'side', 'debit',  'currency', 'USD', 'amount_ccy', abs(p_amount)),
            jsonb_build_object('account_code', fin_cost_account(p_cost_type), 'side', 'credit', 'currency', 'USD', 'amount_ccy', abs(p_amount)))
    END;
$function$


CREATE OR REPLACE FUNCTION public.fin_journal_cost_entry()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_run_code text;
    v_lines    jsonb;
BEGIN
    SELECT code INTO v_run_code FROM processing_runs WHERE id = NEW.run_id;

    IF TG_OP = 'INSERT' THEN
        IF NEW.deleted_at IS NOT NULL OR NEW.amount_usd = 0 THEN
            RETURN NULL;
        END IF;
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Cost ' || v_run_code || ' ' || NEW.cost_type,
            'processing_cost', NEW.id,
            fin_cost_lines(NEW.cost_type, NEW.amount_usd, false));
        RETURN NULL;
    END IF;

    -- UPDATE:软删 → 冲销现额(优先,忽略同笔 UPDATE 里的其它变化)
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        IF OLD.amount_usd <> 0 THEN
            PERFORM post_journal_entry(
                CURRENT_DATE,
                'Cost removed ' || v_run_code,
                'processing_cost', NEW.id,
                fin_cost_lines(OLD.cost_type, OLD.amount_usd, true));
        END IF;
        RETURN NULL;
    END IF;
    IF NEW.deleted_at IS NOT NULL THEN
        RETURN NULL;  -- 已软删行的其它变更不入账
    END IF;

    -- 金额/类型变化 → 一张调整分录:冲旧 + 记新(至多 4 行,自平)
    IF NEW.amount_usd IS DISTINCT FROM OLD.amount_usd
       OR NEW.cost_type IS DISTINCT FROM OLD.cost_type THEN
        v_lines := '[]'::jsonb;
        IF OLD.amount_usd <> 0 THEN
            v_lines := v_lines || fin_cost_lines(OLD.cost_type, OLD.amount_usd, true);
        END IF;
        IF NEW.amount_usd <> 0 THEN
            v_lines := v_lines || fin_cost_lines(NEW.cost_type, NEW.amount_usd, false);
        END IF;
        IF jsonb_array_length(v_lines) >= 2 THEN
            PERFORM post_journal_entry(
                CURRENT_DATE,
                'Cost adj ' || v_run_code,
                'processing_cost', NEW.id,
                v_lines);
        END IF;
    END IF;
    RETURN NULL;
END;
$function$


-- (trigger attachments trg_processing_cost_entries_journal_ins / _upd moved to
--  db/tables/processing_cost_entries.sql — 2026-07-31 镜像漂移审计起,每张表的
--  镜像完整描述它自己的触发器,函数文件只放函数)
