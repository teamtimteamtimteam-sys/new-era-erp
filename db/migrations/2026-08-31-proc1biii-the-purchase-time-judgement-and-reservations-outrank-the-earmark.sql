-- PROC-1B-iii(2026-08-31):采购时的那个判断 · 而客户的承诺压过工序指定
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【一刀两件事,它们【没有】逻辑联系 —— 这句话写在这里,免得下一个人去找】
-- 件一动 purchasing × inbound,件二动 processing × sales;不共用一行代码、
-- 一张表、一份 fixture。合成一刀的理由是【运维上的】,不是逻辑上的:
-- 两件都小,而备份是这里最贵的一步(见 AGENTS.md 的备份判据),
-- 分两刀要付两次备份、两次门、两个窗口、两段破窗期。
-- ★ 不要从"它们在同一支迁移里"推出它们有关系。它们没有。★
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【两条被删掉的前提 —— 本刀的任务书自己写错了,改正记在这里】★★
--
-- 【错 1:"今天这个冲突只在发货时才浮出来,太晚了"】—— 不成立,实测。
--   sales_order_reservations 上挂着 trg_so_reservations_form_saleable
--   (BEFORE INSERT → guard_batch_form_saleable → assert_output_batch_saleable),
--   另有三个同胞挂在 quote_lines / sales_order_lines / sales_records 上。
--   于是【先指定、后预留】这个方向**今天就在预留那一刻按名拒绝**,
--   抛的是 SALE_BATCH_EARMARKED。发货根本不是它落地的地方。
--
-- 【错 2:"镜像用例(先指定、后预留)没有定义"】—— 它不但有定义,
--   而且已经建好、上线、有 fixture(166)钉着。
--
-- ★【真正的缺口是【单向】的,而本刀只补那一个方向】★
--     先指定 → 后预留:**今天就拒**(SALE_BATCH_EARMARKED,不动它一个字);
--     先预留 → 后指定:**今天悄悄成功** ← 这一条,且只有这一条,是本刀补的。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【Tim 的裁定 R4 是【有方向的】—— 不是一条对称的排序】
--   "客户的承诺压过工序指定" 与 "要许货给客户,先把工序指定释放掉" 是
--   **同一条排序**;差别只在于【释放这个动作由谁做】,而 Tim 裁定:**由操作员做。**
--   于是既有的那条拒绝原样留着 —— 一个悄悄毁掉一项没人同意毁掉的安排的系统,
--   比一句响亮的、带一步旁路的拒绝更坏。那条拒绝自己的 HINT 就是操作员
--   学到这条排序的地方。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【件二 · 部分预留:整批拒,不在"未预留的余量"上放行】—— 这是一个裁定,写下来
--   判据不是保守,是【今天的模型说不出那句话】:
--   purpose_code 是 output_batches 上的【一个列,作用于整批】。**没有部分指定
--   这种东西**,也没有子批模型(它是明确挂起的:写销分母那一条在等它)。
--   于是"在余量上放行"落到库里只能是【把整批】翻成非可售 —— 连同已经许给客户
--   的那一部分。而那一部分接着会被 assert_output_batch_saleable 拦在发货门外:
--   ★ 一个"部分放行"会把一句【守住了的承诺】变成一句【毁约】★ ——
--   那正是 R4 存在要防的东西。
--   整批拒是今天的数据模型唯一说得诚实的答案。旁路与镜像侧同一条:
--   把预留释放掉(将来子批模型落地了,就是把批拆开),再指定。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 件一 · 采购时的那个判断
-- ════════════════════════════════════════════════════════════════════════════

-- 【为什么是字典表,不是 boolean】"能不能深度放电"看着是二值的,而在【路由】
-- 那一刻它是三值的,三个值对应三个不同的下一步动作。可空 boolean 装得下三个值,
-- 但它把【两种缺席】压成同一个 NULL,而它们是两件不同的事 —— 见列注释。
-- 这个仓库为这件事付过账:materials.may_be_processed 是可空 boolean,
-- 于是"没人裁定过"只好写在散文里(known-wrong-until-cutover.md 那两批计价库存)。
CREATE TABLE public.deep_discharge_judgements (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    -- 【规则列,而且它【有消费者】】grn_discrepancies 拿它决定"这一侧算不算
    -- 一次主张"。没有它,那张视图就得把 'not_assessed' 这个字面量写死在
    -- CASE 里 —— 而这个仓库对写死阈值有一条成文的规矩(见 grn_discrepancies
    -- 抬头【阈值一个都没写死】)。
    -- ★【它不是一个没人读的列】★ 加一列没人读的东西,会教下一个人
    --   "这件事已经在管了" —— 见 inbound_safety_states 抬头对"存放要求"的处置。
    is_a_claim boolean NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.deep_discharge_judgements IS
'PROC-1B-iii:【这批料能不能深度放电】—— 一个在【采购时】做出的判断。
RUNTIME CONFIG,加一种是加一行(与 inbound_safety_states / output_batch_purposes 同形)。

★【三个值各自路由到哪里 —— 这是本表存在的理由,不是装饰】★
  · can          → 【深度放电】(专用设备)→ 人工拆解 → 电芯 → …
  · cannot       → 【整电池粉料线】(旁路;它与极片粉料线是两台设备,两道工序)
  · not_assessed → **不可路由。** 没有人看过,而【你不许照着一个猜测去路由】。

★★【"没评估"是一个【记下来的事实】,不是一个空值】★★
两种缺席,而它们是【两件不同的事】,不许压成同一个 NULL:
  · 列上是 NULL     = **这一行比这条轴还老。** 不回填,不拦人。
  · not_assessed 这一行 = **有人打开了表单,并且没有下判断。** 那是一个
    positive 的、被记下来的事实,它必须存得下。
把两者并成一个可空 boolean,正是 materials.may_be_processed 走过的路:
最后要靠散文去解释线上那两批计价库存的 NULL 是什么意思。
★【一个没设的判断,永远不许被读成"不能"】★ —— 字典让这句话是【结构性的】,
而不是一条要靠人记着的约定。

【它与 inbound_safety_states 是【两条轴】,不是同一条 —— 这一段是刻意写下来的】
  · inbound_safety_states 答【状态】:这批料现在放没放电(charged_not_discharged /
    discharged_verified)。**那条轴是起火闸读的**(guard_processing_input)。
  · 本表答【能力】:这批料【压根能不能】放电。
两者【不是同一个事实记两遍】,证据就在 operation_type_safety_states 里:
整电池粉料线【受理 charged_not_discharged 而【不】解决它】—— 因为它专收
【放不了电】的料。也就是说"带电"与"放得了电"必须能同时说出口,
而且组合起来指向不同的产线:
    带电 + 能放电   → 深度放电线
    带电 + 放不了电 → 整电池粉料线
★【为什么"实际"不做成 inbound_safety_states 的一行】★ 那会把【能力】搬到
【起火闸读的那条状态轴】上,于是同一件事有了第二种说法 —— 而"一个事实两个来源"
正是这个仓库反复付账的那一类缺陷。**同一本字典让两侧可比;不同的表让能力轴
离起火闸远远的。**';

COMMENT ON COLUMN public.deep_discharge_judgements.is_a_claim IS
'PROC-1B-iii:这个取值【算不算一次主张】。
can / cannot = true(它们各自主张了一件事);not_assessed = false(它什么都没主张)。

【谁读它】grn_discrepancies:一次差异需要【两次互相矛盾的主张】,
而"我没看"不是一次主张 —— 于是任何一侧不是主张时,差异是 NULL,不是 true。
与 assay_beyond_tolerance 在任一侧缺失时给 NULL 是同一条,只是取值集合更宽。

【它让"以后加第四个值"真的只是加一行】比如 can_with_precautions:
is_a_claim = true,视图当场就把它算进比较里,一行代码都不用改。';

INSERT INTO public.deep_discharge_judgements (code, name_en, name_zh, is_a_claim, sort_order, notes) VALUES
    ('can', 'Can be deep-discharged', '可深度放电', true, 1,
     '路由到【深度放电】。这是主线:放电 → 人工拆解到模组 → 模组拆解到电芯 → 开壳 → 极片分离。'),
    ('cannot', 'Cannot be deep-discharged', '不可深度放电', true, 2,
     '路由到【整电池粉料线】(旁路)。放不了电的整包 / 模组 / 3C 电池走这里 —— '
     || '而它与极片粉料线是【两台不同的设备】,因此是两道工序,不是一道。'),
    ('not_assessed', 'Not assessed', '未评估', false, 3,
     '**有人打开了表单,并且没有下判断** —— 这是一个记下来的事实,不是一个空值。'
     || '【不可路由】:你不许照着一个猜测去路由。它与列上的 NULL(这一行比这条轴还老)'
     || '是两件不同的事,而这正是本表不做成可空 boolean 的全部理由。');

ALTER TABLE public.deep_discharge_judgements ENABLE ROW LEVEL SECURITY;
-- 【目录不敏感】与 inbound_safety_states / material_kinds / waste_classifications 同一处置。
CREATE POLICY "deep_discharge_judgements select all"
    ON public.deep_discharge_judgements AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "deep_discharge_judgements write by permission"
    ON public.deep_discharge_judgements AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.deep_discharge_judgements TO authenticated;

-- ── R1:判断挂在【采购行】上 ────────────────────────────────────────────────
ALTER TABLE public.purchase_order_lines
    ADD COLUMN deep_discharge_judgement_code text
        REFERENCES public.deep_discharge_judgements (code);

COMMENT ON COLUMN public.purchase_order_lines.deep_discharge_judgement_code IS
'PROC-1B-iii(R1):【采购时】做出的那个判断 —— 这批料能不能深度放电。

★【为什么在采购行上,而不是在进料批上】★ 因为**这个判断是在买的时候做出的,
在货到之前** —— 那一刻【进料批还不存在】。这不是把它放在方便的地方,
是放在它真正发生的地方。仓库里已有同一个理由的先例:work_order_lines
按【物料】排产而不按批次,写的也是"排产的时候那个批次常常还不存在"。

【NULL = 这一行比这条轴还老】不回填,不拦人。**要记"看过了但没下判断",
用字典里的 not_assessed —— 那是一个 positive 的事实,不是一个空值。**
★ 一个没设的判断【永远不许被读成"不能"】★。

【R3:它【不拦】收货】这个判断影响的是【怎么路由】,不是【收不收货】——
它不是在门口拒收的理由。receive_inbound_batch_against_po 一个字都没为它改过,
而 fixture 168 把这件事钉住了:一张收货,实际与判断【矛盾】,仍然成功。';

-- ── R2:实际到的货记在【进料批】上 ──────────────────────────────────────────
ALTER TABLE public.inbound_batches
    ADD COLUMN deep_discharge_actual_code text
        REFERENCES public.deep_discharge_judgements (code);

COMMENT ON COLUMN public.inbound_batches.deep_discharge_actual_code IS
'PROC-1B-iii(R2):**实际到的货**能不能深度放电 —— 到货后看过之后记下的。

★【两个值都活着,谁也不覆盖谁】★ 采购行上的判断(purchase_order_lines.
deep_discharge_judgement_code)不因为这里记了一个值就被改写,反之亦然。
**两者不一致必须看得见** —— 那正是 Tim 拿去跟供应商谈的东西。
差异由 grn_discrepancies 报(kinds 里的 deep_discharge_contradicted),
【不另起一套机制】:expected_assay vs 实际化验、declared_qty vs quantity,
仓库里这个"预期 vs 实际"的形状已经有两份了,本条跟其中一份走。

★★【它【不是】安全状态那条轴上的东西 —— 两半理由都写在这里】★★
  ① **同一本字典**(deep_discharge_judgements)让采购侧与到货侧【可比】——
     两侧取值集合不同,那个比较就没有意义。
  ② **不同的表**让【能力轴】离【起火闸】远远的。inbound_batch_safety_states
     答的是"这批料现在放没放电"(状态),guard_processing_input 读它;
     本列答的是"这批料压根能不能放电"(能力)。把本列做成 safety_states 的一行,
     就等于给同一件事造了第二种说法 —— 而那是这个仓库反复付账的那一类缺陷。
  证据:整电池粉料线【受理 charged_not_discharged 却不解决它】,因为它专收
  【放不了电】的料。带电+能放电 → 放电线;带电+放不了电 → 电池粉料线。
  两条轴必须能同时说话。

【NULL = 这一行比这条轴还老】不回填。要记"看过了但说不上来",用 not_assessed。';

-- ════════════════════════════════════════════════════════════════════════════
-- 件一 2c · 差异走 grn_discrepancies,【不另起一套机制】
--
-- 【为什么扩这张视图,比另开一对列/一套读法更便宜 —— 这是量过的,不是偏好】
--   本视图的 FROM 里【已经同时握着这次比较要用的两侧】:pol(采购行,判断在
--   那儿)与 b(进料批,实际在那儿)。于是扩它的代价是:两个 LEFT JOIN 到字典、
--   三列、kinds 里一个分支。**零新表、零新 RLS、零新权限裁定、零新屏幕**
--   —— 差异页(app/purchasing/discrepancies)本来就在渲染 kinds。
--   另起一对列/一套读法则要重新裁一次【跨模块属主权限】(inbound × purchasing,
--   OPS-14 的 xmodule 陷阱 —— 这张视图已经踩过并写下了处置),外加一个屏幕、
--   一份 i18n。**严格更贵,而且它正是任务书禁止的"第二套差异机制"。**
--
-- 【NULL-when-missing 对【这次】比较也是对的,而且理由更强】
--   一次差异需要【两次互相矛盾的主张】。"我没看"不是一次主张。
--   于是任一侧 NULL(比轴还老)【或】任一侧 not_assessed(看了没判)时,
--   deep_discharge_contradicted 是 NULL —— 不是 false,更不是 true。
--   判据由 is_a_claim 这个列回答,**不由视图里写死的字面量回答**。
--
-- ★【"未评估 vs 不能" 与 "没设 vs 不能" 必须分得开 —— 而它们的布尔值一样】★
--   两者的 contradicted 都是 NULL。所以【分辨力不能来自那个布尔】,
--   它来自视图【同时把两侧的原始码露出来】:
--       deep_discharge_judged / deep_discharge_actual
--   没设 → NULL;看了没判 → 字面量 'not_assessed'。屏幕上是两个不同的字。
--   **一个只露布尔的视图会把这两件事变成同一件,那正是本刀在别处拒绝做的事。**
-- ════════════════════════════════════════════════════════════════════════════

-- ★【它有一个下游视图 —— 必须一并落下再原样建回来】★
-- supplier_receipt_pattern(GRN-2)读 grn_discrepancies("短交的定义只有一处"),
-- 于是 PostgreSQL 不许直接 DROP 上游。
-- 【为什么不 CASCADE】CASCADE 会把下游【删掉就算完】,建不建回来全靠人记得 ——
-- 而那正是这个仓库反复付账的形状。这里显式落、显式建回,建回来的是
-- db/views/supplier_receipt_pattern.sql 的【逐字副本,一个字没改】:
-- 它与本刀无关,只是挡在路上。实测它自己没有下游(pg_depend 查过,零行)。
DROP VIEW public.supplier_receipt_pattern;
DROP VIEW public.grn_discrepancies;

CREATE VIEW public.grn_discrepancies WITH (security_invoker = off) AS
 WITH cfg AS (
         SELECT receiving_settings.grn_short_pct,
            receiving_settings.grn_over_pct,
            receiving_settings.grn_assay_tolerance_pct
           FROM receiving_settings
         LIMIT 1
        ), line_totals AS (
         SELECT ib.purchase_order_line_id AS line_id,
            sum(ib.quantity) AS line_received_qty,
            count(*) AS line_receipt_count
           FROM inbound_batches ib
          WHERE ib.purchase_order_line_id IS NOT NULL AND ib.deleted_at IS NULL
          GROUP BY ib.purchase_order_line_id
        ), applied_assay AS (
         SELECT DISTINCT ON (a.inbound_batch_id) a.inbound_batch_id,
            a.id AS assay_id
           FROM assay_results a
          WHERE a.inbound_batch_id IS NOT NULL AND a.deleted_at IS NULL AND a.applied_at IS NOT NULL
          ORDER BY a.inbound_batch_id, a.applied_at DESC
        ), assay_gap AS (
         SELECT b_1.id AS batch_id,
            bool_or((abs(m.content_pct - e.content_pct) / e.content_pct * 100::numeric) > cfg_1.grn_assay_tolerance_pct) AS beyond,
            count(*) AS metals_compared
           FROM inbound_batches b_1
             JOIN purchase_order_lines pol_1 ON pol_1.id = b_1.purchase_order_line_id
             JOIN applied_assay aa ON aa.inbound_batch_id = b_1.id
             CROSS JOIN cfg cfg_1
             CROSS JOIN LATERAL jsonb_to_recordset(
                CASE
                    WHEN jsonb_typeof(pol_1.expected_assay) = 'array'::text THEN pol_1.expected_assay
                    ELSE '[]'::jsonb
                END) e(metal text, content_pct numeric)
             JOIN assay_result_metals m ON m.assay_result_id = aa.assay_id AND m.metal = e.metal
          WHERE e.content_pct > 0::numeric
          GROUP BY b_1.id
        )
 SELECT b.id AS batch_id,
    b.code AS batch_code,
    b.arrival_date,
    b.supplier_id,
    sup.legal_name AS supplier_name,
    po.id AS po_id,
    po.code AS po_code,
    po.status AS po_status,
    pol.id AS line_id,
    pol.line_no,
    pol.material_id AS ordered_material_id,
    om.code AS ordered_material_code,
    b.material_id AS received_material_id,
    rm.code AS received_material_code,
    pol.quantity AS ordered_qty,
    pol.unit AS ordered_unit,
    b.quantity AS received_qty,
    b.unit AS received_unit,
    b.declared_qty,
    round(lt.line_received_qty, 4) AS line_received_qty,
    lt.line_receipt_count,
    round(lt.line_received_qty - pol.quantity, 4) AS line_delta_qty,
    round((lt.line_received_qty - pol.quantity) / pol.quantity * 100::numeric, 2) AS line_delta_pct,
        CASE
            WHEN b.declared_qty IS NULL THEN NULL::numeric
            ELSE round(b.quantity - b.declared_qty, 4)
        END AS declared_delta_qty,
    ag.beyond AS assay_beyond_tolerance,
    ag.metals_compared AS assay_metals_compared,
    -- ── PROC-1B-iii:两侧的【原始码】都露出来 ─────────────────────────────
    -- 【为什么露码而不只露那个布尔】"没设"(NULL)与"看了没判"(not_assessed)
    -- 的布尔都是 NULL —— 分辨力只能来自这两列。见本刀抬头那一段。
    pol.deep_discharge_judgement_code AS deep_discharge_judged,
    b.deep_discharge_actual_code AS deep_discharge_actual,
    -- 【一次差异要两次互相矛盾的主张】任一侧不是主张(NULL 或 not_assessed)
    -- → NULL,不是 false。判据读 is_a_claim,不写死字面量。
    -- (jj.is_a_claim AND ja.is_a_claim 在任一侧为 NULL 时整体为 NULL,
    --  CASE 落到 ELSE;为 false 时同样落到 ELSE。两条路都给 NULL。)
        CASE
            WHEN jj.is_a_claim AND ja.is_a_claim
                THEN (pol.deep_discharge_judgement_code IS DISTINCT FROM b.deep_discharge_actual_code)
            ELSE NULL::boolean
        END AS deep_discharge_contradicted,
    (((((ARRAY[]::text[] ||
        CASE
            WHEN (po.status = ANY (ARRAY['closed'::text, 'cancelled'::text])) AND lt.line_received_qty < (pol.quantity * (1::numeric - cfg.grn_short_pct / 100::numeric)) THEN ARRAY['short'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN lt.line_received_qty > (pol.quantity * (1::numeric + cfg.grn_over_pct / 100::numeric)) THEN ARRAY['over'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN b.declared_qty IS NOT NULL AND b.declared_qty > 0::numeric AND (b.quantity < (b.declared_qty * (1::numeric - cfg.grn_short_pct / 100::numeric)) OR b.quantity > (b.declared_qty * (1::numeric + cfg.grn_over_pct / 100::numeric))) THEN ARRAY['declared_vs_actual'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN b.material_id IS DISTINCT FROM pol.material_id THEN ARRAY['material_mismatch'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN ag.beyond THEN ARRAY['assay_beyond_tolerance'::text]
            ELSE ARRAY[]::text[]
        END) ||
        -- 【PROC-1B-iii】与 material_mismatch 同形:**它是告警,永远不是拒绝。**
        -- CASE 的条件为 NULL 时走 ELSE —— 于是缺一侧【不会】变成一个假阳性。
        CASE
            WHEN jj.is_a_claim AND ja.is_a_claim
                 AND pol.deep_discharge_judgement_code IS DISTINCT FROM b.deep_discharge_actual_code
                THEN ARRAY['deep_discharge_contradicted'::text]
            ELSE ARRAY[]::text[]
        END AS kinds
   FROM inbound_batches b
     JOIN purchase_order_lines pol ON pol.id = b.purchase_order_line_id
     JOIN purchase_orders po ON po.id = pol.purchase_order_id
     JOIN suppliers sup ON sup.id = b.supplier_id
     JOIN materials om ON om.id = pol.material_id
     JOIN materials rm ON rm.id = b.material_id
     JOIN line_totals lt ON lt.line_id = pol.id
     CROSS JOIN cfg
     LEFT JOIN assay_gap ag ON ag.batch_id = b.id
     -- 【LEFT JOIN,不是 JOIN】内连接会让【没记判断的收货行整行消失】——
     -- 那是把"这一行没有这个差异"变成"这一行不存在",而本视图抬头
     -- 已经为同一个错误写过一段(没挂采购行的批次整行缺席)。
     LEFT JOIN deep_discharge_judgements jj ON jj.code = pol.deep_discharge_judgement_code
     LEFT JOIN deep_discharge_judgements ja ON ja.code = b.deep_discharge_actual_code
  WHERE b.deleted_at IS NULL AND po.deleted_at IS NULL AND has_permission('module.purchasing.view'::text);

COMMENT ON VIEW public.grn_discrepancies IS
    'GRN-1a:收货差异,一条【挂了采购行的】收货一行 —— 订量、实收、申报量、三个差额,以及 kinds 点名哪里不对(short / over / declared_vs_actual / material_mismatch / assay_beyond_tolerance / deep_discharge_contradicted)。【三个阈值现读 receiving_settings,一个数都没写死】。
【它活过关单】—— po_receivable_lines 只收 confirmed/receiving,purchase_order_status 在【单】上汇总(一行超一行短可以正好抵成 100%),两个现成读者都在短交刚成为问题的那一刻消失。本视图两者都不做。
【没挂采购行的批次整行缺席,不是一行零】(work_order_fulfilment 的 has_plan 那一条:没估过 ≠ 估了零)。同理 assay_beyond_tolerance 在两侧缺任何一侧时是 NULL 而不是 false,declared_delta_qty 在没记申报量时是 NULL 而不是 0。
【short/over 是采购行级的事实,挂在该行的每一条收货上】:分批到货不该被报成短交,所以两者都比【累计】;而一条 short 出现两次的意思是"这一行短了、它有两次收货",要按行计数请 DISTINCT line_id。short 只在 closed/cancelled 时报(开着的单"少"只是"还没收完"),over 任何状态都报(它当场就占了地方、欠了钱)—— 与 processing_settings 那两个工单阈值逐字同一条。
【material_mismatch 是告警,永远不是拒绝】—— 换料是可以谈成的正当场景;但它必须【被点名】,因为它也正是"谎报货物性质"在技术上的样子。
★【PROC-1B-iii:deep_discharge_contradicted】★ 采购时判断(purchase_order_lines.deep_discharge_judgement_code)vs 实际到货(inbound_batches.deep_discharge_actual_code)。**两个值都活着,谁也不覆盖谁** —— 不一致正是 Tim 拿去跟供应商谈的东西。【它同样是告警,永远不是拒绝】:R3 明令这个判断不拦收货,fixture 168 钉着"实际与判断矛盾的收货仍然成功"。
【一次差异要【两次互相矛盾的主张】】任一侧是 NULL(这一行比这条轴还老)【或】是 not_assessed(看了但没下判断)时,deep_discharge_contradicted 是 **NULL,不是 false,更不是 true** —— 与 assay_beyond_tolerance 同一条,只是取值集合更宽。判据读字典的 is_a_claim 列,**不在视图里写死 ''not_assessed'' 这个字面量**。
★【"未评估 vs 不能" 与 "没设 vs 不能" 分得开,而分辨力【不在那个布尔上】】★ 两者的 contradicted 都是 NULL。所以视图【同时露出两侧的原始码】deep_discharge_judged / deep_discharge_actual:没设是 NULL,看了没判是字面量 ''not_assessed''。屏幕上是两个不同的字。只露布尔会把这两件事并成一件。
【两个字典 LEFT JOIN,不是 JOIN】内连接会让没记判断的收货行【整行消失】,那是把"没有这个差异"变成"不存在"。
【属主权限 + module.purchasing.view】:跨 inbound × purchasing 两个模块,invoker 会让无权那一侧的行被 RLS 静默丢掉、内连接把整行带走,读者得到的是"没有差异"而不是"受限"(OPS-14)。谓词取 purchasing 是因为【订量本来就只在那道门后面】(po_receivable_lines / purchase_order_status 同码),而线上每个持 purchasing.view 的角色都持 inbound.view —— 实测,不放宽任何一行。';

GRANT SELECT ON public.grn_discrepancies TO authenticated;

-- ── 原样建回下游视图(与本刀无关,只是挡在 DROP 的路上)────────────────────
-- db/views/supplier_receipt_pattern.sql 的逐字副本。**一个字都没有改。**
-- 它读 grn_discrepancies 的那三处引用不受本刀影响:本刀只【加】列,没有改名、
-- 没有删列、没有动 kinds 里既有的任何一个取值。
CREATE VIEW public.supplier_receipt_pattern WITH (security_invoker = off) AS
 WITH win AS (
         SELECT 180 AS window_days
        ), cfg AS (
         SELECT receiving_settings.grn_short_pct,
            receiving_settings.grn_over_pct,
            receiving_settings.grn_assay_tolerance_pct
           FROM receiving_settings
         LIMIT 1
        ), d AS (
         SELECT g.batch_id,
            g.batch_code,
            g.arrival_date,
            g.supplier_id,
            g.line_id,
            g.line_delta_qty,
            g.kinds
           FROM grn_discrepancies g
             CROSS JOIN win w_1
          WHERE g.arrival_date IS NOT NULL AND g.arrival_date >= (CURRENT_DATE - w_1.window_days)
        ), receipt_agg AS (
         SELECT d.supplier_id,
            count(*) AS comparable_receipts,
            count(*) FILTER (WHERE 'short'::text = ANY (d.kinds)) AS short_receipts,
            count(*) FILTER (WHERE 'over'::text = ANY (d.kinds)) AS over_receipts,
            count(*) FILTER (WHERE 'declared_vs_actual'::text = ANY (d.kinds)) AS declared_vs_actual_receipts,
            count(*) FILTER (WHERE 'material_mismatch'::text = ANY (d.kinds)) AS material_mismatch_receipts,
            count(*) FILTER (WHERE 'assay_beyond_tolerance'::text = ANY (d.kinds)) AS assay_beyond_receipts,
            count(*) FILTER (WHERE cardinality(d.kinds) > 0) AS receipts_with_any_discrepancy,
            min(d.arrival_date) AS earliest_receipt,
            max(d.arrival_date) AS latest_receipt
           FROM d
          GROUP BY d.supplier_id
        ), line_facts AS (
         SELECT DISTINCT ON (d.supplier_id, d.line_id) d.supplier_id,
            d.line_id,
            d.line_delta_qty,
            d.kinds
           FROM d
          ORDER BY d.supplier_id, d.line_id, d.batch_id
        ), line_agg AS (
         SELECT lf.supplier_id,
            count(*) FILTER (WHERE 'short'::text = ANY (lf.kinds)) AS short_lines,
            count(*) FILTER (WHERE 'over'::text = ANY (lf.kinds)) AS over_lines,
            COALESCE(sum(lf.line_delta_qty) FILTER (WHERE 'short'::text = ANY (lf.kinds)), 0::numeric) AS short_qty,
            COALESCE(sum(lf.line_delta_qty) FILTER (WHERE 'over'::text = ANY (lf.kinds)), 0::numeric) AS over_qty
           FROM line_facts lf
          GROUP BY lf.supplier_id
        ), excluded_agg AS (
         SELECT b.supplier_id,
            count(*) AS excluded_receipts
           FROM inbound_batches b
             CROSS JOIN win w_1
          WHERE b.deleted_at IS NULL AND b.arrival_date IS NOT NULL AND b.arrival_date >= (CURRENT_DATE - w_1.window_days) AND NOT (EXISTS ( SELECT 1
                   FROM grn_discrepancies g
                  WHERE g.batch_id = b.id))
          GROUP BY b.supplier_id
        ), undated_agg AS (
         SELECT b.supplier_id,
            count(*) AS undated_receipts,
            count(*) FILTER (WHERE (EXISTS ( SELECT 1
                   FROM grn_discrepancies g
                  WHERE g.batch_id = b.id AND cardinality(g.kinds) > 0))) AS undated_with_discrepancy
           FROM inbound_batches b
          WHERE b.deleted_at IS NULL AND b.arrival_date IS NULL
          GROUP BY b.supplier_id
        )
 SELECT s.id AS supplier_id,
    s.code AS supplier_code,
    s.legal_name AS supplier_name,
    w.window_days,
    CURRENT_DATE - w.window_days AS window_from,
    COALESCE(ra.comparable_receipts, 0::bigint) AS comparable_receipts,
    COALESCE(ra.short_receipts, 0::bigint) AS short_receipts,
    COALESCE(ra.over_receipts, 0::bigint) AS over_receipts,
    COALESCE(ra.declared_vs_actual_receipts, 0::bigint) AS declared_vs_actual_receipts,
    COALESCE(ra.material_mismatch_receipts, 0::bigint) AS material_mismatch_receipts,
    COALESCE(ra.assay_beyond_receipts, 0::bigint) AS assay_beyond_receipts,
    COALESCE(ra.receipts_with_any_discrepancy, 0::bigint) AS receipts_with_any_discrepancy,
    COALESCE(la.short_lines, 0::bigint) AS short_lines,
    COALESCE(la.over_lines, 0::bigint) AS over_lines,
    COALESCE(la.short_qty, 0::numeric) AS short_qty,
    COALESCE(la.over_qty, 0::numeric) AS over_qty,
    COALESCE(ea.excluded_receipts, 0::bigint) AS excluded_receipts,
    COALESCE(ua.undated_receipts, 0::bigint) AS undated_receipts,
    COALESCE(ua.undated_with_discrepancy, 0::bigint) AS undated_with_discrepancy,
    ra.earliest_receipt,
    ra.latest_receipt,
    cfg.grn_short_pct,
    cfg.grn_over_pct,
    cfg.grn_assay_tolerance_pct
   FROM suppliers s
     CROSS JOIN win w
     CROSS JOIN cfg
     LEFT JOIN receipt_agg ra ON ra.supplier_id = s.id
     LEFT JOIN line_agg la ON la.supplier_id = s.id
     LEFT JOIN excluded_agg ea ON ea.supplier_id = s.id
     LEFT JOIN undated_agg ua ON ua.supplier_id = s.id
  WHERE s.deleted_at IS NULL AND s.supplies_goods AND has_permission('module.purchasing.view'::text);
;

COMMENT ON VIEW public.supplier_receipt_pattern IS 'GRN-2:一家供应商一行 —— 这家是不是【一直】短交。一次短交是行情,连续短交是供应商问题,而 grn_discrepancies 逐条说得出"这一条怎么了",说不出"这一家一向如何"。
【三个计数是三件不同的事,永远不许合并】comparable_receipts(窗口内、有日期、比对得了的)是分母;excluded_receipts(有日期但没有订量可比 —— 判据是【不在 grn_discrepancies 里】,因此也涵盖采购单被软删这条路)【不是合规】,它是"没法评判";undated_receipts(没有到货日,放不进任何窗口)是第三类。把后两类折进分母,等于把"不知道"算成"没问题"。
【undated_with_discrepancy 是这一族最要紧的数】它回答"把日期补上会不会改变结论"。实测(2026-08-18):全库唯一一条 short(IN-2026-0029)正在这一类里 —— 一个朴素的窗口谓词会让那家供应商显示"零次短交"。
【次数按收货算,数量按采购行算】line_delta_qty 是行级事实、挂在该行的每一条收货上,直接按收货求和会把挂了多次收货的行算两遍(线上已有一条)。所以 short_qty / over_qty 在 DISTINCT line_id 上汇总,而 *_receipts 按收货计数。两种单位,列名各自说清。
【没有"一贯短交"这个布尔量,也没有百分比】那需要一个没有人选过的阈值,而这张视图没有资格替采购员做那个判断;百分比则藏起分母(1 次里 1 次也是 100%)。给原始计数,分母摆在明处。
【短交的定义只有一处】本视图读 grn_discrepancies,不重算 —— 两份定义必然漂开。三个阈值同样现读 receiving_settings,并【原样返回】,好让屏幕显示的就是判出这些计数的那三个数。
【一家没有可比对收货的供应商仍然出现,值为 0】从 suppliers 左连接出发,于是页面分得出"没有可比对的收货"与"查不到这家供应商"。
【属主权限 + module.purchasing.view】跨 purchasing × inbound 两模块,invoker 会让无权那侧的行被 RLS 静默丢掉(OPS-14)。实测线上没有任何角色持 purchasing.view 而不持 inbound.view,所以这道门不比今天任何一条路径更宽。';

GRANT SELECT ON public.supplier_receipt_pattern TO authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- 件二 · 客户的承诺压过工序指定 —— 【只补缺的那一个方向】
--
-- 【今天的行为,实测,两个方向不对称】
--   先指定 → 后预留:trg_so_reservations_form_saleable(BEFORE INSERT on
--     sales_order_reservations)→ assert_output_batch_saleable → 抛
--     SALE_BATCH_EARMARKED。**已经拒了。一个字都不动它,fixture 166 照旧。**
--   先预留 → 后指定:set_output_batch_purpose **一次预留检查都没做**,
--     UPDATE 直接落库。← 本段补的就是这一条,且只有这一条。
--
-- ★★【为什么是【触发器】,而不只是那个函数 —— 这一条是决定性的】★★
--   output_batches 上挂着一条敞开的 UPDATE 策略:
--       USING (has_permission('module.output.edit'))
--   于是一句直插的 `UPDATE output_batches SET purpose_code = 'process_feed'`
--   **整个绕开 set_output_batch_purpose**。把守卫只放在函数里,等于给这条规则
--   留了一扇没人看的门。而 CHECK 约束做不到这件事:它的谓词要读【另一张表】。
--   ★ 镜像那一侧【已经是触发器】★(trg_so_reservations_form_saleable)——
--   把一条规则的两半用两种不同的强度去执行,正是一条规则被绕过去的方式。
--   所以:**触发器是守卫,函数只负责把话说得更好听。**
--
-- ★★【SECURITY DEFINER 不是装饰 —— 不加它,这个守卫会【因为看不见而放行】】★★
--   sales_order_reservations 的 SELECT 策略要 module.sales.view。
--   一个只有 module.processing.edit 的加工员【看不见任何预留行】,
--   于是一个 INVOKER 的守卫会查到零行、安静地放行 —— **它会原样重演
--   PROC-WIRE-1B-ii 刚刚修掉的那个缺陷**(一个看不见的断言必须按名拒绝)。
--   实测过的处置在这里更简单也更强:本函数 SECURITY DEFINER,属主 postgres,
--   而 sales_order_reservations 由 postgres 拥有且 **relforcerowsecurity = false**
--   (2026-08-31 实测),于是属主【绕过 RLS】,守卫是真的看得见的。
--   ★ 因此本守卫【不需要】assert_output_batch_saleable 那条"第五条拒绝" ★ ——
--     那一条是给【看不见】的情形准备的,而这里看不见是不可能的。
--     **这句话是有代价的断言,所以 fixture 170 拿一个只有 processing.edit、
--     没有 sales.view 的用户去撞它** —— 那一臂绿了,这段话才算数。
--
-- 【触发器只挂 UPDATE,不挂 INSERT —— 这是一个决定,不是一个遗漏】
--   sales_order_reservations.output_batch_id 有外键指向 output_batches。
--   于是在一个产出批【被插入的那一刻】,不可能存在任何指向它的预留。
--   给 INSERT 也挂上,只会让每一次建批都白跑一次查询。
--
-- 【WHEN 子句:只在 purpose_code 【真的变了】的时候才管】
--   否则每一次动 output_batches 的无关 UPDATE(库存流水回写之类)都要付一次
--   查询,而且会把一条与本规则无关的更新拦下来。
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.guard_output_batch_not_promised()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_saleable boolean;
    v_qty      numeric;
    v_orders   text;
BEGIN
    -- 【只有【非可售】的指定才与承诺冲突】把一批货指回 saleable_stock
    -- (也就是【释放】这个指定)对一份承诺没有任何妨碍 —— 恰恰相反,
    -- 那正是镜像那一侧的 HINT 教操作员做的那一步。**拦它会把旁路堵死。**
    SELECT p.is_saleable_stock INTO v_saleable
      FROM public.output_batch_purposes p WHERE p.code = NEW.purpose_code;

    -- 【字典里没有这个码?不是本守卫的题】set_output_batch_purpose 的
    -- BATCH_PURPOSE_UNKNOWN 与那条外键各自管它。一个守卫只说一句话。
    IF v_saleable IS NOT FALSE THEN
        RETURN NEW;
    END IF;

    -- 【活预留 = 未释放 且 未消耗】(SO-3b 起两个条件,与 line_spoken_for 同源)。
    -- 已释放的货回到了 available,已消耗的货已经发走了 —— 两者都不再是一份
    -- 悬着的承诺,都不该拦住一次指定。
    SELECT sum(r.qty),
           string_agg(DISTINCT so.code, ', ' ORDER BY so.code)
      INTO v_qty, v_orders
      FROM public.sales_order_reservations r
      JOIN public.sales_order_lines sol ON sol.id = r.sales_order_line_id
      JOIN public.sales_orders so ON so.id = sol.sales_order_id
     WHERE r.output_batch_id = NEW.id
       AND r.released_at IS NULL
       AND r.consumed_at IS NULL;

    IF v_qty IS NULL OR v_qty <= 0 THEN
        RETURN NEW;
    END IF;

    -- ★【部分预留 → 整批拒。这是一个裁定,理由在抬头,不要"优化"成放行余量】★
    --   purpose_code 作用于【整批】,没有部分指定这种东西,也没有子批模型。
    --   在余量上放行,落到库里就是把整批(连同已许出去的那一部分)翻成非可售,
    --   而那一部分接着会被 assert_output_batch_saleable 拦在发货门外 ——
    --   **一次"部分放行"会把一句守住了的承诺变成一句毁约。**
    RAISE EXCEPTION 'BATCH_PROMISED_TO_CUSTOMER|%|%|%', NEW.code, v_qty, v_orders
      USING HINT = '这一批已经许给了客户(见上面的订单号),所以它不能被指定成下游工序的投料。'
                || '【部分预留也是整批拒】:指定是【整批】的事,没有"只指定没许出去的那部分"这种做法 —— '
                || '那会把已经许出去的货一起翻成非可售,发货那天就成了毁约。'
                || '要拿这一批去投料,先到销售订单上把预留释放掉,或者换一批。';
END;
$function$;

COMMENT ON FUNCTION public.guard_output_batch_not_promised() IS
'PROC-1B-iii(R4):**一批已经许给客户的货,不许被指定成下游工序的投料。**

★【它补的是一个【单向】的缺口】★ 镜像那一侧(先指定、后预留)从 PROC-BUILD-1 起
就在预留那一刻按名拒了(trg_so_reservations_form_saleable → SALE_BATCH_EARMARKED),
**本刀一个字都没动它**。缺的一直是这一侧:先预留、后指定 —— 此前悄悄成功。

【R4 是有方向的排序,Tim 已裁定】"客户的承诺压过工序指定"与"要许货给客户,
先把工序指定释放掉"是同一条排序;差别只在于【释放由谁做】,而答案是【操作员】。
一个悄悄毁掉一项没人同意毁掉的安排的系统,比一句响亮的、带一步旁路的拒绝更坏。

【为什么是触发器】output_batches 有一条敞开的 UPDATE 策略(module.output.edit),
直插的 UPDATE 会整个绕开 set_output_batch_purpose;而 CHECK 约束读不了另一张表。
**函数里那一份只是为了把话说得更好听,守卫是这一份。**

【为什么 SECURITY DEFINER】sales_order_reservations 要 module.sales.view 才看得见。
一个 INVOKER 的守卫对着只有 processing.edit 的加工员会查到零行、**安静地放行** ——
那是 PROC-WIRE-1B-ii 刚修掉的缺陷原样重演。属主 postgres 且该表
relforcerowsecurity=false(实测),于是属主绕过 RLS,守卫真的看得见。
fixture 170 用一个没有 sales.view 的用户撞它,那一臂就是这句话的凭据。

【部分预留:整批拒】purpose_code 作用于整批,没有部分指定,也没有子批模型
(它被明确挂起了)。放行余量落到库里是把整批翻成非可售,连同已许出去的那部分,
而那部分随后会被挡在发货门外 —— 一次"部分放行"会把守住的承诺变成毁约。

【只挂 UPDATE】预留有外键指向 output_batches,建批那一刻不可能有预留指着它。';

CREATE TRIGGER trg_output_batches_not_promised
    BEFORE UPDATE OF purpose_code ON public.output_batches
    FOR EACH ROW
    WHEN (NEW.purpose_code IS DISTINCT FROM OLD.purpose_code)
    EXECUTE FUNCTION public.guard_output_batch_not_promised();

-- ── 函数侧:同一条规则,更好的一句话(守卫仍然是上面那个触发器)──────────────
-- 【为什么两处都写,而不是只留触发器】触发器的消息是给【任何】写入者的;
-- 这一份是给走正门的人的,它能在 RAISE 之前就把话说完整,并且与函数里其它
-- 五条拒绝排在一起被读到。**它不是第二道闸** —— 触发器在它后面兜着,
-- 而 fixture 170 会证明直插那条路也一样被拒。
CREATE OR REPLACE FUNCTION public.set_output_batch_purpose(p_output_batch_id uuid, p_purpose_code text, p_awaiting_operation_type_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_code    text;
    v_deleted timestamptz;
    v_old     text;
    v_saleable boolean;
    v_await   text;
    v_res_qty numeric;
    v_res_ord text;
BEGIN
    PERFORM public.require_permission('module.processing.edit');

    SELECT code, deleted_at, purpose_code INTO v_code, v_deleted, v_old
      FROM public.output_batches WHERE id = p_output_batch_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED|%', v_code;
    END IF;

    -- 【停用的用途不许再被指派上去,但既有的行不动】—— 与 is_active 在别处
    -- 的意思一致:停用是"以后别再选它",不是"把历史改掉"。
    SELECT is_saleable_stock INTO v_saleable FROM public.output_batch_purposes
     WHERE code = p_purpose_code AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BATCH_PURPOSE_UNKNOWN|%', COALESCE(p_purpose_code, '(null)');
    END IF;

    -- ★★【PROC-1B-iii(R4):这一批许给客户了吗】★★
    -- 【按名拒,而且这个名字与那五条销售拒绝【都不一样】】
    --   assert_output_batch_saleable 的五条讲的都是"这一批能不能【卖】";
    --   本条讲的是反方向的一句话:"这一批能不能被【拿去投料】"。
    --   共用一个错误码会让操作员读到一句与他正在做的事无关的话。
    -- 【它排在权限与字典之后、UPDATE 之前】——"你没权限"和"没有这个用途"
    --   是更早的问题;把本条排到它们前面,会让一个手滑打错用途码的人
    --   收到一句关于客户承诺的话。
    IF v_saleable IS FALSE THEN
        SELECT sum(r.qty),
               string_agg(DISTINCT so.code, ', ' ORDER BY so.code)
          INTO v_res_qty, v_res_ord
          FROM public.sales_order_reservations r
          JOIN public.sales_order_lines sol ON sol.id = r.sales_order_line_id
          JOIN public.sales_orders so ON so.id = sol.sales_order_id
         WHERE r.output_batch_id = p_output_batch_id
           AND r.released_at IS NULL
           AND r.consumed_at IS NULL;

        IF v_res_qty IS NOT NULL AND v_res_qty > 0 THEN
            RAISE EXCEPTION 'BATCH_PROMISED_TO_CUSTOMER|%|%|%', v_code, v_res_qty, v_res_ord
              USING HINT = '这一批已经许给了客户(见上面的订单号),所以它不能被指定成下游工序的投料。'
                        || '【部分预留也是整批拒】:指定是【整批】的事,没有"只指定没许出去的那部分"这种做法 —— '
                        || '那会把已经许出去的货一起翻成非可售,发货那天就成了毁约。'
                        || '要拿这一批去投料,先到销售订单上把预留释放掉,或者换一批。';
        END IF;
    END IF;

    -- 【释放指定就把"在等哪一道"一并清掉】留着它会造出一个自相矛盾行,
    -- 而守卫会把这次释放整个拒掉 —— 那等于让"释放"这个动作莫名其妙地失败。
    -- **清掉是这扇门的责任,不是调用者要记得的一步。**
    v_await := CASE WHEN v_saleable THEN NULL ELSE p_awaiting_operation_type_code END;

    IF v_await IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.operation_types
                        WHERE code = v_await AND is_active) THEN
        RAISE EXCEPTION 'WIP_OPERATION_UNKNOWN|%', v_await
          USING HINT = '没有这一道工序,或者它已经停用了。到【设置 → 工序】看一眼有哪些。';
    END IF;

    UPDATE public.output_batches
       SET purpose_code = p_purpose_code,
           awaiting_operation_type_code = v_await,
           updated_by   = v_user,
           updated_at   = now()
     WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'code', v_code,
        'purpose_from', v_old,
        'purpose_to', p_purpose_code,
        'awaiting_operation', v_await);
END;
$function$;

COMMIT;
