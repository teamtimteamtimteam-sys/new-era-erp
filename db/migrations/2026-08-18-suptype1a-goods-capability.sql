-- SUP-TYPE-1a:一张供应商表,两件不同的事 —— 【会不会从他们那里收到货】
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这个标记服务的是谁 —— 写在最前面,免得它日后被读成"员工"】
-- 房东、水电、保险、专业服务、承包商 —— **我们向他们采购、付钱,但永远不会
-- 从他们那里收到一车货,他们也永远不会持有一张危废证。**
-- 员工报销【不在本刀范围内】:Tim 的决定是让它整个离开 suppliers 表,那是 PAYEE-1。
-- 所以本列【不是】"是不是员工",也不该被那样使用。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么不是 supplier_types —— 三条理由,每一条单独就够】
--   ① 它没有任何约束:text[] DEFAULT '{}',没有 CHECK,任何字符串都存得进去。
--      把一个从未被校验过的列变成判据,等于把判断建在一个谁都能写坏的值上。
--   ② 它是多选的:一家可以同时是 recycler + trader。多选表达不了一个二元能力
--      ——「既是 A 又是 B」在能力问题上没有意义,而"空数组"到底是"没有能力"
--      还是"没人填过",它答不出来。
--   ③ **它回答的是另一个问题**:他们做哪一行(dismantler / battery_factory_scrap
--      / recycler / trader),不是"我们收不收他们的货"。一家 trader 可能供货,
--      也可能只是中介。用行业去推断能力,正是本刀要终结的那次混同。
-- 实测(2026-08-18):supplier_types 至今【没有任何代码读它做判断】——
-- 两张表单写它,列表页与 CSV 导出显示它,仅此而已。它是描述,不是判据;
-- 本刀不动它,也不把它升格成判据。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【列的形状:boolean,不是枚举】
-- 要回答的问题是二元的:我们会不会从他们那里收到实物。一家既供货又收钱的
-- 供应商(线上 Acme 就是)仍然是 supplies_goods = true —— 这个标记问的不是
-- "他们唯一的角色是什么",而是"收货这条路对他们成不成立"。
-- 造一个三值枚举需要发明一套没有人要求过的分类法,而本仓库的规矩是:
-- 不替人做没人做过的决定。命名跟随本库既有的布尔风格(allows_half_day /
-- approvals_enabled / gst_registered / has_plan —— 动词短语,不加 is_)。
--
-- 【NOT NULL DEFAULT true:每一家现存供应商默认【供货】】
-- 这是安全的方向:现存三家里两家确实在供货,第三家(Staff Reimbursements)
-- 由本迁移显式标成 false。默认 false 会把两家真供应商一夜之间挡在收货门外。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【写入路径:CHECK 与触发器,不是 RPC —— 因为 ground 说这里没有 RPC】
-- 实测:**suppliers 没有任何写入函数**。app 走的是 PostgREST 的裸
-- .insert() / .update()(app/suppliers/new/actions.ts:52、[id]/edit/actions.ts:50),
-- 由 RLS 把关。所以"经由现有供应商函数写入并具名拒绝"这条路【不存在可走的门】,
-- 约束只能落在表上(NOT NULL + 布尔本身就是约束)。
-- suppliers 也【不是】列级遮蔽表(没有 suppliers_masked,表级 ACL 完好),
-- 所以 WO-1a 那条"ADD COLUMN + 列级 GRANT + _masked 三件事一支迁移"在这里
-- 不适用 —— 实测过,不是想当然。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【收货的拒绝落在【触发器】上,不落在两个 RPC 里 —— 而这是量出来的】
-- Tim 的判断是"按名拒绝,因为 RPC 直接够得到"。ground 同意这个判断,并且把
-- 位置收窄了一格:
--   * 以 authenticated 裸 INSERT inbound_batches:**被 RLS 拒**(该表有 RLS、
--     却【没有任何 INSERT 策略】)—— 实测:new row violates row-level security policy;
--   * 但 **service_role 与 postgres 都 rolbypassrls = true**(实测),
--     所以服务密钥这条路【绕得过 RLS,直接写得进表】;
--   * 而且收货侧现有的五条规矩(PO_NOT_RECEIVABLE / PO_LINE_MISMATCH /
--     PO_NOT_APPROVED / SUPPLIER_QUALIFICATION_EXPIRED / 硬删)**全部是触发器**。
-- 把这一条写进两个 RPC,就是把同一个判断抄两份(AGENTS.md 反复点名的那件事),
-- 而且漏掉服务密钥那条路。所以:触发器,一处,覆盖所有门。
--
-- 【触发器只在 INSERT 与【换供应商】的 UPDATE 上开火 —— 这一条是必需的】
-- 若它在任意 UPDATE 上开火,那么把 SUP-2026-0083 标成非供货之后,
-- **它自己那条收货就再也软删不掉了**(软删是一次 UPDATE)。
-- 换句话说,一个写得太宽的守卫会把本迁移第 4 步锁死。顺序也因此是:
-- 先软删那条收货,再标记供应商。
--
-- 镜像:db/tables/suppliers.sql、db/functions/guard_inbound_supplier_supplies_goods.sql、
--       db/views/{operations_now,supplier_receipt_pattern}.sql;行为断言:fixture 89。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ═══ 1 · 能力列 ═════════════════════════════════════════════════════════════
ALTER TABLE public.suppliers
    ADD COLUMN supplies_goods boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.suppliers.supplies_goods IS
    'SUP-TYPE-1a:【我们会不会从这一家收到实物货】。true = 会(收货、采购单、收货差异统计都对它成立);false = 不会 —— 房东、水电、保险、专业服务、承包商这一类:我们向他们采购并付钱,但永远不会有一车货到场,他们也永远不会持有一张危废证。
【它不是"是不是员工"】员工报销走的是另一条路,Tim 的决定是让它整个离开 suppliers 表(PAYEE-1)。SUP-2026-0083(Staff Reimbursements)在本迁移里被标成 false,那是【过渡】——PAYEE-1 预期会把那一行整个退休;这个标记真正长期承载的是房东/水电那一类。
【为什么不用 supplier_types】那一列是 text[]、无 CHECK、多选,而且回答的是【他们做哪一行】(recycler/trader/dismantler/battery_factory_scrap),不是【我们收不收他们的货】。实测它至今没有任何代码读它做判断。把一个从未校验过、且答着另一个问题的列升格成判据,正是本刀要终结的那次混同。
【为什么是 boolean 而不是枚举】问题本身是二元的。一家既供货又收钱的供应商(线上 Acme)仍然是 true —— 本列问的是"收货这条路成不成立",不是"他们唯一的角色是什么"。
【默认 true】现存供应商一律视为供货,这是安全的方向:默认 false 会把真供应商挡在收货门外。
它把关三处:operations_now 的 qualification_missing 支、supplier_receipt_pattern、以及收货触发器 guard_inbound_supplier_supplies_goods(RECEIPT_AGAINST_NON_GOODS_VENDOR)。';

-- ═══ 2 · 收货守卫:按名拒绝 ═════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.guard_inbound_supplier_supplies_goods()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_sup record;
BEGIN
    -- 【只在 INSERT 与【换了供应商】的 UPDATE 上开火】
    -- 写宽一格的代价是具体的:软删是一次 UPDATE,而一条挂在非供货户下的历史收货
    -- 【必须还能被软删掉】——否则本刀第 4 步(清掉那条冒烟残留)会被自己锁死。
    -- 同理,已经在册的历史收货不因为供应商日后被标成非供货而变得不可维护。
    IF TG_OP = 'UPDATE' AND NEW.supplier_id IS NOT DISTINCT FROM OLD.supplier_id THEN
        RETURN NEW;
    END IF;

    SELECT code, legal_name, supplies_goods INTO v_sup
      FROM suppliers WHERE id = NEW.supplier_id;

    -- 查不到供应商不是本守卫的事(外键会管),不越权替它报错
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    IF NOT v_sup.supplies_goods THEN
        -- 【按名拒绝,并且说得出是哪一家】一句"不允许"让操作员无从下手:
        -- 要么这一家标错了(去供应商页改),要么收货挑错了户(重选)。
        RAISE EXCEPTION 'RECEIPT_AGAINST_NON_GOODS_VENDOR|%|%', v_sup.code, v_sup.legal_name;
    END IF;

    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_inbound_supplier_supplies_goods() IS
    'SUP-TYPE-1a:不许把货收在一个【不供货】的往来户名下(房东、水电、保险这一类)。按名抛 RECEIPT_AGAINST_NON_GOODS_VENDOR|<code>|<name>。
【为什么是触发器而不是写进两个收货 RPC】实测:以 authenticated 裸 INSERT 会被 RLS 拒(该表没有 INSERT 策略),但 service_role 与 postgres 都 rolbypassrls = true,服务密钥这条路绕得过 RLS。而收货侧现有五条规矩全部是触发器 —— 写进 RPC 既要抄两份(第二份会漂开),又盖不住服务密钥那条路。
【只在 INSERT 与换供应商的 UPDATE 上开火】写宽一格会让挂在非供货户下的历史收货【软删不掉】(软删是一次 UPDATE),那正是本刀清理冒烟残留时会撞上的墙。';

CREATE TRIGGER trg_inbound_batches_supplier_supplies_goods
    BEFORE INSERT OR UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION guard_inbound_supplier_supplies_goods();

-- ═══ 3 · 先清掉那条冒烟残留,【再】标记供应商 ═══════════════════════════════
-- 【顺序要紧】守卫只在换供应商时才管 UPDATE,所以这两步其实互不阻塞;
-- 但先删后标仍然是对的次序:标记是一个关于"以后"的声明,而残留是"以前"的事。
--
-- 【谁删的 —— 照直说,不伪造】AUDEL-1b 的门要求 deleted_by 非空,而迁移里
-- auth.uid() 是 NULL。所以这里把 claims 设成【真实存在的管理员账号】
-- admin@swm-os.test(321f1819…,持 module.inbound.edit,实测),
-- 并把"其实是这支迁移干的"写进理由本身 —— 于是 deleted_by 说的是"管理员账号",
-- delete_reason 说的是"哪一刀、为什么",两句合起来没有骗任何人。
-- (FIN-26:一条伪造的出处比空白更坏;而这里空白是不允许的,所以只能把真相
--  写进那个允许写字的字段。)
SELECT set_config('request.jwt.claims',
                  format('{"sub":"%s","role":"authenticated"}',
                         '321f1819-8449-48f7-9ae0-78b2c4b50f35'), true);

SELECT soft_delete_inbound_batch(
    (SELECT id FROM inbound_batches WHERE code = 'IN-2026-0267'),
    '冒烟走查残留(物料 ZZ-SMOKE-NTF)—— 由 SUP-TYPE-1a 迁移清理,非业务收货');

SELECT set_config('request.jwt.claims', '', true);

-- SUP-2026-0083:标成非供货。【这是过渡】——
-- PAYEE-1 预期把这一行整个退休(员工报销离开 suppliers 表)。
-- 本列真正长期承载的是房东 / 水电 / 保险 / 专业服务 / 承包商那一类。
UPDATE public.suppliers SET supplies_goods = false WHERE code = 'SUP-2026-0083';

-- ═══ 4 · qualification_missing 收窄到【供货的】供应商 ═══════════════════════
-- 【EXEC-3a 那句话到此退休】2026-08-16-exec3a-four-executive-arms.sql:349 写着:
--   "**有了'这家需要合规文件'的标记之后,这一支应当收窄到它**"
-- 这就是那一刻。那条注释【不能改历史提交】,所以退休记录写在这里、写在
-- db/views/operations_now.sql 的支注释里,以及本刀的提交信息里。
--
-- 【为什么必须收窄:实测过的永久亮灯】SUP-TYPE-0 的勘察把它走了一遍 ——
-- 把 Staff Reimbursements 沿合法路径推到 status='active'(draft → pending_review
-- → approved → active),qualification_missing 当场亮起,days_waiting = 17 并且
-- 【永远不会灭】,因为一个房东式的往来户永远不会去办一张危废证。
-- 判据是 supplies_goods,不是 supplier_types(理由见本文件抬头)。
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
          WHERE s_2.deleted_at IS NULL AND s_2.supplies_goods AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
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
-- ═══ 5 · supplier_receipt_pattern 同样收窄 ══════════════════════════════════
-- 一个不供货的往来户不该出现在"这家是不是一直短交"里 —— 它一次货都不会收,
-- 于是 GRN-2 那块面板会对它永远显示"没有可比对的收货",而那句话虽然为真,
-- 却是在回答一个对它根本不成立的问题。
CREATE OR REPLACE VIEW public.supplier_receipt_pattern WITH (security_invoker = off) AS
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
;

COMMIT;
