-- db/functions/reverse_journal_entry.sql
-- 手工冲销一张分录(module.finance.edit)。付款、转账、代扣税缴纳的分录按名拒,走各自的申请。
-- ★ PAYROLL-APR-1(2026-09-24,Tim 的 Q5):工资期的过账分录与它的冲销也按名拒 —— 撤销走撤销申请。
-- ★ APR-5a(2026-09-25,grilling Q11 ④):发票与贷项通知的分录(以及它们的冲销)也按名拒 —— 走作废 / 贷项申请。
-- ★★ APR-6(2026-09-25,grilling Q6):**这扇门从此一张都不冲 —— 它只会拒,而且说出去哪儿冲。**
--   · 有自己冲销路径的(journal_entry_reversal_route = 'source_path':上面那些,加上 expense · freight ·
--     allocation · processing_cost · year_close)→ JE_REVERSE_USE_SOURCE_PATH|编号|source_type,与以前同一句。
--   · 其余一切('request':手工凭证,以及没有自己路径的系统分录)→ JOURNAL_NEEDS_APPROVED_REQUEST|编号 ——
--     冲它要提一张冲销申请(submit_journal_reversal_request),CFO 批准那一刻才冲(矩阵「手工凭证与冲销 |
--     财务 | CFO」)。批准就是执行,所以永远不存在"批了还没冲"的申请 —— 这扇门因此没有"带着申请"那一支
--     (APR-5a 的 create_credit_note / void_invoice 同形)。
--   · 已经冲过的 → JE_ALREADY_REVERSED(与引擎同一句);找不到 → JE_NOT_FOUND。
--   签名不变:旧的冲销钮在破窗里调它,得到的是一句按名的拒绝,而不是一次不经批准的冲销。
--   冲销的本体一直在 reverse_journal_entry_internal(EXECUTE 早已收回),各单据自己的冲销路径照旧调它。

CREATE OR REPLACE FUNCTION public.reverse_journal_entry(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_src   text;
    v_code  text;
    v_route text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT source_type, code INTO v_src, v_code FROM journal_entries WHERE id = p_entry_id;
    v_route := journal_entry_reversal_route(p_entry_id);
    IF v_route IS NULL THEN
        RAISE EXCEPTION 'JE_NOT_FOUND|%', COALESCE(p_entry_id::text, '?');
    END IF;
    IF v_route = 'reversed' THEN
        RAISE EXCEPTION 'JE_ALREADY_REVERSED|%', v_code;
    END IF;
    IF v_route = 'source_path' THEN
        RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
    END IF;
    RAISE EXCEPTION 'JOURNAL_NEEDS_APPROVED_REQUEST|%', v_code;
END;
$function$;
