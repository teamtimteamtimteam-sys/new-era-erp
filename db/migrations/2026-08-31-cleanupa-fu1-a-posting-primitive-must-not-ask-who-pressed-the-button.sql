-- CLEANUP-A fu1(2026-08-31):**计值不许取决于谁按的按钮。**
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★【本刀主迁移做错了一件事,而 gate 的【行为断言】当场抓住了它】★
--
-- 主迁移给 inbound_batch_landed_unit_cost 加了判据
-- (data.view_prices OR module.stocktakes.edit)—— R3 要的"自带检查"。
-- 那件事本身是对的,**放错了地方**:那支函数【同时】是
--   ① 一个读者会读的价格,和
--   ② 一个【过账时用来算钱】的原语。
-- 给 ② 加上"读者是谁"的判据,就等于让**账上的金额取决于按按钮的人有什么权限**。
--
-- 【实测,不是推演】gate 退 4,db/fixtures/172 当场红:
--   LANDED_COST_PERMISSION_DENIED|data.view_prices
-- 172 的"受限读者"持 module.inventory.view + module.inbound.view +
-- module.finance.view 而【没有】data.view_prices —— 一个完全合法的部分权限读者,
-- 而 inventory_valuation_snapshot 本来就【已经】对他做对了事:
-- prices_visible=false、restriction 具名、金额 NULL、数量照常。
-- **主迁移把一条本来就正确的路打断了。** 这正是 R2 说的反方向失败。
--
-- 而更要紧的一处 gate 还没走到:emit_batch_writeoff_movement 这个【触发器】。
-- 它的抬头自己写着这句话:
--     「读的是不带判据的那一支 —— 计值不许取决于谁按的按钮;
--       一个只有 inbound.edit 的仓管按下注销时,带判据的读取器会返回 NULL,
--       COALESCE 成 0 就等于本缺陷静默复发。」
-- 主迁移把那句话作废了:那个仓管现在按下注销会【直接撞一条权限拒绝】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【修法:用这个仓库【已经有】的那个形状 —— 判据名 + _all 名】
--
-- PROC-COST-1 fu2 早就为同一个问题立过这个模式:
--     batch_freight_base(definer,带判据)      ←→ batch_freight_base_all(无判据)
--     batch_processing_cost_base(带判据)       ←→ batch_processing_cost_base_all(无判据)
-- 而 inbound_batch_landed_unit_cost 的函数体里【本来就写着】
--     「读的是 _all 那一对,不是带判据的那一对」——
-- 也就是说:**它一直站在这个分裂的"过账"那一侧**,只是自己没有名字说明这件事。
--
-- 于是:
--   · inbound_batch_landed_unit_cost_all(uuid) —— 【无判据】的过账原语。
--     四个机器调用方读它:注销触发器、post_stocktake、
--     inventory_control_reconciliation、inventory_valuation_snapshot。
--     它与旧函数【逐字同一段算术】,所以 PROC-COST-2 R1 那条
--     「注销与盘点必须永远给同一个答案」原样成立。
--     不授给 authenticated(与 _all 那一对同一条 REVOKE)。
--   · inbound_batch_landed_unit_cost(uuid) —— 【带判据】的读者名,
--     判据不变,函数体改为委托给 _all。R3 仍然被满足:
--     **一个拿得到 EXECUTE 的调用者仍然会被它自己拦住**(fixtures/174 E 臂钉的就是这个)。
--
-- 【为什么不是"把白名单再放宽一点"】那条路要一直加到
-- data.view_prices OR stocktakes.edit OR finance.view OR inbound.edit 才够,
-- 而最后那一条是【写权限】—— 用"你能改进料批"去论证"你能看价格",不成话。
-- 到那时它拦不住任何人,就是 R2 说的另一半:**太宽的检查是戏**。
-- 真正的区别不在权限清单上,在【问题】上:
--     给人看一个价格  → 要问权限;
--     算一笔要过账的钱 → 【不许】问权限。
-- 这条分界线就是 _all 这个后缀在本仓库里的全部含义。

BEGIN;

-- ── 一 · 无判据的过账原语 ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.inbound_batch_landed_unit_cost_all(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【无判据,这是刻意的】它算的是要过账的钱,而账上的金额不许取决于
    -- 按按钮的人有什么读权限(emit_batch_writeoff_movement 的抬头写着同一句)。
    -- 与 batch_freight_base_all / batch_processing_cost_base_all 同一条理由、同一个后缀。
    --
    -- 算术与 CLEANUP-A 之前的 inbound_batch_landed_unit_cost 【逐字相同】——
    -- PROC-COST-2 R1「注销与盘点必须永远给同一个答案」靠的就是这一份实现。
    --
    -- 【什么时候是 NULL】采购价没定过【而且】两项资本化都为零 —— 那是一批
    -- 真正"没有金额"的货,调用方据此只出量、不入账。
    SELECT CASE
        WHEN ib.unit_price IS NULL
         AND batch_freight_base_all(ib.id) + batch_processing_cost_base_all(ib.id) = 0
        THEN NULL
        ELSE COALESCE(ib.unit_price, 0)
             + CASE WHEN ib.quantity > 0
                    THEN (batch_freight_base_all(ib.id)
                          + batch_processing_cost_base_all(ib.id)) / ib.quantity
                    ELSE 0 END
    END
    FROM inbound_batches ib
    WHERE ib.id = p_inbound_batch_id;
$function$;

COMMENT ON FUNCTION public.inbound_batch_landed_unit_cost_all(uuid) IS
    'CLEANUP-A fu1:落地单位成本的【过账】原语 —— 无判据,刻意的。账上的金额不许取决于'
    '按按钮的人有什么读权限(emit_batch_writeoff_movement 的抬头写着同一句;一个只有 '
    'inbound.edit 的仓管按下注销时,带判据的读取器会让这笔钱静默变 0)。与 '
    'batch_freight_base_all / batch_processing_cost_base_all 同一条理由、同一个后缀。'
    '四个机器调用方:注销触发器、post_stocktake、inventory_control_reconciliation、'
    'inventory_valuation_snapshot。算术与带判据的那一支逐字相同 —— PROC-COST-2 R1 '
    '「注销与盘点必须永远给同一个答案」靠的就是这一份实现。不授给 authenticated。';

-- ── 二 · 带判据的读者名,改为委托 ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.inbound_batch_landed_unit_cost(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【R3:授权不是控制】—— 一个【拿得到 EXECUTE】的调用者仍然被这里拦住。
    -- db/fixtures/174 的 E 臂刻意以那样的身份来问,问的就是这一句。
    IF NOT (has_permission('data.view_prices'::text)
            OR has_permission('module.stocktakes.edit'::text)) THEN
        RAISE EXCEPTION 'LANDED_COST_PERMISSION_DENIED|%', 'data.view_prices'
          USING HINT = '落地单位成本【是一个价格】—— 要看它得有 data.view_prices,'
                       '或者正走在盘点/注销那条路上(module.stocktakes.edit)。'
                       '这不是"这批货没有金额",是权限:两者在这支函数里必须分得开。'
                       '【要算一笔过账的钱、而不是给人看】的调用方读 _all 那一支。';
    END IF;
    -- 【算术只有一份】委托给 _all,不复制 —— 两份实现会悄悄分开。
    RETURN inbound_batch_landed_unit_cost_all(p_inbound_batch_id);
END
$function$;

COMMENT ON FUNCTION public.inbound_batch_landed_unit_cost(uuid) IS
    'CLEANUP-A:落地单位成本的【读者】名 —— 自带判据 data.view_prices OR '
    'module.stocktakes.edit(R3:授权不是控制,一个拿得到 EXECUTE 的调用者也被拦)。'
    '拒绝用 RAISE 不用 NULL,因为本支的 NULL 已经有主:它是"这批货真的没有金额",'
    'inbound_batch_valuation.unpriced 就定义为它 IS NULL。'
    'fu1 起算术委托给 inbound_batch_landed_unit_cost_all —— 【要算过账的钱】的调用方'
    '读 _all 那一支,因为账上的金额不许取决于按按钮的人有什么读权限。';
-- ── emit_batch_writeoff_movement(1 处调用改指 _all)──
CREATE OR REPLACE FUNCTION public.emit_batch_writeoff_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx   text := current_setting('evoltrya.movement_ctx', true);
    v_run   uuid;
    v_value numeric;
    v_acct  text;
    v_amt   numeric;
    v_bd    date;      -- FIN-32:这条流水的【业务日】
    v_resn  int;       -- SO-2:这批货上还有几条【活预留】
    v_orders text;
BEGIN
    -- AUDEL-1b:三处 drain_stock 的 p_created_by 从 NEW.updated_by 改成
    -- COALESCE(NEW.deleted_by, NEW.updated_by) —— 台账要记的是【谁注销了这批料】,
    -- 那就是 deleted_by。门会把两者设成同一个人,所以今天的值不变;
    -- COALESCE 兜住 rollback 那条路(它设的是 updated_by)与任何历史行。
    -- 【函数体其余部分逐字未动】—— 预留守卫、business_date 的两类推理、
    -- 注销入账那一段都在原处。
    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【一批还许着人的货,不能就这么注销掉】
    -- 排空一律走 drain_stock 的 ARRAY['available','on_hold'] —— 那两个桶是
    -- 【没有外部账】的:暂扣只是一个理由字符串。committed 不同,它在
    -- sales_order_reservations 里有一行对应的事实,还挂在某张订单的某一行上。
    -- 把它排空,那一行预留会指着一批不存在的货,而订单页上什么都不会变。
    -- 【所以这里不是"把 committed 加进排空数组",而是拒绝】—— 补救写在消息里:
    -- 先释放(那一步会留下理由、会回到 available、会写进订单历史),再注销。
    -- 【一个决定,而不是一次保守】:注销是不可逆的,而释放是有主人的动作;
    -- 让系统替销售决定"这个承诺可以撤了",正是它不该做的事。
    -- 反过来说,下面 drain 的两个数组【一个字都不用改】:committed 在这里就被
    -- 挡住了,排空永远见不到它 —— 这条注释是那两个数组为什么可以原样不动的
    -- 全部理由,删掉守卫就必须同时回来改数组。
    -- ════════════════════════════════════════════════════════════════════════
    IF TG_TABLE_NAME = 'output_batches' THEN
        SELECT count(*), string_agg(DISTINCT o.code, ', ' ORDER BY o.code)
          INTO v_resn, v_orders
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
          JOIN sales_orders o      ON o.id = l.sales_order_id
         WHERE r.output_batch_id = OLD.id AND r.released_at IS NULL AND r.consumed_at IS NULL;
        IF v_resn > 0 THEN
            RAISE EXCEPTION 'SO_BATCH_HAS_RESERVATIONS|%|%|%', OLD.code, v_resn, v_orders;
        END IF;
    END IF;

    IF OLD.remaining_qty > 0 THEN
        -- ════════════════════════════════════════════════════════════════════
        -- FIN-32:business_date =【这件事在业务上发生在哪一天】,与它被记进系统的
        -- 时刻是两回事。两类事,两个答案,不能共用一个:
        --
        --   * 注销(writeoff)是【真实发生的物理事件】—— 货报废了。发生在有人
        --     按下注销的那天,而那天就写在行上:deleted_at。取它的日期部分,
        --     是【读记录】而不是 CURRENT_DATE 那种【当场编一个】。
        --     (触发器只在 deleted_at 由空变非空时触发,所以它必然有值。)
        --
        --   * 冲销(reversal_void)【不是物理事件】—— 电池处理过了就处理过了,
        --     回滚是在更正一次【记错的加工单】。所以它的业务日是【原加工单的
        --     process_date】,不是今天:那样一错一改在同一天对消,中间那几天的
        --     库存历史不会凭空多出一批实际并不存在的货。
        --     会计侧的先例同向:reverse_journal_entry 把冲销日做成【显式入参】,
        --     从不假定 —— 这里没有入参可传,但答案同样来自记录(run.process_date),
        --     不来自时钟。
        --
        -- 【两个账会给出两个日期,这是知情的选择,不是疏漏】(FIN-32-fu1)
        -- 同一次更正:分录侧的冲销按【显式传入的冲销日】入账(它必须如此 ——
        -- 期间锁不许往已关闭的月份里塞东西),而这里的流水按【原加工日】。
        -- 于是一次更正在两个账里带着两个日期。这是两种账的性质不同:
        --   * 分录是【价值账,带锁】—— 它记的是"这笔更正在哪个会计期发生";
        --   * 流水是【数量账,无锁】—— 它记的是"那批货实际在不在库里"。
        -- 按日期把两个账对起来的人一定会撞上这处差异,所以写在这里:
        -- 撞上时该问的是"这两个日期各自回答的是哪个问题",不是"哪个错了"。
        -- ════════════════════════════════════════════════════════════════════
        IF TG_TABLE_NAME = 'inbound_batches' THEN
            -- IOD-1:注销排空【所有】桶,两种状态都算 —— 报废一批货,不会因为其中
            -- 一部分被扣住就留在账上。这也是三个消耗方里唯一一个必须动 on_hold 的。
            -- SO-2:committed 不在数组里,因为它【到不了这里】(上面的守卫已经拒了);
            -- 进料批次本来也不可能有 committed —— 预留只指向产出批次。
            PERFORM drain_stock(
                p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                p_business_date => NEW.deleted_at::date, p_inbound_batch_id => OLD.id,
                p_statuses => ARRAY['available','on_hold'], p_created_by => COALESCE(NEW.deleted_by, NEW.updated_by));
        ELSE  -- output_batches
            IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'reversal' THEN
                v_run := split_part(v_ctx, ':', 2)::uuid;
                SELECT process_date INTO v_bd FROM processing_runs WHERE id = v_run;
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'reversal_void',
                    p_business_date => v_bd, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_run_id => v_run,
                    p_created_by => COALESCE(NEW.deleted_by, NEW.updated_by));
            ELSE
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                    p_business_date => NEW.deleted_at::date, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_created_by => COALESCE(NEW.deleted_by, NEW.updated_by));
            END IF;
        END IF;

        -- cut 2a:注销即入账(仅已计值批次,借 5200 / 贷 1200|1220)。
        -- 【PROC-COST-2:reversal_void 仍然不入账,但理由换了 —— 这两件事必须一起读】
        -- 原来的理由是「void 的产出从未入过 1220,无可冲销」。**有了分摊之后那句话
        -- 不再成立**:已分摊的产出批确实入过 1220。结论仍然成立,只是理由变了 ——
        -- 解除 1220 的是 rollback_processing_run 冲销的那张资本化分录。
        -- **两处都做就是重复计数。** 未计值批次只出量不入账。
        IF v_ctx IS NULL OR split_part(v_ctx, ':', 1) <> 'reversal' THEN
            IF TG_TABLE_NAME = 'inbound_batches' THEN
                -- ════════════════════════════════════════════════════════════
                -- PROC-COST-2 · R1:【注销解除的是全部落地成本,不是采购价】
                -- 改之前这里是 `v_value := OLD.unit_price`,于是一批落地 900 的货
                -- 注销只解除 500,**400 留在 1200 上,而那批货已经不存在了**
                -- (线上实测:docs/landed-cost-relief.md 第一节)。
                -- 【一份实现,两个调用者】post_stocktake 读的是同一支函数 ——
                -- R1 要求两者一起改,正是因为它们必须永远给出同一个答案。
                -- 【比例免费】下面 v_amt = remaining_qty × v_value,单位费率乘剩余量,
                -- 半批注销天然解除一半落地成本,不需要第二套算术。
                -- 【读的是不带判据的那一支(经 inbound_batch_landed_unit_cost)】
                -- 计值不许取决于谁按的按钮 —— 一个只有 inbound.edit 的仓管按下注销时,
                -- 带判据的读取器会返回 NULL,COALESCE 成 0 就等于本缺陷静默复发。
                -- ════════════════════════════════════════════════════════════
                v_value := inbound_batch_landed_unit_cost_all(OLD.id);
                v_acct := '1200';
            ELSE
                SELECT po.unit_cost_base INTO v_value
                FROM public.processing_outputs po
                WHERE po.output_batch_id = OLD.id
                LIMIT 1;
                v_acct := '1220';
            END IF;
            IF v_value IS NOT NULL THEN
                v_amt := round(OLD.remaining_qty * v_value, 2);
                IF v_amt <> 0 THEN
                    PERFORM post_journal_entry(
                        CURRENT_DATE,
                        'Write-off ' || OLD.code,
                        'writeoff', OLD.id,
                        jsonb_build_array(
                            jsonb_build_object('account_code', '5200', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt),
                            jsonb_build_object('account_code', v_acct, 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt)));
                END IF;
            END IF;
        END IF;

        NEW.remaining_qty := 0;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── post_stocktake(1 处调用改指 _all)──
CREATE OR REPLACE FUNCTION public.post_stocktake(p_stocktake_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user           uuid := auth.uid();
    v_st             record;
    v_line           record;
    v_code           text;
    v_current        numeric;
    v_deleted        timestamptz;
    v_delta          numeric;
    v_lines_total    integer := 0;
    v_lines_adjusted integer := 0;
    v_total_delta    numeric := 0;
    v_value          numeric;
    v_inv_acct       text;
    v_amt            numeric;
    v_je_lines       jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.stocktakes.edit');
    SELECT id, code, status, deleted_at INTO v_st
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_st.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_st.status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_st.status;
    END IF;

    FOR v_line IN SELECT * FROM stocktake_lines WHERE stocktake_id = p_stocktake_id
    LOOP
        v_lines_total := v_lines_total + 1;

        IF v_line.inbound_batch_id IS NOT NULL THEN
            SELECT code, remaining_qty, deleted_at INTO v_code, v_current, v_deleted
            FROM inbound_batches WHERE id = v_line.inbound_batch_id FOR UPDATE;
            -- ════════════════════════════════════════════════════════════════
            -- PROC-COST-2 · R1:【盘点计值 = 落地成本,与注销同一支函数】
            -- 改之前这里取的是 unit_price(上一行的 SELECT 列表里),于是一批
            -- 落地 900 的货盘成 0 只解除 500,**400 留在 1200 上**(线上实测)。
            --
            -- ★【两个方向都改,而这是让修复安全的那一半】★
            -- 下面 v_value 同时喂给盘盈(借库存)与盘亏(贷库存)两支。只改盘亏
            -- 的实现会让一次"点少了、再点回来"**永久销毁**运费与加工成本 ——
            -- 那批料一克都没离开过厂房。**一次修复造出来的新缺陷,比被修的更坏。**
            -- fixture 的 D 臂钉的就是这一条:100 → 50 → 100,1200 必须回到起点。
            --
            -- 【读的是 landed_unit_cost,不是带判据的读取器】计值不许取决于
            -- 谁按的按钮 —— 见本刀迁移抬头第四节。
            -- 【FOR UPDATE 之后单独取】把函数调用留在 FOR UPDATE 的目标列表里
            -- 会让人以为它也被锁保护;它不是,它是一次独立的读。分两行写。
            -- ════════════════════════════════════════════════════════════════
            v_value := inbound_batch_landed_unit_cost_all(v_line.inbound_batch_id);
            v_inv_acct := '1200';
        ELSE
            SELECT ob.code, ob.remaining_qty, ob.deleted_at, po.unit_cost_base
            INTO v_code, v_current, v_deleted, v_value
            FROM output_batches ob
            LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
            WHERE ob.id = v_line.output_batch_id
            FOR UPDATE OF ob;
            v_inv_acct := '1220';
        END IF;

        IF v_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'BATCH_DELETED|%', v_code;
        END IF;

        v_delta := v_line.counted_qty - v_current;
        IF v_delta <> 0 THEN
            IF v_line.inbound_batch_id IS NOT NULL THEN
                -- ════════════════════════════════════════════════════════════
                -- FIN-32-fu1:业务日 = 过账日(CURRENT_DATE),而这是【查过之后】
                -- 的结论,不是"没有更好的来源"那种含糊话。
                -- stocktakes 上确实有个 started_at,名字听起来像盘点日 —— 它不是:
                -- 它是 timestamptz NOT NULL DEFAULT now(),【全代码库没有任何一处
                -- 写过它】,而线上每一行的 started_at 与 created_at 【逐微秒相等】
                -- (实测 3/3,最大差 0.000000 秒)。它是建单时间戳,不是盘点日期。
                -- 所以周一盘、周二过账,这里记的仍是周二 —— 而这是【诚实的】:
                -- 系统里根本没有人告诉过它周一。
                -- 真要记录盘点当天,得先有一个【盘点日字段让人填】(Phase 2 的
                -- 盘点单),那时这里改成读它 —— 与注销读 deleted_at 同一条规矩:
                -- 日期要来自记录,而记录得先存在。
                -- ════════════════════════════════════════════════════════════
                INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.inbound_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE inbound_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.inbound_batch_id;
            ELSE
                INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.output_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE output_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.output_batch_id;
            END IF;
            v_lines_adjusted := v_lines_adjusted + 1;
            v_total_delta := v_total_delta + v_delta;

            -- cut 2a:有单值的差异行,成对累积分录行(盘盈:借库存 贷 5200;盘亏反向)。
            -- 无值(未计价进料 / 无成本产出)只调量不入账。
            -- PROC-COST-2:v_value 现在是【单位落地成本】,两支共用它 —— 见上。
            IF v_value IS NOT NULL THEN
                v_amt := round(abs(v_delta) * v_value, 2);
                IF v_amt <> 0 THEN
                    IF v_delta > 0 THEN
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', '5200',     'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt);
                    ELSE
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', '5200',     'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt);
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;

    UPDATE stocktakes
    SET status = 'posted', posted_at = now(), updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;

    -- cut 2a:一张分录覆盖全部有值差异行(每行自成一对,天然自平)
    IF jsonb_array_length(v_je_lines) >= 2 THEN
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Stocktake ' || v_st.code,
            'stocktake', p_stocktake_id,
            v_je_lines);
    END IF;

    RETURN jsonb_build_object(
        'stocktake_id', p_stocktake_id,
        'code', v_st.code,
        'lines_total', v_lines_total,
        'lines_adjusted', v_lines_adjusted,
        'total_delta', v_total_delta
    );
END;
$function$;

-- ── inventory_control_reconciliation(3 处调用改指 _all)──
CREATE OR REPLACE FUNCTION public.inventory_control_reconciliation(p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_sides      jsonb := '[]'::jsonb;
    v_live       boolean;
    v_refuse     text;
    -- raw
    v_led_raw    numeric;
    v_sub_raw    numeric;
    v_c1 numeric; v_c2 numeric; v_c3 numeric; v_c6 numeric;
    v_m3 numeric; v_m4 numeric;
    v_diff_raw   numeric;
    v_unexp_raw  numeric;
    -- fg
    v_led_fg     numeric;
    v_sub_fg     numeric;
    v_fg_pre     numeric;
    v_diff_fg    numeric;
    v_unexp_fg   numeric;
    v_null_bd    integer;
    v_late_cap   integer;
BEGIN
    -- 【定义者函数必须自己问】见抬头第五节:授权不是控制。
    PERFORM require_permission('module.finance.view');
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'AS_OF_REQUIRED';
    END IF;

    v_live := (p_as_of >= CURRENT_DATE);

    -- ── 明细侧能不能重建 ────────────────────────────────────────────────
    IF NOT v_live THEN
        SELECT count(*) INTO v_null_bd
          FROM inventory_movements m
         WHERE m.business_date IS NULL;
        SELECT count(*) INTO v_late_cap
          FROM (
            SELECT fa.created_at FROM freight_allocations fa
            UNION ALL
            SELECT bpca.created_at FROM batch_processing_cost_allocations bpca
          ) c
         WHERE c.created_at::date > p_as_of;

        IF v_null_bd > 0 THEN
            v_refuse := 'BUSINESS_DATES_INCOMPLETE|' || v_null_bd
                     || '|' || COALESCE((SELECT min(business_date)::text
                                           FROM inventory_movements
                                          WHERE business_date IS NOT NULL), '?');
        ELSIF v_late_cap > 0 THEN
            v_refuse := 'CAPITALISATION_AFTER_AS_OF|' || v_late_cap;
        END IF;
    END IF;

    -- ── 账面侧:两个科目,as-at 精确(分录带日期,不需要重建) ──────────
    SELECT COALESCE(SUM(l.debit - l.credit), 0) INTO v_led_raw
      FROM journal_activity_lines(NULL, p_as_of, true) l
     WHERE l.account_code = '1200';
    SELECT COALESCE(SUM(l.debit - l.credit), 0) INTO v_led_fg
      FROM journal_activity_lines(NULL, p_as_of, true) l
     WHERE l.account_code = '1220';

    IF v_refuse IS NOT NULL THEN
        -- 【拒绝也要把账面侧报出来】它是算得准的;拒的是明细侧。
        -- reconciled 为 NULL:「答不上来」不是「对不上」。
        v_sides := jsonb_build_array(
            jsonb_build_object(
                'side','inventory_raw','control_account','1200',
                'ledger_base', round(v_led_raw,2),
                'subledger_base', NULL, 'difference_base', NULL,
                'subledger_basis','refused','refusal', v_refuse,
                'variances','[]'::jsonb,
                'unexplained_base', NULL, 'reconciled', NULL),
            jsonb_build_object(
                'side','inventory_fg','control_account','1220',
                'ledger_base', round(v_led_fg,2),
                'subledger_base', NULL, 'difference_base', NULL,
                'subledger_basis','refused','refusal', v_refuse,
                'variances','[]'::jsonb,
                'unexplained_base', NULL, 'reconciled', NULL));
        RETURN v_sides;
    END IF;

    -- ── 明细侧 + 逐批归因 ───────────────────────────────────────────────
    WITH eff AS (
        SELECT COALESCE(o.source_type, je.source_type) AS st,
               COALESCE(o.source_id,   je.source_id)   AS sid,
               (l.debit - l.credit)                    AS amt
          FROM journal_activity_lines(NULL, p_as_of, true) l
          JOIN journal_entries je ON je.id = l.entry_id
          -- 【原分录优先】见抬头:冲销分录的 source_id 指向原分录,不是批次。
          LEFT JOIN journal_entries o ON o.reversed_by = je.id
         WHERE l.account_code = '1200'
    ),
    attr AS (
        SELECT e.sid AS batch_id, e.amt, e.st FROM eff e
         WHERE e.st IN ('purchase','writeoff')
           AND EXISTS (SELECT 1 FROM inbound_batches b WHERE b.id = e.sid)
        UNION ALL
        SELECT pi.inbound_batch_id,
               e.amt * (pi.quantity_consumed * COALESCE(inbound_batch_landed_unit_cost_all(pi.inbound_batch_id),0))
                     / NULLIF(w.tot,0), e.st
          FROM eff e
          JOIN processing_inputs pi ON pi.run_id = e.sid
          JOIN LATERAL (SELECT SUM(p2.quantity_consumed * COALESCE(inbound_batch_landed_unit_cost_all(p2.inbound_batch_id),0)) AS tot
                          FROM processing_inputs p2
                         WHERE p2.run_id = e.sid AND p2.inbound_batch_id IS NOT NULL) w ON true
         WHERE e.st = 'allocation' AND pi.inbound_batch_id IS NOT NULL
        UNION ALL
        SELECT sl.inbound_batch_id,
               e.amt * (sl.counted_qty - sl.book_qty) / NULLIF(w.tot,0), e.st
          FROM eff e
          JOIN stocktake_lines sl ON sl.stocktake_id = e.sid
          JOIN LATERAL (SELECT SUM(s2.counted_qty - s2.book_qty) AS tot
                          FROM stocktake_lines s2
                         WHERE s2.stocktake_id = e.sid AND s2.inbound_batch_id IS NOT NULL) w ON true
         WHERE e.st = 'stocktake' AND sl.inbound_batch_id IS NOT NULL
        UNION ALL
        SELECT fa.inbound_batch_id, e.amt * fa.amount_base / NULLIF(w.tot,0), e.st
          FROM eff e
          JOIN freight_allocations fa ON fa.freight_document_id = e.sid
          JOIN LATERAL (SELECT SUM(f2.amount_base) AS tot FROM freight_allocations f2
                         WHERE f2.freight_document_id = e.sid) w ON true
         WHERE e.st = 'freight'
    ),
    b AS (
        SELECT ib.id,
               round(COALESCE(ib.remaining_qty * inbound_batch_landed_unit_cost_all(ib.id),0),2) AS batch_side,
               round(COALESCE((SELECT SUM(a.amt) FROM attr a WHERE a.batch_id = ib.id),0),2) AS ledger_net,
               COALESCE((SELECT count(*) FROM attr a WHERE a.batch_id = ib.id AND a.st='purchase'),0) AS purch_n,
               round(COALESCE((SELECT SUM(a.amt) FROM attr a WHERE a.batch_id = ib.id AND a.st='purchase'),0),2) AS purch_net,
               EXISTS (SELECT 1 FROM processing_inputs pi
                         JOIN processing_runs r ON r.id = pi.run_id
                        WHERE pi.inbound_batch_id = ib.id AND r.deleted_at IS NULL
                          AND r.status = 'committed' AND r.allocated_at IS NULL) AS unalloc
          FROM inbound_batches ib
    )
    SELECT round(SUM(batch_side),2),
           -- C1:从来没有过计价分录,而批次身上有价 —— 计价早于过账通路。
           round(SUM(CASE WHEN batch_side > 0 AND purch_n = 0 AND ledger_net <= 0
                          THEN batch_side ELSE 0 END),2),
           -- C2:计价分录有过,但净额为零(冲销之后没有按新价补过)。
           round(SUM(CASE WHEN batch_side > 0 AND purch_n > 0 AND purch_net = 0
                          THEN batch_side ELSE 0 END),2),
           -- C3/C5:账面被解除到了【贷方】—— 放出去的钱从来没有进来过。
           round(SUM(CASE WHEN ledger_net < 0 THEN -ledger_net ELSE 0 END),2),
           -- C6/M1:货已消耗,而 1200 还挂着它的成本(已提交、未分摊)。
           round(SUM(CASE WHEN ledger_net > batch_side AND unalloc
                          THEN -(ledger_net - batch_side) ELSE 0 END),2)
      INTO v_sub_raw, v_c1, v_c2, v_c3, v_c6
      FROM b;

    -- M3 LANDED-DENOM:资本化落在【已被部分消耗】的批次上,分母是 quantity,
    -- 于是解除不足,残值搁浅在 1200。今天为零 —— 唯一一笔资本化已回滚。
    SELECT round(COALESCE(SUM(
             bpca.amount_base * (1 - LEAST(ib.remaining_qty / NULLIF(ib.quantity,0), 1))
           ),0),2) INTO v_m3
      FROM batch_processing_cost_allocations bpca
      JOIN inbound_batches ib ON ib.id = bpca.inbound_batch_id
      JOIN processing_runs r ON r.id = bpca.run_id
     WHERE r.deleted_at IS NULL AND r.status <> 'reversed'
       AND ib.remaining_qty < ib.quantity;

    -- M4:运费按过账当刻的 in_stock_ratio 劈分,之后不再重算。
    -- 残差 = 冻结的比例与今天的比例之差。今天为零 —— 唯一一张运费单已冲销。
    SELECT round(COALESCE(SUM(
             fa.amount_base * (fa.in_stock_ratio
               - LEAST(COALESCE(ib.remaining_qty,0) / NULLIF(ib.quantity,0), 1))
           ),0),2) INTO v_m4
      FROM freight_allocations fa
      JOIN inbound_batches ib ON ib.id = fa.inbound_batch_id
      JOIN freight_documents fd ON fd.id = fa.freight_document_id
     WHERE fd.status <> 'reversed' AND fd.deleted_at IS NULL;

    v_diff_raw  := round(v_sub_raw - v_led_raw, 2);
    -- ★ 没有兜底桶:只扣这六项,任何没被分类的来源原样留在 unexplained 里。
    v_unexp_raw := round(v_diff_raw - (v_c1 + v_c2 + v_c3 + v_c6 + v_m3 + v_m4), 2);

    -- ── 产成品侧 ────────────────────────────────────────────────────────
    -- 【三种状态不许长得一样】(R6):有数 / 0.00(卖光了) / NULL(从未分摊)。
    -- 这里只加【有数】的那些;从未分摊的批次不是 0,它们不参与合计,
    -- 由报表侧渲染成 '—' 并单独报量。
    SELECT round(COALESCE(SUM(ob.remaining_qty * po.unit_cost_base),0),2) INTO v_sub_fg
      FROM output_batches ob
      JOIN processing_outputs po ON po.output_batch_id = ob.id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0
       AND po.unit_cost_base IS NOT NULL;

    -- M10:成本在 1220 通路存在【之前】就分摊掉了 —— 明细里有,总账里一张分录都没有。
    SELECT round(COALESCE(SUM(ob.remaining_qty * po.unit_cost_base),0),2) INTO v_fg_pre
      FROM output_batches ob
      JOIN processing_outputs po ON po.output_batch_id = ob.id
      JOIN processing_runs r ON r.id = po.run_id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0
       AND po.unit_cost_base IS NOT NULL
       AND NOT EXISTS (
             SELECT 1 FROM journal_activity_lines(NULL, p_as_of, true) l
              JOIN journal_entries je ON je.id = l.entry_id
             WHERE l.account_code = '1220'
               AND je.source_type = 'allocation' AND je.source_id = r.id);

    v_diff_fg  := round(v_sub_fg - v_led_fg, 2);
    v_unexp_fg := round(v_diff_fg - v_fg_pre, 2);

    v_sides := jsonb_build_array(
        jsonb_build_object(
            'side','inventory_raw','control_account','1200',
            'ledger_base',     round(v_led_raw,2),
            'subledger_base',  v_sub_raw,
            'difference_base', v_diff_raw,
            'subledger_basis', CASE WHEN v_live THEN 'live_position' ELSE 'reconstructed' END,
            'refusal', NULL,
            'variances', jsonb_build_array(
                jsonb_build_object('code','never_capitalised','amount_base',v_c1),
                jsonb_build_object('code','orphaned_reprice_delta','amount_base',v_c2),
                jsonb_build_object('code','relief_without_capitalisation','amount_base',v_c3),
                jsonb_build_object('code','unallocated_consumption','amount_base',v_c6),
                jsonb_build_object('code','stranded_capitalisation','amount_base',v_m3),
                jsonb_build_object('code','freight_split_residue','amount_base',v_m4)),
            'unexplained_base', v_unexp_raw,
            'reconciled', (v_unexp_raw = 0)),
        jsonb_build_object(
            'side','inventory_fg','control_account','1220',
            'ledger_base',     round(v_led_fg,2),
            'subledger_base',  v_sub_fg,
            'difference_base', v_diff_fg,
            'subledger_basis', CASE WHEN v_live THEN 'live_position' ELSE 'reconstructed' END,
            'refusal', NULL,
            'variances', jsonb_build_array(
                jsonb_build_object('code','costed_before_1220_path','amount_base',v_fg_pre)),
            'unexplained_base', v_unexp_fg,
            'reconciled', (v_unexp_fg = 0)));

    RETURN v_sides;
END;
$function$;

-- ── inventory_valuation_snapshot(5 处调用改指 _all)──
CREATE OR REPLACE FUNCTION public.inventory_valuation_snapshot(p_as_of date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_prices  boolean;
    v_base    text;
    v_loc     jsonb;
    v_age     jsonb;
    v_prod    jsonb;
    v_unpriced_qty numeric;
    v_unpriced_n   integer;
    v_nocost_qty   numeric;
    v_nocost_n     integer;
    v_noloc_n      integer;
    v_mv_n         integer;
    v_unalloc_n    integer;
BEGIN
    -- 【授权不是控制】见抬头第五节:本函数自己判,不靠 EXECUTE 授权收得够窄。
    PERFORM require_permission('module.inventory.view');
    -- ★【这里 NULL =「此刻」,而这与 gl_control_reconciliation 的 AS_OF_REQUIRED
    -- 【不矛盾】,理由要写下来,否则下一个人会把它当成放松了的判词】★
    --   那一条拒绝 NULL,是因为一个【历史时点】被默默填成今天,会让人把今天的
    --   数字读成六月的数字 —— 那是无中生有。
    --   这一支是【实时快照】:「此刻」不是一个被编造的时点,它就是这张屏幕的含义。
    -- 【而且强迫应用自己算"今天"是一个真的 bug】线上 DB 的 TimeZone 是
    --   Asia/Singapore,而 Next.js 侧 toISOString() 给的是 UTC 日期。
    --   每天 00:00–08:00(SGT)两者【差一天】,应用会送来"昨天",于是这张页面
    --   会被自己的 as-at 判词拒掉八个小时。日期的唯一权威是数据库自己。
    p_as_of := COALESCE(p_as_of, CURRENT_DATE);
    -- R5:任意 as-at 具名拒绝 —— business_date 在 2026-07-03 之前【不存在】,
    -- 照样作答会返回一个自信的 0.00。月末从冻结的管理包里取。
    IF p_as_of < CURRENT_DATE THEN
        RAISE EXCEPTION 'AS_OF_NOT_RECONSTRUCTABLE|%|%', p_as_of,
            COALESCE((SELECT min(business_date)::text FROM inventory_movements
                       WHERE business_date IS NOT NULL), '?')
          USING HINT = '业务日在此之前不完整,历史时点的存货无法重建 —— '
                    || '月末数请从已冻结的管理包里取,不要在今天重算一个历史数字。';
    END IF;

    v_prices := has_permission('data.view_prices');
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ── B 节:物料 × 库位 × 状态。★【必须与 stock_snapshot 数出同样的量】★
    -- 那张表(RPT-1 的数量表)把【进料与产出一起】按流水分组;本节若只数进料,
    -- 同一个页面上会出现两张对同一个库位给出不同数量的表 —— 而读的人无从知道
    -- 哪一张漏了什么。所以这里 union 两侧,并用 batch_kind 区分成本口径:
    --   进料腿 → inbound_batch_landed_unit_cost_all(到岸成本)
    --   产出腿 → processing_outputs.unit_cost_base(分摊出来的单位成本)
    -- 【两个口径,一张表,而它们各自说得出自己是谁】—— 不是把两种钱悄悄相加。
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'location_code' NULLS LAST,
                              x->>'material_code', x->>'batch_kind'), '[]'::jsonb)
      INTO v_loc
      FROM (
        SELECT jsonb_build_object(
                 'location_id',   mv.location_id,
                 'location_code', sl.code,
                 'location_name', sl.name,
                 'material_code', mt.code,
                 'material_name', mt.name,
                 'unit',          mt.unit,
                 'stock_status',  mv.stock_status,
                 'batch_kind',    CASE WHEN mv.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
                 'qty',           SUM(mv.qty_delta),
                 -- 【读不到价 → NULL,不是 0】
                 'value_base', CASE WHEN v_prices THEN
                     round(COALESCE(SUM(mv.qty_delta * COALESCE(
                         inbound_batch_landed_unit_cost_all(ib.id), po.unit_cost_base)), 0), 2)
                     ELSE NULL END,
                 -- 【没有成本口径的量单独报】进料侧是"没有价",产出侧是"从未分摊";
                 -- 两者都【不是】"值 0 的货",所以不进 value,单独出现在这里。
                 'uncosted_qty', SUM(CASE WHEN COALESCE(
                         inbound_batch_landed_unit_cost_all(ib.id), po.unit_cost_base) IS NULL
                                          THEN mv.qty_delta ELSE 0 END)
               ) AS x
          FROM inventory_movements mv
          LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
          LEFT JOIN output_batches  ob ON ob.id = mv.output_batch_id
          LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
          JOIN materials mt ON mt.id = COALESCE(ib.material_id, ob.material_id)
          LEFT JOIN storage_locations sl ON sl.id = mv.location_id
         WHERE mt.deleted_at IS NULL
           AND ib.deleted_at IS NULL AND ob.deleted_at IS NULL
         GROUP BY mv.location_id, sl.code, sl.name, mt.code, mt.name, mt.unit,
                  mv.stock_status, CASE WHEN mv.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END
        HAVING SUM(mv.qty_delta) <> 0
      ) s;

    -- ── C 节:库龄。档位取 aging_bucket,缺日期是一个【被渲染的档位】 ──
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'bucket'), '[]'::jsonb)
      INTO v_age
      FROM (
        SELECT jsonb_build_object(
                 'bucket',  COALESCE(aging_bucket((p_as_of - ib.arrival_date)::integer), 'no_date'),
                 'batches', count(*),
                 'qty',     SUM(ib.remaining_qty),
                 'value_base', CASE WHEN v_prices THEN
                     round(COALESCE(SUM(ib.remaining_qty * inbound_batch_landed_unit_cost_all(ib.id)), 0), 2)
                     ELSE NULL END
               ) AS x
          FROM inbound_batches ib
         WHERE ib.deleted_at IS NULL AND ib.remaining_qty > 0
         GROUP BY COALESCE(aging_bucket((p_as_of - ib.arrival_date)::integer), 'no_date')
      ) s;

    -- ── 产出侧:三种状态必须长得不一样(R6) ────────────────────────────
    --   有数 / 0.00(计过价,货卖光了) / NULL(从未分摊,'—')
    SELECT jsonb_build_object(
             'on_hand_batches', count(*),
             'on_hand_qty',     COALESCE(SUM(ob.remaining_qty),0),
             'costed_value_base', CASE WHEN v_prices THEN
                 round(COALESCE(SUM(ob.remaining_qty * po.unit_cost_base) FILTER (WHERE po.unit_cost_base IS NOT NULL),0),2)
                 ELSE NULL END,
             'never_costed_batches', count(*) FILTER (WHERE po.unit_cost_base IS NULL),
             'never_costed_qty',     COALESCE(SUM(ob.remaining_qty) FILTER (WHERE po.unit_cost_base IS NULL),0))
      INTO v_prod
      FROM output_batches ob
      LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0;

    -- ── 这张报表看不见什么 —— 逐条具名,不留给读的人猜 ──────────────────
    SELECT COALESCE(SUM(ib.remaining_qty),0), count(*)
      INTO v_unpriced_qty, v_unpriced_n
      FROM inbound_batches ib
     WHERE ib.deleted_at IS NULL AND ib.remaining_qty > 0
       AND inbound_batch_landed_unit_cost_all(ib.id) IS NULL;
    SELECT COALESCE(SUM(ob.remaining_qty),0), count(*)
      INTO v_nocost_qty, v_nocost_n
      FROM output_batches ob
      LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0 AND po.unit_cost_base IS NULL;
    SELECT count(*) INTO v_noloc_n FROM inventory_movements WHERE location_id IS NULL;
    SELECT count(*) INTO v_mv_n    FROM inventory_movements;
    SELECT count(*) INTO v_unalloc_n FROM processing_runs
     WHERE deleted_at IS NULL AND status='committed' AND allocated_at IS NULL;

    RETURN jsonb_build_object(
        'as_of', p_as_of,
        'base_currency', v_base,
        'basis', 'landed_cost',
        'prices_visible', v_prices,
        -- ★ 具名受限 —— 不是一个更小的合计
        'restriction', CASE WHEN v_prices THEN NULL
                            ELSE 'PRICE_COMPONENTS_RESTRICTED|data.view_prices' END,
        'by_location', v_loc,
        'ageing', v_age,
        'produced', v_prod,
        'cannot_see', jsonb_build_object(
            'unpriced_on_hand_qty',      v_unpriced_qty,
            'unpriced_on_hand_batches',  v_unpriced_n,
            'never_costed_produced_qty', v_nocost_qty,
            'never_costed_produced_batches', v_nocost_n,
            'movements_without_location', v_noloc_n,
            'movements_total',            v_mv_n,
            'committed_runs_unallocated', v_unalloc_n,
            -- 关账闸【关不住】的那四条,连同今天的金额一起写在报表脸上,
            -- 免得有人把 PROCESSING_COSTS_UNALLOCATED 读成"1200 从此不会漂"。
            'close_gate_does_not_cover',
                jsonb_build_array('stranded_capitalisation (M3)',
                                  'freight_split_residue (M4)',
                                  'stocktake_gain_over_relief (M5)',
                                  'relief_without_capitalisation (M7)')));
END;
$function$;
-- ── 四 · 新的 _all 原语不授给 authenticated(与那一对同一条规矩)──────────
REVOKE EXECUTE ON FUNCTION public.inbound_batch_landed_unit_cost_all(uuid) FROM authenticated;

COMMIT;
