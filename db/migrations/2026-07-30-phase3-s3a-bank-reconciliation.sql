-- db/migrations/2026-07-30-phase3-s3a-bank-reconciliation.sql
-- Phase 3 supplement 3a: bank reconciliation engine (DB only).
--
-- CORE DESIGN: a bank statement line is matched to a JOURNAL LINE that hits that
-- bank account — universal, since payments, paid expenses and manual entries all
-- produce one. Statement amounts are in the bank account's NATIVE currency
-- (1000 → SGD, 1010 → USD), so matching compares journal_lines.amount_ccy (not
-- the USD debit/credit) and requires the journal line's currency to equal the
-- account's native currency.
--
-- Pieces:
--   B0.  bank_native_currency() helper
--   B1.  bank_import_profiles (saved CSV mappings — storage only)
--   B2.  bank_statements (gapless 'BS-YYYY-NNNN', soft-deletable unless reconciled)
--   B3.  bank_statement_lines (signed amounts, unmatched/matched/ignored)
--   B4.  bank_line_matches (statement line ↔ journal line, a JL matches at most once)
--   B5.  import_bank_statement()
--   B6.  match_bank_line()
--   B7.  unmatch_bank_line() / ignore_bank_line() / unignore_bank_line()
--   B8.  reconcile_statement() / unreconcile_statement()
--   B9.  view bank_reconciliation_status
--   B10. view bank_unmatched_journal_lines

BEGIN;

-- ============================================================================
-- B0. Native currency of a bank account.
-- Adding a bank account means extending this function PLUS the existing
-- bank_account_code CHECKs (payments/expenses/bank_import_profiles/bank_statements).
-- ============================================================================
CREATE FUNCTION public.bank_native_currency(p_account_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE p_account_code
        WHEN '1000' THEN 'SGD'
        WHEN '1010' THEN 'USD'
    END;
$function$;

-- ============================================================================
-- B1. bank_import_profiles — saved CSV column mappings.
-- mapping 只是存储:UI 解析 CSV 时用它({date_column, description_column,
-- reference_column, amount_column 或 debit_column+credit_column, date_format,
-- decimal_separator, thousands_separator, sign_convention});DB 不解释它 ——
-- 导入函数收的是 UI 解析好的行。存下来是为了每月导入不用重新映射。
-- ============================================================================
CREATE TABLE public.bank_import_profiles (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bank_account_code text NOT NULL CHECK (bank_account_code IN ('1000','1010')),
    name              text NOT NULL,
    mapping           jsonb NOT NULL,
    deleted_at        timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid DEFAULT auth.uid()
);

CREATE UNIQUE INDEX uq_bank_import_profiles_account_name
    ON public.bank_import_profiles (bank_account_code, name)
    WHERE deleted_at IS NULL;

CREATE TRIGGER trg_bank_import_profiles_updated_at
    BEFORE UPDATE ON public.bank_import_profiles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.bank_import_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on bank_import_profiles"
    ON public.bank_import_profiles AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B2. bank_statements
-- ============================================================================
CREATE TABLE public.bank_statements (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code              text NOT NULL UNIQUE,  -- gapless 'BS-YYYY-NNNN', assigned by import_bank_statement
    bank_account_code text NOT NULL CHECK (bank_account_code IN ('1000','1010')),
    currency          text NOT NULL REFERENCES public.currencies (code),
    period_start      date NOT NULL,
    period_end        date NOT NULL CHECK (period_end >= period_start),
    opening_balance   numeric NOT NULL,
    closing_balance   numeric NOT NULL,
    file_name         text,
    status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','reconciled')),
    reconciled_at     timestamptz,
    reconciled_by     uuid,
    notes             text,
    deleted_at        timestamptz,  -- 坏导入必须能丢弃;已对账的报表除外(守卫触发器)
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid DEFAULT auth.uid()
);

CREATE TRIGGER trg_bank_statements_updated_at
    BEFORE UPDATE ON public.bank_statements
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 已对账的报表不许软删(先 unreconcile 再删)
CREATE OR REPLACE FUNCTION public.guard_bank_statement_delete()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND OLD.status = 'reconciled' THEN
        RAISE EXCEPTION 'STATEMENT_RECONCILED';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_bank_statements_no_delete_reconciled
    BEFORE UPDATE ON public.bank_statements
    FOR EACH ROW EXECUTE FUNCTION public.guard_bank_statement_delete();

ALTER TABLE public.bank_statements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on bank_statements"
    ON public.bank_statements AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B3. bank_statement_lines — signed amounts:正 = 入账(银行借方),负 = 出账。
-- RLS 全权限:match/ignore 的状态翻转就是整个工作流。
-- ============================================================================
CREATE TABLE public.bank_statement_lines (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    statement_id  uuid NOT NULL REFERENCES public.bank_statements (id) ON DELETE RESTRICT,
    line_no       integer NOT NULL,
    line_date     date NOT NULL,
    description   text,
    reference     text,
    amount        numeric NOT NULL CHECK (amount <> 0),
    match_status  text NOT NULL DEFAULT 'unmatched' CHECK (match_status IN ('unmatched','matched','ignored')),
    ignore_reason text,
    notes         text,
    created_at    timestamptz DEFAULT now(),
    UNIQUE (statement_id, line_no)
);

CREATE INDEX idx_bank_statement_lines_statement ON public.bank_statement_lines (statement_id);
CREATE INDEX idx_bank_statement_lines_date ON public.bank_statement_lines (line_date);
CREATE INDEX idx_bank_statement_lines_status ON public.bank_statement_lines (match_status);

ALTER TABLE public.bank_statement_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on bank_statement_lines"
    ON public.bank_statement_lines AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B4. bank_line_matches — 一条分录行终生只能被匹配一次(UNIQUE journal_line_id)。
-- matched_amount = 从该分录行认领的原币金额(当前实现 = 整行 amount_ccy)。
-- ============================================================================
CREATE TABLE public.bank_line_matches (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    statement_line_id uuid NOT NULL REFERENCES public.bank_statement_lines (id) ON DELETE CASCADE,
    journal_line_id   uuid NOT NULL UNIQUE REFERENCES public.journal_lines (id) ON DELETE RESTRICT,
    matched_amount    numeric NOT NULL CHECK (matched_amount > 0),
    created_at        timestamptz DEFAULT now(),
    created_by        uuid DEFAULT auth.uid()
);

CREATE INDEX idx_bank_line_matches_statement_line ON public.bank_line_matches (statement_line_id);

ALTER TABLE public.bank_line_matches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on bank_line_matches"
    ON public.bank_line_matches AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B5. import_bank_statement — UI 解析 CSV 后送来行数组;这里守门:
-- 余额恒等式 opening + Σ = closing(截断/映射错误的 CSV 在门口拦下)、
-- 行日期必须落在期间内。重叠期间/疑似重复行只是警告,随返回值带回。
-- ============================================================================
CREATE FUNCTION public.import_bank_statement(
    p_bank_account text,
    p_period_start date,
    p_period_end   date,
    p_opening      numeric,
    p_closing      numeric,
    p_file_name    text,
    p_lines        jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_ccy          text;
    v_statement_id uuid := gen_random_uuid();
    v_year         integer;
    v_seq          integer;
    v_code         text;
    v_line         jsonb;
    v_no           integer := 0;
    v_amount       numeric;
    v_date         date;
    v_sum          numeric := 0;
    v_overlaps     integer;
    v_dups         integer := 0;
BEGIN
    v_ccy := bank_native_currency(p_bank_account);
    IF v_ccy IS NULL THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_bank_account, '?');
    END IF;
    IF p_period_start IS NULL OR p_period_end IS NULL OR p_period_end < p_period_start THEN
        RAISE EXCEPTION 'PERIOD_INVALID|%|%', COALESCE(p_period_start::text,'?'), COALESCE(p_period_end::text,'?');
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- 先整体校验(金额为非零数字、日期在期间内)并求 Σ
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_no := v_no + 1;
        IF jsonb_typeof(v_line->'amount') <> 'number' OR (v_line->>'amount')::numeric = 0 THEN
            RAISE EXCEPTION 'LINE_AMOUNT_INVALID|%', v_no;
        END IF;
        v_amount := (v_line->>'amount')::numeric;
        v_date := (v_line->>'line_date')::date;
        IF v_date IS NULL OR v_date < p_period_start OR v_date > p_period_end THEN
            RAISE EXCEPTION 'LINE_DATE_OUT_OF_RANGE|%|%', v_no, COALESCE(v_date::text, '?');
        END IF;
        v_sum := v_sum + v_amount;

        -- 疑似重复(同账户其他在册报表上已有同日期+同金额+同摘要的行)—— 只计数
        SELECT v_dups + count(*) INTO v_dups
        FROM bank_statement_lines l
        JOIN bank_statements s ON s.id = l.statement_id
        WHERE s.bank_account_code = p_bank_account
          AND s.deleted_at IS NULL
          AND l.line_date = v_date
          AND l.amount = v_amount
          AND l.description IS NOT DISTINCT FROM (v_line->>'description');
    END LOOP;

    -- 余额恒等式:opening + Σ = closing
    IF round(p_opening + v_sum, 2) IS DISTINCT FROM round(p_closing, 2) THEN
        RAISE EXCEPTION 'STATEMENT_NOT_BALANCED|%|%', round(p_opening + v_sum, 2), round(p_closing, 2);
    END IF;

    -- 期间重叠警告(不拦)
    SELECT count(*) INTO v_overlaps
    FROM bank_statements s
    WHERE s.bank_account_code = p_bank_account
      AND s.deleted_at IS NULL
      AND s.period_start <= p_period_end
      AND s.period_end >= p_period_start;

    -- 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款/开支手法)
    v_year := EXTRACT(YEAR FROM p_period_end)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('bank_stmt_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM bank_statements
    WHERE code LIKE 'BS-' || v_year::text || '-%';
    v_code := 'BS-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO bank_statements (id, code, bank_account_code, currency, period_start, period_end,
                                 opening_balance, closing_balance, file_name)
    VALUES (v_statement_id, v_code, p_bank_account, v_ccy, p_period_start, p_period_end,
            p_opening, p_closing, p_file_name);

    -- 行按数组顺序编号
    v_no := 0;
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_no := v_no + 1;
        INSERT INTO bank_statement_lines (statement_id, line_no, line_date, description, reference, amount)
        VALUES (v_statement_id, v_no, (v_line->>'line_date')::date,
                v_line->>'description', v_line->>'reference', (v_line->>'amount')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'statement_id', v_statement_id,
        'code', v_code,
        'line_count', v_no,
        'overlapping_statements', v_overlaps,
        'possible_duplicates', v_dups
    );
END;
$function$;

-- ============================================================================
-- B6. match_bank_line — 报表行 ↔ 一组分录行(Σ amount_ccy 必须精确等于 |行金额|)。
-- 方向必须一致:正数行(入账)只配银行借方,负数行(出账)只配银行贷方。
-- ============================================================================
CREATE FUNCTION public.match_bank_line(
    p_statement_line_id uuid,
    p_journal_line_ids  uuid[]
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_line   record;
    v_jl_id  uuid;
    v_jl     record;
    v_sum    numeric := 0;
    v_count  integer := 0;
BEGIN
    SELECT l.id, l.amount, l.match_status,
           s.status AS stmt_status, s.bank_account_code, s.currency
    INTO v_line
    FROM bank_statement_lines l
    JOIN bank_statements s ON s.id = l.statement_id AND s.deleted_at IS NULL
    WHERE l.id = p_statement_line_id
    FOR UPDATE OF l;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'LINE_NOT_FOUND|%', p_statement_line_id;
    END IF;
    IF v_line.stmt_status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_RECONCILED';
    END IF;
    IF v_line.match_status <> 'unmatched' THEN
        RAISE EXCEPTION 'LINE_NOT_UNMATCHED|%', v_line.match_status;
    END IF;

    IF p_journal_line_ids IS NULL OR array_length(p_journal_line_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_JOURNAL_LINES';
    END IF;

    FOREACH v_jl_id IN ARRAY p_journal_line_ids
    LOOP
        SELECT l.id, l.debit, l.credit, l.currency, l.amount_ccy,
               a.code AS account_code, e.status AS entry_status
        INTO v_jl
        FROM journal_lines l
        JOIN accounts a ON a.id = l.account_id
        JOIN journal_entries e ON e.id = l.entry_id
        WHERE l.id = v_jl_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'JL_NOT_FOUND|%', v_jl_id;
        END IF;
        IF v_jl.account_code <> v_line.bank_account_code THEN
            RAISE EXCEPTION 'JL_WRONG_ACCOUNT|%', v_jl_id;
        END IF;
        IF v_jl.currency <> v_line.currency THEN
            RAISE EXCEPTION 'JL_WRONG_CURRENCY|%|%', v_jl_id, v_jl.currency;
        END IF;
        IF EXISTS (SELECT 1 FROM bank_line_matches m WHERE m.journal_line_id = v_jl_id) THEN
            RAISE EXCEPTION 'JL_ALREADY_MATCHED|%', v_jl_id;
        END IF;
        IF v_jl.entry_status <> 'posted' THEN
            RAISE EXCEPTION 'JL_ENTRY_REVERSED|%', v_jl_id;
        END IF;
        -- 方向:入账(+)= 银行借方,出账(−)= 银行贷方
        IF (v_line.amount > 0 AND v_jl.debit <= 0) OR (v_line.amount < 0 AND v_jl.credit <= 0) THEN
            RAISE EXCEPTION 'JL_WRONG_DIRECTION|%', v_jl_id;
        END IF;

        -- 立即插入:同一数组里的重复 id 会被上面的 already-matched 检查看见
        INSERT INTO bank_line_matches (statement_line_id, journal_line_id, matched_amount)
        VALUES (p_statement_line_id, v_jl_id, v_jl.amount_ccy);

        v_sum := v_sum + v_jl.amount_ccy;
        v_count := v_count + 1;
    END LOOP;

    IF round(v_sum, 2) IS DISTINCT FROM round(abs(v_line.amount), 2) THEN
        RAISE EXCEPTION 'MATCH_AMOUNT_MISMATCH|%|%', round(abs(v_line.amount), 2), round(v_sum, 2);
    END IF;

    UPDATE bank_statement_lines SET match_status = 'matched' WHERE id = p_statement_line_id;

    RETURN jsonb_build_object(
        'statement_line_id', p_statement_line_id,
        'matched_count', v_count,
        'matched_total', round(v_sum, 2)
    );
END;
$function$;

-- ============================================================================
-- B7. unmatch / ignore / unignore
-- ============================================================================
CREATE FUNCTION public.unmatch_bank_line(p_statement_line_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_line record;
BEGIN
    SELECT l.id, l.match_status, s.status AS stmt_status
    INTO v_line
    FROM bank_statement_lines l
    JOIN bank_statements s ON s.id = l.statement_id AND s.deleted_at IS NULL
    WHERE l.id = p_statement_line_id
    FOR UPDATE OF l;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'LINE_NOT_FOUND|%', p_statement_line_id;
    END IF;
    IF v_line.stmt_status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_RECONCILED';
    END IF;
    IF v_line.match_status <> 'matched' THEN
        RAISE EXCEPTION 'LINE_NOT_MATCHED|%', v_line.match_status;
    END IF;

    DELETE FROM bank_line_matches WHERE statement_line_id = p_statement_line_id;
    UPDATE bank_statement_lines SET match_status = 'unmatched' WHERE id = p_statement_line_id;
END;
$function$;

CREATE FUNCTION public.ignore_bank_line(p_statement_line_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_line record;
BEGIN
    SELECT l.id, l.match_status, s.status AS stmt_status
    INTO v_line
    FROM bank_statement_lines l
    JOIN bank_statements s ON s.id = l.statement_id AND s.deleted_at IS NULL
    WHERE l.id = p_statement_line_id
    FOR UPDATE OF l;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'LINE_NOT_FOUND|%', p_statement_line_id;
    END IF;
    IF v_line.stmt_status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_RECONCILED';
    END IF;
    IF v_line.match_status <> 'unmatched' THEN
        RAISE EXCEPTION 'LINE_NOT_UNMATCHED|%', v_line.match_status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    UPDATE bank_statement_lines
    SET match_status = 'ignored', ignore_reason = btrim(p_reason)
    WHERE id = p_statement_line_id;
END;
$function$;

CREATE FUNCTION public.unignore_bank_line(p_statement_line_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_line record;
BEGIN
    SELECT l.id, l.match_status, s.status AS stmt_status
    INTO v_line
    FROM bank_statement_lines l
    JOIN bank_statements s ON s.id = l.statement_id AND s.deleted_at IS NULL
    WHERE l.id = p_statement_line_id
    FOR UPDATE OF l;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'LINE_NOT_FOUND|%', p_statement_line_id;
    END IF;
    IF v_line.stmt_status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_RECONCILED';
    END IF;
    IF v_line.match_status <> 'ignored' THEN
        RAISE EXCEPTION 'LINE_NOT_IGNORED|%', v_line.match_status;
    END IF;

    UPDATE bank_statement_lines
    SET match_status = 'unmatched', ignore_reason = NULL
    WHERE id = p_statement_line_id;
END;
$function$;

-- ============================================================================
-- B8. reconcile / unreconcile
-- ============================================================================
CREATE FUNCTION public.reconcile_statement(p_statement_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_stmt        record;
    v_outstanding integer;
    v_matched     integer;
    v_ignored     integer;
BEGIN
    SELECT * INTO v_stmt FROM bank_statements
    WHERE id = p_statement_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', p_statement_id;
    END IF;
    IF v_stmt.status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_ALREADY_RECONCILED|%', v_stmt.code;
    END IF;

    SELECT count(*) FILTER (WHERE match_status = 'unmatched'),
           count(*) FILTER (WHERE match_status = 'matched'),
           count(*) FILTER (WHERE match_status = 'ignored')
    INTO v_outstanding, v_matched, v_ignored
    FROM bank_statement_lines
    WHERE statement_id = p_statement_id;

    IF v_outstanding > 0 THEN
        RAISE EXCEPTION 'LINES_OUTSTANDING|%', v_outstanding;
    END IF;

    UPDATE bank_statements
    SET status = 'reconciled', reconciled_at = now(), reconciled_by = auth.uid()
    WHERE id = p_statement_id;

    RETURN jsonb_build_object(
        'statement_id', p_statement_id,
        'code', v_stmt.code,
        'matched_lines', v_matched,
        'ignored_lines', v_ignored,
        'closing_balance', v_stmt.closing_balance
    );
END;
$function$;

CREATE FUNCTION public.unreconcile_statement(p_statement_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_stmt record;
BEGIN
    SELECT * INTO v_stmt FROM bank_statements
    WHERE id = p_statement_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', p_statement_id;
    END IF;
    IF v_stmt.status <> 'reconciled' THEN
        RAISE EXCEPTION 'STATEMENT_NOT_RECONCILED|%', v_stmt.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    UPDATE bank_statements
    SET status = 'open',
        reconciled_at = NULL,
        reconciled_by = NULL,
        notes = COALESCE(notes || E'\n', '') || 'UNRECONCILED ' || now()::text || ': ' || btrim(p_reason)
    WHERE id = p_statement_id;
END;
$function$;

-- ============================================================================
-- B9. bank_reconciliation_status — one row per bank account.
-- 对账恒等式:latest_closing_balance + 未匹配分录行净额 − 未匹配报表行净额
-- 应当回到 ledger_balance;UI 用两侧未匹配清单解释 difference 的缺口。
-- ============================================================================
CREATE VIEW public.bank_reconciliation_status
WITH (security_invoker = on) AS
SELECT b.account_code,
       bank_native_currency(b.account_code) AS currency,
       round(COALESCE(led.balance, 0), 2) AS ledger_balance,
       ls.code AS latest_statement_code,
       ls.period_end AS latest_statement_period_end,
       ls.closing_balance AS latest_closing_balance,
       COALESCE(sl.unmatched, 0) AS unmatched_statement_lines,
       COALESCE(sl.ignored, 0) AS ignored_statement_lines,
       COALESCE(jl.unmatched_count, 0) AS unmatched_journal_lines,
       round(COALESCE(jl.unmatched_net, 0), 2) AS unmatched_journal_amount,
       round(COALESCE(led.balance, 0) - ls.closing_balance, 2) AS difference
FROM (VALUES ('1000'), ('1010')) b(account_code)
LEFT JOIN LATERAL (
    SELECT sum(CASE WHEN l.debit > 0 THEN l.amount_ccy ELSE -l.amount_ccy END) AS balance
    FROM journal_lines l
    JOIN accounts a ON a.id = l.account_id AND a.code = b.account_code
    JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'
    WHERE l.currency = bank_native_currency(b.account_code)
) led ON true
LEFT JOIN LATERAL (
    SELECT s.code, s.period_end, s.closing_balance
    FROM bank_statements s
    WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL
    ORDER BY s.period_end DESC, s.created_at DESC
    LIMIT 1
) ls ON true
LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE l.match_status = 'unmatched') AS unmatched,
           count(*) FILTER (WHERE l.match_status = 'ignored') AS ignored
    FROM bank_statement_lines l
    JOIN bank_statements s ON s.id = l.statement_id
    WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL
) sl ON true
LEFT JOIN LATERAL (
    SELECT count(*) AS unmatched_count,
           sum(CASE WHEN l.debit > 0 THEN l.amount_ccy ELSE -l.amount_ccy END) AS unmatched_net
    FROM journal_lines l
    JOIN accounts a ON a.id = l.account_id AND a.code = b.account_code
    JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'
    WHERE l.currency = bank_native_currency(b.account_code)
      AND NOT EXISTS (SELECT 1 FROM bank_line_matches m WHERE m.journal_line_id = l.id)
) jl ON true;

-- ============================================================================
-- B10. bank_unmatched_journal_lines — 匹配工作台的候选清单:
-- 银行科目上、posted、原币 = 账户本币、且尚未被任何报表行认领的分录行。
-- ============================================================================
CREATE VIEW public.bank_unmatched_journal_lines
WITH (security_invoker = on) AS
SELECT l.id AS journal_line_id,
       e.id AS entry_id,
       e.code AS entry_code,
       e.entry_date,
       e.memo,
       e.source_type,
       e.source_id,
       a.code AS account_code,
       l.currency,
       l.amount_ccy,
       CASE WHEN l.debit > 0 THEN 'debit' ELSE 'credit' END AS direction
FROM journal_lines l
JOIN accounts a ON a.id = l.account_id
JOIN journal_entries e ON e.id = l.entry_id
WHERE a.code IN ('1000','1010')
  AND e.status = 'posted'
  AND l.currency = bank_native_currency(a.code)
  AND NOT EXISTS (SELECT 1 FROM bank_line_matches m WHERE m.journal_line_id = l.id);

COMMIT;
