-- db/functions/journal_request_post_internal.sql
-- APR-6(2026-09-25):把一张手工凭证 / 冲销申请【过账】—— 批准那一刻(或审批关着时提交那一刻)跑的那一支,
-- 也是试跑(journal_request_dry_run)跑的同一支。参数全从申请行上读,就是提交时冻下来的那一组(grilling Q3)。
--
--   entry    → post_journal_entry(entry_date, memo, 'manual', 本申请的 id, lines)—— 永远是 'manual',
--              source_id 指回申请(Q3)。人给不了别的 source_type:post_journal_entry 对 authenticated 已收回(Q1)。
--   reversal → reverse_journal_entry_internal(target, entry_date, memo)—— 先问 journal_entry_reversal_route:
--              只有 'request' 这一格能走到这里;'source_path' 按名拒 JE_REVERSE_USE_SOURCE_PATH,
--              已冲过的交给引擎按原话拒(JE_ALREADY_REVERSED)。
--   其它种类 → JOURNAL_REQUEST_KIND_UNKNOWN(不认识的种类按名拒,不许落进一个 ELSE 去做别的事)。
--
-- 【过完账再读那一张分录,按它说话】与 invoice_request_post_internal 读它自己那张分录同一条 —— 同一支引擎的
-- 产物,不在这里另算一份会漂开的数:
--   · amount_base = 借方合计(本位币);credits_bank = 有一行贷在 is_cash 科目上(Q7:准许,但要说出来)。
--   · ★ 1100 / 2000 按名拒 JE_MANUAL_CONTROL_ACCOUNT|label|科目(Q7):应收、应付的总账数只能由它们自己的
--     单据动 —— 手敲一行,list_ledger_reconciliation 那两边就会出现一笔说不出名字的差。冲销申请同一条
--     (冲掉一张 sale / prepayment 分录的总账一半,单据那一半不动,同样是一笔说不出名字的差);唯一的例外是
--     'revaluation' 的冲销 —— 那一条核对按 source_type 点名扣掉重估,冲销抄原分录的 source_type,仍被点名。
--   拒绝就是抛错:外层(批准 / 提交 / 试跑)整笔回滚,过出来的分录与编号一起消失。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.journal_request_post_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      journal_requests%ROWTYPE;
    v_res    jsonb;
    v_entry  uuid;
    v_code   text;
    v_src    text;
    v_route  text;
    v_ctrl   text;
    v_base   numeric;
    v_bank   boolean;
BEGIN
    SELECT * INTO v_r FROM journal_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    CASE v_r.kind
    WHEN 'entry' THEN
        v_res := post_journal_entry(v_r.entry_date, v_r.memo, 'manual', v_r.id, v_r.lines);
        v_entry := (v_res->>'entry_id')::uuid;
        v_code := v_res->>'code';
        v_src := 'manual';
    WHEN 'reversal' THEN
        SELECT je.code, je.source_type INTO v_code, v_src FROM journal_entries je WHERE je.id = v_r.target_entry_id;
        v_route := journal_entry_reversal_route(v_r.target_entry_id);
        IF v_route = 'source_path' THEN
            RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
        END IF;
        v_res := reverse_journal_entry_internal(v_r.target_entry_id, v_r.entry_date, v_r.memo);
        v_entry := (v_res->>'reversal_id')::uuid;
        v_code := v_res->>'code';
    ELSE
        RAISE EXCEPTION 'JOURNAL_REQUEST_KIND_UNKNOWN|%|%', v_r.label, v_r.kind;
    END CASE;

    SELECT string_agg(DISTINCT a.code, ',' ORDER BY a.code) INTO v_ctrl
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id = v_entry AND a.code IN ('1100', '2000');
    IF v_ctrl IS NOT NULL AND NOT (v_r.kind = 'reversal' AND v_src = 'revaluation') THEN
        RAISE EXCEPTION 'JE_MANUAL_CONTROL_ACCOUNT|%|%', v_r.label, v_ctrl;
    END IF;

    SELECT round(COALESCE(sum(l.debit), 0), 2),
           COALESCE(bool_or(l.credit > 0 AND a.is_cash), false)
      INTO v_base, v_bank
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id = v_entry;

    RETURN jsonb_build_object('entry_id', v_entry, 'journal_code', v_code,
                              'amount_base', v_base, 'credits_bank', v_bank);
END;
$function$;
