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
--
-- ★★【C-2(2026-09-05)加了两样,而其中一样是一道新的门】★★
--   ① `p_feedback_note` —— Sandra 录三样:分数、证据、反馈。
--      evidence_note 回答「凭什么是这个分」,feedback_note 回答「要跟他说什么」。
--   ② ★【locked_at:锁 ≠ 关】★ 此前只有 `status='closed'`,而它【同时】
--      做两件事:拒绝写入(冻结)与把分数放给本人看(揭晓)。Tim 的裁定是
--      「一个月在它的关口锁上之前一直可改」+「M3 关口锁住第 1–3 个月」——
--      一个 flag 表达不了:为了冻结而 close 会把分数提前揭晓给每个人,
--      不 close 则前两个月永远冻不住。所以拆成两个概念,而**锁那一道排在前面**:
--      被锁住的月份抛 KPI_CYCLE_LOCKED 而不是 KPI_CYCLE_CLOSED,
--      因为「重开周期」不是解决它的办法。
--
-- ★【签名变了要 DROP + CREATE,不是 CREATE OR REPLACE】★ 参数表变了就是另一个
--   签名,CREATE OR REPLACE 会留下【两个】同名函数(FIN-21 那次漂移)。
--   preflight_migration.py 正是为拒绝这件事而存在,而它认得同一支迁移里
--   出现在 CREATE 之前的 DROP —— 那是它放行的那条路。
--
-- NOTE: introduced by db/migrations/2026-08-29-kpi1-positions-and-the-kpi-framework.sql;
--       feedback + lock by db/migrations/2026-09-05-c2-hire-dates-holiday-identity-and-kpi-entry.sql.

CREATE OR REPLACE FUNCTION public.score_kpi_entry(p_entry_id uuid, p_score integer, p_score_kind text DEFAULT 'judged'::text, p_evidence_note text DEFAULT NULL::text, p_feedback_note text DEFAULT NULL::text, p_computed_basis text DEFAULT NULL::text, p_override_cap integer DEFAULT NULL::integer, p_override_reason text DEFAULT NULL::text)
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

    -- ★★【锁在前,关在后 —— 两道分开的门,两句分开的话】★★
    --   锁是关口按下的冻结(M3 锁 1–3 月);关是"这个月结束了,分数对本人揭晓"。
    --   一个被锁住的月份说"被关口锁了",而不是"已经关了" —— 后者会让人以为
    --   去重开周期就能改,而那不是这里发生的事。
    IF v_cycle.locked_at IS NOT NULL THEN
        RAISE EXCEPTION 'KPI_CYCLE_LOCKED|%|%', v_cycle.name, COALESCE(v_cycle.gate, '')
          USING HINT = '这个月已被关口锁住 —— 一道过后还能靠改那个月推翻的关口,不是关口。要改先解锁,那一步会留痕';
    END IF;
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
    IF p_score_kind = 'computed'
       AND NULLIF(btrim(COALESCE(p_computed_basis, '')), '') IS NULL THEN
        RAISE EXCEPTION 'KPI_COMPUTED_NEEDS_BASIS|%', v_e.kpi_ref
          USING HINT = '标成【算出来的】就要写清它算的是什么(哪几次盘点、哪张账龄、截至哪一天)—— 否则 computed 只是一个更好看的标签';
    END IF;
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
           feedback_note = NULLIF(btrim(COALESCE(p_feedback_note, '')), ''),
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
        'effective_score', LEAST(p_score, COALESCE(p_override_cap, 5)),
        'capped', (p_override_cap IS NOT NULL AND p_override_cap < p_score),
        'weighted', round(LEAST(p_score, COALESCE(p_override_cap, 5))::numeric / 5 * v_e.weight_pct, 2));
END;
$function$;
