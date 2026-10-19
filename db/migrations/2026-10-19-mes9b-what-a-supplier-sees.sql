-- db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql
-- MES-9b —— 供应商在门户里看得见什么:一位门户账号现在能打开它自己那一家的采购单、对账单与销毁证书【签发时存下的那一份 PDF】
--   (取的时候对着签发记录重算 sha256,对不上就 409),并看见它自己的收货与地磅单(按今天记着的样子,没有一个价钱);别家的、内部的、
--   活的价钱一样都看不见,每一次下载都记下来。(MES 组的第二十四刀,v1.4.61;发布那一行在 docs/handbacks/MES-9b.md 的抬头。)
--   由 db/scripts/build_mes9b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-19:MES-9 Step 0 §15 —— Q14 · Q15 · Q16–Q18 · Q22 照推荐;委托书把 Q14 / Q15 / Q22 逐字重述)
--   ① 一张新表 portal_document_downloads(门户下载记录,Q22):只追加;只经 portal_document_open 写;员工 module.suppliers.view 读;
--      变更记录的第九张豁免(它本身就是一份只追加的日志)—— change_log_exclusions() 换成九行。
--   ② 四支门户函数,只授 supplier_portal:portal_documents(单据清单)· portal_deliveries(收货与地磅单)·
--      portal_document_open(写调用者自己的一行下载记录,交出桶 · 路径 · 哈希)· portal_can_read_object(下面那条存储策略的判据)。
--   ③ 存储:supplier_portal 得到 storage 架构的 USAGE 与 storage.objects 的 SELECT;一条 TO supplier_portal 的读策略 —— 三个单据桶里、
--      这位门户账号两分钟内刚为之写下过下载记录的那一个对象(所以每一次取字节前面都有一行记录)。不能写、不能删、不能看别的。
--   门户角色够得着的每一样新东西都按名进了 db/portal-grants-baseline.tsv(判词八):四支函数 · 一个架构 · 一张表 · 一条策略,以及
--   storage 架构里对 PUBLIC 开着 EXECUTE 的 19 支平台函数(调用者权限;读到的行仍由那条策略筛)。
--
-- 【不做什么】不碰 hook、登录、刷新、空闲登出与大屏的豁免;不建任何门户账号;不建、不停、不改七个账号中的任何一个;不碰审批开关;
--   不改任何既有的行;不改任何既有的存储对象、桶或别的策略(存储策略 52 → 53,多的只有门户那一条);授权表一行不动;不回填;
--   require_calibrated_since 保持空。没有交货通知、争议回复、争议页、评分卡(Q16–Q18)。
--
-- 【破窗】这一窗什么都不坏:旧应用不读任何新东西;线上没有门户账号(供应商那一侧没有人调得到这四支);员工的令牌与读写一样都不变。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变,hook 对它们每一个仍逐字节原样返回;没有任何门户
--   账号;supplier_portal 能执行的 public 函数恰好是六支、能读的关系恰好是 storage.objects、能写的一样都没有;存储策略 53 条、作用于门户的恰好
--   那一条;存储对象一个字节不动(两张 COD 在内);在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;既有的行逐字未变;
--   本事务一行变更记录都没写;变更记录覆盖零缺口、豁免 9;324 张表;没有一张视图对 anon / authenticated 带写授权。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES9B_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.portal_document_downloads') IS NOT NULL OR to_regprocedure('public.portal_documents()') IS NOT NULL
       OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND policyname = 'portal reads its own logged issued documents') THEN
        RAISE EXCEPTION 'MES9B_PRE|MES-9b objects already exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supplier_portal') OR to_regprocedure('public.portal_require_link()') IS NULL THEN
        RAISE EXCEPTION 'MES9B_PRE|MES-9a (supplier_portal, portal_require_link) is expected on live';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test')) <> 7 THEN
        RAISE EXCEPTION 'MES9B_PRE|expected the 7 real accounts';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users) THEN
        RAISE EXCEPTION 'MES9B_PRE|no portal account is expected on live';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 323 THEN
        RAISE EXCEPTION 'MES9B_PRE|expected 323 public tables';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 52 THEN
        RAISE EXCEPTION 'MES9B_PRE|expected 52 storage policies';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES9B_PRE|expected 8 change-log exclusions';
    END IF;
    IF has_schema_privilege('supplier_portal', 'storage', 'USAGE') THEN
        RAISE EXCEPTION 'MES9B_PRE|supplier_portal already reaches schema storage';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9B_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'MES9B_PRE|expected the two recorded COD byte strings';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes9b_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';
CREATE TEMP TABLE mes9b_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes9b_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE mes9b_objects_before ON COMMIT DROP AS
SELECT bucket_id, name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects;
CREATE TEMP TABLE mes9b_policies_before ON COMMIT DROP AS
SELECT policyname, cmd, roles::text AS roles, COALESCE(qual, '') AS qual, COALESCE(with_check, '') AS with_check FROM pg_policies WHERE schemaname = 'storage';
CREATE TEMP TABLE mes9b_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) AS suppliers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM counterparty_contacts t ) AS counterparty_contacts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_portal_users t ) AS supplier_portal_users,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM account_settings t ) AS account_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM purchase_orders t ) AS purchase_orders,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM po_issues t ) AS po_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) AS certificates_of_destruction,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statements t ) AS supplier_statements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statement_issues t ) AS supplier_statement_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM weighbridge_tickets t ) AS weighbridge_tickets,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM weighbridge_ticket_shares t ) AS weighbridge_ticket_shares,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) AS permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) AS role_permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) AS roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) AS user_roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) AS finance_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) AS ingest_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM floor_board_settings t ) AS floor_board_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t ) AS document_types;

-- ── 1 · 守卫(镜像原样):下载记录只追加 ──

-- db/functions/guard_portal_document_download_append_only.sql
-- MES-9b(2026-10-19,MES-9 Step 0 Q22,Tim):门户下载记录【只追加】。一行写下就是"那一刻,这位门户账号要走了这一份签发档"的事实 ——
--   改一个字、删一行,它就不再证明任何事。UPDATE 拒(行级);DELETE / TRUNCATE 拒(【语句级】—— 没有 DELETE 策略时员工的 DELETE 在 RLS 那里
--   就是零行,行级触发器不会醒,U1-B 的那一课)。PORTAL_DOWNLOAD_LOG_APPEND_ONLY|<操作>。
--   写只经 portal_document_open()(SECURITY DEFINER,门户会话自己的那一行);它也是变更记录的第九张豁免(本身就是一份只追加的日志)。
--
-- NOTE: introduced by db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql.

CREATE OR REPLACE FUNCTION public.guard_portal_document_download_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'PORTAL_DOWNLOAD_LOG_APPEND_ONLY|%', lower(TG_OP);
END;
$function$;

-- ── 2 · 新表(镜像原样):门户下载记录(Q22)──

-- db/tables/portal_document_downloads.sql
-- MES-9b(2026-10-19,MES-9 Step 0 Q22,Tim):【门户下载记录】—— 一位门户账号每要走一份签发档,这里就多一行:谁(账号 · 链接 · 供应商)、
--   哪一份(种类 · 签发记录 id · 单据号 · 版本 · 桶里的路径 · 当时记下的 sha256)、什么时候。只记门户账号(员工的下载不记 —— docs/pdpa.md 的决定照旧)。
--
-- 【只追加】guard_portal_document_download_append_only:改、删、清空一律按名拒。
-- 【谁写】只经 portal_document_open()(SECURITY DEFINER,只授 supplier_portal):它先过 portal_require_link(角色 · 链接 · 撤销 · 会话),
--   再确认那一份签发档属于调用者自己那一家,然后写下这一行、交出路径与哈希。没有任何 INSERT / UPDATE / DELETE 策略,authenticated 与 anon
--   连写的授权都没有 —— 门户会话写得进的【只有】它自己的这几行,而且只经那一支函数(委托书:门户用户除此之外什么都写不了)。
-- 【它也是存储的钥匙】门户会话读桶里的那一份 PDF 时,存储策略(portal_can_read_object)要求【这位账号刚刚为这一个对象写下过一行】
--   (两分钟内)—— 于是绕过这张表直接去桶里取字节是取不到的:每一次真正的取字节前面都有一行记录。
-- 【谁读】员工:module.suppliers.view(供应商页门户那一块,与门户账号那一张同一个码)。门户会话自己不直接读。
-- 【变更记录】第九张豁免(change_log_exclusions):它本身就是一份只追加的日志,再记一遍是把量翻一倍而不多一个事实(MES-1 那一类)。
--
-- NOTE: introduced by db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.portal_document_downloads (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    portal_user_id  uuid NOT NULL REFERENCES public.supplier_portal_users (id) ON DELETE RESTRICT,
    user_id         uuid NOT NULL,
    supplier_id     uuid NOT NULL REFERENCES public.suppliers (id) ON DELETE RESTRICT,
    document_kind   text NOT NULL CHECK (document_kind IN ('purchase_order', 'supplier_statement', 'cod')),
    issue_id        uuid NOT NULL,
    document_code   text NOT NULL,
    version         integer CHECK (version IS NULL OR version >= 1),
    bucket_id       text NOT NULL,
    file_path       text NOT NULL,
    sha256          text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    downloaded_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT portal_document_downloads_version_shape
        CHECK ((document_kind = 'cod') = (version IS NULL))
);

CREATE INDEX idx_portal_document_downloads_supplier ON public.portal_document_downloads (supplier_id, downloaded_at DESC);
CREATE INDEX idx_portal_document_downloads_object ON public.portal_document_downloads (portal_user_id, bucket_id, file_path, downloaded_at DESC);

COMMENT ON TABLE public.portal_document_downloads IS
    'MES-9b:门户下载记录(Q22)—— 门户账号每要走一份签发档一行(谁 · 哪一份 · 什么时候)。只追加;只经 portal_document_open() 写;它也是存储的钥匙(portal_can_read_object 要求两分钟内有这一行)。员工读 module.suppliers.view。变更记录的第九张豁免。';

CREATE TRIGGER trg_portal_document_downloads_append_only
    BEFORE UPDATE ON public.portal_document_downloads
    FOR EACH ROW EXECUTE FUNCTION public.guard_portal_document_download_append_only();
CREATE TRIGGER trg_portal_document_downloads_no_delete
    BEFORE DELETE OR TRUNCATE ON public.portal_document_downloads
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_portal_document_download_append_only();

ALTER TABLE public.portal_document_downloads ENABLE ROW LEVEL SECURITY;
CREATE POLICY "portal_document_downloads select by permission" ON public.portal_document_downloads
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
REVOKE ALL ON public.portal_document_downloads FROM authenticated, anon;
GRANT SELECT ON public.portal_document_downloads TO authenticated;

-- ── 3 · 新函数(镜像原样):四支门户函数 ──

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

-- db/functions/portal_deliveries.sql
-- MES-9b(2026-10-19,MES-9 Step 0 Q14 · Q15 · §4,Tim):【门户的收货与地磅单】—— 调用者自己那一家的收货记录,以及记在这些收货上的地磅单,
--   【按今天库里记着的样子】(as_of 是这一次读的时刻;页面写"as recorded today")。它们是记录,不是签发过的单据,所以没有 PDF。
--   先过 portal_require_link()(角色 · 链接 · 撤销 · 会话);供应商只从链接推出来,没有任何参数。
--   收货:单号 · 到货日 · 物料名 · 数量与单位 · 关联的采购单号。地磅单:单号 · 方向 · 完成时刻 · 是否作废 · 【分到这家收货上的公斤数】
--     (一张地磅单可以分给几张收货 —— 只回分给【自己那几张】的那几份,别家的那一份连存在都不说)。
--   【一个价钱都没有,一样内部的都没有】(Q15 · §4):不回单价、计价状态、估值、安全状态、库位、加工阶段、备注、车牌、照片、
--     毛重皮重、任何员工的名字。软删的收货不出现;作废的地磅单照样列出、标 voided。
--   EXECUTE 只授 supplier_portal(zzz_function_grants.sql;db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql.
CREATE OR REPLACE FUNCTION public.portal_deliveries()
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
        'as_of', now(),
        'receipts', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'code', b.code,
                       'arrival_date', b.arrival_date,
                       'material', m.name,
                       'quantity', b.quantity,
                       'unit', b.unit,
                       'purchase_order_code', (SELECT po.code FROM purchase_orders po WHERE po.id = b.purchase_order_id AND po.deleted_at IS NULL),
                       'tickets', COALESCE((
                           SELECT jsonb_agg(t.code ORDER BY t.code)
                             FROM weighbridge_ticket_shares sh JOIN weighbridge_tickets t ON t.id = sh.ticket_id
                            WHERE sh.inbound_batch_id = b.id), '[]'::jsonb))
                   ORDER BY b.arrival_date DESC NULLS LAST, b.code DESC)
              FROM inbound_batches b
              JOIN materials m ON m.id = b.material_id
             WHERE b.supplier_id = v_supplier AND b.deleted_at IS NULL), '[]'::jsonb),
        'tickets', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'code', t.code,
                       'direction', t.direction,
                       'completed_at', t.completed_at,
                       'voided', t.voided_at IS NOT NULL,
                       'shares', (SELECT jsonb_agg(jsonb_build_object('receipt_code', b.code, 'kg', sh.kg) ORDER BY b.code)
                                    FROM weighbridge_ticket_shares sh JOIN inbound_batches b ON b.id = sh.inbound_batch_id
                                   WHERE sh.ticket_id = t.id AND b.supplier_id = v_supplier AND b.deleted_at IS NULL))
                   ORDER BY t.created_at DESC, t.code DESC)
              FROM weighbridge_tickets t
             WHERE EXISTS (SELECT 1 FROM weighbridge_ticket_shares sh JOIN inbound_batches b ON b.id = sh.inbound_batch_id
                            WHERE sh.ticket_id = t.id AND b.supplier_id = v_supplier AND b.deleted_at IS NULL)), '[]'::jsonb));
END;
$function$;

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

-- db/functions/portal_can_read_object.sql
-- MES-9b(2026-10-19,MES-9 Step 0 §3 · Q14 · Q22 · Q27,Tim):【存储策略的判据】—— 一个门户会话能不能读桶里的这一个对象。
--   storage.objects 上那条 TO supplier_portal 的 SELECT 策略只调它(db/storage/buckets-and-policies.sql)。
--   成立 = 这是一个有效的门户会话(portal_require_link 不拒)并且【这位门户账号在两分钟内为这一个对象写下过一行下载记录】
--   (portal_document_open 写的那一行 —— 它只为调用者自己那一家的、没作废的签发档写)。
--   ★ 为什么要求那一行,而不只是"这是自己那一家的档案":门户会话的令牌够得着 Storage API;只认"自己的",它就能绕过路由直接取字节,
--     下载记录(Q22)就有了漏网的那一份。要求【先有一行】,每一次取字节前面就都有一行 —— 记录完整是机制,不是约定。
--   【绝不抛】在 RLS 里抛会把一次读变成一次 500;这里任何一步不成立都回 false(于是存储那一侧是"没有这个对象")。
--   拒的理由由 portal_document_open 自己按名说(撤销 · 会话结束 · 不是自己的 · 作废)。
--   EXECUTE 只授 supplier_portal(策略以调用者身份求值;zzz_function_grants.sql;db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql.
CREATE OR REPLACE FUNCTION public.portal_can_read_object(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link uuid;
BEGIN
    BEGIN
        v_link := portal_require_link();
    EXCEPTION WHEN OTHERS THEN
        RETURN false;
    END;
    RETURN EXISTS (SELECT 1 FROM portal_document_downloads d
                    WHERE d.portal_user_id = v_link AND d.bucket_id = p_bucket AND d.file_path = p_name
                      AND d.downloaded_at > now() - interval '2 minutes');
END;
$function$;

-- ── 4 · 换掉的函数(镜像原样,同签名):变更记录的豁免 8 → 9 ──

-- db/functions/change_log_exclusions.sql
-- HISTORY-1(Tim 的 Q5):不挂变更记录触发器的表 —— 【唯一】的一份名单,每一条带理由。
--
-- 三处读它,所以它只能有一份:
--   · change_log_coverage_gaps() —— gate 的 changelog 那一行(线上 + 重建)与 fixture 234;
--   · scripts/check-change-log-coverage.mjs —— 构建里的静态检查,从本文件的 VALUES 里读;
--   · db/scripts/gen_change_log_bindings.py —— 生成绑定清单时跳过这几张。
-- ★ 规矩(docs/change-log.md):新建的每一张 public 表,要么在 db/views/zzz_change_log_triggers.sql
--   里有两条绑定,要么在这里有一行带理由的豁免。两者都没有,构建与 gate 都会红。
-- ★ MES-1(2026-10-06,MES-0 Q14,Tim):第二种被接受的豁免 —— 【采集层的三份日志】(收件箱 · 传输日志 · 网关中断)。
--   它们本身就是只追加的日志(守卫按名拒改与删);再记一遍是把规格 §2.1 警告的量翻一倍,而不多一个事实。
--   状态的变化记在行上(收件箱的 attempts · last_attempt_* · discarded_*)。
-- ★ MES-9b(2026-10-19,MES-9 Step 0 Q22,Tim):第九张 —— 门户下载记录(portal_document_downloads)。同一类:它本身就是一份只追加的日志
--   (守卫按名拒改、删、清空),每一行就是一个事实;再记一遍是把量翻一倍而不多一个事实。豁免 8 → 9。
CREATE OR REPLACE FUNCTION public.change_log_exclusions()
 RETURNS TABLE(table_name text, reason text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('change_log'::text, 'The change log itself; a trigger on it would record its own writes.'::text),
        ('festival_doodles', 'Home-screen holiday artwork; screen decoration with no business meaning.'),
        ('gateway_outages', 'Ingestion log (MES-1): itself an append-only record of gateway silences; logging it again doubles the volume and adds no fact.'),
        ('home_greetings', 'Home-screen greeting text; screen decoration with no business meaning.'),
        ('ingest_inbox', 'Ingestion log (MES-1): itself an append-only landing table; its status changes are recorded on the row (attempts, last attempt, discard).'),
        ('ingest_transmissions', 'Ingestion log (MES-1): itself an append-only log of every gateway call; logging it again doubles the volume and adds no fact.'),
        ('notification_reads', 'Per-viewer "seen" marks on notifications; screen state with no business meaning.'),
        ('portal_document_downloads', 'Supplier portal download log (MES-9b, MES-9 Step 0 Q22): itself an append-only record of every issued document a portal user took; logging it again doubles the volume and adds no fact.'),
        ('scan_events', 'Scan log (MES-3b): itself an append-only record of every scan resolved on a page; logging it again doubles the volume and adds no fact.');
$function$;

-- ── 5 · 存储(与 db/storage/buckets-and-policies.sql 逐字同一份):两条授权 + 一条策略 ──
GRANT USAGE ON SCHEMA storage TO supplier_portal;
GRANT SELECT ON storage.objects TO supplier_portal;

DROP POLICY IF EXISTS "portal reads its own logged issued documents" ON storage.objects;
CREATE POLICY "portal reads its own logged issued documents"
    ON storage.objects AS PERMISSIVE FOR SELECT TO supplier_portal
    USING (((bucket_id = ANY (ARRAY['po-documents'::text, 'cod-documents'::text, 'supplier-statement-documents'::text])) AND public.portal_can_read_object(bucket_id, name)));

-- ── 6 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.portal_documents() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_documents() TO supplier_portal;
REVOKE EXECUTE ON FUNCTION public.portal_deliveries() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_deliveries() TO supplier_portal;
REVOKE EXECUTE ON FUNCTION public.portal_document_open(text, uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_document_open(text, uuid) TO supplier_portal;
REVOKE EXECUTE ON FUNCTION public.portal_can_read_object(text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_can_read_object(text, text) TO supplier_portal;
REVOKE EXECUTE ON FUNCTION public.guard_portal_document_download_append_only() FROM PUBLIC, anon;

-- ── 7 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes9b_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE mes9b_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    v_ev    jsonb;
    k       text;
    a       record;
BEGIN
    -- ① 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变;没有任何门户账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES9B_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM mes9b_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM mes9b_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'MES9B_PROOF|an account or its roles changed';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users) THEN RAISE EXCEPTION 'MES9B_PROOF|no portal account may exist'; END IF;

    -- ② hook 不变:七个真账号的 event 逐字节原样返回(本刀不碰 hook —— 这一句证它)
    FOR a IN SELECT id, email FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test') ORDER BY email LOOP
        v_ev := jsonb_build_object('user_id', a.id, 'authentication_method', 'password',
                    'claims', jsonb_build_object('aud', 'authenticated', 'exp', 2000000000, 'iat', 1900000000, 'sub', a.id, 'email', a.email,
                                                 'phone', '', 'role', 'authenticated', 'aal', 'aal1', 'session_id', gen_random_uuid(),
                                                 'is_anonymous', false, 'app_metadata', jsonb_build_object('provider', 'email'),
                                                 'user_metadata', '{}'::jsonb, 'amr', '[]'::jsonb));
        v_j := portal_access_token_hook(v_ev);
        IF v_j IS DISTINCT FROM v_ev THEN
            RAISE EXCEPTION 'MES9B_PROOF|the hook changed the claims of %', a.email;
        END IF;
    END LOOP;

    -- ③ 门户角色的可达面:public 函数恰好六支;能读的关系恰好 storage.objects;能写的一样都没有;作用于它的存储策略恰好一条;
    --    storage 架构只有 USAGE;仍不是任何角色的成员
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me' THEN
        RAISE EXCEPTION 'MES9B_PROOF|supplier_portal executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(n.nspname || '.' || c.relname, ', ' ORDER BY 1), '') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
       AND has_schema_privilege('supplier_portal', n.oid, 'USAGE') AND has_table_privilege('supplier_portal', c.oid, 'SELECT');
    IF v_bad <> 'storage.objects' THEN RAISE EXCEPTION 'MES9B_PROOF|supplier_portal reads: %', v_bad; END IF;
    SELECT COALESCE(string_agg(n.nspname || '.' || c.relname, ', '), '') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
       AND has_table_privilege('supplier_portal', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE');
    IF v_bad <> '' THEN RAISE EXCEPTION 'MES9B_PROOF|supplier_portal can write: %', v_bad; END IF;
    IF (SELECT count(*) FROM pg_policies WHERE 'supplier_portal' = ANY (roles)) <> 1
       OR NOT has_schema_privilege('supplier_portal', 'storage', 'USAGE') OR has_schema_privilege('supplier_portal', 'storage', 'CREATE')
       OR EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member = 'supplier_portal'::regrole) THEN
        RAISE EXCEPTION 'MES9B_PROOF|supplier_portal: one policy, USAGE on storage only, a member of nothing';
    END IF;
    IF has_table_privilege('authenticated', 'public.portal_document_downloads', 'INSERT,UPDATE,DELETE,TRUNCATE')
       OR has_table_privilege('anon', 'public.portal_document_downloads', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
       OR NOT has_table_privilege('authenticated', 'public.portal_document_downloads', 'SELECT') THEN
        RAISE EXCEPTION 'MES9B_PROOF|portal_document_downloads grants: authenticated SELECT only, anon nothing';
    END IF;

    -- ④ 存储:策略 53 条,既有的 52 条逐字未变;存储对象一个字节不动(两张 COD 在内)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 53
       OR EXISTS (SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM mes9b_policies_before
                  EXCEPT SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM pg_policies WHERE schemaname = 'storage') THEN
        RAISE EXCEPTION 'MES9B_PROOF|storage policies: expected the 52 unchanged plus the portal one';
    END IF;
    IF EXISTS ((SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects
                EXCEPT SELECT bucket_id, name, size, etag FROM mes9b_objects_before)
               UNION ALL
               (SELECT bucket_id, name, size, etag FROM mes9b_objects_before
                EXCEPT SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects)) THEN
        RAISE EXCEPTION 'MES9B_PROOF|a stored object changed';
    END IF;

    -- ⑤ 在途单据一张不少、一张不多;既有的行逐字未变;本事务一行变更记录都没写
    IF EXISTS ((SELECT b.k, b.id FROM mes9b_pending_before b EXCEPT SELECT a2.k, a2.id FROM mes9b_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM mes9b_pending_after a2 EXCEPT SELECT b.k, b.id FROM mes9b_pending_before b)) THEN
        RAISE EXCEPTION 'MES9B_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) IS DISTINCT FROM (SELECT suppliers FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM counterparty_contacts t ) IS DISTINCT FROM (SELECT counterparty_contacts FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_portal_users t ) IS DISTINCT FROM (SELECT supplier_portal_users FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM account_settings t ) IS DISTINCT FROM (SELECT account_settings FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) IS DISTINCT FROM (SELECT inbound_batches FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM purchase_orders t ) IS DISTINCT FROM (SELECT purchase_orders FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM po_issues t ) IS DISTINCT FROM (SELECT po_issues FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) IS DISTINCT FROM (SELECT cod_issues FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) IS DISTINCT FROM (SELECT certificates_of_destruction FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statements t ) IS DISTINCT FROM (SELECT supplier_statements FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statement_issues t ) IS DISTINCT FROM (SELECT supplier_statement_issues FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM weighbridge_tickets t ) IS DISTINCT FROM (SELECT weighbridge_tickets FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM weighbridge_ticket_shares t ) IS DISTINCT FROM (SELECT weighbridge_ticket_shares FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) IS DISTINCT FROM (SELECT journal_entries FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) IS DISTINCT FROM (SELECT journal_lines FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) IS DISTINCT FROM (SELECT payments FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) IS DISTINCT FROM (SELECT expenses FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) IS DISTINCT FROM (SELECT approval_log FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) IS DISTINCT FROM (SELECT permissions FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) IS DISTINCT FROM (SELECT role_permissions FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) IS DISTINCT FROM (SELECT roles FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) IS DISTINCT FROM (SELECT user_roles FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) IS DISTINCT FROM (SELECT finance_settings FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) IS DISTINCT FROM (SELECT ingest_settings FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM floor_board_settings t ) IS DISTINCT FROM (SELECT floor_board_settings FROM mes9b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t ) IS DISTINCT FROM (SELECT document_types FROM mes9b_rows_before) THEN
        RAISE EXCEPTION 'MES9B_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes9b_log_before), 0) AND c.txid = txid_current()) THEN
        RAISE EXCEPTION 'MES9B_PROOF|this migration wrote change_log rows';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9B_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:324 张表;变更记录覆盖零缺口、豁免 9(第九张带理由);遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 324 THEN
        RAISE EXCEPTION 'MES9B_PROOF|expected 324 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9
       OR NOT EXISTS (SELECT 1 FROM change_log_exclusions() x WHERE x.table_name = 'portal_document_downloads' AND x.reason LIKE '%Q22%') THEN
        RAISE EXCEPTION 'MES9B_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'MES9B_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES9B_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑦ 匿名面不变;四支门户函数 authenticated · anon 都调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES9B_PROOF|anon executes: %', v_bad;
    END IF;
    FOREACH k IN ARRAY ARRAY['public.portal_documents()', 'public.portal_deliveries()', 'public.portal_document_open(text, uuid)', 'public.portal_can_read_object(text, text)'] LOOP
        IF has_function_privilege('authenticated', k::regprocedure, 'EXECUTE') OR has_function_privilege('anon', k::regprocedure, 'EXECUTE')
           OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = k::regprocedure) THEN
            RAISE EXCEPTION 'MES9B_PROOF|%: expected SECURITY DEFINER, executable by supplier_portal only', k;
        END IF;
    END LOOP;

    -- ⑧ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes9b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES9B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes9b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES9B_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes9b_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
