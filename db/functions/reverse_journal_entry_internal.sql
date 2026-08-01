-- db/functions/reverse_journal_entry_internal.sql
-- 冲销分录的【内部算子】:DEFINER,不检查权限,EXECUTE 已对 PUBLIC/authenticated/anon 收回。
--
-- 为什么要拆:reverse_journal_entry 既是财务的界面入口(必须查 module.finance.edit),
-- 又是别的动作的内部一步 —— 运营重做成本分摊要先冲掉上一次的资本化分录,
-- 人力资源反过账要冲掉薪资分录。DEFINER 不改变 auth.uid(),所以内层检查查的仍是
-- 最终用户,于是这两个岗位会被财务的码挡在自己的正当动作外面。
--
-- 手工冲销一张分录仍然要 module.finance.edit;变的只是:检查的是【正在做的那件事】
-- 的权限,而不是这件事在账上留下的痕迹所属模块的权限(cut 2a B4(b) 的规矩)。
--
-- NOTE: introduced by db/migrations/2026-08-02-perm3b-reversal-boundary.sql.

CREATE OR REPLACE FUNCTION public.reverse_journal_entry_internal(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        record;
    v_lines       jsonb;
    v_result      jsonb;
    v_reversal_id uuid;
BEGIN
    SELECT * INTO v_orig FROM journal_entries WHERE id = p_entry_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JE_NOT_FOUND|%', p_entry_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by IS NOT NULL THEN
        RAISE EXCEPTION 'JE_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 行全部翻边(debit↔credit),原币金额/汇率原样 → USD 侧必然精确对冲。
    SELECT jsonb_agg(
        jsonb_build_object(
            'account_code', a.code,
            'side', CASE WHEN l.debit > 0 THEN 'credit' ELSE 'debit' END,
            'currency', l.currency,
            'amount_ccy', l.amount_ccy,
            'fx_rate', l.fx_rate,
            'line_memo', l.line_memo
        ) ORDER BY l.created_at, l.id
    ) INTO v_lines
    FROM journal_lines l
    JOIN accounts a ON a.id = l.account_id
    WHERE l.entry_id = p_entry_id;

    -- 期间锁由 post_journal_entry 对 p_reversal_date 统一执行
    v_result := post_journal_entry(
        p_reversal_date,
        'REVERSAL: ' || COALESCE(p_memo, v_orig.memo, v_orig.code),
        v_orig.source_type,
        v_orig.id,
        v_lines
    );
    v_reversal_id := (v_result->>'entry_id')::uuid;

    UPDATE journal_entries
    SET status = 'reversed', reversed_by = v_reversal_id
    WHERE id = p_entry_id;

    RETURN jsonb_build_object(
        'reversal_id', v_reversal_id,
        'code', v_result->>'code'
    );
END;
$function$;
