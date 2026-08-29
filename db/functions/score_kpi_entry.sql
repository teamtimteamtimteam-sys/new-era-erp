-- db/functions/score_kpi_entry.sql
-- KPI-1:给一条 KPI 打分 —— 0–5,并说清这个分是【算出来的】还是【人判的】(§10.2)。
--
-- ★【安全/监管否决是一个【封顶】动作,不是一个分数】★(原表第六页)
--   「Major breach can cap score at 0–2 depending on severity」、
--   「Critical control gap may cap at 2」、「Any unauthorized operation = 0」。
--   **封顶不覆盖原始判断**:score 与 override_cap 都留着,
--   于是事后分得清「他本来就只有 2 分」与「他被封到 2 分」——
--   这两句话在一次复盘里意思完全不同,而一个只存最终分的实现说不出后一句。
--   生效分 = LEAST(score, override_cap),由视图算,不另存(算得出来的不存)。

CREATE OR REPLACE FUNCTION public.score_kpi_entry(
    p_entry_id uuid,
    p_score integer,
    p_score_kind text DEFAULT 'judged'::text,
    p_evidence_note text DEFAULT NULL::text,
    p_computed_basis text DEFAULT NULL::text,
    p_override_cap integer DEFAULT NULL::integer,
    p_override_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_e     kpi_entries%ROWTYPE;
    v_cycle kpi_cycles%ROWTYPE;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_e FROM kpi_entries WHERE id = p_entry_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KPI_ENTRY_NOT_FOUND|%', p_entry_id; END IF;
    SELECT * INTO v_cycle FROM kpi_cycles WHERE id = v_e.cycle_id;
    IF v_cycle.status = 'closed' THEN
        RAISE EXCEPTION 'KPI_CYCLE_CLOSED|%', v_cycle.name
          USING HINT = '这个周期已经关了 —— 改一个关掉的周期里的分数是在改历史,要改先重开周期,那一步会留痕';
    END IF;

    IF p_score IS NULL OR p_score < 0 OR p_score > 5 THEN
        RAISE EXCEPTION 'KPI_SCORE_OUT_OF_RANGE|%', COALESCE(p_score::text, 'null')
          USING HINT = '打分是 0–5 的整数(原表第六页逐档定义了 5/4/3/2/1/0,没有小数档)';
    END IF;
    IF p_score_kind IS NULL OR p_score_kind NOT IN ('judged','computed') THEN
        RAISE EXCEPTION 'KPI_SCORE_KIND_INVALID|%', COALESCE(p_score_kind, 'null')
          USING HINT = '一个分数要说出它是【算出来的】还是【人判的】—— 两者可靠性差着一个数量级,而屏幕上必须长得不一样(规格 §10.2)';
    END IF;
    -- ★【说自己是算出来的,就得说出算的是什么】★ 否则 computed 只是一个更好看的标签,
    --   而那正是 §10.2 要防的:打分的人以为整条都有据可依。
    IF p_score_kind = 'computed'
       AND NULLIF(btrim(COALESCE(p_computed_basis, '')), '') IS NULL THEN
        RAISE EXCEPTION 'KPI_COMPUTED_NEEDS_BASIS|%', v_e.kpi_ref
          USING HINT = '标成【算出来的】就要写清它算的是什么(哪几次盘点、哪张账龄、截至哪一天)—— 否则 computed 只是一个更好看的标签';
    END IF;
    -- 封顶要有理由 —— 一次没有理由的否决,事后与一次低分长得一模一样。
    IF p_override_cap IS NOT NULL
       AND NULLIF(btrim(COALESCE(p_override_reason, '')), '') IS NULL THEN
        RAISE EXCEPTION 'KPI_OVERRIDE_NEEDS_REASON|%', v_e.kpi_ref
          USING HINT = '安全/监管否决要写明是哪一件事(原表:major breach 可封到 0–2、unauthorized operation = 0)—— 没有理由的封顶,事后与一次低分长得一模一样';
    END IF;
    IF p_override_cap IS NOT NULL AND (p_override_cap < 0 OR p_override_cap > 5) THEN
        RAISE EXCEPTION 'KPI_SCORE_OUT_OF_RANGE|%', p_override_cap; END IF;

    UPDATE kpi_entries
       SET score = p_score,
           score_kind = p_score_kind,
           computed_basis = NULLIF(btrim(COALESCE(p_computed_basis, '')), ''),
           evidence_note = NULLIF(btrim(COALESCE(p_evidence_note, '')), ''),
           override_cap = p_override_cap,
           override_reason = NULLIF(btrim(COALESCE(p_override_reason, '')), ''),
           scored_by = auth.uid(), scored_at = now(),
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_entry_id;

    RETURN jsonb_build_object(
        'entry_id', p_entry_id,
        'kpi_ref', v_e.kpi_ref,
        'score', p_score,
        'score_kind', p_score_kind,
        -- 生效分:封顶之后的那个。**两个数都回,不只回一个** —— 见抬头。
        'effective_score', LEAST(p_score, COALESCE(p_override_cap, 5)),
        'capped', (p_override_cap IS NOT NULL AND p_override_cap < p_score),
        'weighted', round(LEAST(p_score, COALESCE(p_override_cap, 5))::numeric / 5 * v_e.weight_pct, 2));
END;
$function$;

COMMENT ON FUNCTION public.score_kpi_entry(uuid, integer, text, text, text, integer, text) IS
'KPI-1:给一条 KPI 打 0–5 分。**分数必须说出自己是 judged 还是 computed**(规格 §10.2 是设计要求不是可选项),而**标成 computed 就必须写出它算的是什么** —— 否则 computed 只是一个更好看的标签,打分的人会以为整条都有据可依。**安全/监管否决是【封顶】不是【分数】**(原表第六页):score 与 override_cap 都留着,于是事后分得清「他本来就只有 2 分」与「他被封到 2 分」—— 一个只存最终分的实现说不出后一句。生效分 = LEAST(score, cap),由视图算,不另存。';
