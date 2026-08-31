-- PROC-COST-2(2026-08-31):注销与盘点按【落地成本】计值 · 转化型回滚的对称性 ·
--                          运费读取器的读者缺陷
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀三件事都是【更正】,不是新功能】没有新科目、没有新报表、没有新屏幕。
-- 三件事同属一个缺陷族:**资本化进存货的成本,系统要么看不见它、要么放不出来。**
--
--   一 · 注销与盘点按 unit_price 计值 —— 运费与加工成本留在 1200 上出不来;
--   二 · 转化型加工单回滚时,资本化分录(与差额分录)不被冲销;
--   三 · batch_freight_base 是 INVOKER + JOIN,无权读者【安静地】读到 0。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【Tim 的裁定 R1】一批料被注销或在盘点中盘亏,**它的全部落地成本一次解除** ——
-- 采购价 + 运费 + 已资本化的加工成本,全部转入损失。**不许为一批已经不存在的
-- 货在存货里留下任何东西。** 注销与盘点必须【一起】改:只改一个,两者就会对
-- "这批货值多少钱"给出两个答案。
--
-- 【Tim 的裁定 R2】本刀更正既有行为,不加任何功能。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★ 一 · 改之前是什么 —— 线上实测的三个数(2026-08-31,整支回滚)★
--
--   一批 100kg @ 5 = 采购 500,放电资本化 400 → **落地成本 900**
--   注销 →  **解除 500** (= remaining_qty × unit_price)
--          **400 留在 1200 上**,而那批货已经不存在了
--
--   盘点走的是同一条:盘成 0 → 同样只解除 500,同样留下 400。
--   带运费的那一半【一模一样】:100kg @ 5 + 运费 250 → 注销解除 500,留下 250。
--   **所以"运费今天为零只是因为线上还没有已过账的运费单"—— 这句话对,但它读起来
--   像"运费没事"。实测的说法是:一有运费单,它就同样搁浅。**
--
--   部分的那一半更难看:100kg 落地 900,盘亏一半 → 只解除 250(应为 450);
--   再注销剩下的一半 → 再解除 250。**两步走完,400 的加工成本一分钱都没出来。**
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★ 二 · 为什么分母是 quantity,而不是载体行自己的 basis_qty ★
--
-- 单位落地成本 = unit_price + (运费 + 加工成本) / **quantity**。
--
-- 【(a) ÷ quantity】—— 本刀采用。它与 allocate_processing_costs 材料成本表达式
-- 【已经在用】的分母逐字相同(`batch_freight_base(ib.id) / ib.quantity`),
-- 于是"消耗"与"注销"两条路**恰好互补**:每一次消耗按这个费率解除,
-- 剩在 1200 上的就恒等于 费率 × remaining_qty,注销把它一次取空,净得零。
--
-- 【(b) ÷ basis_qty】—— **看起来更对,实际会把 1200 打成负数。** 一张只放电了
-- 100kg 中 30kg 的单,成本挂在 30kg 上;按 500/30 的费率注销整批 100kg,
-- 解除 1,666.67 而 1200 上只有 500。而且它还要把 allocate_processing_costs
-- 一起拖进来改 —— 为了一个更坏的答案。
--
-- 【留下的那个残差,明写在这里,不做无声的缺口】把成本资本化到一批**已经被
-- 消耗过一部分**的料上时,÷ quantity 会**少解除**,余额搁浅在 1200 上。
-- 这个不精确是**从材料成本表达式继承来的**,不是本刀造成的;要修得先有
-- 【子批身份】(这批 100kg 里的哪 30kg 被放过电),而那是一个功能,R2 不许。
-- 记在 docs/known-issues.md,带它实测出来的形状。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★ 三 · 盘点【两个方向都改】—— 这是让这次修复【安全】的那一半 ★
--
-- post_stocktake 盘盈与盘亏用的是同一个 v_value。只改盘亏那一边的话:
--   盘亏 50 解除 450(落地),盘盈 50 只补回 250(采购价)
--   → 一次"点少了、再点回来"就**永久销毁**了 200 的运费与加工成本,
--     而那批料**一克都没有离开过厂房**。
-- **那是一次修复造出来的新缺陷,比被修的那个更坏。** 所以两个方向同一个费率。
-- 实测基线:改之前 100 → 50 → 100 的净额是 0.00;改之后必须仍然是 0.00。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★ 四 · 为什么计值【不能】读那两个带权限判据的读取器 ★
--
-- batch_processing_cost_base 对无权读者返回 NULL(PROC-COST-1 fu2),本刀让
-- batch_freight_base 也这样(见第六节)。**而一笔要过账的计值绝不能读它们:**
-- 那样"这批货值多少钱"就取决于【谁按的按钮】—— 一个只有 inbound.edit 的仓管
-- 按下注销,COALESCE(NULL,0) 会让它安静地退回按 unit_price 计值,
-- 也就是**本刀正在修的那个缺陷,原样复发,而且再也没人看得见**。
--
-- 处置:把【算术】与【受众】拆成两层,各自只有一份定义 ——
--   * `batch_freight_base_all` / `batch_processing_cost_base_all`
--     属主权限、**无判据**、对 authenticated **不可执行**(见 zzz_function_grants)。
--     这是【计值读取器】:过账用它,不问调用者是谁。
--   * `batch_freight_base` / `batch_processing_cost_base`
--     判据 + 委托给上面那一支。这是【屏幕读取器】:无权返回 NULL(受限),不是 0。
-- 于是"运费怎么算"在全库仍然只有一处写法,而"谁看得见"是另一个问题、另一层。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★ 五 · 转化型回滚:三处不对称,一次全补,而且是【同一段代码】★
--
-- 实测,一张转化型加工单回滚之后留下:
--   (i)   资本化分录(借 1220 / 贷 1200 / 贷 5xxx)**原样立着** —— 产出批已经被
--         软删,1220 上却还挂着它的成本;
--   (ii)  重分摊的**差额分录**(allocation_snapshot->'delta_entry_ids')同样立着 ——
--         只补 (i) 的话,一张【被重分摊过】的单仍然错,而它看起来已经修好了;
--   (iii) capitalization_entry_id / capitalized_cost_base **没有清** ——
--         一张已删的单还指着一张已冲销的分录。
-- 第四个候选 —— sales_records 上的 COGS 分录 —— **不需要任何处置**:
-- 第 2 步的 OUTPUT_CONSUMED 闸在任何产出动过之后就拒绝回滚,而卖出必然动
-- remaining_qty。**够不到的东西不需要修,但需要被点名**,否则下一个读的人会重推一遍。
--
-- 【一个机制,不是两条路】原来那段冲销只在 `IF v_sc_kind` 里跑(状态改变型)。
-- 本刀**把那个判断拿掉**,让同一段代码管两种工序,并在其后补上差额分录那一圈 ——
-- 而不是照着它再写一份转化型专用的。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★ 六 · batch_freight_base 的读者缺陷,与它为什么现在才成立 ★
--
-- FRT-1 fu2(2026-08-11)把它【改回】INVOKER,理由写得很清楚:它只读
-- freight_allocations / freight_documents,而那两张表的 SELECT 策略就是
-- `inbound.view OR finance.view` —— 守卫跟着数据自己的 RLS 走。
-- **那个理由在当时是对的,因为那时读它的只有运费自己那批人。**
-- PROC-COST-1 在批次页上摆出了落地成本拆解,于是**一个只有 module.processing.view
-- 的读者第一次会去调它** —— JOIN 把每一行丢掉,函数安静地返回 0。
-- 而 `0.00` 与「受限」不是同一件事:第一个是谎话(OPS-14 的 xmodule 那一族)。
--
-- 【白名单为什么含 processing.edit —— 它是这一项的承重墙】
-- allocate_processing_costs 的材料成本表达式把它写在一个**加法**里:
--     quantity_consumed * (unit_price + 运费/quantity + 加工成本/quantity)
-- 一个 NULL 加数会让整个加数变 NULL,`quantity_consumed * NULL` 是 NULL,
-- **SUM 于是把整条投料腿跳过 —— 连它的 unit_price 一起**。
-- 也就是说:白名单开窄一格,一个【显示】缺陷就变成一个比它更坏的【计值】缺陷。
-- allocate_processing_costs 第一行就是 require_permission('module.processing.edit'),
-- 所以它的调用者必然持有它 —— 白名单与 batch_processing_cost_base 逐字相同,
-- 理由也逐字相同。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀没有改的】unit_price 一个字节没动(它仍是**应付之锚**);
-- 5200 没有按原因拆成多个损失科目(那要一套原因分类法 —— 那是功能,R2 不许);
-- 借贷两侧的科目一个都没换(借 5200 / 贷 1200,与改之前相同);
-- 产出批那一臂(unit_cost_base / 1220)一个字没动 —— 载体只挂在进料批上。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1 · 计值读取器:属主权限,无判据。算术在这里,只有这一份 ─────────────────
CREATE OR REPLACE FUNCTION public.batch_freight_base_all(p_inbound_batch_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【计值读取器 —— 不问调用者是谁】过账用的数不许取决于谁按的按钮。
    -- 屏幕读取器是 batch_freight_base(),它加判据、无权给 NULL。
    -- 【对 authenticated 不可执行】见 db/views/zzz_function_grants.sql —— 它没有
    -- 调用者检查,靠的就是调不到(gate 的 B2 认这条出路)。
    --
    -- 【派生,不存冗余列】落地成本 = quantity × unit_price
    --                              + 本函数 + batch_processing_cost_base_all。
    -- 冲销掉的运费单不计(status = 'reversed')。
    SELECT COALESCE(SUM(fa.amount_base), 0)
    FROM freight_allocations fa
    JOIN freight_documents fd ON fd.id = fa.freight_document_id
    WHERE fa.inbound_batch_id = p_inbound_batch_id
      AND fd.deleted_at IS NULL AND fd.status = 'posted';
$function$;

CREATE OR REPLACE FUNCTION public.batch_processing_cost_base_all(p_inbound_batch_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【计值读取器】同 batch_freight_base_all —— 理由见那一支的抬头。
    -- 【冲销即解除】回滚把加工单软删(deleted_at),这里就不再计它 ——
    -- 与只认 status = 'posted' 的运费单是同一条。
    -- 【实测确认(PROC-COST-2 步骤 2d)】回滚之后载体行【仍然物理存在】,
    -- 排除靠的是这里的 deleted_at / status,不是删行。
    SELECT COALESCE(SUM(a.amount_base), 0)
    FROM batch_processing_cost_allocations a
    JOIN processing_runs r ON r.id = a.run_id
    WHERE a.inbound_batch_id = p_inbound_batch_id
      AND r.deleted_at IS NULL AND r.status = 'committed';
$function$;

-- ── 2 · 屏幕读取器:判据 + 委托。无权返回 NULL,不是 0 ──────────────────────
-- 【本刀的第三件事就是这一支】FRT-1 fu2 把它做成 INVOKER,理由在当时成立;
-- PROC-COST-1 让一个只有 module.processing.view 的读者第一次调到它之后不再成立。
-- 处置是 OPS-14 处置表的 (a) 支:属主权限 + 把读者的判据写进函数体。
CREATE OR REPLACE FUNCTION public.batch_freight_base(p_inbound_batch_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【屏幕读取器】0.00 与「受限」不是同一件事:第一个是谎话。
    -- 白名单与 batch_processing_cost_base 逐字相同,理由也逐字相同 ——
    -- 【edit 也在列】allocate_processing_costs 的调用者必然持有它,于是
    -- 材料成本表达式里这一支【按构造】不可能是 NULL。一个 NULL 加数会让
    -- SUM 跳过整条投料腿(连 unit_price 一起),那比读到 0 更坏。
    SELECT CASE
        WHEN has_permission('module.inbound.view')
          OR has_permission('module.finance.view')
          OR has_permission('module.processing.view')
          OR has_permission('module.processing.edit')
        THEN batch_freight_base_all(p_inbound_batch_id)
        ELSE NULL
    END;
$function$;

CREATE OR REPLACE FUNCTION public.batch_processing_cost_base(p_inbound_batch_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【屏幕读取器】PROC-COST-1 fu2 立的这条,本刀只把算术抽到
    -- batch_processing_cost_base_all 去 —— 行为一个字节没变,
    -- 变的是"算术"与"受众"从此各有一份定义,而计值路径读的是前者。
    SELECT CASE
        WHEN has_permission('module.inbound.view')
          OR has_permission('module.finance.view')
          OR has_permission('module.processing.view')
          OR has_permission('module.processing.edit')
        THEN batch_processing_cost_base_all(p_inbound_batch_id)
        ELSE NULL
    END;
$function$;

-- ── 3 · 单位落地成本:注销与盘点【共用的那一份】────────────────────────────
CREATE OR REPLACE FUNCTION public.inbound_batch_landed_unit_cost(p_inbound_batch_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【R1 的算术,一份实现,两个调用者】注销触发器与 post_stocktake 各自
    -- 抄一遍就是两次漂移机会 —— 而它们必须永远对"这批货值多少钱"给同一个答案,
    -- 那正是 R1 要求两者【一起】改的理由。
    --
    -- 【分母是 quantity】与 allocate_processing_costs 材料成本表达式逐字相同,
    -- 于是消耗与注销互补、净得零。为什么不是 basis_qty:见本迁移抬头第二节。
    --
    -- 【读的是 _all 那一对,不是带判据的那一对】计值不许取决于谁按的按钮 ——
    -- 见抬头第四节。COALESCE(NULL, 0) 在这里会让缺陷无声复发。
    --
    -- 【什么时候是 NULL】采购价没定过【而且】两项资本化都为零 —— 那是一批
    -- 真正"没有金额"的货,调用方据此只出量、不入账(既有行为,一个字没松)。
    -- 反过来:没定过价【但身上挂着加工成本】的批次**必须**入账 ——
    -- 那笔钱确实进过 1200,不放出来就是本刀正在修的那件事。
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

-- ── 4 · 注销:按落地成本解除(R1)──────────────────────────────────────────
-- 【只改进料那一臂的三行】v_value 的来源从 OLD.unit_price 换成
-- inbound_batch_landed_unit_cost(OLD.id)。产出批那一臂(unit_cost_base / 1220)
-- 一个字没动 —— 载体只挂在进料批上,而产出批的 unit_cost_base 本来就已经
-- 把投料的落地成本吃进去了(材料成本表达式,PROC-COST-1 起三项俱全)。
-- 【比例是免费得到的】v_amt 已经是 remaining_qty × v_value —— 单位费率乘剩余量,
-- 天然按量成比例。半批注销解除一半落地成本,不需要第二套算术。
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
                v_value := inbound_batch_landed_unit_cost(OLD.id);
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

-- ── 5 · 盘点:按落地成本计值,【两个方向都是】(R1 + 第三节)────────────────
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
            v_value := inbound_batch_landed_unit_cost(v_line.inbound_batch_id);
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

-- ── 6 · 回滚:资本化的解除【两种工序共用同一段代码】(第五节)────────────────
CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_run_deleted_at timestamptz;
    v_process_date date;     -- FIN-32:还原流水的业务日 = 原加工单的加工日
    v_bad_output record;
    v_input record;
    v_old_remaining numeric;
    v_new_remaining numeric;
    v_quantity numeric;
    v_cap uuid;             -- 首挂的资本化分录
    v_delta_id uuid;        -- PROC-COST-2:重分摊的差额分录,逐张
    v_code text;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- AUDEL-1b:【理由必填】回滚一张加工单是一次很大的操作动作 —— 它软删产出批、
    -- 还原投入、写一整串冲销流水 —— 而此前它【一个 why 都不记】。
    -- 校验放在任何写之前:被拒 = 什么都没发生。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ROLLBACK_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM processing_runs WHERE id = p_run_id), '?');
    END IF;
    -- 1. 锁定加工单，校验存在且未删除
    SELECT process_date INTO v_process_date FROM processing_runs WHERE id = p_run_id;
    SELECT deleted_at INTO v_run_deleted_at
    FROM processing_runs
    WHERE id = p_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;

    IF v_run_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_ALREADY_DELETED';
    END IF;

    -- 标记本次为回滚上下文,供产出批次软删触发器发出 reversal_void。
    PERFORM set_config('evoltrya.movement_ctx', 'reversal:' || p_run_id::text, true);

    -- 2. 安全检查：任何一个产出批次动过就拒绝
    SELECT ob.code, ob.state, ob.quantity, ob.remaining_qty
    INTO v_bad_output
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id
      AND ob.deleted_at IS NULL
      AND (ob.state <> '库存中' OR ob.remaining_qty <> ob.quantity)
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'OUTPUT_CONSUMED|%|%|%|%',
            v_bad_output.code, v_bad_output.state, v_bad_output.remaining_qty, v_bad_output.quantity;
    END IF;

    -- 3. 还原进料：加回 remaining_qty，重判 stage，记 reversal_restore 流水。
    --    FIN-25:产出批投料同样还原(不碰 state —— 那是销售状态)。
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
        IF v_input.inbound_batch_id IS NOT NULL THEN
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM inbound_batches
            WHERE id = v_input.inbound_batch_id
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 进料批次已被删，跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining >= v_quantity THEN '待加工' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.inbound_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:还原不是物理事件,是在更正一次记错的加工单 —— 业务日取
                -- 【原加工单的 process_date】,于是消耗与还原在同一天对消,
                -- 中间那几天的库存历史不会凭空少掉一批实际还在的货。
                --
                -- 【IOD-1:逐行镜像原始流水,不按规则重新分配】投料现在可能跨几个
                -- 库位桶写出多行;还原必须把货放回【它原来所在的那些桶】,而不是
                -- 按 drain 的顺序倒着来一遍 —— 那两者在一般情形下并不相等,
                -- 差额会安静地把库存挪到别的库位上。所以这里读原始的
                -- processing_consume 行,逐行取反。
                PERFORM mirror_consume_restore(p_run_id, v_input.inbound_batch_id, NULL,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        ELSE
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM output_batches
            WHERE id = v_input.output_batch_id AND deleted_at IS NULL
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 上游产出批已被删（如其自身加工单已冲销），跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.output_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:同上 —— 产出批投料的还原(FIN-25 那条边)业务日一样取原加工日
                PERFORM mirror_consume_restore(p_run_id, NULL, v_input.output_batch_id,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        END IF;
    END LOOP;

    -- 4. 软删这张单生成的产出批次(void 流水 + 归零由 BEFORE UPDATE 触发器处理)
    -- AUDEL-1b:软删要走门 —— 标记 + deleted_by + delete_reason,否则
    -- guard_soft_delete_provenance 会按名拒。产出批的删除理由【就是这次回滚的
    -- 理由】:它们不是被单独注销的,是被这次回滚带走的。
    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE output_batches
    SET deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id IN (
        SELECT output_batch_id FROM processing_outputs WHERE run_id = p_run_id
    )
    AND deleted_at IS NULL;

    -- 5. 软删加工单本身（腿表保留作审计）
    UPDATE processing_runs
    SET status = 'reversed',
        deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id = p_run_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);   -- 用毕即清(同 movement_ctx)

    -- ════════════════════════════════════════════════════════════════════════
    -- 【解除资本化 —— 台账与分录在同一个地方一起解除】(PROC-COST-1 立,
    --   PROC-COST-2 把工序种类的判断【拿掉】)
    --
    -- 台账那一半由基函数按本单的 deleted_at 自动排除(形状免费提供的);
    -- 分录那一半必须显式冲销 —— 两半都在这里发生,所以它们永远不会各说各话。
    -- 少做任何一半:要么成本留在存货上而单已经没了(账挂在一张不存在的单上),
    -- 要么台账清了而存货虚高。
    --
    -- ★【PROC-COST-2:这里原来有一句 `IF v_sc_kind`,只管状态改变型】★
    -- 于是**转化型加工单回滚之后,它的资本化分录(借 1220 / 贷 1200 / 贷 5xxx)
    -- 原样立着** —— 产出批已经被软删,1220 上却还挂着它的成本。
    -- 那个判断本刀【拿掉】:两种工序共用同一段代码,不是照着它再写一份。
    --   * 状态改变型:冲销 借 1200 / 贷 5xxx,成本从原料批上退回费用;
    --   * 转化型:    冲销 借 1220 / 贷 1200 / 贷 5xxx —— 1220 上的产出成本
    --     被拿掉,而投料的 1200 同时被还回来,与第 3 步还原 remaining_qty 同向。
    --
    -- 【产出批软删【不再】另外入账,这两件事必须一起读】注销触发器在
    -- reversal 上下文里不写分录 —— 因为解除 1220 的是这里冲销的这张分录。
    -- 两处都做就是重复计数。
    --
    -- ★【差额分录也要冲 —— 只补首挂的话,一张被重分摊过的单仍然错】★
    -- 转化型重分摊走的是差额路径:capitalization_entry_id 仍指首挂,新的差额
    -- 分录记在 allocation_snapshot->'delta_entry_ids' 里。只冲首挂,差额留在
    -- 1220 上,而这张单看起来已经修好了 —— 那是最坏的一种半修。
    -- (状态改变型不会有差额分录:它走的是冲旧挂新,capitalization_entry_id
    --  永远指着唯一活着的那一张。这个循环对它自然空转,不需要分支。)
    --
    -- 【第四个候选:sales_records 上的 COGS 分录 —— 不需要任何处置】
    -- 第 2 步的 OUTPUT_CONSUMED 闸在任何产出动过之后就拒绝回滚,而一次销售
    -- 必然动 remaining_qty。**够不到的东西不需要修,但需要被点名**,
    -- 否则下一个读到这里的人会把这条推理重做一遍。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT code, capitalization_entry_id INTO v_code, v_cap
      FROM processing_runs WHERE id = p_run_id;

    IF v_cap IS NOT NULL
       AND (SELECT status FROM journal_entries WHERE id = v_cap) = 'posted' THEN
        PERFORM reverse_journal_entry_internal(v_cap, CURRENT_DATE,
            'Rollback ' || COALESCE(v_code, '?'));
    END IF;

    FOR v_delta_id IN
        SELECT (jsonb_array_elements_text(
                    COALESCE(pr.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)))::uuid
          FROM processing_runs pr WHERE pr.id = p_run_id
    LOOP
        IF (SELECT status FROM journal_entries WHERE id = v_delta_id) = 'posted' THEN
            PERFORM reverse_journal_entry_internal(v_delta_id, CURRENT_DATE,
                'Rollback ' || COALESCE(v_code, '?'));
        END IF;
    END LOOP;

    UPDATE processing_runs
       SET capitalization_entry_id = NULL, capitalized_cost_base = 0
     WHERE id = p_run_id;

    PERFORM set_config('evoltrya.movement_ctx', '', true);   -- 用毕即清(同 commit)
END;
$function$;

COMMIT;
