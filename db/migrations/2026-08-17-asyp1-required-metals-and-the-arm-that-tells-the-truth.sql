-- ASY-P1:物料带着它要求的金属,awaiting_assay 于是说得出真话(数据库那一半)
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【改之前那一支在问什么】operations_now 的 awaiting_assay 支写的是
--     FROM batch_assay_status b WHERE b.assay_count = 0
-- 也就是【这个批次一份化验都没有】。它有两个毛病,都是线上量出来的:
--
--   ① **它看不见"化验做了一半"。** IN-2026-0001 只有一份已应用化验,覆盖 cu 一种
--      金属;IN-2026-0156 只覆盖 co。两个都【不亮】,因为 assay_count > 0 ——
--      而"这个批次该化验的金属化验齐了吗"这个问题,它从来没有问过。
--   ② **它点着两盏永远灭不掉的灯。** IN-2026-0011(14 kg)与 IN-2026-0153(680 kg)
--      的 remaining_qty 都是 **0** —— 料已经全部耗掉了。化验要取样,而【样没了】,
--      所以这两盏灯不是"等人处理",是"没人处理得了"。一盏灭不掉的灯会教人别看
--      这块看板,那比不点这盏灯坏得多。
--
-- 【新的一支问的是】:这个批次的物料【声明了】要化验哪些金属,而其中至少一种
-- 还没有被一份【已应用的】化验覆盖,并且这个批次【还救得回来】(remaining_qty > 0)。
-- 行上点名【缺哪几种金属】。
--
-- 【"覆盖"读的是哪几列 —— 量过之后选的,不是挑的】两条候选:
--   P1  assay_results(applied_at IS NOT NULL, deleted_at IS NULL)
--       ⋈ assay_result_metals(metal)          ← 采用
--   P2  inbound_batch_metals.content_source = 'assay'
--   线上实测:**19 行进料含量的 content_source 全部是 NULL**(PROC-1 之前写入,
--   出处未知,刻意不回填)。用 P2 会把【每一个批次】判成零覆盖,包括 IN-2026-0152
--   与 IN-2026-0181 那两个六种金属齐备的。P1 在同一批数据上给出正确答案。
--   而且 P1 是"已应用的化验覆盖了这种金属"这句话的【字面】表达,不需要中转。
--
-- 【手工填的含量不算覆盖,这是有意的】IN-2026-0003 有 co/cu/ni 三行含量却没有任何
-- 化验单。这一支叫 awaiting_ASSAY —— 人手敲进去的数字不是实验室结论。
-- 与 PROC-1 那条同源:出处是【记录】的,绝不从"有没有数字"反推。
--
-- 【为什么耗尽的批次退出,而理由要说准】任务书上的说法是"没有任何东西补救得了"。
-- **那句话不准确,而准确的理由更强**:耗尽的批次【财务上仍然补救得了】——
-- reprice_split 对 remaining_qty = 0 的批次照样算,差额整份进 5000。
-- 真正的理由是【取不到样】:料已经不在了,这份化验永远做不出来。
-- 对一支"等化验"的告警,这才是它该退出的原因。
--
-- 【选项 3 成立:可见,但绝不拦路】本迁移不改任何提交路径 —— 收货、应用化验、
-- 计价、加工一个字没动。缺化验是【看板上的一行】,不是一道闸。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 物料要求哪些金属
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.material_required_metals (
    material_id uuid NOT NULL REFERENCES public.materials (id) ON DELETE CASCADE,
    -- 【七金属 CHECK:照抄,因为这个仓库没有别的写法】
    -- 全库没有 domain、没有 enum —— 同一个集合内联在 7 张表的 CHECK 与 3 个函数的
    -- IF 里(metal_prices / inbound_batch_metals / output_batch_metals /
    -- assay_result_metals / pricing_formula_metals / pricing_formula_history /
    -- pricing_term_commitment_metals)。加金属时要【同时】放宽全部这些。
    -- 本表因此是第八处,而不是第一处例外:现在去建 domain 会是一次动 10 个地方的
    -- 单独的刀,混进这一刀里就是趁人不注意改一条全库约定。
    metal       text NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    -- 【复合主键【就是】那条 UNIQUE (material_id, metal)】—— 与
    -- inbound_batch_metals / assay_result_metals 同形:属性行,没有代理键,没有软删。
    PRIMARY KEY (material_id, metal)
);

COMMENT ON TABLE public.material_required_metals IS
$$ASY-P1:这种物料【应当化验哪些金属】。一物料一金属一行。

【没有行 = 没有要求,而这是一个假设,不是一个事实】它读作"这种物料不需要化验",
而它同样是"还没有人为这种物料想过这件事"的样子 —— 两者在本表里长得一模一样。
所以界面那一半(ASY-P2)必须在【每一个】物料上把这个状态按名印出来(「无化验要求」),
而不是让空白自己去说话。本迁移落地时线上 4 个在册物料【全部】没有要求,
因此 awaiting_assay 会安静下来,直到有人填进来 —— 那是这条默认的直接后果,写在这里。

【为什么不给一个"已决定:不需要"的第三态】那会是更诚实的模型,而它也会是一次
关于"谁在什么时候决定的、凭什么"的设计,不属于这一刀。缺口记在这里。$$;

ALTER TABLE public.material_required_metals ENABLE ROW LEVEL SECURITY;

-- 【读跟着物料字典走】能看物料的人就能看它要求哪些金属 —— 这不是第二个秘密。
CREATE POLICY "material_required_metals select by permission"
    ON public.material_required_metals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.materials.view'::text));

-- 【写只走函数,所以基表上【不给】INSERT/UPDATE/DELETE 策略】
-- 没有策略 = 没有任何 authenticated 的写入路径能过 RLS。唯一入口是下面那个
-- SECURITY DEFINER 函数,它自己 require_permission('module.materials.edit')。
-- 这样"整套要求"永远是一次替换,不会出现改了一半的中间态。

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 唯一写入口:整套替换
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.set_material_required_metals(
    p_material_id uuid,
    p_metals text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_metal text;
    v_clean text[];
BEGIN
    PERFORM require_permission('module.materials.edit');

    IF p_material_id IS NULL THEN
        RAISE EXCEPTION 'MATERIAL_REQUIRED';
    END IF;
    SELECT code INTO v_code FROM materials WHERE id = p_material_id AND deleted_at IS NULL;
    -- 【物料不存在 ≠ 物料没有要求】前者是问错了问题。合成一个"没有要求"就是把
    -- 打错的 id 显示成一个正当的答案(mustRows / restRows / ACCOUNT_NOT_FOUND 同一条)。
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', p_material_id;
    END IF;

    -- 【NULL 与空数组【都】是"清空要求",而它们必须走到同一个地方】
    -- 一个把 NULL 读成"什么都不做"的实现,会让"取消全部要求"这个动作静默失败。
    v_clean := COALESCE(p_metals, ARRAY[]::text[]);

    FOREACH v_metal IN ARRAY v_clean LOOP
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
            RAISE EXCEPTION 'METAL_UNKNOWN|%', COALESCE(v_metal, '(null)');
        END IF;
    END LOOP;

    -- 【重复的金属按名拒,不是悄悄去重】传 ['cu','cu'] 的调用方对自己要什么是糊涂的,
    -- 而去重会让它以为自己说清楚了。
    IF (SELECT count(*) FROM unnest(v_clean)) <>
       (SELECT count(DISTINCT x) FROM unnest(v_clean) x) THEN
        RAISE EXCEPTION 'METAL_DUPLICATED|%', array_to_string(v_clean, ',');
    END IF;

    -- 整套替换:先删后插,同一个事务 —— 不存在"改了一半"的中间态。
    DELETE FROM material_required_metals WHERE material_id = p_material_id;
    INSERT INTO material_required_metals (material_id, metal)
    SELECT p_material_id, x FROM unnest(v_clean) x;

    RETURN jsonb_build_object(
        'material_id', p_material_id,
        'material_code', v_code,
        -- 【空集就报空集,并且说出来它是空的】调用方(ASY-P2 的界面)据此印
        -- 「无化验要求」那句话,而不是靠"数组长度是 0"自己去猜一句文案。
        'metals', COALESCE(to_jsonb(v_clean), '[]'::jsonb),
        'metal_count', COALESCE(array_length(v_clean, 1), 0),
        'has_requirement', COALESCE(array_length(v_clean, 1), 0) > 0
    );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. 缺口视图:一个批次一行,点名缺哪几种金属
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是一张视图而不是把谓词塞进 operations_now】三个消费者:看板那一支、
-- ASY-P2 的批次页、以及 fixture。三处各写一遍就是三份会漂开的实现 ——
-- 这一条在这个仓库已经付过四次学费(AGENTS.md「预览过账的屏幕要问数据库」)。
--
-- 【属主权限,不是 invoker】它跨 inbound / materials / suppliers 三处。
-- invoker 会让 RLS 把读者无权那部分的行【静默丢掉】,而这里行消失意味着
-- "这个批次不缺化验" —— 一个错的好消息(OPS-14 的 xmodule 那一课)。
-- 所以属主权限读全量,体内带【读者自己的】模块谓词。
CREATE VIEW public.batch_required_assay_gaps WITH (security_invoker = off) AS
 SELECT g.inbound_batch_id,
    g.batch_code,
    g.material_id,
    g.material_code,
    g.material_name,
    g.supplier_name,
    g.arrival_date,
    g.remaining_qty,
    g.required_metals,
    g.missing_metals,
    -- 【还救不救得回来】料没了就取不到样,这份化验永远做不出来。
    -- 注意它【不是】"财务上还补救得了":reprice_split 对耗尽的批次照样算,
    -- 差额整份进 5000。取样与补价是两件事,这一支管的是前者。
    (g.remaining_qty > 0) AS sampleable
   FROM ( SELECT ib.id AS inbound_batch_id,
            ib.code AS batch_code,
            ib.material_id,
            m.code AS material_code,
            m.name AS material_name,
            sup.legal_name AS supplier_name,
            COALESCE(ib.arrival_date, ib.created_at::date) AS arrival_date,
            ib.remaining_qty,
            array_agg(r.metal ORDER BY r.metal) AS required_metals,
            -- 【缺 = 没有任何一份【已应用且在册】的化验带着这种金属的含量行】
            -- 读的就是 assay_results.applied_at + assay_result_metals.metal;
            -- 不读 inbound_batch_metals.content_source(线上 19 行全是 NULL,
            -- 用它会把每个批次都判成零覆盖 —— 见本迁移抬头的实测)。
            array_agg(r.metal ORDER BY r.metal) FILTER (
                WHERE NOT EXISTS (
                    SELECT 1
                      FROM assay_results ar
                      JOIN assay_result_metals arm ON arm.assay_result_id = ar.id
                     WHERE ar.inbound_batch_id = ib.id
                       AND ar.deleted_at IS NULL
                       AND ar.applied_at IS NOT NULL
                       AND arm.metal = r.metal)) AS missing_metals
           FROM inbound_batches ib
             JOIN materials m ON m.id = ib.material_id
             -- 【INNER JOIN 就是"这个物料有要求"那一条】没有要求的物料在这里
             -- 整个消失,不需要第二个判断。
             JOIN material_required_metals r ON r.material_id = ib.material_id
             LEFT JOIN suppliers sup ON sup.id = ib.supplier_id
          WHERE ib.deleted_at IS NULL
          GROUP BY ib.id, ib.code, ib.material_id, m.code, m.name, sup.legal_name,
                   ib.arrival_date, ib.created_at, ib.remaining_qty) g
  -- 一种都不缺的批次不出现在这里(array_agg FILTER 全不命中时是 NULL)
  WHERE g.missing_metals IS NOT NULL
    AND has_permission('module.inbound.view'::text);

COMMENT ON VIEW public.batch_required_assay_gaps IS
    'ASY-P1:每个【物料声明了化验要求、而其中至少一种金属还没有被一份已应用化验覆盖】的在册进料批一行,点名缺哪几种(missing_metals)。覆盖读 assay_results.applied_at ⋈ assay_result_metals.metal —— 手工敲进 inbound_batch_metals 的含量不算覆盖(这一支叫 awaiting_assay)。sampleable = remaining_qty > 0:料没了就取不到样,那盏灯灭不掉,所以看板那一支只取 sampleable 的行。属主权限 + 体内 module.inbound.view 谓词(跨三个模块,invoker 会静默丢行)。';

-- ════════════════════════════════════════════════════════════════════════════
-- 4. 那一支本身
-- ════════════════════════════════════════════════════════════════════════════
-- 【subject 从"供应商名"换成"缺哪几种金属"】subject 这一列在每一支里都是
-- 【那一支最该让人看见的那个事实】(assay_unapplied 放的是化验单号,
-- batch_unpriced 放的是供应商)。对这一支,能让人下一步动起来的是【缺哪几种】,
-- 不是这批货是谁送来的 —— 供应商名仍在 batch_required_assay_gaps 上,
-- 批次页要用随时取得到。
-- 【WHERE g.sampleable】= remaining_qty > 0。耗尽的批次退出这一支,理由见抬头:
-- 取不到样,所以这盏灯灭不掉;一盏灭不掉的灯会教人别看这块看板。
--
-- CREATE OR REPLACE 成立:输出列名、类型、顺序一个都没动,改的只是 UNION 里
-- 那一支的取数。

CREATE OR REPLACE VIEW public.operations_now AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            g.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            g.batch_code AS item_code,
            array_to_string(g.missing_metals, ', '::text) AS subject,
            g.arrival_date AS item_date
           FROM batch_required_assay_gaps g
          WHERE g.sampleable
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND sc.valid_until IS NOT NULL AND sc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            COALESCE(ar.sales_record_id, ar.invoice_id) AS item_id,
            ar.doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text
        UNION ALL
         SELECT 'metal_quote_stale'::text AS item_type,
            'module.pricing.view'::text AS permission,
            mp.latest_id AS item_id,
            NULL::text AS doc_kind,
            mp.metal AS item_code,
            mp.latest_price::text AS subject,
            mp.max_date AS item_date
           FROM ( SELECT p.metal,
                    max(p.price_date) AS max_date,
                    (array_agg(p.id ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_id,
                    (array_agg(p.price_usd_per_tonne ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_price
                   FROM metal_prices p
                  WHERE p.deleted_at IS NULL
                  GROUP BY p.metal) mp
          WHERE (CURRENT_DATE - mp.max_date) > (( SELECT ps.metal_quote_stale_days
                   FROM pricing_settings ps
                 LIMIT 1))
        UNION ALL
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))        UNION ALL
-- ── EXEC-3a:工单逾期 ──────────────────────────────────────────────────────
-- 【排产日为空【永远不是】逾期】—— 空的意思是"没排期",而不是"排在过去"。
-- 一个 COALESCE(scheduled_date, CURRENT_DATE) 会把没排期的全部报成今天到期,
-- COALESCE(..., 'infinity') 会把它们全部漏掉 —— 两个方向都错,所以这里
-- 显式 IS NOT NULL(WO-1c 记在 arm inventory 里的那条)。
--
-- 【"放行了三个月、从没排过期"该不该有别的支管】—— 仍然是一个【开着的问题】,
-- 记在 arm inventory 里。这一支不假装回答它:它只报"排了期而且过了期"的。
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text
            AND w.scheduled_date IS NOT NULL
            AND w.scheduled_date < CURRENT_DATE
        UNION ALL
-- ── EXEC-3a:工单差异超阈 ──────────────────────────────────────────────────
-- 【两种坏消息,两个阈值,两种触发时机】—— WO-1c 在 arm inventory 里留的那个
-- 问题("投入超耗与产出短交是否用同一个阈值")的答案是【不是】,所以
-- processing_settings 有两列,而这一支有两条腿:
--
--   * 投入超耗:吃掉的比计划多出 t_in% 以上。**开着的单和收了工的单都报** ——
--     超耗在它发生的那一刻就是可处理的事(料已经下去了,要么改计划、要么查为什么)。
--   * 产出短交:产出比预期少 t_out% 以上。**只报收了工的单** —— 在收工之前,
--     "少"只是"还没做完",把它报出来等于每天提醒一件正在进行的事。
--
-- 【没记录预期的行永远不报】has_plan = false 意味着没人估过,而不是估了零。
-- 一个把它当零的实现会让每一次产出都成为"短交 100%"—— 这正是 WO-1a 让
-- 预期产出行可选、WO-1b 让视图返回 NULL 的全部理由,在这里必须一路守住。
--
-- 阈值现读 processing_settings,不写死(与 metal_quote_stale 同一条)。
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
            CASE WHEN f.side = 'input'::text
                 THEN 'input overrun · ' || COALESCE(f.material_code, '?') || ' · '
                      || trim_scale(f.actual_qty)::text || ' / ' || trim_scale(f.planned_or_expected_qty)::text
                 ELSE 'output shortfall · ' || COALESCE(f.material_code, '?') || ' · '
                      || trim_scale(f.actual_qty)::text || ' / ' || trim_scale(f.planned_or_expected_qty)::text
            END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan
            AND f.planned_or_expected_qty > 0::numeric
            AND (
                 (f.side = 'input'::text
                  AND w2.status = ANY (ARRAY['released'::text, 'closed'::text])
                  AND f.actual_qty > f.planned_or_expected_qty
                      * (1::numeric + (SELECT ps.wo_input_overrun_pct FROM processing_settings ps LIMIT 1) / 100::numeric))
              OR (f.side = 'output'::text
                  AND w2.status = 'closed'::text
                  AND f.actual_qty < f.planned_or_expected_qty
                      * (1::numeric - (SELECT ps.wo_output_shortfall_pct FROM processing_settings ps LIMIT 1) / 100::numeric))
            )
) a
  WHERE has_permission(permission) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));;;;

GRANT SELECT ON public.operations_now TO authenticated;

COMMIT;
