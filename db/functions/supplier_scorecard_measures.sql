-- db/functions/supplier_scorecard_measures.sql
-- MES-8a(2026-10-16,MES-0 Q78 · MES-8 Step 0 Q2 · Q3 · Q4,Tim):【一家供应商在一个窗口里的评分卡计数 —— 现算】。只有计数,没有金额。
--   窗口由调用者给(评审人输入,Q4);必填、不倒置、不晚于今天(新加坡日子)。门 module.suppliers.view(Q91:分数跟着供应商的查看码)。
--   一张收货"在窗口里" = 到货日(没有就取建单日)落在 [from, to];没删的。
--   【计分的几项】(scored —— 键名正好是 supplier_scorecard_measure_keys(),V23 的权重按它们给):
--     short_lines            短交的采购行(按行 DISTINCT —— grn_discrepancies 的抬头:一条 short 出现两次是"这一行短了、它有两次收货")。
--                            短交只在单 closed / cancelled 时判(开着的单"少"只是还没收完),所以【比过的】= 窗口里收货所在的、单已关的那些行;
--                            单还开着的行与没挂采购行的收货 = "not compared"。
--     over_lines             超交的采购行(DISTINCT);每一条挂了行的都比得了,没挂采购行的收货 = not compared。
--     ncr_open · ncr_accept · ncr_accept_with_penalty · ncr_reject · ncr_rework · ncr_downgrade
--                            窗口里开的、挂在这一家的进料批次上的不合格报告,按处置(还开着的单独一项)。
--     disputes               窗口里开的、挂在这一家的进料批次上的化验争议(撤回的不算,只显示)。
--     discharge_mismatches   采购时的深度放电判断与到货的实际判断互相矛盾的收货(grn_discrepancies 的 deep_discharge_contradicted);
--                            任一侧没下判断(NULL / not_assessed)= not compared,没挂采购行的收货也是。
--     certificate_lapse_days 这一家持有过的每一类 block / warn 证书,窗口里【一张有效的都没有】的天数之和;
--                            一类这样的证书都没有 = not compared(没有可以过期的东西)。
--   ★【一次没比过的比较读"not compared",永远不是 0】(Q3;known-issues 的 NULL-AS-ZERO 那一条):比过的个数是 0 时 count 是 null。
--     屏幕照它说"Not compared";评级时一项 null 不计分(supplier_scorecard_grade)—— 也就是说,没比过的不算这一家的错,而评审会把它抄下来。
--   【只显示、不计分】(shown):grade_breaches —— contract_grade_breaches 在窗口里(按化验日)这一家的行数,带着 CONTRACT-1 的说明:
--     那个判据不看品位规格的物料、也不看化验是哪一方出的,在它上面计分就是按一个已知会判错的判据给供应商打分。
--   【一份定义,不重算】短交 / 超交 / 放电判断矛盾读 grn_discrepancies_all(grn_discrepancies 的底视图 —— 外壳的 module.purchasing.view 按调用者
--     解析,持 suppliers.view 而不持 purchasing.view 的读者在这里会读到零行,于是底视图)。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.supplier_scorecard_measures(p_supplier_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_today      date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_code       text;
    v_receipts   int;
    v_noline     int;
    v_short      int;
    v_short_cmp  int;
    v_short_open int;
    v_over       int;
    v_over_cmp   int;
    v_dd         int;
    v_dd_cmp     int;
    v_dd_null    int;
    v_ncr        jsonb;
    v_disp       int;
    v_disp_wd    int;
    v_cert_types int;
    v_cert_days  int;
    v_breaches   int;
BEGIN
    PERFORM require_permission('module.suppliers.view');
    SELECT s.code INTO v_code FROM suppliers s WHERE s.id = p_supplier_id AND s.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', COALESCE(p_supplier_id::text, '?');
    END IF;
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'SCORECARD_WINDOW_REQUIRED';
    END IF;
    IF p_to < p_from THEN
        RAISE EXCEPTION 'SCORECARD_WINDOW_INVALID|%|%', p_from, p_to;
    END IF;
    IF p_to > v_today THEN
        RAISE EXCEPTION 'SCORECARD_WINDOW_FUTURE|%|%', p_to, v_today;
    END IF;

    -- ── 收货 ───────────────────────────────────────────────────────────────
    SELECT count(*), count(*) FILTER (WHERE b.purchase_order_line_id IS NULL)
      INTO v_receipts, v_noline
      FROM inbound_batches b
     WHERE b.supplier_id = p_supplier_id AND b.deleted_at IS NULL
       AND COALESCE(b.arrival_date, b.created_at::date) BETWEEN p_from AND p_to;

    WITH g AS (
        SELECT g.*
          FROM grn_discrepancies_all g
          JOIN inbound_batches b ON b.id = g.batch_id
         WHERE g.supplier_id = p_supplier_id
           AND COALESCE(b.arrival_date, b.created_at::date) BETWEEN p_from AND p_to
    )
    SELECT count(DISTINCT g.line_id) FILTER (WHERE 'short' = ANY (g.kinds)),
           count(DISTINCT g.line_id) FILTER (WHERE g.po_status IN ('closed', 'cancelled')),
           count(DISTINCT g.line_id) FILTER (WHERE g.po_status NOT IN ('closed', 'cancelled')),
           count(DISTINCT g.line_id) FILTER (WHERE 'over' = ANY (g.kinds)),
           count(DISTINCT g.line_id),
           count(*) FILTER (WHERE g.deep_discharge_contradicted IS TRUE),
           count(*) FILTER (WHERE g.deep_discharge_contradicted IS NOT NULL),
           count(*) FILTER (WHERE g.deep_discharge_contradicted IS NULL)
      INTO v_short, v_short_cmp, v_short_open, v_over, v_over_cmp, v_dd, v_dd_cmp, v_dd_null
      FROM g;

    -- ── 不合格报告,按处置 ────────────────────────────────────────────────────
    SELECT jsonb_object_agg(k.key, jsonb_build_object('count', COALESCE(c.n, 0)))
      INTO v_ncr
      FROM (VALUES ('ncr_open', NULL::text), ('ncr_accept', 'accept'), ('ncr_accept_with_penalty', 'accept_with_penalty'),
                   ('ncr_reject', 'reject'), ('ncr_rework', 'rework'), ('ncr_downgrade', 'downgrade')) k(key, disposition)
      LEFT JOIN LATERAL (
            SELECT count(*) AS n
              FROM nonconformance_reports n
              JOIN inbound_batches b ON b.id = n.inbound_batch_id
             WHERE b.supplier_id = p_supplier_id
               AND (n.opened_at AT TIME ZONE 'Asia/Singapore')::date BETWEEN p_from AND p_to
               AND ((k.disposition IS NULL AND n.status = 'open')
                    OR (k.disposition IS NOT NULL AND n.status = 'decided' AND n.disposition = k.disposition))
      ) c ON true;

    -- ── 化验争议(买方那一侧:挂在这一家的进料批次上)──────────────────────────
    SELECT count(*) FILTER (WHERE d.status <> 'withdrawn'), count(*) FILTER (WHERE d.status = 'withdrawn')
      INTO v_disp, v_disp_wd
      FROM assay_disputes d
      JOIN inbound_batches b ON b.id = d.inbound_batch_id
     WHERE b.supplier_id = p_supplier_id
       AND (d.created_at AT TIME ZONE 'Asia/Singapore')::date BETWEEN p_from AND p_to;

    -- ── 证书断档的天数:每一类 block / warn 证书,窗口里一张有效的都没有的那几天 ─────────
    SELECT count(*) INTO v_cert_types
      FROM (SELECT DISTINCT c.cert_type_code
              FROM supplier_compliance c JOIN certificate_types t ON t.code = c.cert_type_code
             WHERE c.supplier_id = p_supplier_id AND c.deleted_at IS NULL AND t.disposition IN ('block', 'warn')) x;
    SELECT count(*) INTO v_cert_days
      FROM (SELECT DISTINCT c.cert_type_code
              FROM supplier_compliance c JOIN certificate_types t ON t.code = c.cert_type_code
             WHERE c.supplier_id = p_supplier_id AND c.deleted_at IS NULL AND t.disposition IN ('block', 'warn')) ty
     CROSS JOIN generate_series(p_from, p_to, interval '1 day') d(day)
     WHERE NOT EXISTS (SELECT 1 FROM supplier_compliance c2
                        WHERE c2.supplier_id = p_supplier_id AND c2.deleted_at IS NULL AND c2.cert_type_code = ty.cert_type_code
                          AND (c2.valid_from IS NULL OR c2.valid_from <= d.day::date)
                          AND (c2.valid_until IS NULL OR d.day::date <= c2.valid_until));

    -- ── 等级超标:只显示,不计分(CONTRACT-1)────────────────────────────────────
    SELECT count(*) INTO v_breaches
      FROM contract_grade_breaches gb
      JOIN inbound_batches b ON b.id = gb.inbound_batch_id
     WHERE b.supplier_id = p_supplier_id AND gb.assay_date BETWEEN p_from AND p_to;

    RETURN jsonb_build_object(
        'supplier_id',   p_supplier_id,
        'supplier_code', v_code,
        'window_from',   p_from,
        'window_to',     p_to,
        'receipts',      v_receipts,
        'receipts_without_po_line', v_noline,
        'scored', jsonb_build_object(
            'short_lines', jsonb_build_object(
                'count', CASE WHEN v_short_cmp > 0 THEN v_short END,
                'compared', v_short_cmp, 'not_compared', v_short_open + v_noline),
            'over_lines', jsonb_build_object(
                'count', CASE WHEN v_over_cmp > 0 THEN v_over END,
                'compared', v_over_cmp, 'not_compared', v_noline),
            'discharge_mismatches', jsonb_build_object(
                'count', CASE WHEN v_dd_cmp > 0 THEN v_dd END,
                'compared', v_dd_cmp, 'not_compared', v_dd_null + v_noline),
            'disputes', jsonb_build_object('count', v_disp),
            'certificate_lapse_days', jsonb_build_object(
                'count', CASE WHEN v_cert_types > 0 THEN v_cert_days END,
                'compared', v_cert_types, 'not_compared', CASE WHEN v_cert_types = 0 THEN 1 ELSE 0 END)
        ) || v_ncr,
        'shown', jsonb_build_object(
            'grade_breaches', jsonb_build_object('count', v_breaches, 'scored', false, 'caveat', 'CONTRACT-1'),
            'disputes_withdrawn', jsonb_build_object('count', v_disp_wd, 'scored', false))
    );
END;
$function$
