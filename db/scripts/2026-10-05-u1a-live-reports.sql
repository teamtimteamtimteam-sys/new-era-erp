-- db/scripts/2026-10-05-u1a-live-reports.sql
-- U1-A · 报表、余额与对账【对每一个打得开它们的读者】前后一样 —— 只读(一笔 ROLLBACK 的事务),以六个持 module.finance.view 的
--   真账号的会话逐个读:试算表(迁移前 = 页面那时的读法,逐行 journal_lines 求和;迁移后 = trial_balance_totals,页面的新读法)·
--   损益表(2026 全年)· 资产负债表(今天)· 应收 / 应付的清单与总账对账。每一样取一个指纹(按内容排好再 md5),对账另给数。
--   迁移前跑一次、全部验证之后跑一次:同一个读者两次的指纹必须逐字相同。
-- ★ 读者的身份是承重的:这几支读法按读者的码过滤(属主身份没有 JWT,读到的是一次拒绝,不是一次测量 —— AGENTS.md 的 0 行那一条)。
BEGIN;
CREATE TEMP TABLE u1a_rep (reader text, item text, value text) ON COMMIT DROP;
DO $rep$
DECLARE
    rd record; v text; v_tb text;
BEGIN
    v_tb := CASE WHEN to_regprocedure('public.trial_balance_totals()') IS NULL
                 THEN 'SELECT md5(COALESCE(string_agg(x::text, ''|'' ORDER BY x::text), '''')) FROM (SELECT l.account_id, sum(l.debit) d, sum(l.credit) c FROM journal_lines l GROUP BY l.account_id) x'
                 ELSE 'SELECT md5(COALESCE(string_agg(x::text, ''|'' ORDER BY x::text), '''')) FROM (SELECT t.account_id, t.debits d, t.credits c FROM trial_balance_totals() t) x' END;
    FOR rd IN SELECT u.email, u.id FROM auth.users u
               WHERE EXISTS (SELECT 1 FROM user_roles ur JOIN role_permissions rp ON rp.role_id = ur.role_id
                              WHERE ur.user_id = u.id AND ur.revoked_at IS NULL AND rp.permission_code = 'module.finance.view')
               ORDER BY u.email LOOP
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', rd.id), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE v_tb INTO v;
        EXECUTE 'RESET ROLE'; INSERT INTO u1a_rep VALUES (rd.email, 'trial balance', v); EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT md5(pnl_statement(DATE '2026-01-01', DATE '2026-12-31')::text) INTO v;
        EXECUTE 'RESET ROLE'; INSERT INTO u1a_rep VALUES (rd.email, 'p&l 2026', v); EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT md5(balance_sheet(CURRENT_DATE)::text) INTO v;
        EXECUTE 'RESET ROLE'; INSERT INTO u1a_rep VALUES (rd.email, 'balance sheet', v); EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT string_agg(s ->> 'side' || ' ' || (s ->> 'list_base') || '/' || (s ->> 'ledger_base') || ' unexplained ' || (s ->> 'unexplained_base')
                          || ' agrees ' || (s ->> 'agrees'), ' · ' ORDER BY s ->> 'side')
          INTO v FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s;
        EXECUTE 'RESET ROLE'; INSERT INTO u1a_rep VALUES (rd.email, 'AP/AR recon', v);
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);
END;
$rep$;
SELECT reader, item, value FROM u1a_rep ORDER BY reader, item;
ROLLBACK;
