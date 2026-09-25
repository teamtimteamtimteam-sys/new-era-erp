-- db/functions/journal_request_submit_internal.sql
-- APR-6(2026-09-25):提一张手工凭证 / 冲销申请 —— submit_journal_request 与 submit_journal_reversal_request
-- 都落进来的那一支。两扇门各自先问 module.finance.edit;本支不问码。
--
--   1. 日期、摘要 / 理由在写入之前就按名拒(JE_LINE_INVALID|entry_date · REVERSAL_DATE_REQUIRED ·
--      JE_MEMO_REQUIRED · JOURNAL_REVERSAL_REASON_REQUIRED)—— 否则撞上的是表上的 NOT NULL / CHECK,屏幕只能说"意外错误"。
--      【日期决定期间,所以必填、从不代填】(AGENTS.md「Dates and amounts that decide a period」)。
--   2. reversal:那张分录要在(JE_NOT_FOUND),要冲得了(已冲过 → JE_ALREADY_REVERSED),而且要落在
--      'request' 那一格 —— 有自己冲销路径的按名拒 JE_REVERSE_USE_SOURCE_PATH(journal_entry_reversal_route
--      一份判据,Q6)。同一张分录已经挂着一张在等的冲销 → JOURNAL_REQUEST_OPEN|分录|那一张(唯一索引是第二道)。
--   3. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动(assert_other_decider,按人认)。
--      没有 → JOURNAL_REQUEST_NO_OTHER_DECIDER|label。线上是 admin@:它与 tim@ 是同一个人,而二级只有 tim@。
--   4. 落一行 submitted;参数原样冻结。
--   5. 按批准那一刻会用的同一支过账试跑(journal_request_dry_run)—— 借贷不平、科目、币种、汇率、期间锁、
--      年结、超出当月、1100 / 2000,这里按引擎的原话拒。amount_base 与 credits_bank 取试跑的结果。
--   6. 审批开着:留痕 submitted,二级。关着:当场过账(journal_request_post_internal),状态 approved,
--      留痕 auto_approved —— 没有人按过批准,留痕就不许说有人按过。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.journal_request_submit_internal(p_kind text, p_entry_date date, p_memo text, p_lines jsonb, p_target_entry_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_on    boolean := approvals_enabled();
    v_id    uuid := gen_random_uuid();
    v_je    journal_entries%ROWTYPE;
    v_route text;
    v_open  text;
    v_n     integer;
    v_label text;
    v_dry   jsonb;
    v_post  jsonb := NULL;
BEGIN
    IF p_kind = 'entry' THEN
        IF p_entry_date IS NULL THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
        END IF;
        IF p_memo IS NULL OR btrim(p_memo) = '' THEN
            RAISE EXCEPTION 'JE_MEMO_REQUIRED';
        END IF;
        IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|lines';
        END IF;
    ELSIF p_kind = 'reversal' THEN
        IF p_entry_date IS NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
        END IF;
        IF p_memo IS NULL OR btrim(p_memo) = '' THEN
            RAISE EXCEPTION 'JOURNAL_REVERSAL_REASON_REQUIRED';
        END IF;
        SELECT * INTO v_je FROM journal_entries WHERE id = p_target_entry_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'JE_NOT_FOUND|%', COALESCE(p_target_entry_id::text, '?');
        END IF;
        v_route := journal_entry_reversal_route(v_je.id);
        IF v_route = 'reversed' THEN
            RAISE EXCEPTION 'JE_ALREADY_REVERSED|%', v_je.code;
        END IF;
        IF v_route = 'source_path' THEN
            RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_je.code, v_je.source_type;
        END IF;
        SELECT q.label INTO v_open FROM journal_requests q
         WHERE q.target_entry_id = v_je.id AND q.kind = 'reversal' AND q.status = 'submitted';
        IF FOUND THEN
            RAISE EXCEPTION 'JOURNAL_REQUEST_OPEN|%|%', v_je.code, v_open;
        END IF;
    ELSE
        RAISE EXCEPTION 'JOURNAL_REQUEST_KIND_UNKNOWN|%|%', '?', COALESCE(p_kind, '?');
    END IF;

    -- label 的序号:同一种类里第几张。咨询锁串行化"数一遍 + 1",与 post_journal_entry 的编号同一个手法。
    PERFORM pg_advisory_xact_lock(hashtext('journal_request_label')::bigint);
    IF p_kind = 'entry' THEN
        SELECT count(*) + 1 INTO v_n FROM journal_requests WHERE kind = 'entry';
        v_label := 'manual journal #' || v_n::text;
    ELSE
        SELECT count(*) + 1 INTO v_n FROM journal_requests WHERE kind = 'reversal' AND target_entry_id = v_je.id;
        v_label := v_je.code || ' · reversal #' || v_n::text;
    END IF;

    PERFORM assert_other_decider('journal_request', 'decide_journal_request', 2::smallint,
                                 'JOURNAL_REQUEST_NO_OTHER_DECIDER|' || v_label);

    INSERT INTO journal_requests (id, kind, status, label, entry_date, memo, lines, target_entry_id,
                                  amount_base, created_by)
    VALUES (v_id, p_kind, 'submitted', v_label, p_entry_date, btrim(p_memo),
            CASE WHEN p_kind = 'entry' THEN p_lines END,
            CASE WHEN p_kind = 'reversal' THEN v_je.id END,
            0, auth.uid());

    v_dry := journal_request_dry_run(v_id);
    UPDATE journal_requests
       SET amount_base = (v_dry->>'amount_base')::numeric,
           credits_bank = (v_dry->>'credits_bank')::boolean
     WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('journal_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_post := journal_request_post_internal(v_id);
        UPDATE journal_requests
           SET status = 'approved', amount_base = (v_post->>'amount_base')::numeric,
               credits_bank = (v_post->>'credits_bank')::boolean,
               result_journal_entry_id = (v_post->>'entry_id')::uuid
         WHERE id = v_id;
        PERFORM record_approval_decision('journal_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场过账,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'kind', p_kind,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'amount_base', COALESCE(v_post->'amount_base', v_dry->'amount_base'),
        'credits_bank', COALESCE(v_post->'credits_bank', v_dry->'credits_bank'),
        'entry_id', v_post->>'entry_id',
        'journal_code', v_post->>'journal_code');
END;
$function$;
