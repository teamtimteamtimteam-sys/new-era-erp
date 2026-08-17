-- GRN-1a:收货差异,数据库那一半
--
-- ════════════════════════════════════════════════════════════════════════════
-- GRN-0 勘察的三个结论,这一刀各答一条:
--   ① 订量 vs 实收【今天就 join 得出来】,但两个现成读者【在关单那一刻消失】
--      —— 而短交恰恰是关单之后才成为问题的。线上三条差异因此一处都不显示。
--   ② 申报量【压根不落库】:收货表单预填之后被过磅数覆盖,只剩一个数。
--   ③ 收的料是不是这一行订的料,【从来没有人比过】—— guard_inbound_po_line_match
--      只查"这一行属不属于这张单"。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【权限:module.purchasing.view,而这不是新画的一条线 —— 是量出来的】
--
-- 这张视图跨两个模块(inbound 的批次 × purchasing 的订单行),而 OPS-14 的
-- xmodule 那一课说得很死:invoker 视图跨模块【不是限制,是撒谎】—— 无权那一侧的
-- 行被 RLS 静默丢掉,内连接把整行带走,读者得到的不是"受限"而是"没有差异"。
-- 所以它是【属主权限】,并把谓词原样写回视图体。
--
-- 谓词取 module.purchasing.view,理由是【订量本来就只在这道门后面】:
--   * po_receivable_lines 与 purchase_order_status 都是 has_permission('module.purchasing.view');
--   * 实测(2026-08-17,单事务内探针后回滚):warehouse 角色读 po_receivable_lines
--     得 0 行、读 inbound_batches_masked 得 21 行;procurement 读得到 3 行。
--   * 线上没有任何一个持 purchasing.view 的角色【不持】inbound.view
--     (admin/auditor/finance/gm/procurement 五个全部两者皆有),
--     所以这个谓词比"两者取交集"更窄的可能性不存在,也不放宽任何一行。
-- 换句话说:operations 与 warehouse 看不见差异,【与他们今天看不见订量是同一件事】。
-- 这不是本刀新加的限制;要改的话该改的是订量那道门,而那是一个单独的决定。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 镜像:db/tables/{receiving_settings,inbound_batches}.sql、
--       db/functions/{create_inbound_batch,receive_inbound_batch_against_po}.sql、
--       db/views/{inbound_batches_masked,grn_discrepancies}.sql;
--       db/check_mirrors.py 的 RUNTIME_CONFIG_TABLES 加 receiving_settings;
-- 行为断言:fixture 87。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ═══ 1 · receiving_settings:三个数,而【短交与超收是两个数】═══════════════════
-- 形状取自 pricing_settings / processing_settings(EXEC-3a),一字不改。
CREATE TABLE public.receiving_settings (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    grn_short_pct           numeric NOT NULL DEFAULT 5
        CHECK (grn_short_pct > 0),
    grn_over_pct            numeric NOT NULL DEFAULT 5
        CHECK (grn_over_pct > 0),
    grn_assay_tolerance_pct numeric NOT NULL DEFAULT 10
        CHECK (grn_assay_tolerance_pct > 0),
    notes      text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.receiving_settings IS
    'GRN-1a:收货模块的单行配置(形状取自 pricing_settings / processing_settings)。装着收货差异的三个阈值。【短交与超收是两个数,不是一个】—— 与 processing_settings 的两个工单阈值同一条道理:短交是履约问题(货没到齐,该找供应商),超收是仓储与现金问题(地方、钱、以及一张对不上的单),合成一个数等于说它们一样严重。grn_discrepancies 【现读这三列】,没有任何地方写死它们。';
COMMENT ON COLUMN public.receiving_settings.grn_short_pct IS
    '短交阈值(百分比)。某个采购行【累计收到】的量低于订量 ×(1 − 本值/100)时,该行的每一条收货都带上 short。【只在采购单 closed / cancelled 时报】—— 与 wo_output_shortfall_pct 完全同一条:单还开着的时候"少"只是"还没收完",报出来等于每天提醒一件正在进行的事。也用作【申报量 vs 实收】方向为"少"时的阈值。';
COMMENT ON COLUMN public.receiving_settings.grn_over_pct IS
    '超收阈值(百分比)。某个采购行累计收到的量高于订量 ×(1 + 本值/100)时报 over。【任何状态都报,不等关单】—— 超收在它发生的那一刻就是可处理的事(货已经占了地方、钱已经欠出去了),这与 wo_input_overrun_pct 对开着的工单也报是同一条。也用作【申报量 vs 实收】方向为"多"时的阈值。';
COMMENT ON COLUMN public.receiving_settings.grn_assay_tolerance_pct IS
    '化验偏差阈值(百分比)。采购行的 expected_assay 与【已应用】化验的 content_pct 逐金属比,|实际 − 预期| / 预期 × 100 超过本值时报 assay_beyond_tolerance。【是相对偏差,不是百分点】—— 这是一个决定,写在这里而不是留给读的人猜:锂常在 0.5% 量级、镍常在 30% 量级,十个百分点对前者是整整二十倍、对后者是三分之一,一个绝对阈值对两者不可能同时有意义。相对偏差对两者都成立。预期为 0 或缺失时【不下任何断言】,而不是判成"在容差内"。';

INSERT INTO public.receiving_settings (id) VALUES (true);

ALTER TABLE public.receiving_settings ENABLE ROW LEVEL SECURITY;
-- 收货的设置归收货。procurement 也持 module.inbound.view(实测),所以采购侧一样读得到。
CREATE POLICY "receiving_settings select by permission" ON public.receiving_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text));
CREATE POLICY "receiving_settings update by permission" ON public.receiving_settings
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit'::text))
    WITH CHECK (has_permission('module.inbound.edit'::text));

GRANT SELECT ON public.receiving_settings TO authenticated;
GRANT UPDATE ON public.receiving_settings TO authenticated;

-- ═══ 2 · declared_qty:供应商【说】要来多少 ═══════════════════════════════════
-- 【三件事一支迁移】WO-1a 那一课:inbound_batches 有 _masked 伴生视图,所以
-- ADD COLUMN、列级 GRANT SELECT、_masked 视图【必须同时落】。缺任何一件,
-- colgrant 的谓词
--     (NOT granted AND NOT in_view) OR (has_view AND NOT in_view)
-- 都会红 —— 一旦一张表有了 _masked,它的每一列都必须在那张视图里。
ALTER TABLE public.inbound_batches ADD COLUMN declared_qty numeric;

COMMENT ON COLUMN public.inbound_batches.declared_qty IS
    'GRN-1a:供应商【申报】的到货量,与 quantity(磅秤说的数)是两回事。【NULL = 没有记录过,是一个具名状态,永不推断】。
【绝对不要用采购行的量去预填它】—— 那是【我们下的单】,不是【他们的申报】。一个被预填的申报量,是系统替供应商说了话:它会让"申报与实收一致"这句话在没有任何供应商文件的情况下成立,而那正是这一列存在要回答的问题。收货表单的数量框预填 remaining_qty 是【便利】(操作员必然会照磅改),申报量预填则是【伪造一条记录】,两者不是同一件事。
两个收货 RPC 的 p_declared_qty 因此 DEFAULT NULL:不填就是没记,而不是等于订量。
差异【不拒绝】—— 它是一条被记下来的事实,由 grn_discrepancies 说出来,由人去判断。';

-- 列级 SELECT 授权【不会自动延伸到新列】(表级 INSERT/UPDATE 才会)——
-- 漏了这一句,应用写得进去却读不出来,而且只要 WHERE 提到它就 42501。
GRANT SELECT (declared_qty) ON public.inbound_batches TO authenticated;

-- 非敏感(它是一个量,不是价),所以进遮蔽视图时不加 CASE。
-- CREATE OR REPLACE 只允许在【末尾】追加列 —— declared_qty 因此排在最后。
CREATE OR REPLACE VIEW public.inbound_batches_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    unit,
    remaining_qty,
    arrival_date,
    stage,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    purchase_order_id,
    purchase_order_line_id,
    pricing_formula_id,
    pricing_status,
    deleted_by,
    delete_reason,
    declared_qty
   FROM inbound_batches
  WHERE has_permission('module.inbound.view'::text);

-- ═══ 3 · 两个收货 RPC 收下 p_declared_qty ═══════════════════════════════════
-- 【DROP + CREATE,不是 CREATE OR REPLACE】追加一个参数就是换了签名,
-- CREATE OR REPLACE 会留下【两个】同名函数(FIN-21 那一课),而
-- preflight_migration.py 正是为此拒绝重载 —— 它认得【同一支迁移里、在 CREATE
-- 之前】的 DROP,所以这样写是它放行的形状。
-- EXECUTE 授权由 apply_migration.sh 在同一事务里重放 zzz_function_grants.sql 补回。
DROP FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid);

CREATE OR REPLACE FUNCTION public.create_inbound_batch(
    p_material_id uuid, p_supplier_id uuid, p_quantity numeric,
    p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date,
    p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric,
    p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid,
    p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid,
    p_declared_qty numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.inbound.edit');

    -- IOD-2-fu1:到货日【按名】必填。不写这一句,漏出去的是 FIN-32 的约束原文。
    -- 【不给默认值】:CURRENT_DATE 会让留空比填对更容易通过。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸。同样在写入之前 —— 它可能抛 IOD_CLASS_EXCLUDED。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- GRN-1a:p_declared_qty 原样落库,【不拒绝任何差异】,也【绝不从采购行推断】。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, unit_price, notes, purchase_order_id, purchase_order_line_id,
        declared_qty, created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_unit_price, p_notes, p_purchase_order_id, p_purchase_order_line_id,
        p_declared_qty, v_user, v_user)
    RETURNING id INTO v_id;

    -- 用毕即清 —— 同 commit_processing_run 的 movement_ctx:免得同事务内后续的
    -- 插入把这个库位当成自己的(那正是 ctx 这种机制唯一的锋利处)。
    PERFORM set_config('evoltrya.location_ctx', '', true);
    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

DROP FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid);

CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(
    p_material_id uuid, p_supplier_id uuid, p_quantity numeric,
    p_arrival_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text,
    p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid,
    p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.inbound.edit');

    -- IOD-2-fu1:同上 —— 现场收货这条路一样进得到 FIN-32 的约束。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- 单位固定 kg、stage 用默认值 —— 与收货表单今天的行为逐字一致。
    -- 【采购单侧的那一串拒绝(PO_NOT_RECEIVABLE / PO_LINE_MISMATCH /
    --  PO_NOT_APPROVED / SUPPLIER_QUALIFICATION_EXPIRED)仍由表上的触发器抛出】,
    -- 这个函数一个字都不重复它们 —— 重复一遍就是第二份会漂开的判断。
    -- 【GRN-1a:收错料【不拒绝】】—— 换料是一个正当的、可以谈成的场景,
    -- 而拒绝会把它变成一次不可能完成的收货。它由 grn_discrepancies 点名
    -- (material_mismatch),由人去判断。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, remaining_qty, unit, arrival_date,
        notes, purchase_order_id, purchase_order_line_id, declared_qty,
        created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, p_quantity, 'kg', p_arrival_date,
        p_notes, p_purchase_order_id, p_purchase_order_line_id, p_declared_qty,
        v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM set_config('evoltrya.location_ctx', '', true);
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

-- ═══ 4 · grn_discrepancies ═════════════════════════════════════════════════
-- 【粒度:一条收货一行】—— 而 short / over 是【行级】事实,理由见下。
--
-- 【没有订量就不下断言】没挂采购行的批次【整行不在这张视图里】,不是一行零。
-- 这是 work_order_fulfilment 的 has_plan 那一条:没估过 ≠ 估了零,一个
-- COALESCE(...,0) 会让每一次自采收货都成为一次 100% 超收。
--
-- 【short / over 算在【采购行的累计】上,不算在单条收货上】
-- PO-2026-0003 订 700,收了 400 + 300 —— 按单条算,那条 400 会被报成"短 43%",
-- 而它只是一次分批到货。所以两者都拿 line_received_qty 去比,并且【行上的每一条
-- 收货都带同一个结论】:一条 short 出现两次的意思是"这一行短了,而它有两次收货",
-- 不是"短了两次"。要按行计数的读者请 DISTINCT line_id ——
-- 【绝不让某几条收货静默地不带这个结论】,那会让"没说"读起来像"这条没问题"。
--
-- 【short 只在 closed / cancelled 时报,over 任何状态都报】
-- 与 processing_settings 那两个阈值逐字同一条:单还开着的时候"少"只是"还没收完";
-- 而超收在它发生的那一刻就占了地方、欠了钱。
CREATE VIEW public.grn_discrepancies WITH (security_invoker = off) AS
WITH cfg AS (
    SELECT grn_short_pct, grn_over_pct, grn_assay_tolerance_pct
      FROM receiving_settings LIMIT 1
),
line_totals AS (
    SELECT ib.purchase_order_line_id AS line_id,
           sum(ib.quantity) AS line_received_qty,
           count(*) AS line_receipt_count
      FROM inbound_batches ib
     WHERE ib.purchase_order_line_id IS NOT NULL AND ib.deleted_at IS NULL
     GROUP BY ib.purchase_order_line_id
),
applied_assay AS (
    -- 【只认已应用的化验】—— 一份录了但没 apply 的化验还不是这批货的事实,
    -- 它连计价都没参与。取最近应用的那一份。
    SELECT DISTINCT ON (a.inbound_batch_id) a.inbound_batch_id, a.id AS assay_id
      FROM assay_results a
     WHERE a.inbound_batch_id IS NOT NULL
       AND a.deleted_at IS NULL
       AND a.applied_at IS NOT NULL
     ORDER BY a.inbound_batch_id, a.applied_at DESC
),
assay_gap AS (
    -- 逐金属比。【两侧缺任何一侧就不产生行】—— 于是缺失自然地表现为
    -- beyond IS NULL(不下断言),而不是 false(在容差内)。
    SELECT b.id AS batch_id,
           bool_or(abs(m.content_pct - e.content_pct) / e.content_pct * 100::numeric
                   > cfg.grn_assay_tolerance_pct) AS beyond,
           count(*) AS metals_compared
      FROM inbound_batches b
      JOIN purchase_order_lines pol ON pol.id = b.purchase_order_line_id
      JOIN applied_assay aa ON aa.inbound_batch_id = b.id
      CROSS JOIN cfg
      CROSS JOIN LATERAL jsonb_to_recordset(
          CASE WHEN jsonb_typeof(pol.expected_assay) = 'array'
               THEN pol.expected_assay ELSE '[]'::jsonb END)
          AS e(metal text, content_pct numeric)
      JOIN assay_result_metals m
        ON m.assay_result_id = aa.assay_id AND m.metal = e.metal
     WHERE e.content_pct > 0::numeric
     GROUP BY b.id
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
    -- 【申报量缺失时是 NULL,不是 0】—— 0 会读成"申报与实收一致"
    CASE WHEN b.declared_qty IS NULL THEN NULL::numeric
         ELSE round(b.quantity - b.declared_qty, 4) END AS declared_delta_qty,
    ag.beyond AS assay_beyond_tolerance,
    ag.metals_compared AS assay_metals_compared,
    -- 【为什么是数组而不是一个 kind】一条收货可以同时短交、收错料、化验超差。
    -- 一个 text 列只装得下其中一个,而"装不下的那些"会变成静默丢失。
    (ARRAY[]::text[]
     || CASE WHEN po.status = ANY (ARRAY['closed'::text, 'cancelled'::text])
              AND lt.line_received_qty < pol.quantity
                  * (1::numeric - cfg.grn_short_pct / 100::numeric)
             THEN ARRAY['short'::text] ELSE ARRAY[]::text[] END
     || CASE WHEN lt.line_received_qty > pol.quantity
                  * (1::numeric + cfg.grn_over_pct / 100::numeric)
             THEN ARRAY['over'::text] ELSE ARRAY[]::text[] END
     || CASE WHEN b.declared_qty IS NOT NULL AND b.declared_qty > 0::numeric
              AND (b.quantity < b.declared_qty
                       * (1::numeric - cfg.grn_short_pct / 100::numeric)
                OR b.quantity > b.declared_qty
                       * (1::numeric + cfg.grn_over_pct / 100::numeric))
             THEN ARRAY['declared_vs_actual'::text] ELSE ARRAY[]::text[] END
     || CASE WHEN b.material_id IS DISTINCT FROM pol.material_id
             THEN ARRAY['material_mismatch'::text] ELSE ARRAY[]::text[] END
     || CASE WHEN ag.beyond THEN ARRAY['assay_beyond_tolerance'::text]
             ELSE ARRAY[]::text[] END
    ) AS kinds
   FROM inbound_batches b
     JOIN purchase_order_lines pol ON pol.id = b.purchase_order_line_id
     JOIN purchase_orders po ON po.id = pol.purchase_order_id
     JOIN suppliers sup ON sup.id = b.supplier_id
     JOIN materials om ON om.id = pol.material_id
     JOIN materials rm ON rm.id = b.material_id
     JOIN line_totals lt ON lt.line_id = pol.id
     CROSS JOIN cfg
     LEFT JOIN assay_gap ag ON ag.batch_id = b.id
  WHERE b.deleted_at IS NULL
    AND po.deleted_at IS NULL
    AND has_permission('module.purchasing.view'::text);

COMMENT ON VIEW public.grn_discrepancies IS
    'GRN-1a:收货差异,一条【挂了采购行的】收货一行 —— 订量、实收、申报量、三个差额,以及 kinds 点名哪里不对(short / over / declared_vs_actual / material_mismatch / assay_beyond_tolerance)。【三个阈值现读 receiving_settings,一个数都没写死】。
【它活过关单】—— po_receivable_lines 只收 confirmed/receiving,purchase_order_status 在【单】上汇总(一行超一行短可以正好抵成 100%),两个现成读者都在短交刚成为问题的那一刻消失。本视图两者都不做。
【没挂采购行的批次整行缺席,不是一行零】(work_order_fulfilment 的 has_plan 那一条:没估过 ≠ 估了零)。同理 assay_beyond_tolerance 在两侧缺任何一侧时是 NULL 而不是 false,declared_delta_qty 在没记申报量时是 NULL 而不是 0。
【short/over 是采购行级的事实,挂在该行的每一条收货上】:分批到货不该被报成短交,所以两者都比【累计】;而一条 short 出现两次的意思是"这一行短了、它有两次收货",要按行计数请 DISTINCT line_id。short 只在 closed/cancelled 时报(开着的单"少"只是"还没收完"),over 任何状态都报(它当场就占了地方、欠了钱)—— 与 processing_settings 那两个工单阈值逐字同一条。
【material_mismatch 是告警,永远不是拒绝】—— 换料是可以谈成的正当场景;但它必须【被点名】,因为它也正是"谎报货物性质"在技术上的样子。
【属主权限 + module.purchasing.view】:跨 inbound × purchasing 两个模块,invoker 会让无权那一侧的行被 RLS 静默丢掉、内连接把整行带走,读者得到的是"没有差异"而不是"受限"(OPS-14)。谓词取 purchasing 是因为【订量本来就只在那道门后面】(po_receivable_lines / purchase_order_status 同码),而线上每个持 purchasing.view 的角色都持 inbound.view —— 实测,不放宽任何一行。';

GRANT SELECT ON public.grn_discrepancies TO authenticated;

COMMIT;
