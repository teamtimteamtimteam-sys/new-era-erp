-- AUD-1:客户审计报告(数据库那一半)—— 推导,以及单据机器
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【地面先量,而地面推翻了任务书的一句前提 —— 写在这里,不藏在报告里】
--
-- ① **线上【没有】两段链。** batch_lineage 上每一个产出批的 max(depth) 都是 1。
--    唯一一条再加工边确实存在(processing_inputs 里 1 行带 output_batch_id):
--    PROC-2026-0143 耗了 OUT-2026-0159,而 OUT-2026-0159 由 PROC-2026-0142 产出。
--    **但那两支加工单都已经 reversed 且软删**,而 batch_lineage 的两个 join 都带
--    `pr.deleted_at IS NULL` —— 所以那条链在【在册】数据里不存在。
--    结论:两段链的断言只能由 fixture 自己造(README 第 2 条本来就要求自带数据),
--    不能拿线上当样本。
-- ② **4 个产出批在 batch_lineage 里一行都没有**(OUT-2026-0005 / 0006 / 0159 / 0160)
--    —— 它们的生产单同样是 reversed + 软删。这不是缺陷,是"血缘不看已回滚的单"
--    这条设计的直接后果。
--    【本段有一句写错了,应用之后实测才发现,改在这里而不是留着】
--    上面这四个批次【自己也是软删的】,所以它们撞的是 BATCH_NOT_FOUND,不是
--    NOTHING_TO_REPORT —— 一个软删的批次不是一个"在册但无来源"的批次。
--    NOTHING_TO_REPORT 在线上的真实用例是另外两个:**OUT-2026-0001 与
--    OUT-2026-0002,在册、却【零支生产单】**(直接建出来的产出批,不是加工产出的)。
--    实测两者都按名拒。差别值得留着:一个是"这张单子不在了",一个是
--    "这批料没有可讲的来历",而客户审计问的正是后者。
--
-- 【键:一个产出批一份报告】客户问的是"你卖给我的这批料,它从哪来、怎么做的"——
-- 那个"这批料"就是产出批。发票或发货单【引用】它的那些批次;一次打包就是
-- 一摞批次报告,不是一种新单据。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【权限:OR,不是 AND —— 而这是量出来的,不是挑的】
--
-- 线上角色矩阵(本迁移当天实测):
--     role        sales.view  processing.view
--     admin           t            t
--     auditor         t            t
--     gm              t            t
--     sales           t            f      ← 面对客户的那批人
--     operations      f            t      ← 真正在跑加工的那批人
-- `sales.view AND processing.view` 只有 admin / auditor / gm 三个角色成立 ——
-- **它会把销售和运营两头都挡在外面**,而客户正是向销售要这份东西的。
-- 那就是任务书说的"if it lies"。所以取 OR,与 batch_margin 的
-- `data.view_prices AND (finance OR processing)` 同一条裁定(AGENTS.md 常设决定 2):
-- 没有任何 live 角色同时持有两者时,AND 不是更严,是更空。
--
-- 【而 OR 撞上了另一条房规,所以本刀还得动两张既有视图】
-- batch_lineage 与 processing_metal_recovery 都是【属主权限 + 体内
-- has_permission('module.processing.view')】。属主权限替得了表的权限,
-- **替不了体内那句 has_permission —— 它按调用者解析**(AGENTS.md 那一节,
-- 已经被发现三次)。于是一个只持 sales.view 的读者从本函数里读这两张视图,
-- 拿到的是【零行】—— 一个错的好消息。
-- 修法就是那一节写明的那条:**把判据挪到外层,内层留一张不带判据的基视图**
-- (先例 stock_class_violations_all)。所以:
--     batch_lineage_all / processing_metal_recovery_all   ← 无判据,不授权给任何人
--     batch_lineage / processing_metal_recovery           ← 原样对外,只是改成读基视图
-- 两张对外视图的列名、类型、顺序一个没动,语义逐字不变(判据是每次调用的常量,
-- 挪到外层不影响 processing_metal_recovery 里那个按 run 分区的窗口函数)。
-- 【绝不第二次递归】报告函数读的是 batch_lineage_all,不是自己再写一遍 WITH RECURSIVE。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 两张基视图 —— 判据挪到外层
-- ════════════════════════════════════════════════════════════════════════════
CREATE VIEW public.batch_lineage_all AS
WITH RECURSIVE up AS (
    SELECT po.output_batch_id AS batch_id,
           pr.id AS via_run_id, pr.code AS via_run_code,
           pi.inbound_batch_id AS parent_inbound_id,
           pi.output_batch_id  AS parent_output_id,
           pi.quantity_consumed, 1 AS depth
    FROM public.processing_outputs po
    JOIN public.processing_runs pr ON pr.id = po.run_id AND pr.deleted_at IS NULL
    JOIN public.processing_inputs pi ON pi.run_id = pr.id
  UNION ALL
    SELECT up.batch_id, pr2.id, pr2.code,
           pi2.inbound_batch_id, pi2.output_batch_id,
           pi2.quantity_consumed, up.depth + 1
    FROM up
    JOIN public.processing_outputs po2 ON po2.output_batch_id = up.parent_output_id
    JOIN public.processing_runs pr2 ON pr2.id = po2.run_id AND pr2.deleted_at IS NULL
    JOIN public.processing_inputs pi2 ON pi2.run_id = pr2.id
    WHERE up.parent_output_id IS NOT NULL
)
SELECT up.batch_id AS output_batch_id,
       up.depth,
       up.via_run_id,
       up.via_run_code,
       CASE WHEN up.parent_inbound_id IS NOT NULL THEN 'inbound' ELSE 'output' END AS parent_kind,
       COALESCE(up.parent_inbound_id, up.parent_output_id) AS parent_batch_id,
       COALESCE(ib.code, ob.code) AS parent_code,
       up.quantity_consumed
FROM up
LEFT JOIN public.inbound_batches ib ON ib.id = up.parent_inbound_id
LEFT JOIN public.output_batches ob ON ob.id = up.parent_output_id;

-- 【不授权给任何人】它是内层算子,靠"够不着"把关 —— 对外那一张仍然带判据。
REVOKE ALL ON public.batch_lineage_all FROM authenticated, anon;

COMMENT ON VIEW public.batch_lineage_all IS
    'AUD-1:batch_lineage 的【无判据基视图】。属主权限替得了表的权限,替不了体内 has_permission(它按调用者解析)—— 所以要让一个只持 module.sales.view 的读者经由 traceability_report_data 读到血缘,判据必须挪到外层,内层留这一张(先例 stock_class_violations_all)。【不授权给任何人】,靠够不着把关;对外读 batch_lineage。';

CREATE OR REPLACE VIEW public.batch_lineage WITH (security_invoker = off) AS
 SELECT l.output_batch_id,
    l.depth,
    l.via_run_id,
    l.via_run_code,
    l.parent_kind,
    l.parent_batch_id,
    l.parent_code,
    l.quantity_consumed
   FROM batch_lineage_all l
  WHERE has_permission('module.processing.view'::text);

CREATE VIEW public.processing_metal_recovery_all AS
 WITH ins AS (
         SELECT pi.run_id,
            m.metal,
            sum(pi.quantity_consumed * m.content_pct / 100.0) AS input_metal_kg,
            CASE
                WHEN min(COALESCE(m.content_source, 'unknown'::text)) = max(COALESCE(m.content_source, 'unknown'::text)) THEN min(COALESCE(m.content_source, 'unknown'::text))
                ELSE 'mixed'::text
            END AS input_source
           FROM processing_inputs pi
             JOIN LATERAL ( SELECT ibm.metal,
                    ibm.content_pct,
                    ibm.content_source
                   FROM inbound_batch_metals ibm
                  WHERE ibm.inbound_batch_id = pi.inbound_batch_id
                UNION ALL
                 SELECT obm.metal,
                    obm.content_pct,
                    obm.content_source
                   FROM output_batch_metals obm
                  WHERE obm.output_batch_id = pi.output_batch_id) m ON true
          GROUP BY pi.run_id, m.metal
        ), outs AS (
         SELECT po.run_id,
            obm.metal,
            sum(po.quantity_produced * obm.content_pct / 100.0) AS output_metal_kg,
            CASE
                WHEN min(obm.content_source) = max(obm.content_source) THEN min(obm.content_source)
                ELSE 'mixed'::text
            END AS output_source
           FROM processing_outputs po
             JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
          GROUP BY po.run_id, obm.metal
        )
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    COALESCE(i.metal, o.metal) AS metal,
    i.input_metal_kg,
    o.output_metal_kg,
    i.metal IS NOT NULL AS input_measured,
    o.metal IS NOT NULL AS output_measured,
        CASE
            WHEN i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric THEN round(o.output_metal_kg / i.input_metal_kg * 100::numeric, 2)
            ELSE NULL::numeric
        END AS recovery_pct,
        CASE
            WHEN i.metal IS NULL THEN 'input_not_measured'::text
            WHEN o.metal IS NULL THEN 'output_not_measured'::text
            WHEN i.input_metal_kg = 0::numeric THEN 'input_measured_zero'::text
            ELSE NULL::text
        END AS recovery_blocked_by,
    i.metal IS NOT NULL AND o.metal IS NOT NULL AND o.output_metal_kg > i.input_metal_kg AS conservation_warning,
    bool_or(i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric) OVER (PARTITION BY r.id) AS run_recovery_computable,
    i.input_source,
    o.output_source
   FROM ins i
     FULL JOIN outs o ON o.run_id = i.run_id AND o.metal = i.metal
     JOIN processing_runs r ON r.id = COALESCE(i.run_id, o.run_id)
  WHERE r.status = 'committed'::text AND r.deleted_at IS NULL;

REVOKE ALL ON public.processing_metal_recovery_all FROM authenticated, anon;

COMMENT ON VIEW public.processing_metal_recovery_all IS
    'AUD-1:processing_metal_recovery 的【无判据基视图】,理由与 batch_lineage_all 逐字相同。【不授权给任何人】;对外读 processing_metal_recovery。';

CREATE OR REPLACE VIEW public.processing_metal_recovery WITH (security_invoker = off) AS
 SELECT v.run_id,
    v.run_code,
    v.process_date,
    v.metal,
    v.input_metal_kg,
    v.output_metal_kg,
    v.input_measured,
    v.output_measured,
    v.recovery_pct,
    v.recovery_blocked_by,
    v.conservation_warning,
    v.run_recovery_computable,
    v.input_source,
    v.output_source
   FROM processing_metal_recovery_all v
  WHERE has_permission('module.processing.view'::text);

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 推导:一个批次的报告数据
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.traceability_report_data(p_output_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ob     record;
    v_chain  jsonb;
    v_runs   jsonb;
    v_rec    jsonb;
    v_depth  integer;
BEGIN
    -- 【OR,不是 AND】理由与实测的角色矩阵写在本迁移抬头。
    IF NOT has_any_permission(ARRAY['module.sales.view', 'module.processing.view']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    IF p_output_batch_id IS NULL THEN
        RAISE EXCEPTION 'BATCH_REQUIRED';
    END IF;

    SELECT ob.id, ob.code, ob.quantity, ob.remaining_qty, ob.unit, ob.output_date,
           m.code AS material_code, m.name AS material_name
      INTO v_ob
      FROM output_batches ob
      LEFT JOIN materials m ON m.id = ob.material_id
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;

    IF NOT FOUND THEN
        -- 【三条拒绝是【有序】的,而顺序本身是内容】先分清"这个 id 根本不是一个
        -- 批次"与"它是个批次、但不是产出批":后者是拿进料批的 id 来要报告 ——
        -- 一个可以理解的错,而它值得一句说得清的话,不是一句 NOT_FOUND。
        IF EXISTS (SELECT 1 FROM inbound_batches ib WHERE ib.id = p_output_batch_id) THEN
            RAISE EXCEPTION 'NOT_AN_OUTPUT_BATCH|%',
                (SELECT ib.code FROM inbound_batches ib WHERE ib.id = p_output_batch_id);
        END IF;
        RAISE EXCEPTION 'BATCH_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    -- ── 血缘:读【基视图】,绝不第二次递归 ──────────────────────────────────
    -- 供应商与到货日是在链条【末端的进料批】上 join 出来的,不是又一次递归:
    -- "供应商批次 → 收货" 那两格就住在 inbound_batches 那一行上。
    -- 【供应商名是随单据走的展示标签】(AGENTS.md 常设决定 3),不另设一道门 ——
    -- 何况这份东西的用途就是交到客户手里。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'depth', l.depth,
               'via_run_id', l.via_run_id,
               'via_run_code', l.via_run_code,
               'parent_kind', l.parent_kind,
               'parent_batch_id', l.parent_batch_id,
               'parent_code', l.parent_code,
               'quantity_consumed', l.quantity_consumed,
               -- 只有进料父才有供应商与到货日;产出父是上一段的产物。
               'supplier_name', sup.legal_name,
               'supplier_code', sup.code,
               'arrival_date', ib.arrival_date,
               'material_code', im.code)
               ORDER BY l.depth, l.via_run_code, l.parent_code), '[]'::jsonb),
           max(l.depth)
      INTO v_chain, v_depth
      FROM batch_lineage_all l
      LEFT JOIN inbound_batches ib ON ib.id = l.parent_batch_id AND l.parent_kind = 'inbound'
      LEFT JOIN suppliers sup ON sup.id = ib.supplier_id
      LEFT JOIN materials im ON im.id = ib.material_id
     WHERE l.output_batch_id = p_output_batch_id;

    -- 【没有血缘 = 没有可报的东西,而它有一个真实的成因】线上四个产出批正是这样:
    -- 生产它们的加工单被冲销并软删,而血缘刻意不看已回滚的单。
    -- 这时候【不能】发一份"来源不详"的报告去糊弄审计 —— 空表比空报告诚实。
    IF jsonb_array_length(v_chain) = 0 THEN
        RAISE EXCEPTION 'NOTHING_TO_REPORT|%', v_ob.code;
    END IF;

    -- ── 涉及的加工单(链条上的每一支,不只是最后那一支)──────────────────
    SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
               'run_id', l.via_run_id, 'run_code', l.via_run_code)), '[]'::jsonb)
      INTO v_runs
      FROM batch_lineage_all l
     WHERE l.output_batch_id = p_output_batch_id;

    -- ── 每支加工单 × 金属的回收行,【逐列原样带走】────────────────────────
    -- 【报告【携带】这些列,绝不重算】input_source / output_source /
    -- recovery_blocked_by / conservation_warning 是那张视图对"它除的是哪一种数"
    -- 的判词(REC-1 与 PROC-1 的全部要点)。在这里重算一遍,就是让同一件事有了
    -- 第二份实现,而这个仓库为这个形状付过四次学费。
    -- 【NULL 的回收率带着它的具名原因走】—— 绝不用一个数字替代它。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'run_id', r.run_id,
               'run_code', r.run_code,
               'process_date', r.process_date,
               'metal', r.metal,
               'input_metal_kg', r.input_metal_kg,
               'output_metal_kg', r.output_metal_kg,
               'input_measured', r.input_measured,
               'output_measured', r.output_measured,
               'recovery_pct', r.recovery_pct,
               'recovery_blocked_by', r.recovery_blocked_by,
               'conservation_warning', r.conservation_warning,
               'run_recovery_computable', r.run_recovery_computable,
               'input_source', r.input_source,
               'output_source', r.output_source)
               ORDER BY r.run_code, r.metal), '[]'::jsonb)
      INTO v_rec
      FROM processing_metal_recovery_all r
     WHERE r.run_id IN (SELECT DISTINCT l.via_run_id
                          FROM batch_lineage_all l
                         WHERE l.output_batch_id = p_output_batch_id);

    RETURN jsonb_build_object(
        'output_batch', jsonb_build_object(
            'id', v_ob.id, 'code', v_ob.code,
            'material_code', v_ob.material_code, 'material_name', v_ob.material_name,
            'quantity', v_ob.quantity, 'remaining_qty', v_ob.remaining_qty,
            'unit', v_ob.unit, 'output_date', v_ob.output_date),
        'chain', v_chain,
        'chain_depth', v_depth,
        'runs', v_runs,
        'recovery', v_rec,
        'chain_row_count', jsonb_array_length(v_chain),
        'recovery_row_count', jsonb_array_length(v_rec)
    );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. 单据机器 —— INV-2a 那一族的第七份,形状逐字
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.next_traceability_report_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】与 next_credit_note_code / next_shipment_code / next_quote_code
    -- 逐字同一套:共用一把锁会让一种单据烧掉另一种的号,而无缝的意思正是
    -- "号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('traceability_report_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM traceability_report_issues
    WHERE code LIKE 'TRC-' || v_year::text || '-%';
    RETURN 'TRC-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_traceability_report_issue_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【自己报名,不靠外键顺带挡】(FIN-31)—— 客户手里那一份是某个具体版本:
    -- 改它或删它,就是把"当时发给客户的是什么"这个问题变成没有答案。
    RAISE EXCEPTION 'TRACEABILITY_REPORT_ISSUE_IMMUTABLE|%', TG_OP;
END;
$function$;

CREATE TABLE public.traceability_report_issues (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    output_batch_id uuid NOT NULL REFERENCES public.output_batches (id),
    -- 【报告号 TRC-YYYY-NNNN 属于"这个批次的报告",不属于每一版】
    -- 第 1 版铸号,之后的版本沿用同一个号 —— 客户引用的是那个号,而重发一版
    -- 不该让他手里的引用失效。所以 code 在同一个批次的各版之间【相同】。
    code            text NOT NULL,
    version         integer NOT NULL CHECK (version >= 1),
    file_path       text NOT NULL,
    sha256          text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at       timestamptz NOT NULL DEFAULT now(),
    issued_by       uuid,
    UNIQUE (output_batch_id, version),
    -- 一个号只对应一个批次(反向唯一由 record 函数保证:同批复用同号)
    UNIQUE (code, version)
);

COMMENT ON TABLE public.traceability_report_issues IS
    'AUD-1:客户审计报告(可追溯报告)的签发档,形状逐字取自 so_issues / po_issues / shipment_issues / cn_issues / qt_issues / invoice_issues(这是第七份)。谁、何时、第几版、哪个产出批、字节摘要。【快照就是那份字节】—— 不另存一份推导结果:报告的每一个输入(血缘、回收率、含量出处)都可能随后续录入而变,而客户手里那一份必须停在发出去的那一刻。code = TRC-YYYY-NNNN,属于【这个批次的报告】而不是每一版:第 1 版铸号,重发沿用,客户的引用因此不会失效。【没有"已发送"标志】—— 系统不知道对方收没收到。';

CREATE INDEX idx_traceability_report_issues_batch
    ON public.traceability_report_issues (output_batch_id, version DESC);

CREATE TRIGGER trg_traceability_report_issues_append_only
    BEFORE UPDATE OR DELETE ON public.traceability_report_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_traceability_report_issue_append_only();

ALTER TABLE public.traceability_report_issues ENABLE ROW LEVEL SECURITY;

-- 【读:与报告本身同一道门(OR)】能看这份报告的人就能看它发过几版 ——
-- 审计要看的正是"发出去的是什么"。
CREATE POLICY "traceability_report_issues select by permission"
    ON public.traceability_report_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.sales.view', 'module.processing.view']));
-- 【没有 INSERT 策略,这是刻意的】唯一写入口是 record_traceability_report_issue
-- (属主权限)—— 与 approval_log / 另外六个族同一条:档案不该有第二个写法。

CREATE OR REPLACE FUNCTION public.record_traceability_report_issue(
    p_output_batch_id uuid,
    p_file_path text,
    p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ob    record;
    v_data  jsonb;
    v_next  integer;
    v_code  text;
BEGIN
    -- 【记档案这个动作要 edit,而读报告要 view】两件事,两道门。
    -- 取 OR 的 edit 侧,理由与读那一侧相同(见本迁移抬头的角色矩阵)。
    IF NOT has_any_permission(ARRAY['module.sales.edit', 'module.processing.edit']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    SELECT ob.id, ob.code INTO v_ob
      FROM output_batches ob
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL
     FOR UPDATE;

    -- ── 三条拒绝,有序:先分清"不是批次" / "不是产出批" / "没有可报的东西" ──
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM inbound_batches ib WHERE ib.id = p_output_batch_id) THEN
            RAISE EXCEPTION 'NOT_AN_OUTPUT_BATCH|%',
                (SELECT ib.code FROM inbound_batches ib WHERE ib.id = p_output_batch_id);
        END IF;
        RAISE EXCEPTION 'BATCH_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    -- 【第三条不自己重判,而是问推导本身】"有没有可报的东西"只有那个函数说了算;
    -- 在这里再写一遍判据,就是让同一件事有两处实现(而它们迟早各说各话)。
    -- 它抛的 NOTHING_TO_REPORT 原样往上走 —— 那正是要说的那句话。
    v_data := traceability_report_data(p_output_batch_id);

    -- 【版本由数据库裁决】对象键不含版本号,并发安全靠这把每批次一把的咨询锁
    -- (与另外六个族逐字同一套)。
    PERFORM pg_advisory_xact_lock(hashtext('traceability_report_' || p_output_batch_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1, MIN(code)
      INTO v_next, v_code
      FROM traceability_report_issues WHERE output_batch_id = p_output_batch_id;

    -- 第 1 版铸号;之后沿用 —— 客户引用的是那个号。
    IF v_code IS NULL THEN
        v_code := next_traceability_report_code();
    END IF;

    INSERT INTO traceability_report_issues
        (output_batch_id, code, version, file_path, sha256, issued_by)
    VALUES (p_output_batch_id, v_code, v_next, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'batch_code', v_ob.code,
        'code', v_code,
        'version', v_next,
        'chain_row_count', v_data->'chain_row_count',
        'recovery_row_count', v_data->'recovery_row_count');
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 4. 桶与它的策略 —— 与表在【同一支迁移】里(INV-2a 的形状)
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO storage.buckets (id, name, public)
VALUES ('traceability-documents', 'traceability-documents', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "authenticated read traceability-documents"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'traceability-documents'::text);

CREATE POLICY "authenticated upload traceability-documents"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'traceability-documents'::text);

COMMIT;
