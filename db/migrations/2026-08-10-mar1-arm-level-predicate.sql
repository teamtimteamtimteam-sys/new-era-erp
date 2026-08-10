-- MAR-1:看板支的权限从【一个码】放宽到【一个谓词】—— 因为批次毛利需要两个模块
--
-- 走查:/margin 没有全局入口。查明它【不是被忘了】—— 它跨两个模块(收入在财务、
-- 分摊成本在加工),而 ModuleEntry.permission 是单个字符串,表达不了
-- data.view_prices AND (finance OR processing)。看板这一侧本来就更接近能表达它
-- (支的权限是数据的一列,不是清单里的一行),但它同样只有一个码。
--
-- 【两条路,选了 (a),理由写在这里】
--   (a) 支级谓词:再加一列 permission_any(ANY 语义),与既有的 permission(必须全有)
--       合起来表达"必须有 X,且 Y 之一"。本迁移走这条。
--   (b) 合成一个新权限码(如 report.margin.view):【不走】。它会在权限目录里多出
--       一条没人授过的条目,日后读起来像一条真的权限;更要命的是它是【第二份
--       "谁能看毛利"的定义】—— batch_margin 自己的谓词仍是 prices AND (fin OR proc),
--       两份必然漂开:有新码而无 prices 的人看得见牌子、点进去零行;有 prices 与
--       finance 却没被授新码的人看不见牌子、却进得去页面。OPS-15 拆掉的正是这种双份定义。
--
-- 【代价,如实记】
--   * 谓词由 arm_permission_any(item_type) 【一处】声明,SELECT 与 WHERE 共用它 ——
--     否则同一条规则会在视图里写两遍,那是本迁移正在拒绝的那种双份定义的小号版本。
--   * 19 支现有的 SELECT 列表【一个都不用动】(UNION ALL 要求各支列一致,改一支就得
--     改十九支);新列在外层算出来。
--   * 页面 TILES 要拿到同样的语义(permissionAny),fixture 45 钉住两侧对同一个人
--     给出同一个答案 —— 这正是 fixture 30 对单码支已经钉住的那件事。
--
-- 【这一支只收"可行动的那一半"】margin_status 有两种算不出:
--   no_unit_cost —— 加工单在、成本没分摊 → 分摊一次就清掉,是待办;
--   no_run       —— 这批货压根不是加工单产出的 → 事后无从补救,放上看板就是一盏
--                   关不掉的灯(REC-1 与 awaiting_assay 的同一条教训)。
-- 所以只收 no_unit_cost;no_run 仍作为一行留在 /margin 上,那是它该在的地方。
-- 线上此刻:no_unit_cost 3 批(收入 10,573)、no_run 1 批(24,000)。
--
-- 【为什么先 DROP】新列 permission_any 要插在 permission 后面才读得懂,而
-- CREATE OR REPLACE VIEW 只能在末尾追加列。已核对:库内没有任何视图/函数依赖
-- operations_now(唯一读者是首页)。
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

CREATE OR REPLACE FUNCTION public.has_any_permission(p_codes text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT EXISTS (SELECT 1 FROM unnest(p_codes) c WHERE has_permission(c));
$function$;

COMMENT ON FUNCTION public.has_any_permission(text[]) IS
    '持有其中【任意一个】权限码即为真(MAR-1)。has_permission 是单码判断;跨模块的看板支需要 ANY —— 批次毛利要 data.view_prices 且 finance 或 processing 之一,而没有任何 live 角色同时持有后两者。';

-- 支级附加谓词的【唯一声明处】。没有附加条件的支返回 NULL。
CREATE OR REPLACE FUNCTION public.arm_permission_any(p_item_type text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN p_item_type = 'margin_cost_not_allocated'
                THEN ARRAY['module.finance.view', 'module.processing.view']
           END;
$function$;

COMMENT ON FUNCTION public.arm_permission_any(text) IS
    '看板某一支除 permission 之外还需要【任意持有其一】的权限码(MAR-1);无附加条件返回 NULL。视图的 SELECT 与 WHERE 都读它 —— 一条规则一处声明。首页 TILES 必须与它同义,fixture 45 钉住。';

DROP VIEW public.operations_now;

CREATE VIEW public.operations_now WITH (security_invoker = off) AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.assay_count = 0
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
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
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text) a
  WHERE has_permission(permission)
    AND (arm_permission_any(item_type) IS NULL
         OR has_any_permission(arm_permission_any(item_type)));;

GRANT SELECT ON public.operations_now TO authenticated;

COMMIT;
