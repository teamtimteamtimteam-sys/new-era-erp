-- db/functions/decide_journal_request.sql
-- APR-6(2026-09-25):CFO 批准或驳回一张手工凭证 / 冲销申请。批准【当场过账】(grilling Q3),按提交时冻下来的
-- 那一组 —— 日期就是提单人填的那一天。
--
-- 【门】module.finance.view + data.view_prices —— 与付款、贷项申请同一对码(凭证页的门,加上看得见金额的那个码;
-- docs/approvals.md §5)。【不是】module.finance.edit:那是提单的码。cfo 两个都持(Step 0 以 postgres 读基表)。
-- 【谁能批】二级审批人,每一张、不分档,从不经按金额分档的那一支(N1 对 journal_entries 退休,Q2)。
-- 【四眼】forbid_self_approval(提单人, NULL, …)—— 一张手工凭证不是谁的"自己的单据",主角那条腿对谁都不成立;
-- 提单人那条腿按人认:admin@ 提的,tim@ 批不了(同一个人)—— 所以提交时就按名拒
-- JOURNAL_REQUEST_NO_OTHER_DECIDER,不让它挂到这里。self_approval_exception 不认本类型,R2 不适用。
--
-- 【批准之前不另查】批准就是那一次真的过账:期间在等待中被锁上(PERIOD_LOCKED)、年结(YEAR_CLOSED)、
-- 科目被停用、那张要冲的分录已经被别的路冲掉 —— 全按引擎原话拒,整笔回滚,申请仍在等;CFO 驳回,
-- 或财务撤回、换一个开着的日子再提(Q4:锁永远赢,从不因为一张在等的申请而被拒)。驳回从不检查这些:
-- 驳回一张坏掉的申请,正是出路。驳回要理由。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
--
-- 【过出来那张分录的 created_by 是批准的 CFO】(列默认 auth.uid(),而过账发生在批准这一刻)。职责分离那条
-- 规矩(sod_manual_posters_in)因此经 journal_requests.result_journal_entry_id 找回【提单人】—— Q5:
-- 批准的 CFO 不是"记手工凭证的人"。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.decide_journal_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    journal_requests%ROWTYPE;
    v_post jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM journal_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'journal_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'JOURNAL_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE journal_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('journal_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_post := journal_request_post_internal(p_request_id);

    UPDATE journal_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           amount_base = (v_post->>'amount_base')::numeric,
           credits_bank = (v_post->>'credits_bank')::boolean,
           result_journal_entry_id = (v_post->>'entry_id')::uuid
     WHERE id = p_request_id;
    PERFORM record_approval_decision('journal_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'kind', v_r.kind,
                              'entry_id', v_post->>'entry_id',
                              'journal_code', v_post->>'journal_code',
                              'amount_base', v_post->'amount_base');
END;
$function$;
