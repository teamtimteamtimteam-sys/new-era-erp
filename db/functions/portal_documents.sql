-- db/functions/portal_documents.sql
-- MES-9b(2026-10-19,MES-9 Step 0 Q14 · Q15,Tim):【门户的单据】—— 调用者自己那一家的采购单、供应商对账单、销毁证书,每一份【只以它签发时存下的 PDF】出现。
--   先过 portal_require_link()(角色 · 链接 · 撤销 · 会话);供应商只从链接推出来,没有任何参数。
--   这里只回【清单】:单据号、日期、状态,以及每一份签发档(签发记录 id · 版本 · 签发时刻 · 是不是最新的那一版)。字节在桶里,经
--   portal_document_open() 取(它写下载记录),路由再对着记下的 sha256 重算 —— 对不上就 409。
--   【一个价钱都没有】(Q15):金额、单价、币种、条款、备注一样都不回 —— 价钱只印在它自己那几份签发档上。
--   【没签发、作废、被取代的照直说,绝不按活数据渲染】:
--     · 采购单:没删的、并且(签发过,或者已批准且不是草稿)。没有签发档的那一张回 issues = [](页面写"还没签发");
--       草稿、待批、被拒、软删的不出现(那些不是一张发给供应商的单)。被取消的照样列出、标 cancelled,它签发过的档案照样取得到。
--     · 对账单:每一份都是签发那一刻冻下来的;被取代的标 superseded 与取代它的那一份的号;没有存档 PDF 的回 issues = []。
--     · 销毁证书:经收货单认是哪一家的。pending(还没签发,也没有号)标 pending;void 标 void 与替它的那一张的号 ——
--       【作废的不给档案】(issue 回 null,portal_document_open 按名拒 PORTAL_DOCUMENT_VOID);签发了却没有存档 PDF 的,issue 回 null。
--   EXECUTE 只授 supplier_portal(zzz_function_grants.sql;db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql.
CREATE OR REPLACE FUNCTION public.portal_documents()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link     uuid := portal_require_link();
    v_supplier uuid;
BEGIN
    SELECT p.supplier_id INTO v_supplier FROM supplier_portal_users p WHERE p.id = v_link;
    RETURN jsonb_build_object(
        'supplier_code', (SELECT s.code FROM suppliers s WHERE s.id = v_supplier),
        'purchase_orders', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', po.id,
                       'code', po.code,
                       'order_date', po.order_date,
                       'state', CASE WHEN po.status = 'cancelled' THEN 'cancelled'
                                     WHEN po.status = 'closed' THEN 'closed' ELSE 'open' END,
                       'issues', COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                                      'issue_id', i.id, 'version', i.version, 'issued_at', i.issued_at,
                                      'current', i.version = (SELECT max(i2.version) FROM po_issues i2 WHERE i2.purchase_order_id = po.id))
                                  ORDER BY i.version DESC)
                             FROM po_issues i WHERE i.purchase_order_id = po.id), '[]'::jsonb))
                   ORDER BY po.order_date DESC, po.code DESC)
              FROM purchase_orders po
             WHERE po.supplier_id = v_supplier AND po.deleted_at IS NULL
               AND (EXISTS (SELECT 1 FROM po_issues i WHERE i.purchase_order_id = po.id)
                    OR (po.status <> 'draft' AND po.approval_status = 'approved'))), '[]'::jsonb),
        'statements', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', st.id,
                       'code', st.code,
                       'period_start', st.period_start,
                       'period_end', st.period_end,
                       'issued_at', st.issued_at,
                       'state', CASE WHEN st.superseded_at IS NULL THEN 'current' ELSE 'superseded' END,
                       'superseded_by_code', (SELECT s2.code FROM supplier_statements s2 WHERE s2.id = st.superseded_by),
                       'issues', COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                                      'issue_id', i.id, 'version', i.version, 'issued_at', i.issued_at,
                                      'current', i.version = (SELECT max(i2.version) FROM supplier_statement_issues i2 WHERE i2.statement_id = st.id))
                                  ORDER BY i.version DESC)
                             FROM supplier_statement_issues i WHERE i.statement_id = st.id), '[]'::jsonb))
                   ORDER BY st.period_end DESC, st.code DESC)
              FROM supplier_statements st
             WHERE st.supplier_id = v_supplier), '[]'::jsonb),
        'cods', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', c.id,
                       'code', c.code,
                       'receipt_code', b.code,
                       'completed_on', c.completed_on,
                       'state', c.status,
                       'issued_at', c.issued_at,
                       'replaced_by_code', (SELECT c2.code FROM certificates_of_destruction c2 WHERE c2.id = c.replaced_by_cod_id),
                       'issue', (SELECT jsonb_build_object('issue_id', i.id, 'issued_at', i.issued_at)
                                   FROM cod_issues i WHERE i.cod_id = c.id AND c.status = 'issued'))
                   ORDER BY c.completed_on DESC, c.created_at DESC)
              FROM certificates_of_destruction c
              JOIN inbound_batches b ON b.id = c.inbound_batch_id
             WHERE b.supplier_id = v_supplier), '[]'::jsonb));
END;
$function$;
