-- db/functions/portal_document_open.sql
-- MES-9b(2026-10-19,MES-9 Step 0 Q14 · Q22,Tim):【门户取一份签发档】—— 写下载记录,交出桶、路径与当时记下的 sha256。
--   先过 portal_require_link()(角色 · 链接 · 撤销 · 会话)。p_kind 是 purchase_order / supplier_statement / cod,p_issue_id 是那一份
--   签发记录(po_issues / supplier_statement_issues / cod_issues)的 id —— 都来自 portal_documents() 的清单。
--   【不是自己那一家的,与根本不存在的,同一句拒】PORTAL_DOCUMENT_NOT_FOUND —— 不给"那一份是别人的"这个事实当作答案。
--   作废的销毁证书 → PORTAL_DOCUMENT_VOID|<号>(作废的证书不再交给任何人);还没签发的销毁证书没有签发记录,自然 NOT_FOUND。
--   软删的采购单的签发档不交(NOT_FOUND)。种类不认识 → PORTAL_DOCUMENT_KIND_UNKNOWN|<种类>。
--   【写的只有一行下载记录】(portal_document_downloads,调用者自己的链接);别的一样都不写(委托书:门户用户除此之外什么都写不了)。
--   那一行也是存储的钥匙:portal_can_read_object 只放行两分钟内有这一行的那一个对象 —— 于是每一次取字节前面都有一行记录。
--   字节由路由以【这个会话自己的令牌】从桶里取,重算 sha256,对不上就 409(app/portal/documents/file/route.ts)。
--   EXECUTE 只授 supplier_portal(zzz_function_grants.sql;db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql.
CREATE OR REPLACE FUNCTION public.portal_document_open(p_kind text, p_issue_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link     uuid := portal_require_link();
    v_user     uuid;
    v_supplier uuid;
    v_bucket   text;
    v_path     text;
    v_sha      text;
    v_code     text;
    v_version  integer;
    v_owner    uuid;
    v_status   text;
    v_log      uuid;
BEGIN
    SELECT p.user_id, p.supplier_id INTO v_user, v_supplier FROM supplier_portal_users p WHERE p.id = v_link;
    IF p_kind = 'purchase_order' THEN
        v_bucket := 'po-documents';
        SELECT i.file_path, i.sha256, po.code, i.version, po.supplier_id
          INTO v_path, v_sha, v_code, v_version, v_owner
          FROM po_issues i JOIN purchase_orders po ON po.id = i.purchase_order_id
         WHERE i.id = p_issue_id AND po.deleted_at IS NULL;
    ELSIF p_kind = 'supplier_statement' THEN
        v_bucket := 'supplier-statement-documents';
        SELECT i.file_path, i.sha256, st.code, i.version, st.supplier_id
          INTO v_path, v_sha, v_code, v_version, v_owner
          FROM supplier_statement_issues i JOIN supplier_statements st ON st.id = i.statement_id
         WHERE i.id = p_issue_id;
    ELSIF p_kind = 'cod' THEN
        v_bucket := 'cod-documents';
        SELECT i.file_path, i.sha256, c.code, b.supplier_id, c.status
          INTO v_path, v_sha, v_code, v_owner, v_status
          FROM cod_issues i JOIN certificates_of_destruction c ON c.id = i.cod_id
          JOIN inbound_batches b ON b.id = c.inbound_batch_id
         WHERE i.id = p_issue_id;
    ELSE
        RAISE EXCEPTION 'PORTAL_DOCUMENT_KIND_UNKNOWN|%', COALESCE(p_kind, '');
    END IF;
    IF v_path IS NULL OR v_owner IS DISTINCT FROM v_supplier THEN
        RAISE EXCEPTION 'PORTAL_DOCUMENT_NOT_FOUND';
    END IF;
    IF p_kind = 'cod' AND v_status = 'void' THEN
        RAISE EXCEPTION 'PORTAL_DOCUMENT_VOID|%', v_code;
    END IF;
    IF p_kind = 'cod' AND v_status IS DISTINCT FROM 'issued' THEN
        RAISE EXCEPTION 'PORTAL_DOCUMENT_NOT_FOUND';
    END IF;
    INSERT INTO portal_document_downloads (portal_user_id, user_id, supplier_id, document_kind, issue_id, document_code, version,
                                           bucket_id, file_path, sha256)
    VALUES (v_link, v_user, v_supplier, p_kind, p_issue_id, v_code, v_version, v_bucket, v_path, v_sha)
    RETURNING id INTO v_log;
    RETURN jsonb_build_object(
        'log_id', v_log,
        'bucket', v_bucket,
        'file_path', v_path,
        'sha256', v_sha,
        'filename', v_code || COALESCE('-v' || v_version, '') || '.pdf');
END;
$function$;
