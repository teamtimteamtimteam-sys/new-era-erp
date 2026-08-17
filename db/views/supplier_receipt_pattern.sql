-- db/views/supplier_receipt_pattern.sql
-- GRN-2:一家供应商一行 —— 这家是不是【一直】短交。
--
-- NOTE: introduced by db/migrations/2026-08-18-grn2-supplier-receipt-pattern.sql.
-- First-run script. Re-running requires DROP VIEW first.
--
-- 【为什么它存在】一次短交是行情,连续短交是供应商问题,而这两件事今天在屏幕上
-- 一模一样。grn_discrepancies 逐条说得出"这一条怎么了",它说不出"这一家一向如何"。
--
-- 【三个计数是三件不同的事,永远不许合并】
--   comparable_receipts —— 窗口内、有日期、比对得了的。**它是分母。**
--   excluded_receipts   —— 有日期,但没有订量可比(判据是【不在 grn_discrepancies
--                          里】,因此也涵盖"采购单被软删"这条路)。**不是合规。**
--   undated_receipts    —— 没有到货日,放不进任何窗口。**第三类。**
-- 把后两类折进分母,等于把"不知道"算成"没问题"。
--
-- 【undated_with_discrepancy 是这一族最要紧的数】
-- 它回答"把日期补上会不会改变结论"。实测(2026-08-18):全库 14 条在册收货里
-- 7 条没有到货日,其中 3 条是可比对的 —— 而**全库唯一一条 short(IN-2026-0029)
-- 就在这一类里**。一个朴素的窗口谓词会让 Acme 显示"零次短交",正是这一刀
-- 要消灭的那种假话。(FIN-32 之后新行必填到货日,所以这一类只会缩小。)
--
-- 【次数按收货算,数量按采购行算】line_delta_qty 是行级事实、挂在该行的每一条
-- 收货上,按收货求和会把挂了多次收货的行算两遍(线上已有一条)。
--
-- 【没有"一贯短交"布尔量,也没有百分比】前者需要一个没有人选过的阈值,
-- 后者藏起分母(1 次里 1 次也是 100%)。给原始计数,判断留给读的人。
--
-- 【短交的定义只有一处】本视图读 grn_discrepancies,不重算。三个阈值现读
-- receiving_settings 并【原样返回】,好让屏幕显示的就是判出这些计数的那三个数。
--
-- 【属主权限 + module.purchasing.view】跨 purchasing × inbound 两模块,invoker 会
-- 让无权那侧的行被 RLS 静默丢掉(OPS-14)。实测线上没有任何角色持 purchasing.view
-- 而不持 inbound.view,所以这道门不比今天任何一条路径更宽。

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
  WHERE s.deleted_at IS NULL AND has_permission('module.purchasing.view'::text);
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
