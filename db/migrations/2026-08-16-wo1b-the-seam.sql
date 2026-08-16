-- WO-1b:接缝 —— 加工单认下它照的是哪张工单,而差异第一次算得出来
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WO-1a 立了计划这一侧,并且【故意】把 processing_runs.work_order_id 建成一列
-- 从没有人写过的空列 —— 它存在,只是为了让 1a 的两道守卫读到真列而不是桩。
-- 这一刀把那条线接上:
--   ① commit_processing_run 多一个【可选】的工单参数,并按名拒两条;
--   ② 冲销对齐 —— 一次被冲销的加工,在每一处读这条链接的地方都不再算数;
--   ③ work_order_fulfilment:计划 vs 实绩,两侧各按物料;
--   ④ 'work_order' 进 approval_log 的主体枚举,放行成为可审批的动作。
--
-- ── 三件必须在这里说清楚的事 ──────────────────────────────────────────────
--
-- 【一 · 签名变了,所以是 DROP + CREATE,而这一段有一个真实的窗口】
-- apply_migration.sh 的预检【拒绝】一次签名不同的 CREATE OR REPLACE(FIN-21:
-- 那是重载而不是替换,旧签名会作为镜像看不见的漂移活下来)。所以这里显式
-- DROP 再 CREATE,同一个事务。
-- **兼容性:新参数带 DEFAULT NULL,而所有既有调用方都用具名参数调用**
-- (app 里是 supabase.rpc('commit_processing_run', {p_process_date: …}),
--  fixture 里是位置参数但都只传六个)—— 它们落到 DEFAULT 上,行为一字不变。
-- 事务提交那一刻函数是新的、app 是旧的,而旧 app 恰好走的就是"不传"那一支。
--
-- 【二 · 冲销:链接是历史,它断言过的消耗不是】
-- 一次加工被 rollback_processing_run 冲销之后,料退回了、产出批作废了 ——
-- **那次消耗不再是一个发生过的事实**。所以每一处读这条链接的地方都必须只数
-- 【没有被冲销的】那些:改单的地板、取消的 WO_HAS_RUNS、以及差异视图。
-- 但 work_order_id 本身【留在那一行上】:那次加工确实是照这张工单做的,
-- 把它抹掉等于篡改历史(与作废发票不删签发档同一条)。
-- **查了 1a 的两道守卫,而答案与预期相反 —— 记在这里因为过程比结论有用。**
-- 改单的地板写的是 `r.status = 'committed'`,取消的 WO_HAS_RUNS 只写了
-- `deleted_at IS NULL`,两处不一致,看起来像后者漏了冲销这一支。
-- **但它没有漏:`rollback_processing_run` 同时写 `status='reversed'` 和
-- `deleted_at = now()`**(实测该函数第 135-140 行),所以 `deleted_at IS NULL`
-- 已经把冲销掉的排除在外了。两个写法【今天等价】。
-- 这一刀仍然把 `status = 'committed'` 补上,理由是【意图】而不是修 bug:
-- 两个条件今天等价,只是因为回滚恰好同时写了两列 —— 哪天有一条路径只写其中
-- 一列(或者软删被用于别的目的),它们就分开了,而那时没有任何东西会喊。
-- **所以这不是一次修复,是把一个隐含的巧合写成一个显式的判据。**
-- 差异视图从第一天起就写显式条件,同一个理由。
--
-- 【三 · 放行是那个可审批的动作,而默认是关的】
-- Doc 2 的运营审计那一节点名要"who approved the work order"。可审批的是
-- 【放行】—— 不是新建(一份草稿谁都可以写),也不是收工(那是事后记录)。
-- 放行的意思正是"可以下料开工了",那是要有人负责的那一下。
-- 层级用 1(主管):工单没有金额,approval_level_for 是按金额分档的,
-- 对一张没有钱的单据问"它属于哪一档"没有意义(与 leave_request /
-- performance_review / stocktake 同一类,它们的 level 也不由金额决定)。
-- **approvals_enabled 默认 false**,所以这一刀【不改变任何人今天的操作】:
-- 关着的时候放行照走,只是会留下一条写明"系统盖的章、没有人做过这个决定"的
-- 留痕 —— 与 create_purchase_order 逐字同一句话。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 审批主体 ══════════════════════════════════════════════════════════
-- approval_log 的镜像里写着"这个枚举【就是】将来加动作时唯一要改的地方"。
ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;
ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check
    CHECK (subject_type IN (
        'leave_request', 'medical_claim', 'performance_review',
        'purchase_order', 'payment', 'expense',
        'pricing_formula', 'stocktake',
        -- WO-1b:工单。可审批的动作是【放行】,不是新建也不是收工。
        'work_order'));

-- record_approval_decision 的 CASE 也要认得它 —— 否则它会
-- APPROVAL_SUBJECT_TYPE_UNKNOWN,而那是对的:主体必须真的存在,不插指向空气的痕。
CREATE OR REPLACE FUNCTION public.record_approval_decision(p_subject_type text, p_subject_id uuid, p_decision text, p_level smallint DEFAULT NULL::smallint, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_ccy  text;
    v_amt  numeric;
    v_rate numeric;
    v_base numeric;
    v_ok   boolean := false;
    v_id   uuid;
    v_base_ccy text;
BEGIN
    SELECT code INTO v_base_ccy FROM currencies WHERE is_base;

    -- 【外键没了,这一段就是它的替代】主体必须真的存在,并且顺手把编号与金额
    -- 冻结下来。不存在 → 点名拒绝,而不是插一行指向空气的留痕。
    CASE p_subject_type
        WHEN 'leave_request' THEN
            -- 请假没有金额:天数不是钱,不塞进币种列
            SELECT true, r.code INTO v_ok, v_code
              FROM leave_requests r WHERE r.id = p_subject_id;
        WHEN 'medical_claim' THEN
            -- amount_sgd 已经是本位币口径(列名是 FIN-0 之前留下的字面量,不是新的判断)
            SELECT true, c.code, c.amount_sgd, v_base_ccy, 1, c.amount_sgd
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM medical_claims c WHERE c.id = p_subject_id;
        WHEN 'performance_review' THEN
            SELECT true, e.code INTO v_ok, v_code
              FROM performance_reviews r JOIN employees e ON e.id = r.employee_id
             WHERE r.id = p_subject_id;
        WHEN 'purchase_order' THEN
            -- 【用单据自己存的汇率】(决定 3)—— 审批档次因此不会随行情事后漂移
            SELECT true, po.code, po.estimated_total_ccy, po.currency, po.fx_rate,
                   round(po.estimated_total_ccy * po.fx_rate, 2)
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM purchase_orders po WHERE po.id = p_subject_id;
        WHEN 'payment' THEN
            SELECT true, p.code, p.amount_ccy, p.currency, p.fx_rate, p.amount_base
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM payments p WHERE p.id = p_subject_id;
        WHEN 'expense' THEN
            SELECT true, e.code, e.amount_ccy, e.currency, e.fx_rate, e.amount_base
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM expenses e WHERE e.id = p_subject_id;
        WHEN 'pricing_formula' THEN
            SELECT true, f.code INTO v_ok, v_code
              FROM pricing_formulas f WHERE f.id = p_subject_id;
        WHEN 'stocktake' THEN
            SELECT true, s.code INTO v_ok, v_code
              FROM stocktakes s WHERE s.id = p_subject_id;
        WHEN 'work_order' THEN
            -- WO-1b:工单【没有金额】—— 它是一份要做什么的计划,不是一笔钱。
            -- 与 leave_request / performance_review / stocktake 同一类:
            -- 只冻结编号,金额那四列留空,而不是塞一个 0 进去
            -- (0 会让它在按金额筛的报表里排到最前面,那是一句假话)。
            SELECT true, w.code INTO v_ok, v_code
              FROM work_orders w WHERE w.id = p_subject_id;
        ELSE
            RAISE EXCEPTION 'APPROVAL_SUBJECT_TYPE_UNKNOWN|%', p_subject_type;
    END CASE;

    IF NOT COALESCE(v_ok, false) THEN
        RAISE EXCEPTION 'APPROVAL_SUBJECT_NOT_FOUND|%|%', p_subject_type, p_subject_id;
    END IF;

    INSERT INTO approval_log (subject_type, subject_id, subject_code, decision, level,
                              actor_user_id, note, amount_ccy, currency, fx_rate, amount_base)
    VALUES (p_subject_type, p_subject_id, v_code, p_decision, p_level,
            auth.uid(), p_note, v_amt, v_ccy, v_rate, v_base)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$function$;

-- ═══ 2 · 放行:可审批的那个动作 ═════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.release_work_order(p_work_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_wo      work_orders%ROWTYPE;
    v_appr_on boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'draft' THEN
        RAISE EXCEPTION 'WO_NOT_DRAFT|%|%', v_wo.code, v_wo.status;
    END IF;

    -- 【放行是那个要有人负责的动作】(WO-1b)Doc 2 点名要"who approved the work
    -- order"。可审批的是放行 —— 不是新建(草稿谁都可以写),也不是收工(事后记录)。
    -- 【层级用 1,而不是按金额分档】工单没有金额,approval_level_for 是按金额分的,
    -- 对一张没有钱的单据问它属于哪一档没有意义(与 leave_request /
    -- performance_review / stocktake 同一类)。
    IF v_appr_on THEN
        PERFORM require_approver_for(1::smallint);
    END IF;

    UPDATE work_orders
       SET status = 'released', updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, changed_by)
    VALUES (p_work_order_id, 'released', v_user);

    -- 【关着的时候也要留痕,而且要说实话】—— 与 create_purchase_order 逐字同一句:
    -- 记录真实发生的事,不要把"系统直接盖章"伪装成一次人的决定。
    IF v_appr_on THEN
        PERFORM record_approval_decision('work_order', p_work_order_id, 'approved', 1::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('work_order', p_work_order_id, 'auto_approved', NULL,
            '审批流未启用(finance_settings.approvals_enabled = false)—— 系统直接盖章,没有人做过这个决定');
    END IF;

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'released', 'approvals_enabled', v_appr_on);
END;
$function$;

-- ═══ 3 · 冲销对齐:被冲销的加工在每一处都不再算数 ═══════════════════════════
-- 【规则,一句话】链接是历史,它断言过的消耗不是。
-- work_order_id 留在被冲销的那一行上(那次加工确实是照这张工单做的);
-- 而每一处【拿它当依据去拦人或算数】的地方,都只数没有被冲销的那些。
CREATE OR REPLACE FUNCTION public.cancel_work_order(p_work_order_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_wo   work_orders%ROWTYPE;
    v_runs integer;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status NOT IN ('draft','released') THEN
        RAISE EXCEPTION 'WO_NOT_CANCELLABLE|%|%', v_wo.code, v_wo.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_CANCEL_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- 【已经开过工的单子不能取消 —— 它只能收工】取消的意思是"这件事没有发生过";
    -- 而挂着一条加工单,就意味着料真的下去了、产出真的进了库。把它标成 cancelled
    -- 会让那几次加工失去它们的出处,而出处是这套系统存在的理由。
    --
    -- 【只数没有被冲销的 —— WO-1b 对齐】一次被冲销的加工,料退回了、产出批作废了,
    -- 那次消耗不再是发生过的事实,所以它拦不住取消。链接本身留在那一行上
    -- (它确实是照这张工单做的),但它断言的消耗已经不成立。
    -- WO-1a 这里只写了 deleted_at IS NULL,于是一张工单在它唯一的加工被冲销之后
    -- 仍然取消不掉,理由是一次没有发生的加工 —— 而同一刀的改单地板写的是
    -- status = 'committed'。两处不一致,这里对齐到后者。
    SELECT count(*) INTO v_runs FROM processing_runs
     WHERE work_order_id = p_work_order_id AND deleted_at IS NULL AND status = 'committed';
    IF v_runs > 0 THEN
        RAISE EXCEPTION 'WO_HAS_RUNS|%|%', v_wo.code, v_runs;
    END IF;

    UPDATE work_orders
       SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_user,
           cancel_reason = btrim(p_reason), updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, amend_reason, changed_by)
    VALUES (p_work_order_id, 'cancelled', btrim(p_reason), v_user);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code, 'status', 'cancelled');
END;
$function$;

-- close 里那个 runs 计数是【写进理由行的信息】,不是一道门 —— 同样对齐口径,
-- 否则"关的时候挂了几条"会把冲销掉的也数进去,而那句话此后没人能复算。
CREATE OR REPLACE FUNCTION public.close_work_order(p_work_order_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_wo   work_orders%ROWTYPE;
    v_runs integer;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'released' THEN
        -- draft 的单子要"不做了",走 cancel —— 见上面那张迁移表的最后一段
        RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_CLOSE_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- 【短交不拦 —— 这是一个决定,不是遗漏】实际做的比计划少,是一个要记下来的
    -- 事实。拦住它只会让人把计划改小以求关单,而那正好把差异从账上抹掉 ——
    -- 一条逼人去伪造数据的规则比没有规则更坏。收工时挂了几条加工单一并记进理由行,
    -- 让"关的时候是什么样"留在历史里,而不必事后重算。
    -- WO-1b:只数没有被冲销的 —— 与地板、与 WO_HAS_RUNS 同一口径。
    SELECT count(*) INTO v_runs FROM processing_runs
     WHERE work_order_id = p_work_order_id AND deleted_at IS NULL AND status = 'committed';

    UPDATE work_orders
       SET status = 'closed', closed_at = now(), closed_by = v_user,
           close_reason = btrim(p_reason), updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, detail, amend_reason, changed_by)
    VALUES (p_work_order_id, 'closed', 'runs=' || v_runs::text, btrim(p_reason), v_user);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'closed', 'runs', v_runs);
END;
$function$;

-- ═══ 4 · 接缝:commit_processing_run 认下它照的是哪张工单 ═══════════════════
-- 【DROP + CREATE,不是 CREATE OR REPLACE】签名变了。预检会拒绝一次签名不同的
-- 替换(FIN-21:那是重载,旧签名会作为镜像看不见的漂移活下来)。
DROP FUNCTION public.commit_processing_run(date, text, numeric, jsonb, jsonb, text);

CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id      uuid := auth.uid();
    v_process_date date;
    v_run_id       uuid;
    v_total_input  numeric := 0;
    v_total_output numeric := 0;
    v_input        jsonb;
    v_output       jsonb;
    v_inbound_id   uuid;
    v_output_id    uuid;   -- FIN-25:再加工投料(产出批为源)
    v_consumed     numeric;
    v_remaining    numeric;
    v_available     numeric;
    v_held          numeric;
    v_new_remaining numeric;
    v_material_id  uuid;
    v_qty          numeric;
    v_unit         text;
    v_purity       text;
    v_new_output_id uuid;
    v_wo           work_orders%ROWTYPE;   -- WO-1b
BEGIN
    PERFORM require_permission('module.processing.edit');
    IF p_process_date IS NULL THEN
        RAISE EXCEPTION 'PROCESS_DATE_REQUIRED';
    END IF;

    -- FIN-36:分摊基准【必填】。不在这里回退到 finance_settings 的公司默认值 ——
    -- 那只会把"没人选过"从 schema 挪进函数,同一个病换一层楼。表单永远带着值来
    -- (预选自 finance_settings.default_allocation_basis),所以必填没有代价。
    IF p_allocation_basis IS NULL THEN
        RAISE EXCEPTION 'ALLOCATION_BASIS_REQUIRED';
    END IF;
    IF p_allocation_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', p_allocation_basis;
    END IF;

    -- ── WO-1b:工单这一支【只在给了参数的时候才存在】────────────────────────
    -- 【为什么是可选的,而不是必填】临时起意的加工是合法的 —— 车间不会为了系统
    -- 先去补一张计划。把它变成必填,得到的不是纪律,是一堆事后补的假工单。
    -- 差异报表因此必须把 work_order_id 为空的那些显示成【计划外】这一个具名的
    -- 类别,而不是让它们悄悄消失(那是 WO-1c 的事,规则记在这里)。
    IF p_work_order_id IS NOT NULL THEN
        SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'WO_NOT_FOUND|%', p_work_order_id;
        END IF;
        -- 【只有放行了的工单可以开工】草稿是还没答应的事(与 reserve_stock 只认
        -- 已确认订单同一条);而 closed / cancelled 是【已经结束的事】,再往上挂
        -- 一次加工会让那张单的完成度在它收工之后继续变 —— 收工时写进理由行的
        -- 那句"runs=N"从此不再复算得出来。
        IF v_wo.status <> 'released' THEN
            RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
        END IF;
    END IF;

    v_process_date := p_process_date;
    -- 0. 基本校验
    IF p_inputs IS NULL OR jsonb_array_length(p_inputs) = 0 THEN
        RAISE EXCEPTION 'NO_INPUTS';
    END IF;
    IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN
        RAISE EXCEPTION 'NO_OUTPUTS';
    END IF;
    IF p_loss_qty IS NOT NULL AND p_loss_qty < 0 THEN
        RAISE EXCEPTION 'LOSS_NEGATIVE';
    END IF;

    -- 0b. 同一批次(不论来源)不能重复添加。FIN-25:投料可为进料批或产出批,
    --     恰一非空;两个都给或都不给 → INPUT_PARENT_INVALID。
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_inputs) elem
        WHERE num_nonnulls(elem->>'inbound_batch_id', elem->>'output_batch_id') <> 1
    ) THEN
        RAISE EXCEPTION 'INPUT_PARENT_INVALID';
    END IF;
    IF (SELECT count(DISTINCT COALESCE(elem->>'inbound_batch_id', elem->>'output_batch_id'))
        FROM jsonb_array_elements(p_inputs) elem) <> jsonb_array_length(p_inputs) THEN
        RAISE EXCEPTION 'DUPLICATE_INPUT';
    END IF;

    -- 1. 遍历投入:校验库存(并锁行)+ 累计投入合计
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_consumed IS NULL OR v_consumed <= 0 THEN
            RAISE EXCEPTION 'INPUT_QTY_INVALID';
        END IF;

        IF v_inbound_id IS NOT NULL THEN
            SELECT remaining_qty INTO v_remaining
            FROM inbound_batches
            WHERE id = v_inbound_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_inbound_id;
            END IF;
        ELSE
            -- FIN-25:产出批投料 —— 同一套校验、同一把锁。库存机器本就共用
            -- (inventory_movements 两侧 XOR,remaining_qty 两表同义)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches
            WHERE id = v_output_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_output_id;
            END IF;
        END IF;
        -- IOD-1:投得进去的是【可用】,不是【物理剩余】—— 被扣住的货还在批次里,
        -- 但它不可动用。拒绝同时说出可用与暂扣两个数,否则人看着 remaining 够
        -- 却投不进去,屏幕上没有任何解释。
        v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                                 WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                                   AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                                   AND m.stock_status = 'available'), 0);
        v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                            WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                              AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                              AND m.stock_status = 'on_hold'), 0);
        IF v_consumed > v_available THEN
            RAISE EXCEPTION 'IOD_CONSUME_EXCEEDS_AVAILABLE|%|%|%', v_consumed, v_available, v_held;
        END IF;

        v_total_input := v_total_input + v_consumed;
    END LOOP;

    -- 2. 遍历产出:校验 + 累计产出合计
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_qty := (v_output->>'quantity')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
        END IF;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
        v_total_output := v_total_output + v_qty;
    END LOOP;

    -- 3. 质量守恒:产出不能大于投入
    IF v_total_output > v_total_input THEN
        RAISE EXCEPTION 'OUTPUT_EXCEEDS_INPUT|%|%', v_total_output, v_total_input;
    END IF;

    -- 4. 建加工单表头(code 由触发器生成)
    INSERT INTO processing_runs (
        process_date, total_input, total_output, loss_qty, notes, status,
        allocation_basis, work_order_id, created_by, updated_by
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        COALESCE(p_loss_qty, v_total_input - v_total_output),
        p_notes, 'committed', p_allocation_basis, p_work_order_id, v_user_id, v_user_id
    )
    RETURNING id INTO v_run_id;

    -- 5. 再遍历投入:扣库存 + 更新阶段 + 建投入腿 + 记库存流水(消耗)
    --    FIN-25:ctx 提前到这里 —— 投入腿的守卫触发器(guard_processing_input)
    --    只放行函数上下文;原来 ctx 在第 6 步(产出)才设,投入腿就会被自己拒掉。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_inbound_id IS NOT NULL THEN
            SELECT remaining_qty INTO v_remaining
            FROM inbound_batches WHERE id = v_inbound_id;
            v_new_remaining := v_remaining - v_consumed;

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_inbound_id;

            -- IOD-1:投料走 drain_stock —— 可能跨几个库位桶,于是写出多行(规则见其函数头)
            PERFORM drain_stock(
                p_qty => v_consumed, p_movement_type => 'processing_consume',
                p_business_date => v_process_date, p_inbound_batch_id => v_inbound_id,
                p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);

            INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
            VALUES (v_run_id, v_inbound_id, v_consumed);
        ELSE
            -- FIN-25:产出批投料。state 是【销售状态】(表注),消耗不碰它 ——
            -- 只扣 remaining_qty,流水挂 output_batch_id(XOR 的另一侧)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches WHERE id = v_output_id;
            v_new_remaining := v_remaining - v_consumed;

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_output_id;

            PERFORM drain_stock(
                p_qty => v_consumed, p_movement_type => 'processing_consume',
                p_business_date => v_process_date, p_output_batch_id => v_output_id,
                p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);

            INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed)
            VALUES (v_run_id, v_output_id, v_consumed);
        END IF;
    END LOOP;

    -- 6. 遍历产出:建产出批次 + 建产出腿
    --    产出的入库流水由 AFTER INSERT 触发器发出;先设置上下文标记本批产出属于本加工单。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := (v_output->>'quantity')::numeric;
        v_unit        := COALESCE(NULLIF(v_output->>'unit', ''), 'kg');
        v_purity      := NULLIF(v_output->>'purity', '');

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced)
        VALUES (v_run_id, v_new_output_id, v_qty);
    END LOOP;

    -- 用毕即清(price_ctx 同一条理由:免得同事务内后续的直改被误放行 ——
    -- fixture 19F 实测:不清,守卫触发器对残留 ctx 放行裸 INSERT)
    PERFORM set_config('evoltrya.movement_ctx', '', true);

    RETURN v_run_id;
END;
$function$;

-- ═══ 5 · 差异视图 ══════════════════════════════════════════════════════════
-- 【单模块,所以按数据自己的 RLS 给权限】(OPS-15 那条规矩)——
-- 计划、行、加工单、投入腿、产出腿全部在 module.processing.* 后面,没有跨模块。
-- 【属主权限】理由与 processing_metal_recovery 相同:invoker 视图会被基表的
-- 列权限与行策略挡住,而把模块谓词原样写回视图体是等价且可读的做法。
--
-- 【三条它【不】做的事,写下来因为它们是这张视图正确性的一半】
--   ① 【不重算回收率】投入金属 ÷ 产出金属是 processing_metal_recovery 的活。
--      这张视图只做一件事:把【计划】与【实绩】相比。两处算同一个数,
--      迟早各说各话(AGENTS.md:一处推导,N 个消费者)。
--   ② 【没有预期就不给差异】expected_qty 为空时 output_variance 是 NULL,
--      而不是 produced - 0。has_expectation 这一列把"没估过"说出来 ——
--      一个 COALESCE(...,0) 会让任何产出都成为超额完成。
--   ③ 【计划外的加工不在这张视图里】work_order_id 为空的加工单按定义不属于
--      任何工单。它们是一个【具名的类别】(WO-1c 报表要单列),不是这里的一个
--      静默的缺席 —— 在这张视图里给它们造一行"计划为零"的记录,等于说
--      "有人计划过零",而没有人计划过。
--
-- 【被冲销的加工不算数】—— 与地板、WO_HAS_RUNS 同一口径:链接是历史,
-- 它断言过的消耗不是。

CREATE VIEW public.work_order_fulfilment WITH (security_invoker = off) AS
WITH linked_runs AS (
    -- 只数【没有被冲销、没有被软删】的加工
    SELECT r.id, r.work_order_id
      FROM processing_runs r
     WHERE r.work_order_id IS NOT NULL
       AND r.deleted_at IS NULL
       AND r.status = 'committed'
),
consumed AS (
    -- 投入腿指向批次,批次才有物料 —— 两侧都要 join 过去
    -- (进料批与再加工的产出批各一条腿,FIN-25 的 XOR)
    SELECT lr.work_order_id,
           COALESCE(ib.material_id, ob.material_id) AS material_id,
           sum(pi.quantity_consumed) AS consumed_qty
      FROM linked_runs lr
      JOIN processing_inputs pi ON pi.run_id = lr.id
      LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
      LEFT JOIN output_batches  ob ON ob.id = pi.output_batch_id
     GROUP BY 1, 2
),
produced AS (
    SELECT lr.work_order_id, ob.material_id, sum(po.quantity_produced) AS produced_qty
      FROM linked_runs lr
      JOIN processing_outputs po ON po.run_id = lr.id
      JOIN output_batches ob ON ob.id = po.output_batch_id
     GROUP BY 1, 2
),
-- 投入侧:计划行与实际消耗【全外连接】—— 计划了却没吃(欠),
-- 以及吃了却没计划(计划外的物料,同样是一种差异)。
input_side AS (
    SELECT COALESCE(wl.work_order_id, c.work_order_id) AS work_order_id,
           COALESCE(wl.material_id,   c.material_id)   AS material_id,
           wl.planned_qty,
           COALESCE(c.consumed_qty, 0) AS consumed_qty
      FROM work_order_lines wl
      FULL JOIN consumed c
        ON c.work_order_id = wl.work_order_id AND c.material_id = wl.material_id
),
output_side AS (
    SELECT COALESCE(we.work_order_id, p.work_order_id) AS work_order_id,
           COALESCE(we.material_id,   p.material_id)   AS material_id,
           we.expected_qty,
           COALESCE(p.produced_qty, 0) AS produced_qty
      FROM work_order_expected_outputs we
      FULL JOIN produced p
        ON p.work_order_id = we.work_order_id AND p.material_id = we.material_id
)
SELECT w.id   AS work_order_id,
       w.code AS work_order_code,
       w.status,
       w.scheduled_date,
       'input'::text AS side,
       s.material_id,
       m.code AS material_code,
       m.name AS material_name,
       s.planned_qty     AS planned_or_expected_qty,
       s.consumed_qty    AS actual_qty,
       -- 【没有计划行 = 计划外的物料,差异说不出来】它吃了没人计划过的料,
       -- 这本身就是要看见的事,但"差多少"没有被减数 —— 所以是 NULL,不是负数。
       CASE WHEN s.planned_qty IS NULL THEN NULL
            ELSE s.consumed_qty - s.planned_qty END AS variance_qty,
       (s.planned_qty IS NOT NULL) AS has_plan
  FROM work_orders w
  JOIN input_side s ON s.work_order_id = w.id
  LEFT JOIN materials m ON m.id = s.material_id
 WHERE has_permission('module.processing.view'::text)
UNION ALL
SELECT w.id, w.code, w.status, w.scheduled_date,
       'output'::text,
       s.material_id, m.code, m.name,
       s.expected_qty,
       s.produced_qty,
       -- 【没有预期就没有差异】—— 不是 produced - 0。见视图头第 ② 条。
       CASE WHEN s.expected_qty IS NULL THEN NULL
            ELSE s.produced_qty - s.expected_qty END,
       (s.expected_qty IS NOT NULL)
  FROM work_orders w
  JOIN output_side s ON s.work_order_id = w.id
  LEFT JOIN materials m ON m.id = s.material_id
 WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.work_order_fulfilment IS
    'WO-1b:计划 vs 实绩,一张工单 × 一侧(input/output)× 一种物料一行。
【has_plan = false 的意思是"没人计划过这一项",而 variance_qty 因此是 NULL,不是负数】—— 同理输出侧的 has_plan(承载 expected 是否存在)。没估过 ≠ 估了零;一个 COALESCE(...,0) 会让任何产出都成为超额完成。
【被冲销的加工不算数】链接是历史(work_order_id 留在被冲销的那一行上),它断言过的消耗不是 —— 与 amend_work_order 的地板、cancel_work_order 的 WO_HAS_RUNS 同一口径。
【计划外的加工(work_order_id 为空)按定义不在这张视图里】它们是一个具名的类别,由报表单列,而不是在这里造一行"计划为零";没有人计划过零。
【不重算回收率】投入金属 ÷ 产出金属属于 processing_metal_recovery。这张视图只把计划与实绩相比。';

COMMIT;
