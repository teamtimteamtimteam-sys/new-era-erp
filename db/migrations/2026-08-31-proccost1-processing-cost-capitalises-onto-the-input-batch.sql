-- PROC-COST-1(2026-08-31):加工成本【资本化回投料批】+ 鼓包漏液的去处
--
-- 两件事,一次迁移。它们同属一刀,是因为两者都在回答同一个问题:
-- **深度放电这道工序跑完之后,留下了什么。** 一是成本,二是那批料现在能去哪。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【R1 · 成本资本化进批次,而没有产出腿时收件人是【投料批】】
-- 这条原则不是新的:每一道工序的运营成本最后都落进产品成本。转化型工序把它
-- 落进产出批(借 1220),状态改变型没有产出批 —— 于是收件人是那批【还在那里的】
-- 原料本身。深度放电不产出任何新东西:料进去、料出来,只是不带电了。
--
-- 【R3 · unit_price 一个字节都不许动 —— 这是上一刀停下来的理由,原样记下】
-- inbound_batches.unit_price 是【应付之锚】:ap_open_items 按 quantity × unit_price
-- 实时算我们欠供应商多少钱。把我们自己烧的电并进去,就是【凭空捏造供应商债务】;
-- 走 reprice_inbound_batch 则会把一次加工记成一次【重新议价】,还留下一串假的
-- 过期标记。所以成本载体与 unit_price 【分开】,估值读"采购价 + 已资本化加工成本"。
--
-- 【A1 · 本刀刻意复用 FRT-1 的形状 —— 一个模式用两次,不是两个碰巧相像的模式】
-- 运费早已解决过同一个问题,理由与措辞都在 db/migrations/2026-08-11-frt1-*.sql:
-- "第二个成本组件,绝不并进 unit_price"。它的形状是
--   【一张对批次记成本事件的台账】+【一个把它求和的派生函数】
-- 而不是批次上的一列。本刀照抄那个形状,于是两件要紧的语义【免费得到】:
--   * 累加:一批货被放电两次 = 两行,SUM 天然累加,永不覆盖;
--   * 冲销即解除:基函数只认【活着的、已提交的】加工单,回滚把单软删,那一行
--     就自动不计 —— 与 batch_freight_base 只认 status='posted' 的运费单同构。
-- 【为什么【不】并进 freight_allocations(A1 的决定性理由)】每一张运费单都指名
-- 一个【货代】,是我们欠钱的对手方,未付即成为一张 ap_open_items。我们自己烧的
-- 电【不欠任何人】—— 它早已付过或已计提。把一个非应付项塞进一个整体形状都假设
-- 有对手方的结构里,迟早会有人按那个假设去读它。
--
-- 【A2 · 科目映射:不新建任何科目】
--   * Tim 说的【生产成本】就是本仓库已有的 5100–5190「加工成本-*」family。
--     它今天就在承载这些成本:fin_journal_cost_entry 在成本条目录入的那一刻
--     借 5xxx / 贷 2200。Tim 的裁定命名的是一个【概念】,而那个概念已经实现了。
--   * 资本化的【去处】,对进料批而言是 1200「存货-原料」,不是 1220「存货-成品」。
--     深度放电不产出任何新东西,那批料【仍然是原料】,成本就该落在原料所在的地方。
--     1220 是转化型工序的去处,因为它们的收件人是产出批。
--   * 【1210「存货-在制品」一个字都不碰】:is_system = false、全库无人引用,
--     那是建账的人的地盘(accounts.sql 的引导段已经写死这条界线)。
--
-- 【A3 · 这【不是】一笔新成本进账,而是一次【重分类】——出销售成本、进存货】
-- 电费早在录入那一刻就已经进了总账(借 5110 / 贷 2200)。所以资本化这一步不新增
-- 任何金额,它把已经在 COGS 里的那笔钱【拨进存货】:
--       借 1200  /  贷 5xxx（逐 cost_type）
-- 这正是既有 借 1220 / 贷 5xxx 的镜像,只是收件人不同。
-- 【冲销必须同时解除台账行与分录,而且在同一个地方做,这样它们永远不会各说各话】
-- 台账行由基函数按加工单的 deleted_at 自动排除;分录由 rollback_processing_run
-- 显式冲销 —— 两者都在回滚那一个函数里发生。
--
-- 【为什么状态改变型的重分摊可以【全额冲销重挂】,而 FIN-24 对转化型禁止这么做】
-- 这不是抄一条惯例,是一条【只在这里成立】的论证:FIN-24 的问题在于成本已经顺着
-- 产出批流向了已售份额,而已过账的 COGS 从不重述 —— 卖得越多错得越多。
-- 状态改变型【没有产出批】:它的成本停在 1200 上一批仍然是原料的货上,没有任何
-- 下游把它当成本消费掉。若那批料后来被一张转化型加工单吃掉,那张单会因为
-- 第七过期源而【过期】,重跑即修正。所以这里冲旧挂新是安全的,且比差额法诚实。
--
-- 【A4 · 一条被测量推翻的前提,原样记下 —— 它比结论更容易被后来的人误解】
-- 本刀的委托书里写着"估值读采购价加已资本化加工成本",这句话【假设存在一个估值口】。
-- 实测:**不存在**。batch_freight_base 全仓库只有【一个】生产消费者 ——
-- allocate_processing_costs 的材料成本表达式(本文件下方那一行)。
-- stock_snapshot 只有数量没有金额;inbound_batches_masked 只透 unit_price;
-- batch_margin 读的是 processing_outputs.unit_cost_base,那只有产出批才有。
-- 于是:**进料批上的资本化成本,只有一条路能走到损益表 —— 那批料后来被一张
-- 转化型加工单吃掉。** 一批放完电就再没被加工过的货,它身上的成本【没有任何
-- 报表看得见】。这与 FRT-1 为运费写下并接受的敞口是同一个,现在是【知情地】
-- 再接受一次,不是漏掉。一张计值存货报表是另一刀,不是本刀留下的缺口。
-- 本刀因此在批次页上建了【落地成本拆解】(采购价 / 运费 / 加工成本 / 合计),
-- 顺带把运费那份同样的隐身也一起解决了。
--
-- 【A5 · 第七过期源,不可省 —— FRT-1 亲口把漏掉它叫做"本刀的头号缺陷"】
-- 一张迟到的放电成本,改变的是【可能已经被下游吃掉的】批次的成本。它若不是
-- 过期源,吃过那批货的加工单永远不标过期,batch_margin 就停在放电之前那个数,
-- 而放电那张分录本身完全正确 —— 这是本仓库最坏的失败形状:每一笔都对,总数错。
-- 【排除自己】(bpca.run_id <> r.id):否则放电单会在分摊完成的那一刻把自己标成过期。
--
-- 【2e · 换掉那条"无处可落"的拒绝之后,还有哪些情形仍然拒绝 —— 一一点名】
--   1. ALLOCATION_STATE_CHANGING_BASIS —— 金属价值基准。它按【产出批的金属含量】
--      拆分,而状态改变型没有产出批:那不是"算出来是零",是那个基准在这里
--      根本没有可读的数。
--   2. ALLOCATION_STATE_CHANGING_OUTPUT_INPUT —— 投料里有【自产产出批】。
--      成本载体按 inbound_batch_id 记,产出批不在它的地址空间里。要建这条路,
--      得先决定产出批的资本化载体是什么;在那之前【按名拒绝,不许悄悄丢掉成本】。
--   3. ALLOCATION_STATE_CHANGING_NO_INPUT —— 没有投料批,资本化没有收件人。
--   4. ALLOCATION_LEDGER_DIVERGED —— 资本化分录被人工冲销(与既有路径同一条)。
-- 【转化型少了产出仍然是 NO_OUTPUTS,一个字没松】—— 那道闸在 commit 上,本刀不碰。
--
-- 【2d · 质量不动】in = out = throughput、损耗恒 0,由 commit 那一侧的
-- STATE_CHANGE_LOSS_NOT_ZERO 与 OPERATION_PRODUCES_NO_OUTPUTS 守着,本刀一个字不改。
-- **成本移动,质量不动。**
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【R4 · 鼓包漏液走整电池粉料线,与损坏料同一处置】
-- operation_type_safety_states 的表注里写着这句话,等的就是今天这条裁定:
--   "为什么 swollen_leaking 一道工序都没有受理 …… 于是这种料今天没有路线,
--    那是刻意的,它等 Tim 的一句裁定,不等一个猜测。"
-- Tim 裁定:鼓包与漏液【同一处置】,不拆成两个安全状态,走整电池粉料线,
-- 与 damaged_deformed 完全同形 —— 粉料线把料粉碎掉,不解决那个状态(resolves = false)。
--
-- 【不变式一个字没松:只许逐工序放宽,不许默认放宽】加一行受理是【逐工序的、
-- 明写的数据】,那正是这张表存在的方式;"设了工序就放行"或"按 kind 旁路"的实现
-- 在 fixture 159 F2/F3 里【仍然是红的】—— 本刀没有碰那两臂。
-- 【深度放电仍然拒绝鼓包漏液】(F3),因为放电机解决不了起火风险。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1 · 成本载体:一张对批次记成本事件的台账(FRT-1 的形状,第二次使用)───────
CREATE TABLE public.batch_processing_cost_allocations (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 【成本事件的来源】加工单。冲销即解除靠它:基函数只认活着且已提交的单。
    run_id           uuid NOT NULL REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    -- 【收件人】进料批。产出批不在这个地址空间里 —— 见上面 2e 的第 2 条拒绝。
    inbound_batch_id uuid NOT NULL REFERENCES public.inbound_batches (id),
    -- 【刻意【没有】>= 0 的约束,而 freight_allocations 有】运费永远为正(总是欠货代
    -- 一笔钱),而 processing_cost_entries 明写"Deliberately no sign check:
    -- by-product / disposal offsets may be negative"。照抄那条约束会让一笔副产品
    -- 冲抵在这里撞墙,而它在源表里是合法的。**形状照抄,理由不成立的约束不照抄。**
    amount_base      numeric NOT NULL,
    -- 【可审计与"碰巧算对了"的分界】这一份是从什么数算出来的:该批的投料量,
    -- 以及全单的投料总量。分摊要能被重新导出,不是被相信(与 freight_allocations
    -- 的 basis_qty 同一条论证)。
    basis_qty        numeric NOT NULL,
    basis_total_qty  numeric NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    -- 一张单对一批货只出一行;重分摊先删后插,所以这条约束也是幂等性的保证。
    UNIQUE (run_id, inbound_batch_id)
);

COMMENT ON TABLE public.batch_processing_cost_allocations IS
'PROC-COST-1:加工成本【资本化进批次】的载体 —— 第二个成本组件,不是更高的单价。

【它与 unit_price 的关系,一句话说清】unit_price 是【应付之锚】(ap_open_items 按
quantity × unit_price 算欠供应商多少钱)。把我们自己烧的电并进去 = 凭空捏造供应商债务。
所以成本【另起一张台账】,估值读"采购价 + batch_freight_base + batch_processing_cost_base"。

【形状来自 FRT-1,那是刻意的】一张对批次记成本事件的台账 + 一个求和的派生函数,
不是批次上的一列。累加(SUM)与冲销即解除(只认活着且已提交的加工单)都由形状免费提供。
一列做不到这两样:它得读-改-写,而两次放电会互相覆盖。

【为什么不并进 freight_allocations】运费单指名一个【货代】,是我们欠钱的对手方,
未付即成为 ap_open_items 的一行。我们自己烧的电不欠任何人。';

COMMENT ON COLUMN public.batch_processing_cost_allocations.amount_base IS
    'PROC-COST-1:本位币金额。【刻意没有 >= 0 约束】—— 源表 processing_cost_entries 明写允许负数(副产品/处置冲抵),照抄 freight_allocations 的正数约束会让一笔在源表里合法的冲抵在这里撞墙。';
COMMENT ON COLUMN public.batch_processing_cost_allocations.basis_qty IS
    'PROC-COST-1:这一份是【从什么数算出来的】—— 该批在本单的投料量(basis_total_qty 是全单投料总量)。分摊要能被重新导出,不是被相信(与 freight_allocations.basis_qty、FIN-26 的 price_source、METAL-3 的 fx_legs 同源)。';
COMMENT ON COLUMN public.batch_processing_cost_allocations.run_id IS
    'PROC-COST-1:成本事件的来源加工单。【冲销即解除靠这一列】batch_processing_cost_base 只认 deleted_at IS NULL AND status = ''committed'' 的单 —— 回滚把单软删,这一行就自动不计,与 batch_freight_base 只认 status=''posted'' 的运费单同构。';

ALTER TABLE public.batch_processing_cost_allocations ENABLE ROW LEVEL SECURITY;
-- 读:进料侧与财务侧都要看得见(批次页的落地成本拆解在进料侧)。与 freight_allocations 同形。
CREATE POLICY "batch_processing_cost_allocations select by permission"
    ON public.batch_processing_cost_allocations AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view') OR has_permission('module.finance.view')
           OR has_permission('module.processing.view'));
-- 写:只由 allocate_processing_costs(SECURITY DEFINER)产生。这条策略是给人挡的门,
-- 不是给函数开的门 —— 函数以属主身份跑,绕过 RLS。
CREATE POLICY "batch_processing_cost_allocations write by permission"
    ON public.batch_processing_cost_allocations AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'))
    WITH CHECK (has_permission('module.processing.edit'));

CREATE INDEX idx_bpca_batch ON public.batch_processing_cost_allocations (inbound_batch_id);
CREATE INDEX idx_bpca_run   ON public.batch_processing_cost_allocations (run_id);

-- ── 2 · 每批的加工成本合计:一处实现,派生而非冗余列 ──────────────────────────
CREATE OR REPLACE FUNCTION public.batch_processing_cost_base(p_inbound_batch_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【派生,不存冗余列】落地成本 = quantity × unit_price
    --                              + batch_freight_base + 本函数。
    -- 【冲销即解除】回滚把加工单软删(deleted_at)并置 status,这里就不再计它 ——
    -- 与 batch_freight_base 只认 status = 'posted' 的运费单是同一条。
    SELECT COALESCE(SUM(a.amount_base), 0)
    FROM batch_processing_cost_allocations a
    JOIN processing_runs r ON r.id = a.run_id
    WHERE a.inbound_batch_id = p_inbound_batch_id
      AND r.deleted_at IS NULL AND r.status = 'committed';
$function$;

COMMENT ON FUNCTION public.batch_processing_cost_base(uuid) IS
    'PROC-COST-1:一批进料身上已资本化的加工成本合计。【SECURITY INVOKER】与 batch_freight_base 同形(FRT-1 fu2 把它从 DEFINER 改回来过:一个金额读取器不该替调用者绕过 RLS)。';

-- ── 3 · 分摊学会状态改变型:那条"无处可落"的拒绝换成真正的去处 ────────────────
-- 【本函数的三处改动】
--   (a) 材料成本表达式多了第三个组件 batch_processing_cost_base —— 这是进料批上
--       的资本化成本【唯一】能走到损益表的那条路(见文件头 A4 段);
--   (b) guard_allocation_not_state_changing 的调用点删掉,换成第 6 步之后的分支;
--   (c) 分支里逐一按名点出仍然拒绝的四种情形(2e 段)。
CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Cost allocation. Metals with a usable price (deleted_at IS NULL, price_date <= run
-- process_date) contribute to metal value; metals WITHOUT one contribute 0 and are
-- recorded in allocation_snapshot.skipped_metals (the former missing-price hard error is gone).
-- NO_METAL_VALUE still blocks when the total metal value across all legs is 0.
-- (Phase 1 follow-up 1, 2026-07-03.)
-- cut 2a (2026-07-06): 10a 资本化分录(借 1220 / 贷 1200 材料 + 贷 5xxx 费用;
-- 重分摊 = 冲旧 + 重挂);10b 给无 COGS 的既有销售按原 sale_date 补挂 COGS。
DECLARE
    v_user                 uuid := auth.uid();
    v_run                  processing_runs%ROWTYPE;
    v_basis                text;
    v_process_date         date;
    v_material             numeric;
    v_process              numeric;
    v_total                numeric;
    v_inputs_without_price integer;
    v_total_basis          numeric;
    v_total_metal_value    numeric;
    v_bad_code             text;
    v_bad_metal            text;
    v_prices_used          jsonb;
    v_default_index        text;
    v_skipped_metals       jsonb;
    v_outputs              jsonb;
    v_sum_alloc            numeric;
    v_snapshot             jsonb;
    v_ct                   record;
    v_sale                 record;
    v_cap_lines            jsonb;
    v_cap_total            numeric;
    v_cap_je               jsonb;
    v_cap_entry_id         uuid;
    v_cogs                 numeric;
    v_cogs_je              jsonb;
    -- FIN-24:差额法用
    v_prior                jsonb;      -- 分摊前各产出腿的 allocated(差额的"已记录"侧)
    v_rec_src              jsonb;      -- 已记录的各来源(material / 各 cost_type)
    v_rec_total            numeric;
    v_by_source            jsonb;      -- 本次各来源(写进 snapshot,下次的"已记录")
    v_delta                numeric;
    v_leg                  record;
    v_d1220                numeric := 0;
    v_d5000                numeric := 0;
    v_d5200                numeric := 0;
    v_l1220                numeric;
    v_l5000                numeric;
    v_other                numeric;
    v_cred_total           numeric := 0;
    v_deb_total            numeric;
    v_cap_status           text;
    -- FIN-25:再加工
    v_material_in          numeric;   -- 进料批投料(→ 1200)
    v_material_re          numeric;   -- 产出批投料(→ 1220 解除上游)
    v_upstream_incomplete  boolean;
    v_re_without_price     integer;
    -- PROC-COST-1:状态改变型分支
    v_state_changing       boolean;
    v_sc_out_inputs        integer;
    v_sc_in_inputs         integer;
    v_sc_basis_total       numeric;
    v_sc_rows              jsonb;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- 1. Lock the run; must exist and be a live committed run.
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    IF v_run.deleted_at IS NOT NULL OR v_run.status <> 'committed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.status;
    END IF;

    -- PROC-COST-1:那条"无处可落"的拒绝在这里【换成了真正的去处】——
    -- 状态改变型的分支在第 6 步之后(它需要 v_material / v_process 都已算出)。
    -- 仍然拒绝的四种情形在分支里逐一按名点出,理由见本迁移的 2e 段。

    -- 2. Resolve + validate basis.
    v_basis := COALESCE(p_basis, v_run.allocation_basis);
    IF v_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', v_basis;
    END IF;
    v_process_date := v_run.process_date;

    -- 3. Unit guard: all math assumes kg.
    SELECT ib.code INTO v_bad_code
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id AND ib.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    SELECT ob.code INTO v_bad_code
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id AND ob.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    -- 4. Material cost(FIN-25 起两路):进料批按 inbound.unit_price;产出批
    --    (再加工)按上游 processing_outputs.unit_cost_base。NULL 价照旧计 0 并
    --    计数 —— 【允许,不拒绝】:车间按天走,财务分摊按月走,拒绝会让车间等
    --    财务。零不静默:cost_incomplete 标记打在本单产出上,逐级传染(见 9c),
    --    上游补分摊后本单过期,重跑即修复。
    -- FRT-1:材料成本 = 【落地成本】,不只是单价 —— 单价 + 分摊到该批的单位运费。
    -- 运费资本化进批次之后,这里若仍只读 unit_price,运费就停在 1200/5000,
    -- 永远走不到产出批的 unit_cost_base,batch_margin 会继续停在运费之前的那个数
    -- (而运费那张分录本身完全正确)。这正是"资本化的错误藏在存货里"最具体的一种。
    SELECT COALESCE(SUM(pi.quantity_consumed
             * (COALESCE(ib.unit_price, 0)
                + CASE WHEN ib.quantity > 0 THEN batch_freight_base(ib.id) / ib.quantity ELSE 0 END
                -- PROC-COST-1:第三个成本组件 —— 该批身上已资本化的加工成本
                -- (放电等状态改变型工序留下的)。【不加这一项,成本就走不出去】:
                -- 它是进料批上的资本化成本【唯一】能到达损益表的那条路。
                + CASE WHEN ib.quantity > 0 THEN batch_processing_cost_base(ib.id) / ib.quantity ELSE 0 END)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material_in, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(po_up.unit_cost_base, 0)), 0),
           COUNT(*) FILTER (WHERE po_up.unit_cost_base IS NULL),
           COALESCE(bool_or(po_up.unit_cost_base IS NULL OR po_up.cost_incomplete), false)
      INTO v_material_re, v_re_without_price, v_upstream_incomplete
    FROM processing_inputs pi
    JOIN processing_outputs po_up ON po_up.output_batch_id = pi.output_batch_id
    WHERE pi.run_id = p_run_id;
    v_inputs_without_price := v_inputs_without_price + COALESCE(v_re_without_price, 0);
    v_material := v_material_in + v_material_re;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_base), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-COST-1:【状态改变型 —— 成本资本化回投料批】
    -- 没有产出腿,于是收件人是那批【还在那里的】原料本身。深度放电不产出任何
    -- 新东西:料进去、料出来,只是不带电了 —— 所以它仍然是原料,成本落在 1200。
    -- 【只有加工成本资本化,材料成本【不】动】那批料的价值早就在 1200 上了;
    -- 再借一次 1200 就是拿 1200 对自己重复计数。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT NOT k.produces_outputs INTO v_state_changing
      FROM operation_types ot
      JOIN operation_kinds k ON k.code = ot.kind_code
     WHERE ot.code = v_run.operation_type_code;
    v_state_changing := COALESCE(v_state_changing, false);

    IF v_state_changing THEN
        -- 【拒绝 1】金属价值基准按【产出批的金属含量】拆分,而这里没有产出批。
        -- 那不是"算出来是零",是那个基准在这里根本没有可读的数。
        IF v_basis = 'metal_value' THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_BASIS|%|%', v_run.code, v_basis
              USING HINT = '金属价值基准读的是产出批的金属含量(output_batch_metals),而状态改变型工序没有产出批。按质量(weight)分摊。';
        END IF;

        SELECT count(*) FILTER (WHERE pi.output_batch_id IS NOT NULL),
               count(*) FILTER (WHERE pi.inbound_batch_id IS NOT NULL)
          INTO v_sc_out_inputs, v_sc_in_inputs
          FROM processing_inputs pi
         WHERE pi.run_id = p_run_id;

        -- 【拒绝 2】成本载体按 inbound_batch_id 记地址,自产产出批不在那个地址空间里。
        -- **按名拒绝,不许悄悄把成本丢掉** —— 要建这条路,先决定产出批的资本化载体
        -- 是什么(产出批已有 unit_cost_base,那是另一种形状,不是这一张台账)。
        IF v_sc_out_inputs > 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_OUTPUT_INPUT|%|%', v_run.code, v_sc_out_inputs
              USING HINT = '成本载体 batch_processing_cost_allocations 按进料批记地址,自产产出批不在它的地址空间里。这条路要建,先决定产出批的资本化载体是什么 —— 在那之前按名拒绝,而不是悄悄把这笔成本丢掉。';
        END IF;

        -- 【拒绝 3】没有投料批,资本化没有收件人。
        IF v_sc_in_inputs = 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_NO_INPUT|%', v_run.code
              USING HINT = '这张单没有进料批投料,资本化没有收件人。';
        END IF;

        SELECT COALESCE(SUM(pi.quantity_consumed), 0) INTO v_sc_basis_total
          FROM processing_inputs pi
         WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL;
        IF v_sc_basis_total <= 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_NO_BASIS|%', v_run.code
              USING HINT = '投料量合计为零,按质量分摊没有可用的分母。';
        END IF;

        -- 【拒绝 4 与既有路径同一条】资本化分录被人工冲销 → 基准与总账已分道。
        IF v_run.capitalization_entry_id IS NOT NULL THEN
            SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
            IF v_cap_status <> 'posted' THEN
                RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
            END IF;
            -- 【重分摊 = 冲旧 + 重挂,而这在这里是安全的 —— 论证只在这里成立】
            -- FIN-24 禁止转化型这么做,是因为成本已顺着产出批流向已售份额,而已过账
            -- 的 COGS 从不重述。状态改变型【没有产出批】:成本停在 1200 上一批仍然
            -- 是原料的货上,没有任何下游把它当成本消费掉。若那批料后来被一张转化型
            -- 加工单吃掉,那张单会因【第七过期源】而过期,重跑即修正。
            PERFORM reverse_journal_entry_internal(v_run.capitalization_entry_id, CURRENT_DATE,
                'Re-allocation ' || v_run.code);
            UPDATE processing_runs
               SET capitalization_entry_id = NULL, capitalized_cost_base = 0
             WHERE id = p_run_id;
        END IF;

        -- ── 台账:先删后插(幂等)。按投料量拆,最大份额吸收进位余数 ────────────
        DELETE FROM batch_processing_cost_allocations WHERE run_id = p_run_id;

        WITH legs AS (
            SELECT pi.inbound_batch_id AS ib, SUM(pi.quantity_consumed) AS q
              FROM processing_inputs pi
             WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL
             GROUP BY pi.inbound_batch_id
        ),
        calc AS (
            SELECT ib, q,
                   round(v_process * q / v_sc_basis_total, 2) AS raw,
                   row_number() OVER (ORDER BY q DESC, ib) AS rn
              FROM legs
        ),
        adj AS (
            SELECT c.*, (round(v_process, 2) - SUM(c.raw) OVER ()) AS rem FROM calc c
        )
        INSERT INTO batch_processing_cost_allocations
            (run_id, inbound_batch_id, amount_base, basis_qty, basis_total_qty)
        SELECT p_run_id, ib, raw + CASE WHEN rn = 1 THEN rem ELSE 0 END, q, v_sc_basis_total
          FROM adj;

        SELECT jsonb_agg(jsonb_build_object(
                   'inbound_batch_id', a.inbound_batch_id,
                   'amount_base', a.amount_base,
                   'basis_qty', a.basis_qty)
               ORDER BY a.inbound_batch_id)
          INTO v_sc_rows
          FROM batch_processing_cost_allocations a WHERE a.run_id = p_run_id;

        -- ── 分录:借 1200 / 贷 5xxx —— 【重分类,不是新成本】────────────────────
        -- 电费在录入那一刻就已经进了总账(fin_journal_cost_entry:借 5110 / 贷 2200)。
        -- 这一步不新增任何金额,它把已经在 COGS 里的钱拨进存货。
        v_cap_lines := '[]'::jsonb;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
              FROM processing_cost_entries
             WHERE run_id = p_run_id AND deleted_at IS NULL
             GROUP BY cost_type
             ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type),
                    'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type),
                    'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF round(v_process, 2) <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_process > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(round(v_process, 2)),
                'line_memo', 'capitalised onto input batch — state-changing run')) || v_cap_lines;
            v_cap_je := post_journal_entry(CURRENT_DATE, 'Capitalize ' || v_run.code,
                'allocation', p_run_id, v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        -- 【快照】capitalized_by_source 只列各 cost_type,【故意没有 material 一项】——
        -- 材料没有被资本化(它早就在 1200 上了),写进去会让后来的人以为它进过账。
        v_by_source := '{}'::jsonb;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
              FROM processing_cost_entries
             WHERE run_id = p_run_id AND deleted_at IS NULL
             GROUP BY cost_type
        LOOP
            v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
        END LOOP;

        UPDATE processing_runs
        SET material_cost_base   = round(v_material, 2),
            process_cost_base    = round(v_process, 2),
            total_cost_base      = round(v_total, 2),
            allocation_basis     = v_basis,
            allocation_snapshot  = jsonb_build_object(
                'capitalized_by_source', v_by_source,
                'capitalised_component', 'process_only',
                'capitalised_onto', 'input_batches',
                'destination_account', '1200',
                'basis', v_basis,
                'computed_at', now(),
                'inputs_without_price', v_inputs_without_price,
                'allocations', COALESCE(v_sc_rows, '[]'::jsonb)),
            allocated_at         = now(),
            allocated_by         = v_user,
            capitalized_cost_base   = round(v_process, 2),
            capitalization_entry_id = v_cap_entry_id,
            updated_at           = now(),
            updated_by           = v_user
        WHERE id = p_run_id;

        RETURN jsonb_build_object(
            'run_id', p_run_id,
            'basis', v_basis,
            'state_changing', true,
            'material_cost_base', round(v_material, 2),
            'process_cost_base', round(v_process, 2),
            'total_cost_base', round(v_total, 2),
            'capitalized_cost_base', round(v_process, 2),
            'capitalised_onto', COALESCE(v_sc_rows, '[]'::jsonb),
            'inputs_without_price', v_inputs_without_price,
            'outputs', '[]'::jsonb
        );
    END IF;

    -- 7. Basis totals. Metals without a usable price contribute 0 (LEFT JOIN + COALESCE)
    --    and are recorded in skipped_metals; only a zero grand total blocks (NO_METAL_VALUE).
    IF v_basis = 'metal_value' THEN
        -- METAL-2:分摊【没有交易可以继承指数】—— 一张加工单不是一笔谈定的买卖,
        -- 没有对手方、没有条款,所以它按 pricing_settings 的房屋约定取价。
        -- 【这是默认值在替一条缺席的条款站位,不是"这批成本按某个声明的指数结算了"】。
        -- 快照里一并记下用的是哪个指数,免得日后有人把它读成一条谈定的条款。
        SELECT default_metal_index INTO v_default_index FROM pricing_settings WHERE id;

        SELECT COALESCE(SUM(
                 po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0)
               ), 0)
          INTO v_total_metal_value
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        LEFT JOIN LATERAL (
            SELECT mp.price_usd_per_tonne
            FROM metal_prices mp
            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.price_date <= v_process_date
            ORDER BY mp.price_date DESC
            LIMIT 1
        ) pr ON true
        WHERE po.run_id = p_run_id;

        IF COALESCE(v_total_metal_value, 0) = 0 THEN
            RAISE EXCEPTION 'NO_METAL_VALUE';
        END IF;

        v_total_basis := v_total_metal_value;

        SELECT COALESCE(jsonb_agg(
                   jsonb_build_object('metal', metal,
                                      'price_usd_per_tonne', price_usd_per_tonne,
                                      'price_date', price_date)
                   ORDER BY metal), '[]'::jsonb)
          INTO v_prices_used
        FROM (
            SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne, mp.price_date
            FROM metal_prices mp
            WHERE mp.deleted_at IS NULL AND mp.price_date <= v_process_date
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.metal IN (
                  SELECT DISTINCT obm.metal
                  FROM processing_outputs po
                  JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
                  WHERE po.run_id = p_run_id AND obm.content_pct > 0
              )
            ORDER BY mp.metal, mp.price_date DESC
        ) q;

        -- Metals present (content > 0) on this run with NO usable price row: excluded from
        -- value (they contributed 0 above) and reported in the snapshot as skipped.
        SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
          INTO v_skipped_metals
        FROM (
            SELECT DISTINCT obm.metal AS m
            FROM processing_outputs po
            JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
            WHERE po.run_id = p_run_id AND obm.content_pct > 0
              AND NOT EXISTS (
                  SELECT 1 FROM metal_prices mp
                  WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                    AND mp.price_date <= v_process_date
              )
        ) s;
    ELSE
        SELECT COALESCE(SUM(quantity_produced), 0) INTO v_total_basis
        FROM processing_outputs WHERE run_id = p_run_id;
        v_total_metal_value := NULL;
        v_prices_used := '[]'::jsonb;
        v_skipped_metals := '[]'::jsonb;
    END IF;

    -- FIN-24:差额法的"已记录"侧 —— 在下面的 UPDATE 改写之前,把各产出腿
    -- 当前的 allocated 拍下来。目标 − 已记录 = 应过账的差额(与重估/折旧同形)。
    SELECT COALESCE(jsonb_object_agg(po.output_batch_id::text,
                    COALESCE(po.allocated_cost_base, 0)), '{}'::jsonb)
      INTO v_prior
    FROM processing_outputs po WHERE po.run_id = p_run_id;

    -- 8 + 9. Allocate (largest-share row absorbs the rounding remainder), persist legs,
    --        and collect the per-output result — all in one statement.
    WITH legs AS (
        SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
               CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
                    ELSE COALESCE((
                        SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0))
                        FROM output_batch_metals obm
                        LEFT JOIN LATERAL (
                            SELECT mp.price_usd_per_tonne
                            FROM metal_prices mp
                            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                              AND mp.price_date <= v_process_date
                            ORDER BY mp.price_date DESC
                            LIMIT 1
                        ) pr ON true
                        WHERE obm.output_batch_id = po.output_batch_id
                    ), 0)
               END AS basis_value
        FROM processing_outputs po
        WHERE po.run_id = p_run_id
    ),
    calc AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw,
               row_number() OVER (ORDER BY basis_value DESC, leg_id) AS rn
        FROM legs
    ),
    adj AS (
        SELECT c.*, (round(v_total, 2) - SUM(alloc_raw) OVER ()) AS remainder
        FROM calc c
    ),
    final AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               alloc_raw + CASE WHEN rn = 1 THEN remainder ELSE 0 END AS allocated
        FROM adj
    ),
    upd AS (
        UPDATE processing_outputs po
        SET allocated_cost_base = f.allocated,
            unit_cost_base = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_base
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_base', allocated,
                   'unit_cost_base', unit_cost_base)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    -- FIN-24:by_source = 本次各来源的入账口径(材料 + 逐 cost_type,各 2 位),
    -- 下一次差额跑的"已记录"就从这里读 —— recorded,不再从分录反推。
    v_by_source := jsonb_build_object('material', round(v_material_in, 2));
    IF round(v_material_re, 2) <> 0 THEN
        -- 再加工材料单列一源:首挂贷 1220(解除上游产出),差额与 material 同贷 5000
        v_by_source := v_by_source || jsonb_build_object('material_reprocessed', round(v_material_re, 2));
    END IF;
    FOR v_ct IN
        SELECT cost_type, round(sum(amount_base), 2) AS amt
        FROM processing_cost_entries
        WHERE run_id = p_run_id AND deleted_at IS NULL
        GROUP BY cost_type
    LOOP
        v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
    END LOOP;

    v_snapshot := jsonb_build_object(
        'capitalized_by_source', v_by_source,
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used,
        -- METAL-2:用的是哪个指数,以及它【是房屋约定而不是条款】。
        -- 读快照的人必须能分清这两件事:这批成本不是"按 LME 结算"的,
        -- 它是"在没有条款可循时,按当时的房屋约定取了 LME 的价"。
        'price_index', v_default_index,
        'price_index_is_house_default', true,
        'skipped_metals', v_skipped_metals
    );

    -- 9c(FIN-25):不完整成本标记 —— 任何投料无价、或上游产出自己就带着标记,
    --    本单全部产出打上 cost_incomplete。零永不静默,层层传染;上游补分摊后
    --    本单过期(状态视图第三支),重跑即清。
    UPDATE processing_outputs
    SET cost_incomplete = (v_inputs_without_price > 0 OR v_upstream_incomplete)
    WHERE run_id = p_run_id;

    -- FIN-36c:告诉基准触发器"这次基准变动是【跟着重分摊一起发生的】,不是漂移"。
    -- 与年结用 evoltrya.close_ctx 穿过期间锁是同一个惯用法(post_journal_entry)。
    -- 【为什么不靠时间戳判断】now() 是事务时间:同一个事务里两次分摊拿到相同的
    -- allocated_at,任何"看 allocated_at 变没变"的判据都会失效(fixture 就在一个
    -- 事务里跑)。显式的上下文标记不受事务边界影响。
    PERFORM set_config('evoltrya.alloc_ctx', '1', true);

    UPDATE processing_runs
    SET material_cost_base   = round(v_material, 2),
        process_cost_base    = round(v_process, 2),
        total_cost_base      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- 标记只覆盖上面那一条 UPDATE:同一事务里【之后】的裸改基准仍算漂移
    PERFORM set_config('evoltrya.alloc_ctx', '', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- 10a.【FIN-24:首挂全额,此后差额 —— 不再全额冲销重挂】
    -- 旧实现重述资本化(1220 按新价整体改写)而已过账 COGS 从不重述:卖掉份额的
    -- 价差留在库存里,卖得越多错得越多;材料价差贷 1200,而 reprice 早把已耗份额
    -- 记进了 5000 —— 两处叠加 = 重复计数 + 1200 变负(实测:100kg@1 全耗、重定价
    -- 到 2、重分摊 → 1220=200 但 5000 多挂 100、1200=−100)。
    -- 差额法(与重估/折旧同形):目标 − 已记录,只过差额,第二次跑为零。
    --   * 每个产出批按【自己】的处置比例拆(Part B:一炉多批、各卖各的):
    --       在库 + 已售未挂COGS → 1220(后者价值仍躺在 1220,10b 随后按新单位成本解除)
    --       已售已挂COGS       → 5000(COGS 补差)
    --       注销/盘亏           → 5200(处置在产出粒度可知,注销总额是运营信号,
    --                              不并进材料成本 —— Tim 的裁定,推翻了与 reprice
    --                              一致性的论证;reprice 在进料粒度分不出注销与
    --                              耗用、整体进 5000 的不精确,另记 known-issues)
    --   * 贷方:材料差额 → 5000(reprice 把已耗价差停在那里;5000 同时是 COGS
    --     科目,已售份额的借方与之同户恰好互抵 —— 这一巧合是本设计的支点);
    --     费用差额 → 各自成本科目(fin_cost_account)。
    --   * 产出批喂回再加工在 schema 上【不可表示】(processing_inputs 只指
    --     inbound_batches)—— 处置只有在库/已售/注销三种。粉线大概率多段加工,
    --     真建了再加工必须先扩这套拆分(known-issues 有账)。
    -- ════════════════════════════════════════════════════════════════════════
    v_rec_total := COALESCE(v_run.capitalized_cost_base, 0);
    IF v_run.capitalization_entry_id IS NOT NULL THEN
        SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
        IF v_cap_status <> 'posted' THEN
            -- 资本化分录被人工冲销:存量"已记录"与总账已分道,差额法的基准不再可信。
            -- 这是【唯一】剩下的红色情形:人工冲销是人做的决定,修复也该是人工分录。
            RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
        END IF;
    END IF;

    IF v_run.capitalization_entry_id IS NULL THEN
        -- ── 首挂:全额资本化(原路径)────────────────────────────────────────
        v_cap_lines := '[]'::jsonb;
        v_cap_total := 0;
        IF round(v_material_in, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_in, 2));
            v_cap_total := v_cap_total + round(v_material_in, 2);
        END IF;
        -- FIN-25:再加工材料 —— 解除的是上游产出的 1220,不是原料的 1200。
        -- 同科目 Dr(资本化进本单产出)/Cr(解除上游)两腿并存,净额即增量。
        IF round(v_material_re, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_re, 2), 'line_memo', 're-processed input relieved');
            v_cap_total := v_cap_total + round(v_material_re, 2);
        END IF;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
            FROM processing_cost_entries
            WHERE run_id = p_run_id AND deleted_at IS NULL
            GROUP BY cost_type
            ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF v_cap_total <> 0 THEN
            v_cap_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1220',
                                   'side', CASE WHEN v_cap_total > 0 THEN 'debit' ELSE 'credit' END,
                                   'currency', base_currency_code(), 'amount_ccy', abs(v_cap_total))
            ) || v_cap_lines;
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Capitalize ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = v_cap_total,
            capitalization_entry_id = v_cap_entry_id
        WHERE id = p_run_id;
    ELSE
        -- ── 差额路径 ─────────────────────────────────────────────────────────
        -- 已记录的各来源:优先 snapshot(FIN-24 起写入);老单从已过账的资本化
        -- 分录行反推 —— 1200 行 = 材料,5xxx 行按 fin_cost_account 的反向映射。
        v_rec_src := v_run.allocation_snapshot->'capitalized_by_source';
        IF v_rec_src IS NULL THEN
            SELECT COALESCE(jsonb_object_agg(q.src, q.amt), '{}'::jsonb) INTO v_rec_src FROM (
                SELECT CASE a.code
                           WHEN '1200' THEN 'material'
                           WHEN '5100' THEN 'labour'
                           WHEN '5110' THEN 'electricity'
                           WHEN '5120' THEN 'gas'
                           WHEN '5130' THEN 'depreciation'
                           WHEN '5140' THEN 'consumables'
                           WHEN '5150' THEN 'waste_treatment'
                           WHEN '5190' THEN 'other'
                       END AS src,
                       round(SUM(jl.credit) - SUM(jl.debit), 2) AS amt
                FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
                WHERE jl.entry_id = v_run.capitalization_entry_id AND a.code <> '1220'
                GROUP BY a.code) q
            WHERE q.src IS NOT NULL;
        END IF;

        -- 贷方:逐来源差额。材料 → 5000(不是 1200!—— reprice 已把已耗价差记在
        -- 5000,这里把属于未售产出的部分从 5000 拨进 1220,双方不再叠加);
        -- 费用 → 各自成本科目。负差翻借方。
        v_cap_lines := '[]'::jsonb;
        v_cred_total := 0;
        FOR v_ct IN
            SELECT key AS src, (v_by_source->>key)::numeric - COALESCE((v_rec_src->>key)::numeric, 0) AS d
            FROM jsonb_object_keys(v_by_source) AS key
            UNION
            SELECT key, 0 - (v_rec_src->>key)::numeric
            FROM jsonb_object_keys(v_rec_src) AS key
            WHERE v_by_source->>key IS NULL
            ORDER BY 1
        LOOP
            IF v_ct.d <> 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object(
                    'account_code', CASE WHEN v_ct.src IN ('material', 'material_reprocessed') THEN '5000' ELSE fin_cost_account(v_ct.src) END,
                    'side', CASE WHEN v_ct.d > 0 THEN 'credit' ELSE 'debit' END,
                    'currency', base_currency_code(), 'amount_ccy', abs(v_ct.d),
                    'line_memo', 'allocation delta: ' || v_ct.src);
                v_cred_total := v_cred_total + v_ct.d;
            END IF;
        END LOOP;

        -- 借方:逐产出批的差额,按该批自己的处置比例拆
        FOR v_leg IN
            SELECT po.output_batch_id, po.quantity_produced AS qty,
                   po.allocated_cost_base AS new_alloc,
                   COALESCE((v_prior->>po.output_batch_id::text)::numeric, 0) AS old_alloc,
                   ob.remaining_qty,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NOT NULL), 0) AS sold_cogs,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NULL), 0) AS sold_nocogs,
                   -- FIN-25 第四处置:被下游加工消耗的份额 → 5000 停车
                   --(与 reprice 对已耗进料完全同构:下游过期后重跑,其材料差额
                   -- 贷 5000 收回停车 —— 传导靠既有过期旗逐级走,不递归)
                   COALESCE((SELECT SUM(pi2.quantity_consumed) FROM processing_inputs pi2
                             WHERE pi2.output_batch_id = po.output_batch_id), 0) AS consumed_proc
            FROM processing_outputs po
            JOIN output_batches ob ON ob.id = po.output_batch_id
            WHERE po.run_id = p_run_id
        LOOP
            v_delta := round(v_leg.new_alloc - v_leg.old_alloc, 2);
            IF v_delta = 0 OR v_leg.qty = 0 THEN CONTINUE; END IF;
            v_other := GREATEST(0, v_leg.qty - v_leg.remaining_qty - v_leg.sold_cogs - v_leg.sold_nocogs - v_leg.consumed_proc);
            v_l1220 := round(v_delta * (v_leg.remaining_qty + v_leg.sold_nocogs) / v_leg.qty, 2);
            v_l5000 := round(v_delta * (v_leg.sold_cogs + v_leg.consumed_proc) / v_leg.qty, 2);
            -- 5200 取残差,保证三桶之和恰等于该批差额
            v_d1220 := v_d1220 + v_l1220;
            v_d5000 := v_d5000 + v_l5000;
            v_d5200 := v_d5200 + (v_delta - v_l1220 - v_l5000);
        END LOOP;

        -- 强制配平:Σ借(三桶)与 Σ贷(逐来源)各自取整后可差一两分 ——
        -- 差额并进 1220 桶(金额最大、且是"目标状态"侧,与 8+9 步的
        -- largest-share-absorbs 同一习惯)。
        v_deb_total := v_d1220 + v_d5000 + v_d5200;
        v_d1220 := v_d1220 + round(v_cred_total - v_deb_total, 2);

        IF v_d1220 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '1220',
                'side', CASE WHEN v_d1220 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d1220),
                'line_memo', 'in-stock share')) || v_cap_lines;
        END IF;
        IF v_d5000 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5000',
                'side', CASE WHEN v_d5000 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5000),
                'line_memo', 'sold/consumed share — COGS catch-up / re-processing park')) || v_cap_lines;
        END IF;
        IF v_d5200 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5200',
                'side', CASE WHEN v_d5200 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5200),
                'line_memo', 'written-off share')) || v_cap_lines;
        END IF;

        -- 幂等出口:没有任何差额 → 不过账(allocated_at 照常刷新,过期标记消除)
        IF jsonb_array_length(v_cap_lines) > 0 THEN
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Re-allocation delta ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            -- 差额分录记进 snapshot 的留痕数组;capitalization_entry_id 仍指首挂
            v_snapshot := v_snapshot || jsonb_build_object('delta_entry_ids',
                COALESCE(v_run.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)
                    || to_jsonb((v_cap_je->>'entry_id')::text));
            UPDATE processing_runs SET allocation_snapshot = v_snapshot WHERE id = p_run_id;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = round(v_rec_total + v_cred_total, 2)
        WHERE id = p_run_id;
    END IF;

    -- 10b. cut 2a:COGS 补挂 —— 只补此前无 COGS 分录的销售(cogs_entry_id IS NULL),
    --      用最新 unit_cost_base,按各自原 sale_date(撞期间锁则 PERIOD_LOCKED 直接抛出)。
    --      已挂 COGS 不追溯重述(标准成本式简化;重述属人工冲销决策)。
    FOR v_sale IN
        SELECT sr.id, sr.quantity, sr.sale_date, ob.code AS batch_code, po.unit_cost_base
        FROM sales_records sr
        JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = p_run_id
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        WHERE sr.cogs_entry_id IS NULL
        ORDER BY sr.sale_date, sr.created_at
    LOOP
        v_cogs := round(v_sale.quantity * v_sale.unit_cost_base, 2);
        IF v_cogs <> 0 THEN
            v_cogs_je := post_journal_entry(
                v_sale.sale_date,
                'COGS ' || v_sale.batch_code,
                'sale', v_sale.id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_cogs_je->>'entry_id')::uuid WHERE id = v_sale.id;
        END IF;
    END LOOP;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_base', round(v_material, 2),
        'process_cost_base', round(v_process, 2),
        'total_cost_base', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$;

-- ── 4 · 第七过期源(A5:不可省)────────────────────────────────────────────────
-- 【CREATE OR REPLACE,不是 DROP + CREATE】public.operations_now 依赖这张视图,
-- DROP 会连它一起要求 CASCADE,而 CASCADE 会把那张视图悄悄重建成【本迁移没有
-- 写过的样子】。列清单一个字没变,所以 REPLACE 是可行的,也是唯一安全的那条路。
CREATE OR REPLACE VIEW public.processing_run_allocation_status WITH (security_invoker = off) AS
 SELECT r.id AS run_id,
    r.code,
    r.allocated_at,
    c.last_cost_change,
    r.allocated_at IS NOT NULL AND c.last_cost_change IS NOT NULL AND c.last_cost_change > r.allocated_at AS is_stale,
    COALESCE(g.cogs_posted, 0::bigint) AS cogs_posted,
    r.capitalization_entry_id IS NULL OR je.status = 'posted'::text AS safe_to_reallocate
   FROM processing_runs r
     LEFT JOIN journal_entries je ON je.id = r.capitalization_entry_id
     LEFT JOIN LATERAL ( SELECT max(x.ts) AS last_cost_change
           FROM ( SELECT GREATEST(e.created_at, e.updated_at) AS ts
                   FROM processing_cost_entries e
                  WHERE e.run_id = r.id
                UNION ALL
                 SELECT fa.created_at
                   FROM freight_allocations fa
                     JOIN freight_documents fd ON fd.id = fa.freight_document_id
                     JOIN processing_inputs pif ON pif.inbound_batch_id = fa.inbound_batch_id
                  WHERE pif.run_id = r.id AND fd.deleted_at IS NULL AND fd.status = 'posted'::text
                UNION ALL
                 SELECT ph.created_at
                   FROM price_history ph
                     JOIN processing_inputs pi ON pi.inbound_batch_id = ph.inbound_batch_id
                  WHERE pi.run_id = r.id
                UNION ALL
                 SELECT r2.allocated_at
                   FROM processing_inputs pi2
                     JOIN processing_outputs po2 ON po2.output_batch_id = pi2.output_batch_id
                     JOIN processing_runs r2 ON r2.id = po2.run_id
                  WHERE pi2.run_id = r.id AND r2.allocated_at IS NOT NULL
                UNION ALL
                 SELECT GREATEST(obm.created_at, obm.updated_at) AS ts
                   FROM processing_outputs po6
                     JOIN output_batch_metals obm ON obm.output_batch_id = po6.output_batch_id
                  WHERE po6.run_id = r.id AND r.allocation_basis = 'metal_value'::text
                UNION ALL
                -- PROC-COST-1:【第七过期源 —— 迟到的加工成本资本化】
                -- 一张状态改变型加工单(放电)把成本挂到某批进料上,而那批料
                -- 【可能已经被这张单吃掉了】。不在这里的话,吃过它的单永远不标过期,
                -- batch_margin 停在放电之前那个数,而放电那张分录本身完全正确 ——
                -- 这是本仓库最坏的失败形状:每一笔都对,总数错。
                -- FRT-1 把漏掉同构的那一臂称作"本刀的头号缺陷";这里不重犯。
                -- 【排除自己】bpca.run_id <> r.id:否则放电单会在分摊完成的那一刻
                -- 把自己标成过期,而它刚刚才算完 —— 一面永远举着的旗等于没有旗。
                 SELECT bpca.created_at
                   FROM batch_processing_cost_allocations bpca
                     JOIN processing_runs rsrc ON rsrc.id = bpca.run_id
                     JOIN processing_inputs pif7 ON pif7.inbound_batch_id = bpca.inbound_batch_id
                  WHERE pif7.run_id = r.id
                    AND bpca.run_id <> r.id
                    AND rsrc.deleted_at IS NULL AND rsrc.status = 'committed'::text
                UNION ALL
                 SELECT r.allocation_basis_changed_at AS ts) x) c ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS cogs_posted
           FROM sales_records sr
             JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = r.id
          WHERE sr.cogs_entry_id IS NOT NULL) g ON true
  WHERE r.deleted_at IS NULL AND has_permission('module.processing.view'::text);
GRANT SELECT ON public.processing_run_allocation_status TO authenticated;

-- ── 5 · 回滚解除资本化(A3:台账与分录在同一个地方一起解除)────────────────────
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
    v_sc_cap uuid;          -- PROC-COST-1:状态改变型的资本化分录
    v_sc_kind boolean;
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
    -- PROC-COST-1:【状态改变型 —— 解除资本化,台账与分录在同一个地方一起解除】
    -- 台账行由 batch_processing_cost_base 按本单的 deleted_at 自动排除(形状免费
    -- 提供的那一半),分录必须显式冲销 —— 两半都在这里发生,所以它们【永远不会
    -- 各说各话】。少做任何一半:要么成本留在 1200 上而单已经没了(账挂在一张不
    -- 存在的单上),要么台账清了而 1200 虚高。
    -- 【只管状态改变型】转化型的资本化分录在回滚时的处置是【本刀之前就有的行为】,
    -- 本刀不碰它 —— 那是另一条独立的判断,记在 docs/proc-cost-capitalisation.md。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT NOT k.produces_outputs INTO v_sc_kind
      FROM processing_runs pr
      JOIN operation_types ot ON ot.code = pr.operation_type_code
      JOIN operation_kinds k ON k.code = ot.kind_code
     WHERE pr.id = p_run_id;

    IF COALESCE(v_sc_kind, false) THEN
        SELECT capitalization_entry_id INTO v_sc_cap FROM processing_runs WHERE id = p_run_id;
        IF v_sc_cap IS NOT NULL
           AND (SELECT status FROM journal_entries WHERE id = v_sc_cap) = 'posted' THEN
            PERFORM reverse_journal_entry_internal(v_sc_cap, CURRENT_DATE,
                'Rollback ' || COALESCE((SELECT code FROM processing_runs WHERE id = p_run_id), '?'));
        END IF;
        UPDATE processing_runs
           SET capitalization_entry_id = NULL, capitalized_cost_base = 0
         WHERE id = p_run_id;
    END IF;


    PERFORM set_config('evoltrya.movement_ctx', '', true);   -- 用毕即清(同 commit)
END;
$function$;

-- ── 5b · 那道守卫功成身退 ────────────────────────────────────────────────────
-- guard_allocation_not_state_changing 的全部内容就是"这条路还没有去处,所以按名
-- 拒绝"。去处建好了,它就没有可守的东西了。【留着比删掉更坏】:一个永远不被调用
-- 的守卫,读起来像是还有一道闸在那里。
DROP FUNCTION IF EXISTS public.guard_allocation_not_state_changing(uuid);

-- ── 6 · R4:鼓包漏液走整电池粉料线,与损坏料同一处置 ──────────────────────────
-- 【这一行就是那张表的表注在等的裁定】它写着:"于是这种料今天没有路线,那是刻意的,
-- 它等 Tim 的一句裁定,不等一个猜测。" 裁定到了。
-- 【与 damaged_deformed 完全同形】resolves = false:粉料线把料【粉碎掉】,
-- 不是把鼓包治好 —— 状态不是被解决的,是那批料不再作为整包存在了。
-- 【鼓包与漏液不拆成两个状态】Tim 已定:同一处置,一个取值。
INSERT INTO public.operation_type_safety_states (operation_type_code, safety_state_code, resolves, notes) VALUES
    ('battery_powder_line', 'swollen_leaking', false,
     '【R4,PROC-COST-1】Tim 裁定:鼓包与漏液同一处置,走整电池粉料线,与 damaged_deformed 同形。不解决 —— 料被粉碎掉了,不是被治好了。【深度放电仍然不受理它】:放电机解决不了起火风险(fixture 159 F3 钉着那一条)。');

-- 表注更新:它原本写着"为什么 swollen_leaking 一道工序都没有受理"。裁定到了,
-- 那一段必须跟着改 —— 一份说着已经不成立的话的文档,比没有文档更坏。
COMMENT ON TABLE public.operation_type_safety_states IS
'PROC-WIRE-1B-i:这道工序【受理】哪些安全状态。**这张表是那个死锁的解。**

【它与 may_be_fed 的关系,一句话说清】may_be_fed 是【没有工序类型时】的答案,
也就是今天的行为;一旦加工单说出了自己是哪道工序,答案就换成这张表。

【不变式:只许收紧,不许默认放宽】
  * 没有工序类型 → may_be_fed,行为一个字不变;
  * 有工序类型 → **只有这张表里明写的才受理,没写的一律拒**,
    哪怕它 may_be_fed = true。
声明一道工序只会把闸收紧;任何放宽都必须是这里的一行【明写的数据】。
**"设了工序就放行"的实现,在 fixture 里是红的。**

【PROC-COST-1(R4):鼓包漏液已经有路线了】此前这里写着"swollen_leaking 一道工序
都没有受理……它等 Tim 的一句裁定"。裁定到了:**鼓包与漏液同一处置,走整电池粉料线**,
与 damaged_deformed 同形(resolves = false —— 料被粉碎掉,不是被治好)。
**深度放电仍然不受理它**:放电机解决不了起火风险。
加这一行是【逐工序的、明写的放宽】,那正是不变式允许的唯一放宽方式;
"按 kind 放行"的实现在 fixture 159 F2/F3 里仍然是红的。

【今天仍然一道工序都不受理的是 water_exposed(进过水)】那不是遗漏,是同一条
处置:它可能在干燥后可投,而那是一个判断,等一次裁定,不等一个猜测。';

COMMIT;
