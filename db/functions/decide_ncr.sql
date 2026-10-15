-- db/functions/decide_ncr.sql
-- MES-6b-1(2026-10-15,MES-0 Q65 · Q66;MES-6b Step 0 Q9 · Q21 · Q22,Tim):【决定一张不合格报告】—— action.ncr_decide(cco · cto · admin)。
--   open → decided,只此一次(之后报告只追加,guard_ncr_mutation)。
--   ★ 开单人这个【人】永远不能决定自己开的那一张(forbid_self_approval,按人认 → SELF_APPROVAL_FORBIDDEN|raiser;同一个人的另一个账号也算)。
--     系统开的(来源 quality_limit,opened_by 为空)没有开单人,任何持码人都能决定(Q9)。不是一张审批单据:四眼是工单那一种,不进审批引擎,
--     审批开关不管它(NCR 的处置是一个质量决定;钱走既有的、自己有审批的单据)。
--   处置(Q22):
--     accept               放行
--     accept_with_penalty  放行,并【指出钱走哪一张既有单据】—— 产出批:一张贷项通知申请(invoice_requests,kind = credit_note);
--                          进料批:这一批的一张收货定价申请(receipt_price_requests)。那一张必须还活着(在等或已批)。报告本身不带金额。
--     rework               放行(下一张加工单就是返工)
--     downgrade            放行,只记下(今天没有改等级的函数 —— 登记在 known-issues)
--     reject               【不放行】:暂扣留到这一批没有货(batch_quality_hold);出路是既有的 CFO 注销申请(Q21)
--   说明必填(NCR_DECISION_NOTE_REQUIRED)。返回 {ncr_id, code, status, disposition, batch_still_held, held_by}:同一批上可能还有别的开着的报告,
--   所以"这一张决定了"不等于"这一批放行了" —— 后者由 batch_quality_hold 当场再问一次。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.decide_ncr(p_ncr_id uuid, p_disposition text, p_note text, p_penalty_invoice_request_id uuid DEFAULT NULL::uuid, p_penalty_price_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_n    nonconformance_reports%ROWTYPE;
    v_hold record;
BEGIN
    PERFORM require_permission('action.ncr_decide');
    SELECT * INTO v_n FROM nonconformance_reports WHERE id = p_ncr_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'NCR_NOT_FOUND|%', COALESCE(p_ncr_id::text, '?');
    END IF;
    IF v_n.status <> 'open' THEN
        RAISE EXCEPTION 'NCR_NOT_OPEN|%|%', v_n.code, v_n.status;
    END IF;
    -- 开单人这个人不决定自己那一张;系统开的(opened_by 为空)这一句放行 —— self_leg 的 NULL 一律不匹配
    PERFORM forbid_self_approval(v_n.opened_by, NULL::uuid, 'ncr');

    IF p_disposition IS NULL OR p_disposition NOT IN ('accept', 'accept_with_penalty', 'reject', 'rework', 'downgrade') THEN
        RAISE EXCEPTION 'NCR_DISPOSITION_INVALID|%', COALESCE(p_disposition, '?');
    END IF;
    IF p_note IS NULL OR btrim(p_note) = '' THEN
        RAISE EXCEPTION 'NCR_DECISION_NOTE_REQUIRED|%', v_n.code;
    END IF;

    IF p_disposition = 'accept_with_penalty' THEN
        IF v_n.output_batch_id IS NOT NULL THEN
            IF p_penalty_invoice_request_id IS NULL OR p_penalty_price_request_id IS NOT NULL THEN
                RAISE EXCEPTION 'NCR_PENALTY_DOCUMENT_REQUIRED|%|credit_note', v_n.code
                  USING HINT = '带罚接受一批产出批:钱走一张贷项通知申请 —— 先在发票上提那一张,再在这里指出它。';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM invoice_requests r WHERE r.id = p_penalty_invoice_request_id
                              AND r.kind = 'credit_note' AND r.status IN ('submitted', 'approved')) THEN
                RAISE EXCEPTION 'NCR_PENALTY_DOCUMENT_INVALID|%|credit_note', v_n.code;
            END IF;
        ELSE
            IF p_penalty_price_request_id IS NULL OR p_penalty_invoice_request_id IS NOT NULL THEN
                RAISE EXCEPTION 'NCR_PENALTY_DOCUMENT_REQUIRED|%|price_request', v_n.code
                  USING HINT = '带罚接受一批进料:钱走这一批的一张收货定价申请 —— 先在收货页上提那一张,再在这里指出它。';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM receipt_price_requests r WHERE r.id = p_penalty_price_request_id
                              AND r.inbound_batch_id = v_n.inbound_batch_id AND r.status IN ('submitted', 'approved')) THEN
                RAISE EXCEPTION 'NCR_PENALTY_DOCUMENT_INVALID|%|price_request', v_n.code;
            END IF;
        END IF;
    ELSIF p_penalty_invoice_request_id IS NOT NULL OR p_penalty_price_request_id IS NOT NULL THEN
        RAISE EXCEPTION 'NCR_PENALTY_DOCUMENT_ONLY_WITH_PENALTY|%', v_n.code;
    END IF;

    UPDATE nonconformance_reports
       SET status = 'decided', disposition = p_disposition, decision_note = btrim(p_note),
           decided_at = now(), decided_by = v_user,
           penalty_invoice_request_id = CASE WHEN p_disposition = 'accept_with_penalty' THEN p_penalty_invoice_request_id END,
           penalty_price_request_id = CASE WHEN p_disposition = 'accept_with_penalty' THEN p_penalty_price_request_id END
     WHERE id = p_ncr_id;

    SELECT h.ncr_code INTO v_hold FROM batch_quality_hold(v_n.inbound_batch_id, v_n.output_batch_id) h;
    RETURN jsonb_build_object('ncr_id', v_n.id, 'code', v_n.code, 'status', 'decided', 'disposition', p_disposition,
                              'batch_still_held', v_hold.ncr_code IS NOT NULL, 'held_by', v_hold.ncr_code);
END;
$function$
