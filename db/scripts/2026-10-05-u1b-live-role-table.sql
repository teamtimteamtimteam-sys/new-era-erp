-- db/scripts/2026-10-05-u1b-live-role-table.sql
-- U1-B · 线上逐角色读数表(委托书 §3「Live verification · Read-only」)—— 一笔事务,ROLLBACK。
--   以七个真账号各自的身份(SET ROLE authenticated + 那个人的 JWT —— PostgREST 对每一次请求做的就是这两件事)读:
--   ① 一张工资分录的冲销申请(线上 0 张,所以在这笔事务里自建一张【自己的】工资分录与冲销申请 —— 不碰任何既有单据,随 ROLLBACK 消失);
--   ② 医疗报销 MC-2026-0001 生成的那张费用单 EXP-2026-0008(既有单据,只读),与报销单本身、它的审批留痕。
--   每一格写的是"读到了什么":一个数 / Restricted(NULL 且受限)/ 42501(基表那一列被拒)/ no rows(那一行读不到)。
-- 以 postgres 跑(psql),输出一张表;不写任何东西(除了随 ROLLBACK 消失的那两行)。
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE TEMP TABLE u1b_who (email text, uid uuid, role text);
INSERT INTO u1b_who
SELECT u.email, u.id, (SELECT string_agg(r.code, '+' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                        WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
  FROM auth.users u ORDER BY u.email;
GRANT SELECT ON u1b_who TO authenticated;

-- ① 自建的工资分录与它的冲销申请(随 ROLLBACK 消失)
CREATE TEMP TABLE u1b_ids (k text, id uuid);
GRANT SELECT ON u1b_ids TO authenticated;
DO $$
DECLARE v_base text; je uuid; jr uuid; ap uuid;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    je := (post_journal_entry(CURRENT_DATE, 'U1B live role table · salary payment', 'payroll', gen_random_uuid(), jsonb_build_array(
        jsonb_build_object('account_code', '2300', 'side', 'debit', 'currency', v_base, 'amount_ccy', 4677, 'fx_rate', 1),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 4677, 'fx_rate', 1)))->>'entry_id')::uuid;
    INSERT INTO journal_requests (kind, status, label, entry_date, memo, target_entry_id, amount_base, credits_bank, created_by)
    VALUES ('reversal', 'submitted', 'U1B live role table', CURRENT_DATE, 'U1B paid twice', je, 4677, true,
            (SELECT id FROM auth.users WHERE email = 'chooer@evoltrya.test')) RETURNING id INTO jr;
    INSERT INTO approval_log (subject_type, subject_id, subject_code, decision, level, actor_user_id, amount_ccy, currency, fx_rate, amount_base)
    VALUES ('journal_request', jr, 'U1B live role table', 'submitted', 2, (SELECT id FROM auth.users WHERE email = 'chooer@evoltrya.test'),
            4677, v_base, 1, 4677) RETURNING id INTO ap;
    INSERT INTO u1b_ids VALUES ('je', je), ('jr', jr), ('ap_jr', ap),
        ('mc', (SELECT id FROM medical_claims WHERE code = 'MC-2026-0001')),
        ('ex', (SELECT id FROM expenses WHERE code = 'EXP-2026-0008')),
        ('ap_mc', (SELECT id FROM approval_log WHERE subject_type = 'medical_claim' AND subject_code = 'MC-2026-0001' LIMIT 1));
END $$;

CREATE TEMP TABLE u1b_out (email text, role text, item text, api text, masked text);
GRANT INSERT, SELECT ON u1b_out TO authenticated;

CREATE FUNCTION pg_temp.u1b_cell(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    EXECUTE p_sql INTO v;
    RETURN COALESCE(v, 'no rows');
EXCEPTION WHEN insufficient_privilege THEN
    RETURN CASE WHEN SQLERRM LIKE 'PERMISSION_DENIED%' THEN split_part(SQLERRM, '|', 1) || ' ' || split_part(SQLERRM, '|', 2) ELSE '42501' END;
WHEN OTHERS THEN
    RETURN CASE WHEN SQLERRM LIKE 'PERMISSION_DENIED%' THEN split_part(SQLERRM, '|', 1) || ' ' || split_part(SQLERRM, '|', 2) ELSE 'error: ' || left(SQLERRM, 60) END;
END $f$;

DO $$
DECLARE w record; jr uuid; ap_jr uuid; mc uuid; ex uuid; ap_mc uuid;
BEGIN
    SELECT id INTO jr FROM u1b_ids WHERE k = 'jr'; SELECT id INTO ap_jr FROM u1b_ids WHERE k = 'ap_jr';
    SELECT id INTO mc FROM u1b_ids WHERE k = 'mc'; SELECT id INTO ex FROM u1b_ids WHERE k = 'ex'; SELECT id INTO ap_mc FROM u1b_ids WHERE k = 'ap_mc';
    FOR w IN SELECT * FROM u1b_who ORDER BY email LOOP
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', w.uid), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO u1b_out VALUES
        (w.email, w.role, 'payroll reversal request · amount',
            pg_temp.u1b_cell(format('SELECT amount_base::text FROM journal_requests WHERE id = %L', jr)),
            pg_temp.u1b_cell(format('SELECT CASE WHEN amount_restricted THEN ''Restricted'' ELSE amount_base::text END FROM journal_requests_masked WHERE id = %L', jr))),
        (w.email, w.role, 'payroll reversal request · approval row amount',
            pg_temp.u1b_cell(format('SELECT amount_base::text FROM approval_log WHERE id = %L', ap_jr)),
            pg_temp.u1b_cell(format('SELECT COALESCE(amount_base::text, ''Restricted'') FROM approval_log_masked WHERE id = %L', ap_jr))),
        (w.email, w.role, 'medical expense EXP-2026-0008 · amount',
            pg_temp.u1b_cell(format('SELECT amount_ccy::text || '' '' || currency FROM expenses WHERE id = %L', ex)),
            '—'),
        (w.email, w.role, 'medical expense EXP-2026-0008 · its notes (system text)',
            pg_temp.u1b_cell(format('SELECT notes FROM expenses WHERE id = %L', ex)),
            '—'),
        (w.email, w.role, 'MC-2026-0001 · description (health text)',
            pg_temp.u1b_cell(format('SELECT description FROM medical_claims WHERE id = %L', mc)),
            pg_temp.u1b_cell(format('SELECT CASE WHEN description IS NULL THEN ''Restricted'' ELSE ''shown ('' || length(description) || '' chars)'' END FROM medical_claims_masked WHERE id = %L', mc))),
        (w.email, w.role, 'MC-2026-0001 · decision reason',
            pg_temp.u1b_cell(format('SELECT COALESCE(decision_notes, ''(empty)'') FROM medical_claims WHERE id = %L', mc)),
            pg_temp.u1b_cell(format('SELECT CASE WHEN has_permission(''data.view_health'') OR employee_id = current_user_employee() THEN COALESCE(decision_notes, ''(empty)'') ELSE ''Restricted'' END FROM medical_claims_masked WHERE id = %L', mc))),
        (w.email, w.role, 'MC-2026-0001 · approval note',
            pg_temp.u1b_cell(format('SELECT COALESCE(note, ''(empty)'') FROM approval_log WHERE id = %L', ap_mc)),
            pg_temp.u1b_cell(format('SELECT CASE WHEN approval_log_note_visible(subject_type, subject_id) THEN COALESCE(note, ''(empty)'') ELSE ''Restricted'' END FROM approval_log_masked WHERE id = %L', ap_mc))),
        (w.email, w.role, 'MC-2026-0001 · amount (claim)',
            pg_temp.u1b_cell(format('SELECT amount_sgd::text FROM medical_claims WHERE id = %L', mc)),
            pg_temp.u1b_cell(format('SELECT COALESCE(amount_sgd::text, ''Restricted'') FROM medical_claims_masked WHERE id = %L', mc)));
        EXECUTE 'RESET ROLE';
        -- 审计记录的那一格:record_trail 以属主身份跑、按读者的 JWT 问规则 —— 这里同样:RESET ROLE 之后、JWT 还是这个人的
        INSERT INTO u1b_out VALUES (w.email, w.role, 'payroll reversal request · change-log rule (trail)', '—',
            CASE WHEN change_log_rule_visible('jr_amount', 'journal_requests', jsonb_build_object('id', jr), NULL, NULL)
                 THEN 'visible' ELSE 'Restricted' END);
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);
END $$;

SELECT email, role, item, api AS "base table (API)", masked AS "masked view / rule (page · trail)" FROM u1b_out ORDER BY item, email;
ROLLBACK;
