-- 冲销一笔开支单。【关于资本性支出,这里有两条规矩,不是一条】
-- * FIN-22(2026-08-06):生出资产卡的那一笔【永不】可冲(EXPENSE_HAS_ASSET)——
--   冲掉它会留下一台无对价的资产。先 dispose_fixed_asset,或走人工分录改正。
-- * EQP-1b-iii(2026-08-21):【追加】进来的那些笔(运费、关税、安装、设备发票)
--   可冲,而且冲销【必须把 cost_base 一起退回去】并当场核对不变量;
--   但资产一旦投用就按名拒(ASSET_IN_SERVICE_COST_LOCKED)。
--
-- ★★【CAPEX-1(2026-08-29)之后,这一条与 record_expense 那一条【不再是同一个铰链】,
--     而这句话原本就写在这里,现在必须改掉:两者不对称,不许合并】★★
--   原文写的是"与 record_expense 拒绝往已投用资产上追加用的是同一个铰链",
--   以及"投用之后,成本冻住"。**两句都不再成立**:
--   record_expense 那一侧已经改成【窄】拒 —— 经一条标了资本化的维修记录就加得上去
--   (政策 4.7),折旧从那个月起往后摊。
--   **而这一侧【一个字没动,而且应当一个字不动】**:
--     · 一次【追加】是一个新事件 —— 已经提过的折旧在当时是对的,往后走就行;
--     · 一次【冲销】断言那笔支出【本不该存在】—— 那是【回溯】的,
--       它要求已经提过的各期重新来过,而 4.7 没有授权任何回溯的东西。
--   所以两边看起来对称,理由完全不同。**把它们合并,或者"顺手也放开这一侧",
--   就是把一次估计变更与一次错误更正当成同一件事。**
--   (同一个不对称,月度例程用负差额封零表达过一次:向上的变化往前摊,
--    向下的变化仍是一次更正、仍走人工分录。)
-- 向下修正一台【已投用】资产的成本今天仍然没有任何路 —— docs/known-issues.md 有记录。
-- * MES-5a-2(2026-10-08):一次电费分摊的费用单【不许】单独冲(EXPENSE_IS_ELECTRICITY_ALLOCATION)—— 理由在那一句旁边。
-- * MES-5b-2(2026-10-09):① 冲销的那一段搬进 reverse_expense_internal(撤回电费单也用它);② 经付款结过 / 冲抵过预付款的按名拒
--   (在 internal 里,每一种费用单都过);③ 冲掉一张月结冲抵时把它冲抵掉的估计放回去(F2,Q21);④ 电费分摊的拒绝带上那张分摊的 id。
-- * ★ MES-6a-1(2026-10-09,F3 · MES-6a Step 0 Q33 · Q34 · Q36,Tim):【每一次冲销都要一句理由】。签名不变(p_memo 仍是第二个参数、
--   仍带默认 —— CREATE OR REPLACE 改不了参数名,fixture 214 钉着这个签名);它从此就是理由:问码之后【第一件事】查它,
--   NULL 或空白按名拒 EXPENSE_REVERSAL_REASON_REQUIRED|<单号>(电费单与运费单的同一个次序)。理由写在被冲掉的那一张上
--   (reversal_reason / reversed_at / reversed_by,在 reverse_expense_internal 里),不再拼进镜像单的 notes。

CREATE OR REPLACE FUNCTION public.reverse_expense(p_expense_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig     expenses%ROWTYPE;
    v_alloc    uuid;
    v_hit      record;
    v_r        jsonb;
    v_restored integer := 0;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- ★ MES-6a-1(F3,Q33):理由在码之后第一件事查(电费单与运费单的同一个次序)。单号只用来让拒绝说出是哪一张。
    IF NULLIF(btrim(COALESCE(p_memo, '')), '') IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_REVERSAL_REASON_REQUIRED|%', COALESCE((SELECT code FROM expenses WHERE id = p_expense_id), '?')
          USING HINT = '没有理由的冲销,事后没人答得出为什么';
    END IF;
    SELECT * INTO v_orig FROM expenses WHERE id = p_expense_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_expense IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_ALREADY_REVERSED|%', v_orig.code;
    END IF;
    -- MES-5a-2:一次电费分摊的费用单不许单独冲 —— 冲掉费用单而留着已结的电费行与被冲掉的估计,2200 就对不上了。
    -- ★ MES-5b-2(Q22):撤回走 reverse_electricity_allocation(那一页 /finance/electricity/<分摊>);拒绝里带着那张分摊的 id,页面据此指路。
    SELECT ea.id INTO v_alloc FROM electricity_allocations ea WHERE ea.expense_id = p_expense_id;
    IF FOUND THEN
        RAISE EXCEPTION 'EXPENSE_IS_ELECTRICITY_ALLOCATION|%|%', v_orig.code, v_alloc
          USING HINT = '电费单的费用单要在那张电费单的页面上整张撤回';
    END IF;
    -- ★ MES-5b-2(2026-10-09,MES-5b Step 0 Q21,Tim):【冲掉一张月结冲抵的费用单,把它冲抵掉的估计放回去】(F2)。
    --   月结冲抵只盖戳(relieved_at / relief_expense_id),不软删;它自己的分录清掉 2200。冲掉那张分录就把 2200 还回来了 ——
    --   所以这里【不过任何分录】,只在同一笔事务里清掉那几条估计上的戳:它们回到"未结",月结那一步与结算页又看得见它们,也能再冲抵一次。
    --   拒(先于任何写):一条电费估计所在的那一炉此后被一张【没撤回】的电费分摊覆盖了 —— 放回去会让那一炉同时带着估计与实际
    --   (MES-5a Q24)→ RELIEF_ESTIMATE_NOW_ALLOCATED|PROC-…|那张分摊的费用单号;走法:先撤回那张分摊。
    IF EXISTS (SELECT 1 FROM processing_cost_entries c WHERE c.relief_expense_id = p_expense_id) THEN
        -- 与 post / reverse_electricity_allocation 同一把咨询锁:判"那一炉有没有被一张没撤回的分摊覆盖"与它们串行
        PERFORM pg_advisory_xact_lock(hashtext('electricity_allocation')::bigint);
    END IF;
    SELECT r.code AS run_code, ae.code AS alloc_code INTO v_hit
      FROM processing_cost_entries c
      JOIN processing_runs r ON r.id = c.run_id
      JOIN electricity_allocation_lines l ON l.run_id = c.run_id
      JOIN electricity_allocations a ON a.id = l.allocation_id
      JOIN expenses ae ON ae.id = a.expense_id
     WHERE c.relief_expense_id = p_expense_id AND c.cost_type = 'electricity'
       AND NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = a.id)
     ORDER BY r.code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'RELIEF_ESTIMATE_NOW_ALLOCATED|%|%', v_hit.run_code, v_hit.alloc_code
          USING HINT = '那一炉此后过了一张电费单 —— 先撤回那张电费单,再冲销这张冲抵';
    END IF;

    -- 冲费用单与分录(资本支出的两条规矩、经付款结过的拒绝都在里面 —— 一份实现,两个调用方)
    v_r := reverse_expense_internal(p_expense_id, btrim(p_memo));

    -- F2:清掉冲抵戳(结算戳只许经财务函数改 —— guard_cost_entry_settled 认这个事务级标记,用毕即清)
    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    UPDATE processing_cost_entries
       SET relieved_at = NULL, relief_expense_id = NULL, updated_by = auth.uid()
     WHERE relief_expense_id = p_expense_id;
    GET DIAGNOSTICS v_restored = ROW_COUNT;
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);

    RETURN v_r || jsonb_build_object('restored_estimates', v_restored);
END;
$function$
