-- db/migrations/2026-10-21-claim-receipts-1.sql
-- CLAIM-RECEIPTS-1 —— 员工给报销单的【每一笔】传收据。(v1.4.65;发布那一行在 docs/handbacks/CLAIM-RECEIPTS-1.md 的抬头。)
--   由 db/scripts/build_claim_receipts1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-21 的裁定:Step 0 Q1–Q14)
--   ① 新表 expense_claim_receipts:一份文件一行(哪张单 · 哪一笔 · 文件名 / 类型 / 大小 · 桶里的路径 · uploading → attached | abandoned;
--      attached → removed,谁、何时)。只经函数写;财务读全部,员工与替他提单的人读自己那张单的(Q6 · Q7)。
--   ② 函数:claim_receipt_begin(先判:调用者是这张单说的员工或替他提单的人 · 单仍 submitted · 与门户同一个上限 10 MB · PDF / JPEG / PNG ·
--      整个项目的存储不到 900 MB —— 过了才登记一行、给出路径;Q1 · Q4 · Q10)· claim_receipt_finish(字节到了、大小与类型对得上)·
--      claim_receipt_abandon(没传成)· claim_receipt_remove(只在 submitted 时拿掉一份,对象留在桶里;Q5)·
--      claim_receipt_can_upload / claim_receipt_can_read(两条存储策略的判据)· claim_receipt_limits(把上限说出来)。
--   ③ 私有桶 claim-receipts(10 MB · PDF / JPEG / PNG)与 storage.objects 上两条策略:传 = 只有自己登记过、还在 uploading 的那一条路径;
--      读 = finance.view,或自己那张单的。没有 UPDATE、没有 DELETE(Q5:没有任何员工持存储的删除权限)。
--   ④ 批准时凭据【按笔】查收据(decide_expense_claim_items);整张单的附件那条路退役:finance_attachments.claim_id 删掉(线上 0 行,Q13),
--      expense_claim_status 拿掉 has_receipt(那是整张单一个布尔值)。submit_expense_claim_items 回每一笔的 id(Q12)。
--      收据取代 finance_attachments 进报销单的两条审计记录。
--
-- 【不做什么】不碰审批开关、hook、portal-uploads 与它的策略、任何账号与角色;不建任何单据;不改任何分录;require_calibrated_since 保持空。
--   上限读的是门户那两列(account_settings V39,Q1:与门户同一个数)—— 那两列与它们的引导值一个字没改。
--
-- 【破窗】旧应用 + 新库这一窗里坏的(推导):旧的 /me 与 /finance/claims 读 expense_claim_status 用的是 select('*'),has_receipt 不在了
--   就是 undefined —— 每一笔印"无收据"(本来也是:线上 0 份);审批照旧调 decide_expense_claim_items(签名未变),逐笔凭据今天只可能是理由
--   (线上 0 份收据)—— 判词与迁移之前相同。没有一条旧路会撞 42703。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变;既有的行逐字未变
--   (finance_attachments 比拿掉 claim_id 之后的);存储:58 条策略 = 之前的 56 条原样 + 两条、21 个桶 = 之前的 20 个原样 + claim-receipts、
--   每一个对象逐字未变;本事务没有写变更记录;清单 ↔ 总账两边未解释仍是 0.00、与迁移之前逐字相同;两张 COD 原样;328 张表;
--   变更记录覆盖零缺口、豁免 9;匿名面与门户面不变;没有一张视图对 anon / authenticated 带写授权;在途单据一张不少、每一张仍有一个决定人。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────
CREATE TEMP TABLE cr1_recon_before (j jsonb) ON COMMIT DROP;
DO $pre$
DECLARE
    v_recon jsonb;
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'CR1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.expense_claim_receipts') IS NOT NULL OR to_regprocedure('public.claim_receipt_begin(uuid, text, text, bigint)') IS NOT NULL
       OR EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'claim-receipts') THEN
        RAISE EXCEPTION 'CR1_PRE|the receipts table, its functions or its bucket already exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'finance_attachments' AND column_name = 'claim_id') THEN
        RAISE EXCEPTION 'CR1_PRE|expected finance_attachments.claim_id';
    END IF;
    IF EXISTS (SELECT 1 FROM finance_attachments WHERE claim_id IS NOT NULL) THEN
        RAISE EXCEPTION 'CR1_PRE|finance_attachments carries claim attachments (Step 0 measured 0; Tim Q13 retires the column on that measurement)';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test')) <> 7
       OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '634c00f9-c3a9-4444-9eed-b624cb6a2a93' AND email = 'tim@evoltrya.test') THEN
        RAISE EXCEPTION 'CR1_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 327 THEN
        RAISE EXCEPTION 'CR1_PRE|expected 327 public tables';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 56 OR (SELECT count(*) FROM storage.buckets) <> 20 THEN
        RAISE EXCEPTION 'CR1_PRE|expected 56 storage policies and 20 buckets';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'CR1_PRE|expected 9 change-log exclusions';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'CR1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'CR1_PRE|expected the two recorded COD byte strings';
    END IF;
    IF (SELECT portal_upload_max_bytes FROM account_settings WHERE id) IS DISTINCT FROM 10485760
       OR (SELECT portal_upload_types FROM account_settings WHERE id) IS DISTINCT FROM ARRAY['application/pdf', 'image/jpeg', 'image/png']::text[] THEN
        RAISE EXCEPTION 'CR1_PRE|V39 is expected at 10 MB · PDF / JPEG / PNG (Tim Q1: the receipts limit is the same number)';
    END IF;
    -- 清单 ↔ 总账此刻两边未解释都是 0.00 —— 以 tim@(cfo)身份【读】,读完即清
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    v_recon := list_ledger_reconciliation();
    PERFORM set_config('request.jwt.claims', '', true);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'CR1_PRE|the list-vs-ledger reconciliation is expected at 0.00 unexplained: %', v_recon;
    END IF;
    INSERT INTO cr1_recon_before (j) VALUES (v_recon - 'base_currency');
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE cr1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE cr1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE cr1_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE cr1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'claim_id')::text, '|' ORDER BY (to_jsonb(t) - 'claim_id')::text), '')) FROM finance_attachments t ) AS finance_attachments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expense_claims t ) AS expense_claims,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expense_claim_items t ) AS expense_claim_items,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expense_lines t ) AS expense_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t ) AS accounts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t ) AS payment_allocations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t ) AS payment_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM medical_claims t ) AS medical_claims,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) AS permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) AS role_permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) AS roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) AS user_roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) AS finance_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) AS ingest_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM account_settings t ) AS account_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) AS employees,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) AS suppliers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM portal_certificate_submissions t ) AS portal_certificate_submissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t ) AS document_types;
CREATE TEMP TABLE cr1_objects_before ON COMMIT DROP AS
SELECT bucket_id, name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects;
CREATE TEMP TABLE cr1_policies_before ON COMMIT DROP AS
SELECT policyname, cmd, roles::text AS roles, COALESCE(qual, '') AS qual, COALESCE(with_check, '') AS with_check FROM pg_policies WHERE schemaname = 'storage';
CREATE TEMP TABLE cr1_buckets_before ON COMMIT DROP AS
SELECT id, name, public, file_size_limit, allowed_mime_types::text AS mimes FROM storage.buckets;

-- ── 1 · 新表(建表脚本原样:db/tables/expense_claim_receipts.sql)──
-- db/tables/expense_claim_receipts.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q1–Q14):报销单【每一笔】的收据 —— 一行一份文件:哪张单 · 哪一笔 · 文件名 / 类型 / 大小 ·
--   私有桶 claim-receipts 里的路径 · 到了哪一步 · 谁传的、谁拿掉的。
--
-- 【收据按笔】(Tim 2026-10-20 的形状)每一笔要么有自己的收据、要么有自己的无收据理由,批准时逐笔查
--   (decide_expense_claim_items,EXPENSE_CLAIM_NO_EVIDENCE|单号|第几笔)。一笔可以有几份文件(Q9,不设份数上限)。
-- 【状态】uploading(登记了,字节还没到)→ attached(字节到了、类型与大小对得上)| abandoned(没传成);
--   attached → removed(Q5:单还在 submitted 时,传的人可以拿掉一份;拿掉的从单上隐去,谁、何时记在这一行;
--   【对象留在桶里】—— 没有任何员工持存储的删除权限,与门户同一条)。
-- 【谁传】(Q4)这张单说的那名员工,以及替他提单的那个人(expense_claims.created_by);只在单还是 submitted 时;别人都不行。
--   「提单人不能批」那一条照旧(decide_expense_claim_items 的 forbid_self_approval)。
-- 【上限】(Q1)与门户同一个数 —— 读的就是门户那两列(account_settings.portal_upload_max_bytes / portal_upload_types,V39):10 MB · PDF / JPEG / PNG。
--   HEIC、Word、Excel 按名拒并说明为什么。照片在浏览器里先缩到长边约 2,000 px、存成 JPEG(Q3);PDF 原样。
--   (Q10)整个项目的存储到了 900 MB,新的收据一律按名拒(CLAIM_RECEIPT_STORAGE_FULL)。
-- 【谁写】只经函数:claim_receipt_begin / _finish / _abandon / _remove(SECURITY DEFINER,各自先判调用者)。没有任何写策略,
--   authenticated 与 anon 连写的授权都没有。
-- 【谁读】(Q6 · Q7)持 module.finance.view 的人读全部;这张单说的那名员工与替他提单的人读这张单的。决定之后仍然读得到;
--   之后谁都拿不掉(拿掉只在 submitted 时)。没有另设 HR / 审计的规矩。
-- 【变更记录】记(不是豁免);审计记录里它挂在报销单那一条下(trail_subject_members:expense_claim · my_expense_claim)。
--
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.expense_claim_receipts (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id      uuid NOT NULL REFERENCES public.expense_claims (id) ON DELETE RESTRICT,
    item_id       uuid NOT NULL REFERENCES public.expense_claim_items (id) ON DELETE RESTRICT,
    file_name     text NOT NULL CHECK (length(file_name) BETWEEN 1 AND 200),
    file_type     text NOT NULL,
    file_size     bigint NOT NULL CHECK (file_size > 0),
    bucket_id     text NOT NULL DEFAULT 'claim-receipts' CHECK (bucket_id = 'claim-receipts'),
    storage_path  text NOT NULL UNIQUE,
    status        text NOT NULL DEFAULT 'uploading'
                  CHECK (status IN ('uploading', 'attached', 'abandoned', 'removed')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid NOT NULL,
    attached_at   timestamptz,
    removed_at    timestamptz,
    removed_by    uuid,
    CONSTRAINT expense_claim_receipts_attached CHECK ((status IN ('attached', 'removed')) = (attached_at IS NOT NULL)),
    CONSTRAINT expense_claim_receipts_removed CHECK ((status = 'removed') = (removed_at IS NOT NULL AND removed_by IS NOT NULL))
);

CREATE INDEX idx_expense_claim_receipts_claim ON public.expense_claim_receipts (claim_id, item_id);
CREATE INDEX idx_expense_claim_receipts_item ON public.expense_claim_receipts (item_id) WHERE status = 'attached';

COMMENT ON TABLE public.expense_claim_receipts IS
    'CLAIM-RECEIPTS-1(Tim 2026-10-21):报销单每一笔的收据(一份文件一行),私有桶 claim-receipts。uploading → attached | abandoned;attached → removed(只在单 submitted 时,对象留在桶里)。传:这张单说的员工与替他提单的人,只在 submitted 时(Q4)。读:module.finance.view 全部,员工与提单人读自己那张单的(Q6)。只经函数写。批准时每一笔要么有一份 attached 的收据、要么有无收据理由。';

-- 【状态只往前走,别的列不可改,行不可删】函数之外的路(postgres 手改)也挡在这里
CREATE OR REPLACE FUNCTION public.guard_expense_claim_receipt_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_IMMUTABLE';
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.claim_id IS DISTINCT FROM OLD.claim_id OR NEW.item_id IS DISTINCT FROM OLD.item_id
       OR NEW.file_name IS DISTINCT FROM OLD.file_name OR NEW.file_type IS DISTINCT FROM OLD.file_type
       OR NEW.file_size IS DISTINCT FROM OLD.file_size OR NEW.bucket_id IS DISTINCT FROM OLD.bucket_id
       OR NEW.storage_path IS DISTINCT FROM OLD.storage_path OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by
       OR NOT ((OLD.status = 'uploading' AND NEW.status IN ('attached', 'abandoned'))
               OR (OLD.status = 'attached' AND NEW.status = 'removed')) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_expense_claim_receipts_immutable
    BEFORE UPDATE OR DELETE ON public.expense_claim_receipts
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_claim_receipt_mutation();

ALTER TABLE public.expense_claim_receipts ENABLE ROW LEVEL SECURITY;

-- Q6:财务看得见全部;这张单说的那名员工与替他提单的人看得见这张单的
CREATE POLICY "expense_claim_receipts select by permission" ON public.expense_claim_receipts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text)
        OR EXISTS (SELECT 1 FROM public.expense_claims c
                    WHERE c.id = expense_claim_receipts.claim_id
                      AND (c.employee_id = current_user_employee() OR c.created_by = auth.uid())));

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是属主权限函数(claim_receipt_begin · _finish · _abandon · _remove)。
REVOKE ALL ON public.expense_claim_receipts FROM authenticated, anon;
GRANT SELECT ON public.expense_claim_receipts TO authenticated;

-- 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 同一串字)
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.expense_claim_receipts
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.expense_claim_receipts
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 2 · 整张单的附件那条路退役(Q13):视图先拆(它读 claim_id),再删那一列,一个父亲的不变量少一个父亲 ──
DROP VIEW public.expense_claim_status;
ALTER TABLE public.finance_attachments DROP CONSTRAINT finance_attachments_one_parent;
DROP INDEX public.idx_finance_attachments_claim;
ALTER TABLE public.finance_attachments DROP COLUMN claim_id;
ALTER TABLE public.finance_attachments ADD CONSTRAINT finance_attachments_one_parent
        CHECK (num_nonnulls(sales_record_id, inbound_batch_id, payment_id, expense_id) = 1);

-- ── 3 · 新函数(镜像原样)──

-- db/functions/claim_receipt_begin.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q1 · Q4 · Q10):【给报销单的一笔开始传一份收据】—— 在【任何一个字节存下之前】判完,过了才登记一行、
--   给出私有桶 claim-receipts 里的路径。MES-9c portal_submission_begin 的形状(先判、再登记、字节由浏览器直传、finish 确认)。
--   依次按名拒(第一条不过就停,什么都不写):
--     这一笔不存在                                         → CLAIM_RECEIPT_ITEM_NOT_FOUND
--     调用者不是这张单说的员工、也不是替他提单的人(Q4)    → CLAIM_RECEIPT_NOT_YOURS|<单号>
--     单不在 submitted(Q4:只在提交之后、决定之前)        → CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|<单号>|<状态>
--     上限没给(门户那两列任一为空 —— Q1:与门户同一个数)  → CLAIM_RECEIPT_LIMITS_NOT_SET
--     文件类型不在上限里(HEIC / Word / Excel 都落在这里)   → CLAIM_RECEIPT_TYPE_NOT_ACCEPTED|<类型>
--     大小 ≤ 0 / 超过上限                                 → CLAIM_RECEIPT_EMPTY / CLAIM_RECEIPT_TOO_LARGE|<上限字节数>
--     文件名空                                             → CLAIM_RECEIPT_NAME_REQUIRED
--     整个项目的存储已到 900 MB(Q10,免费方案 1 GB)        → CLAIM_RECEIPT_STORAGE_FULL|<已用字节数>|<上限字节数>
--   过了:写一行 status = uploading(路径 = <单 id>/<笔 id>/<这一行的 id>.<扩展名>,扩展名由类型定,不取文件名里的),回 id · 桶 · 路径。
--   【900 MB 是 Tim 的数,写在这里而不是一张设置表里】它只活到付费方案(Q10:"Nothing else until the paid plan");
--   到那天删掉这一条,而不是把它调大。数的是 storage.objects 每一个对象 metadata 里的 size(所有桶)。
--   EXECUTE 授 authenticated(zzz_function_grants.sql);调用者在函数体里判。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_begin(p_item_id uuid, p_file_name text, p_file_type text, p_file_size bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_item    expense_claim_items%ROWTYPE;
    v_c       expense_claims%ROWTYPE;
    v_max     bigint;
    v_types   text[];
    v_used    bigint;
    v_ceiling constant bigint := 943718400;   -- 900 MB(Tim Q10)
    v_id      uuid := gen_random_uuid();
    v_ext     text;
    v_path    text;
    v_name    text := left(btrim(regexp_replace(COALESCE(p_file_name, ''), '[\\/[:cntrl:]]+', '_', 'g')), 200);
BEGIN
    SELECT * INTO v_item FROM expense_claim_items WHERE id = p_item_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_ITEM_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM expense_claims WHERE id = v_item.claim_id FOR UPDATE;
    IF NOT COALESCE(v_c.employee_id = current_user_employee() OR v_c.created_by = auth.uid(), false) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_YOURS|%', v_c.code;
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT a.portal_upload_max_bytes, a.portal_upload_types INTO v_max, v_types FROM account_settings a WHERE a.id;
    IF v_max IS NULL OR v_types IS NULL THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_LIMITS_NOT_SET';
    END IF;
    IF p_file_type IS NULL OR NOT (p_file_type = ANY (v_types)) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_TYPE_NOT_ACCEPTED|%', COALESCE(p_file_type, '');
    END IF;
    IF p_file_size IS NULL OR p_file_size <= 0 THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_EMPTY';
    END IF;
    IF p_file_size > v_max THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_TOO_LARGE|%', v_max;
    END IF;
    IF v_name = '' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NAME_REQUIRED';
    END IF;
    SELECT COALESCE(sum((o.metadata ->> 'size')::bigint), 0) INTO v_used FROM storage.objects o;
    IF v_used + p_file_size > v_ceiling THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_STORAGE_FULL|%|%', v_used, v_ceiling;
    END IF;
    v_ext := CASE p_file_type WHEN 'application/pdf' THEN 'pdf' WHEN 'image/jpeg' THEN 'jpg' WHEN 'image/png' THEN 'png' ELSE 'bin' END;
    v_path := v_c.id::text || '/' || v_item.id::text || '/' || v_id::text || '.' || v_ext;
    INSERT INTO expense_claim_receipts (id, claim_id, item_id, file_name, file_type, file_size, storage_path, created_by)
    VALUES (v_id, v_c.id, v_item.id, v_name, p_file_type, p_file_size, v_path, auth.uid());
    RETURN jsonb_build_object('id', v_id, 'bucket', 'claim-receipts', 'path', v_path);
END;
$function$;

-- db/functions/claim_receipt_finish.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q1 · Q12):【一份收据的字节到了】—— 确认对象在桶里、大小与类型与登记的那一行对得上,
--   这一行变成 attached(从此算这一笔的凭据)。MES-9c portal_submission_finish 的形状。
--   按名拒:不是自己登记的 → CLAIM_RECEIPT_NOT_FOUND;登记的人此刻已不是这张单的人(Q4)→ CLAIM_RECEIPT_NOT_YOURS|<单号>;不在 uploading → CLAIM_RECEIPT_NOT_UPLOADING|<状态>;
--   单已不是 submitted(上传途中被批 / 驳回 / 撤回)→ CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|<单号>|<状态>;
--   对象不在 → CLAIM_RECEIPT_NOT_STORED;大小或类型对不上 → CLAIM_RECEIPT_MISMATCH。
--   【文件头】库读不到字节:按文件头认类型的那一步在调用它的服务端动作里(app/me/claimReceiptActions.ts),
--   认不出或与登记的类型不同 → 那一步调 claim_receipt_abandon 而不是这一支。
--   单行锁上报销单(FOR UPDATE),与 decide_expense_claim_items 的锁同一行 —— 一份收据要么在决定之前到,要么就不算。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_finish(p_receipt_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r      expense_claim_receipts%ROWTYPE;
    v_c    expense_claims%ROWTYPE;
    v_meta jsonb;
BEGIN
    SELECT * INTO r FROM expense_claim_receipts x WHERE x.id = p_receipt_id AND x.created_by = auth.uid();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM expense_claims WHERE id = r.claim_id FOR UPDATE;
    -- 登记它的人此刻仍是这张单的人(Q4)—— 与 begin 同一条
    IF NOT COALESCE(v_c.employee_id = current_user_employee() OR v_c.created_by = auth.uid(), false) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_YOURS|%', v_c.code;
    END IF;
    SELECT * INTO r FROM expense_claim_receipts x WHERE x.id = p_receipt_id FOR UPDATE;
    IF r.status <> 'uploading' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_UPLOADING|%', r.status;
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT COALESCE(o.metadata, '{}'::jsonb) INTO v_meta FROM storage.objects o WHERE o.bucket_id = r.bucket_id AND o.name = r.storage_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_STORED';
    END IF;
    IF (v_meta ? 'size' AND (v_meta ->> 'size')::bigint <> r.file_size)
       OR (v_meta ? 'mimetype' AND v_meta ->> 'mimetype' <> r.file_type) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_MISMATCH';
    END IF;
    UPDATE expense_claim_receipts SET status = 'attached', attached_at = now() WHERE id = r.id;
    RETURN jsonb_build_object('id', r.id, 'state', 'attached');
END;
$function$;

-- db/functions/claim_receipt_abandon.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q12):【一份收据没传成】—— 自己登记的、还在 uploading 的那一行变成 abandoned。
--   传字节失败、或服务端按文件头认出类型不对时,由服务端动作调它。桶里若已留下字节,它们留着 —— 没有删除策略(Tim 2026-10-21 Q5:
--   没有任何员工持存储的删除权限;与门户那一份的裁定同形,Tim 2026-10-20 d2 #3:字节留着,不建清理路径)。
--   按名拒:不是自己登记的 → CLAIM_RECEIPT_NOT_FOUND;登记的人此刻已不是这张单的人 → CLAIM_RECEIPT_NOT_YOURS|<单号>;不在 uploading → CLAIM_RECEIPT_NOT_UPLOADING|<状态>。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_abandon(p_receipt_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status text;
BEGIN
    SELECT x.status INTO v_status FROM expense_claim_receipts x WHERE x.id = p_receipt_id AND x.created_by = auth.uid() FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_FOUND';
    END IF;
    -- 登记它的人此刻仍是这张单的人(Q4)—— 与 begin 同一条
    IF NOT EXISTS (SELECT 1 FROM expense_claim_receipts x JOIN expense_claims c ON c.id = x.claim_id
                    WHERE x.id = p_receipt_id AND (c.employee_id = current_user_employee() OR c.created_by = auth.uid())) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_YOURS|%', (SELECT c.code FROM expense_claim_receipts x JOIN expense_claims c ON c.id = x.claim_id WHERE x.id = p_receipt_id);
    END IF;
    IF v_status <> 'uploading' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_UPLOADING|%', v_status;
    END IF;
    UPDATE expense_claim_receipts SET status = 'abandoned' WHERE id = p_receipt_id;
    RETURN jsonb_build_object('id', p_receipt_id, 'state', 'abandoned');
END;
$function$;

-- db/functions/claim_receipt_remove.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q5 · Q6):【从一笔上拿掉一份收据】—— 只在单还是 submitted 时;只有能往这张单上传的人
--   (Q4:这张单说的员工,与替他提单的人)。拿掉的那一行变成 removed,谁、何时记在行上;它从单上隐去,不再算这一笔的凭据;
--   【对象留在桶里】—— 没有任何员工持存储的删除权限(Q5,与门户同一条)。决定之后(批准 / 驳回 / 撤回)谁都拿不掉(Q6)。
--   按名拒:收据不在 → CLAIM_RECEIPT_NOT_FOUND;不是你的 → CLAIM_RECEIPT_NOT_YOURS|<单号>;
--   单不在 submitted → CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|<单号>|<状态>;不是 attached → CLAIM_RECEIPT_NOT_ATTACHED|<状态>。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_remove(p_receipt_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r   expense_claim_receipts%ROWTYPE;
    v_c expense_claims%ROWTYPE;
BEGIN
    SELECT * INTO r FROM expense_claim_receipts x WHERE x.id = p_receipt_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM expense_claims WHERE id = r.claim_id FOR UPDATE;
    IF NOT COALESCE(v_c.employee_id = current_user_employee() OR v_c.created_by = auth.uid(), false) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_YOURS|%', v_c.code;
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT * INTO r FROM expense_claim_receipts x WHERE x.id = p_receipt_id FOR UPDATE;
    IF r.status <> 'attached' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_ATTACHED|%', r.status;
    END IF;
    UPDATE expense_claim_receipts SET status = 'removed', removed_at = now(), removed_by = auth.uid() WHERE id = r.id;
    RETURN jsonb_build_object('id', r.id, 'state', 'removed');
END;
$function$;

-- db/functions/claim_receipt_can_upload.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q4):【存储策略的判据】—— 这个会话能不能往 claim-receipts 的这一条路径传字节(与读回它刚传的那一行)。
--   成立 = 有一行 status = uploading 的收据,路径正是这一条、是【这个会话自己】在十分钟内登记的、它的单仍是 submitted、
--   而这个会话此刻仍是那张单的人(说的那名员工,或替他提单的人 —— Q4)
--   —— 那一行只由 claim_receipt_begin 在判过调用者、单的状态、上限与存储余量之后写。于是:没先过 begin 的字节存不进来;
--   别人的路径、已经传完的、过了十分钟的、单已经被决定或撤回的,一律存不进来。改与删没有策略。
--   MES-9c portal_can_upload_object 的形状,换成 auth.uid()。【绝不抛】在 RLS 里抛会把一次上传变成一次 500;不成立就回 false。
--   EXECUTE 授 authenticated(策略以调用者身份求值)。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_can_upload(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'claim-receipts'
       AND EXISTS (SELECT 1 FROM expense_claim_receipts r JOIN expense_claims c ON c.id = r.claim_id
                    WHERE r.storage_path = p_name AND r.status = 'uploading' AND r.created_by = auth.uid()
                      AND r.created_at > now() - interval '10 minutes' AND c.status = 'submitted'
                      AND (c.employee_id = current_user_employee() OR c.created_by = auth.uid())), false)
$function$;

-- db/functions/claim_receipt_can_read.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q6 · Q7):【存储策略的判据】—— 这个会话能不能读 claim-receipts 里的这一个对象。
--   成立 = 持 module.finance.view(Q7:admin · cco · cfo · cto · finance · gm 读每一名员工的收据,Tim 接受),
--        或者这个对象是一行收据的路径,而那张单说的是【你】、或者是【你】替人提的(Q6:决定之后照样读得到);
--        或者它正是你刚登记、还在上传的那一条(Storage API 插入之后读回那一行要它 —— 与 claim_receipt_can_upload 同一条)。
--   一份被拿掉(removed)的收据:员工与提单人不再读到它(Q5:从单上隐去);财务照样读得到(对象留在桶里,留痕的一部分)。
--   【绝不抛】;EXECUTE 授 authenticated。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_can_read(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'claim-receipts'
       AND (has_permission('module.finance.view')
            OR EXISTS (SELECT 1 FROM expense_claim_receipts r JOIN expense_claims c ON c.id = r.claim_id
                        WHERE r.storage_path = p_name
                          AND (r.status = 'attached' OR (r.status = 'uploading' AND r.created_by = auth.uid()))
                          AND (c.employee_id = current_user_employee() OR c.created_by = auth.uid()))), false)
$function$;

-- db/functions/claim_receipt_limits.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q1):收据的上限,给页面印出来与给浏览器先判一遍用 —— 判据只有一份,在库里(claim_receipt_begin
--   读的同两列,与门户同一个数);这一支只是把那个数【说出来】,不另写一份。account_settings 对员工不可读,所以经这一支。
--   set = 两列都给了;max_bytes / types 原样。没有登录的调用者(auth.uid() 为空)读到 NULL。EXECUTE 授 authenticated。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_limits()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object('set', a.portal_upload_max_bytes IS NOT NULL AND a.portal_upload_types IS NOT NULL,
                              'max_bytes', a.portal_upload_max_bytes, 'types', to_jsonb(a.portal_upload_types))
      FROM account_settings a WHERE a.id AND auth.uid() IS NOT NULL
$function$;

-- ── 4 · 换掉的函数(镜像原样,同签名)──

-- db/functions/decide_expense_claim_items.sql
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q3 · Step 0b Q1 · Q3 · Q8):报销单的决定路径,【按明细】。
--   p_items = [{line_no, account_code, tax_code?}, ...] —— 财务给【每一笔】明细一个科目与税码,什么都不预选(Q1);
--   必须逐笔覆盖整张单(少一笔 → EXPENSE_CLAIM_ACCOUNT_REQUIRED|单号|第几笔;多出一个不存在的行号 →
--   EXPENSE_CLAIM_ITEM_UNKNOWN|单号|行号)。驳回【只能整张】(Q3),理由可以点名是哪一笔。
--   批准时整张单生出【一张】费用单(record_expense_document),每一笔明细一行、行备注 = 明细说明;
--   表头备注 = 'Expense claim <单号> (<员工号>) — <用途>'。
--   decide_expense_claim(旧签名)是这一支的【单笔包装】(Q8):多笔的单走旧调用按名拒(EXPENSE_CLAIM_HAS_ITEMS)。
-- ★ CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q13):凭据【按笔】查 —— 这一笔有一份 attached 的收据(expense_claim_receipts),
--   或者它自己有一句无收据理由。整张单的附件那条路(finance_attachments.claim_id)退役了(那一列已删,线上 0 行)。
--   下面 CLAIM-1 / APR-3 / CLAIM-GST-1 的说明原样保留 —— 它们说的是这一支的门、分档与税,而那几样一个字都没变。
-- 报销单的决定路径。CLAIM-1 建的;★ APR-3(2026-09-22)把它接上审批引擎。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ APR-3 在这支函数上改了三件事,每一件都是 Tim 的一条裁定 ★★★
-- ════════════════════════════════════════════════════════════════════════════
--
-- ① 【门从 module.finance.edit 换成 module.finance.view + data.view_prices】(Q1)
--    采购单那条链的形状,原样照搬 —— approve_purchase_order 要的正是这两个码,
--    而它【刻意】不要 edit:「一个提得了这张单的人不是一道管控」。
--    ★ 而决定性的理由是实测出来的:cfo 持 module.finance.view 与 data.view_prices,
--      【不持】module.finance.edit。写成 edit,今天二级之所以还有一个人批得动,
--      靠的只是 cfo 的唯一真持有人就是 admin 账号(docs/approvals.md §0b 记着的
--      那次撞车);Tim 一拿到独立的 CFO 账号、把 cfo 从 admin 上收回,
--      二级当场归零,approval_gate_intersections 会在【那一天】才变红,
--      而那时没有任何东西会说是这一刀造成的。
--    ⚠【代价照直说,因为它是真的】本函数是 SECURITY DEFINER,批准那一支会
--      调 record_expense 建一张开支单。于是一个持 view + prices 而【不持】
--      module.finance.edit 的人,经由这条路造得出一笔开支 —— 线上是 phua 与
--      sandra 两个人。这是 Tim 的裁定,不是疏忽:批的人与做的人本来就该分开,
--      而"做"这一步是引擎代他做的,不是他自己去写那张表。
--
-- ② 【四眼换成全库唯一的那一份判据】(Q5)
--    此前这里调的是 assert_segregated('EXPENSE_CLAIM_SELF_APPROVAL', …) ——
--    两条腿(受益人 + 提报人)其实是对的,但它是四眼的【第二份定义】,
--    而 APR-2 §3d 的全部论证就是"一条写成两遍的规矩,第三条链会漏掉它"。
--    ★ 而它同时在屏幕上说错过一句话:两条腿共用一句
--      「报销 X 是你提的,所以批它的不能是你」—— 当拒绝是因为【你就是那张单
--      说的那个人】时,那句话是假的,并且把人指去修错的东西。
--      APR-2 把这一句拆成两句,正是为了这个;这里接上那两句。
--    ☞ assert_segregated 本身【留着】,它还有三个正当的调用方
--      (guard_payment_sod · guard_finance_settings_sod · sod_supplier_creator)。
--
-- ③ 【接上分档与留痕】(本刀的主体)
--    approvals_enabled() 为真时按金额分档并 require_approver_for(级别);
--    两条分支【都】落一行 approval_log。
--    ★【永远不写 auto_approved】Tim 对 HR 三条链的裁定逐字适用:
--      开着还是关着,做决定的都是一个人。审批关着时写的是 approved/rejected、
--      level 为 NULL —— 不是"系统盖的章"。
--    ★【驳回也分档,所以驳回也要看得见金额】与采购单不同:那里 reject 单独一支
--      函数、门窄一格(不显示金额)。这里是一支函数两条分支,两边都落带 level
--      的留痕,所以两边都得先知道这是几级的单 —— 门一样宽,registry 里那两行
--      因此是同一个 gate_permissions。
--
-- 【金额从哪来】expense_claims 上没有 fx_rate 也没有 amount_base,所以那个数要算,
--   而判据只有一份:expense_claim_amount_base()(spend_date 的 tt_sell,理由见
--   那个文件的抬头 —— 一句话:posting_date 是审批人自己填的入参,拿它分档等于
--   让审批人挑自己的权限)。查不到牌价时它返回 NULL,由【这里】按名拒:
--   那句 FX_RATE_MISSING 归 fx_rate_for() 那一份定义所有,本函数不复述它。

-- CLAIM-GST-1(2026-09-24):报销单的 amount_ccy 是【收据上的总额】,已含 GST。
-- 此前它被当成净额、在上面再加 9%(TX 时那 9% 进 1400):报 100 记成欠员工 109(CLM-2026-0002 →
-- EXP-2026-0007,留作测试数据残留,见 docs/known-wrong-until-cutover.md)。现在调 record_expense 时
-- 传 p_amount_includes_tax := true,税从总额里拆出来,欠员工的恰好是收据上的数。
--
CREATE OR REPLACE FUNCTION public.decide_expense_claim_items(p_claim_id uuid, p_approve boolean, p_items jsonb DEFAULT NULL::jsonb, p_posting_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c        expense_claims%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_exp      jsonb;
    v_item     record;
    v_pick     jsonb;     -- 财务给这一笔的那一条 {line_no, account_code, tax_code}
    v_acct     text;
    v_tax      text;
    v_lines    jsonb := '[]'::jsonb;
    v_x        jsonb;
    v_date     date;
    v_base     numeric;
    v_level    smallint;
    v_appr_on  boolean := approvals_enabled();
BEGIN
    -- ① APR-3(Q1):门是【看得见财务 + 看得见金额】,不是【改得了财务】。
    --    两个码分两句,与 approve_purchase_order 同形 —— 拒绝要说清缺的是哪一个。
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_c FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT * INTO v_emp FROM employees WHERE id = v_c.employee_id;

    -- ══ ★② 四眼:全库【唯一】一份判据,两条腿 ★ ════════════════════════════
    -- 【为什么这道闸必须在这里】SOD-1 的 guard_payment_sod 明确豁免了付给员工的
    -- 款,理由是"由 HR 建档、财务付款,已经跨了两个模块的门"。那句话在写下的
    -- 那天是对的 —— 而 CLAIM-1 开出了一条新路:**员工自己发起**。发起人现在
    -- 就是受益人,那个论证对新路不成立。「换了推导来源,闸就要跟着搬」。
    -- 【两条腿各是谁】raiser = 提这张单的人(代人录入时不是员工本人);
    -- subject = 这张单【说的是谁】,也就是拿到这笔钱的那位员工。
    -- 顺序是定的:raiser 先判(APR-2 §3.5)。
    PERFORM forbid_self_approval(v_c.created_by, v_c.employee_id, 'expense_claim');

    -- ══ ★③ 分档 ★ ════════════════════════════════════════════════════════
    -- 【只在审批开着时问这一句】关着的时候,分档是一个没有意义的动作:
    -- 没有哪一级在生效,而 require_approver_for 会拿一条没有人在执行的策略
    -- 去拒绝一个本来做得了决定的人。这与 HR 三条链的形状一致 ——
    -- ☞ 也正因为如此,一张 submitted 的报销单【不挡】审批关闭
    --   (approval_pending_documents 的 blocks_disable = false,理由写在那里)。
    IF v_appr_on THEN
        SELECT b.amount_base INTO v_base FROM expense_claim_amount_base(p_claim_id) b;
        IF v_base IS NULL THEN
            -- 【那句话归 fx_rate_for 所有,这里只是把它请出来】——
            -- 自己拼一句 FX_RATE_MISSING 就是这条 FX 规矩的第二份定义。
            PERFORM fx_rate_for(v_c.currency, v_c.spend_date, 'tt_sell');
            -- 上面必定抛;真走到这里说明牌价其实查得到而上一步算出了 NULL,
            -- 那是一个【不该发生】的状态,按名拒而不是继续往下走。
            RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_BASE_UNRESOLVED|%', v_c.code;
        END IF;
        v_level := approval_level_for(v_base);
        PERFORM require_approver_for(v_level);
    END IF;

    -- ══ 驳回 ══════════════════════════════════════════════════════════════
    IF NOT p_approve THEN
        -- 【按名拒,而不是让 CHECK 抛约束原文】fixture 90 立的那条
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_REJECT_REASON_REQUIRED|%', v_c.code;
        END IF;
        UPDATE expense_claims
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_claim_id;
        -- ★ 驳回【也】留痕 —— APR-1 建这张表的第一条理由就是"驳回 → 重提 →
        --   批准之后,驳回那一次不留痕迹"。报销单此前正是那个形状:
        --   decision_notes 会被下一次决定覆盖掉。
        PERFORM record_approval_decision('expense_claim', p_claim_id, 'rejected',
                                         v_level, btrim(p_notes));
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'rejected',
                                  'level', v_level);
    END IF;

    -- ══ 批准 ══════════════════════════════════════════════════════════════
    -- ★ EXPENSE-MULTILINE-1:p_items 里每一个行号都必须是这张单上的一笔(不认识的行号按名拒,不悄悄丢掉)
    IF p_items IS NOT NULL AND jsonb_typeof(p_items) <> 'array' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEMS_INVALID|%', v_c.code;
    END IF;
    FOR v_x IN SELECT x FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) x LOOP
        IF NOT EXISTS (SELECT 1 FROM expense_claim_items i
                        WHERE i.claim_id = p_claim_id AND i.line_no = NULLIF(v_x->>'line_no', '')::integer) THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_ITEM_UNKNOWN|%|%', v_c.code, COALESCE(v_x->>'line_no', '?');
        END IF;
    END LOOP;

    FOR v_item IN SELECT * FROM expense_claim_items WHERE claim_id = p_claim_id ORDER BY line_no LOOP
        SELECT x INTO v_pick FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) x
         WHERE NULLIF(x->>'line_no', '')::integer = v_item.line_no LIMIT 1;
        v_acct := NULLIF(btrim(COALESCE(v_pick->>'account_code', '')), '');
        v_tax  := NULLIF(btrim(COALESCE(v_pick->>'tax_code', '')), '');
        IF v_acct IS NULL THEN
            -- 会计口径由审批人给 —— 没有科目就没法记账,而猜一个科目比拒绝坏(逐笔)
            RAISE EXCEPTION 'EXPENSE_CLAIM_ACCOUNT_REQUIRED|%|%', v_c.code, v_item.line_no;
        END IF;

        -- ★【GST 开着时,税码是【必给】的 —— 而且只能由审批人给】★(逐笔)
        -- 实测:resolve_tax_code 接受 override 或【往来对象的默认税码】,两者皆空就
        -- 按名拒(TAX_CODE_REQUIRED)。而 employees **没有 default_tax_code 这一列** ——
        -- 员工这一侧【永远】解析不出默认值。所以报销这条路上,税码只能显式给。
        -- 【为什么在这里先拒一次,而不是让 resolve_tax_code 去拒】它的提示语是
        -- 「给这个往来对象设一个默认税码,或在这张单据上指定一个」—— 对员工来说
        -- 前半句是【做不到的事】,于是那句话有一半是错的指路。这里按名拒并说清楚
        -- 要做的判断:进项税可抵是 TX,不可抵是 BL,而那是一个财务判断。
        IF (SELECT gst_registered FROM finance_settings) AND v_tax IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_TAX_CODE_REQUIRED|%|%', v_c.code, v_item.line_no;
        END IF;

        -- ★【凭据:要么有收据,要么有一句说得出为什么没有】★ —— 逐笔(Tim Step 0b Q2;CLAIM-RECEIPTS-1 Q13:收据也按笔)
        -- 【为什么查在这一步而不是提交那一步】凭据真正起作用的时刻,正是有人要据它做决定的时刻。
        -- 【为什么留了一条例外的路】一条没有例外出口的规矩会被绕过 —— 允许没有收据,但要求把【为什么】说出来。
        -- 只算 attached 的:还在上传的(uploading)、没传成的(abandoned)、被拿掉的(removed)都不算。
        IF NOT EXISTS (SELECT 1 FROM expense_claim_receipts r WHERE r.item_id = v_item.id AND r.status = 'attached')
           AND COALESCE(btrim(v_item.no_receipt_reason), '') = '' THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_NO_EVIDENCE|%|%', v_c.code, v_item.line_no;
        END IF;

        UPDATE expense_claim_items SET account_code = v_acct, tax_code = v_tax WHERE id = v_item.id;
        v_lines := v_lines || jsonb_build_object('account_code', v_acct, 'amount', v_item.amount_ccy,
                                                 'tax_code', v_tax, 'notes', v_item.description);
    END LOOP;

    -- 入账日:默认花钱那天;期间关了账时由审批人显式给
    v_date := COALESCE(p_posting_date, v_c.spend_date);

    -- 【成本与欠款在这里同时落地】unpaid = 一笔挂在这名员工头上的应付,
    -- 它会立刻出现在 ap_open_items 里带着他自己的名字(PAYEE-1a)。
    -- 汇率传 NULL:由 record_expense 按【那一天】自己查牌价 —— 一条 FX 规矩,
    -- 查不到就按名拒(FX_RATE_MISSING),报销不是它的例外。
    -- ⚠ APR-3 照直说:这里过账取的是 v_date 那天的牌价,而上面分档取的是
    --   spend_date 那天的 —— 两个日期不同时,两个数可以不一样。那是两个不同的
    --   问题(这笔承诺有多大 / 账上记多少),理由写在 expense_claim_amount_base。
    -- ★★【这张开支单【不】另外走一次审批】它是引擎在一个人已经批准之后代他
    --   记的账,不是一份新提交的单据 —— 与 N5 对系统生成凭证的裁定逐字同源。
    --   expense 这个 subject_type 在 APR-3 里【没有】接上引擎(Tim 的 Q2 裁定:
    --   payments / expenses 没有在途态,要先做一次建模改动),所以今天这一格
    --   不需要任何豁免机制;那条路开工时,豁免要写成一个【显式入参】,不是 GUC
    --   (Tim 的 Q9),理由记在 docs/forward-queue.md。
    -- ★ EXPENSE-MULTILINE-1:一张报销单 → 【一张】费用单,每笔明细一行(Tim Step 0 Q3)。
    v_exp := record_expense_document(
        p_expense_date   := v_date,
        p_currency       := v_c.currency,
        p_lines          := v_lines,
        p_payment_status := 'unpaid',
        p_bank_account   := NULL,
        p_supplier_id    := NULL,
        p_employee_id    := v_c.employee_id,
        p_payee_name     := v_emp.legal_name,
        p_notes          := format('Expense claim %s (%s) — %s', v_c.code, v_emp.code, v_c.description),
        -- CLAIM-GST-1(Tim Q3):员工报上来的是【收据上的总额】,已含 GST —— 税从里面拆出来,不加在上面(逐行)。
        p_amount_includes_tax := true);

    UPDATE expense_claims
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           posting_date = v_date,
           expense_id = (v_exp->>'expense_id')::uuid
     WHERE id = p_claim_id;

    PERFORM record_approval_decision('expense_claim', p_claim_id, 'approved',
                                     v_level, NULLIF(btrim(COALESCE(p_notes, '')), ''));

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'approved',
                              'expense_id', v_exp->>'expense_id', 'posting_date', v_date,
                              'level', v_level);
END;
$function$;

-- db/functions/submit_expense_claim_items.sql
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q3 · Step 0b Q4 · Q5 · Q7):提交一张【多笔】报销单。
--   p_purpose  —— 整张单的用途(必填;落进 expense_claims.description,搜索读它,Q7);
--   p_items    —— [{spend_date, amount, description, no_receipt_reason?}, ...],至少一笔。金额是【收据上的总额】(含税,与此前一样)。
--   一张单一个币种(Q4)。日期(Q5,两条都按名拒):
--     · 所有明细落在【同一个日历月】—— 一张单生出一张费用单,一张费用单只有一个入账期间
--       (EXPENSE_CLAIM_ITEMS_SPAN_MONTHS|最早|最晚);
--     · 非本位币的单,所有明细【同一天】—— 一张费用单只有一个汇率,而汇率规矩是"按交易自己那一天"
--       (EXPENSE_CLAIM_FOREIGN_ITEMS_ONE_DATE|币种|最早|最晚)。
--   表头 spend_date = 最晚那一笔(它决定审批档次、默认入账日与汇率);amount_ccy = 明细之和 —— 两样都由
--   guard_expense_claim_totals 在提交时强制。科目与税码【不在这里】:那是财务批准时逐笔给的(Step 0b Q1)。
--   submit_expense_claim(旧签名)是这一支的【单笔包装】(Q8)。
CREATE OR REPLACE FUNCTION public.submit_expense_claim_items(p_employee_id uuid, p_currency text, p_purpose text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp   employees%ROWTYPE;
    v_code  text;
    v_id    uuid;
    v_base  numeric;
    v_n     integer;
    v_i     integer;
    v_it    jsonb;
    v_date  date;
    v_amt   numeric;
    v_first date;
    v_last  date;
    v_total numeric := 0;
BEGIN
    -- 【自助:本人,或者持财务读权限的人代录】与 submit_medical_claim 同一条谓词
    -- ★ EMP-SELF-1(Q9 · Q2):COALESCE(…, false)。没有员工档案的账号 current_user_employee() 是 NULL,
    --   于是 NOT (false OR NULL) = NULL,IF 不触发 —— 这一道门对它【从来没有关上过】。
    IF NOT COALESCE(has_permission('module.finance.view') OR p_employee_id = current_user_employee(), false) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(p_employee_id::text, '?');
    END IF;
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEMS_REQUIRED';
    END IF;
    v_n := jsonb_array_length(p_items);
    -- 逐笔:日期必填、不晚于今天,金额为正(多笔的单错误码带一个 '|<第几笔>' 尾巴;单笔与此前逐字相同)
    FOR v_i IN 1 .. v_n LOOP
        v_it := p_items -> (v_i - 1);
        IF jsonb_typeof(v_it) <> 'object' THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_ITEMS_INVALID|%', v_i;
        END IF;
        v_date := NULLIF(v_it->>'spend_date', '')::date;
        IF v_date IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_REQUIRED%', CASE WHEN v_n > 1 THEN '|' || v_i ELSE '' END;
        END IF;
        IF v_date > CURRENT_DATE THEN
            -- 一笔"将来才会花的钱"不是报销,那是备用金 —— 而备用金被否决了(§0)
            RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_FUTURE|%|%', v_date::text, CURRENT_DATE::text;
        END IF;
        v_amt := NULLIF(v_it->>'amount', '')::numeric;
        IF v_amt IS NULL OR v_amt <= 0 THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_INVALID|%', COALESCE(v_amt::text, '?');
        END IF;
        v_first := LEAST(COALESCE(v_first, v_date), v_date);
        v_last  := GREATEST(COALESCE(v_last, v_date), v_date);
        v_total := v_total + v_amt;
    END LOOP;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies WHERE code = p_currency) THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_CURRENCY_UNKNOWN|%', COALESCE(p_currency, '?');
    END IF;
    FOR v_i IN 1 .. v_n LOOP
        IF NULLIF(btrim(COALESCE(p_items -> (v_i - 1) ->> 'description', '')), '') IS NULL THEN
            -- 「买了什么」是审批人唯一能据以判断的东西 —— 逐笔
            RAISE EXCEPTION 'EXPENSE_CLAIM_DESCRIPTION_REQUIRED%', CASE WHEN v_n > 1 THEN '|' || v_i ELSE '' END;
        END IF;
    END LOOP;
    IF p_purpose IS NULL OR btrim(p_purpose) = '' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_PURPOSE_REQUIRED';
    END IF;
    -- Q5:同一个日历月;非本位币同一天
    IF date_trunc('month', v_first) <> date_trunc('month', v_last) THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEMS_SPAN_MONTHS|%|%', v_first::text, v_last::text
          USING HINT = '一张报销单生出一张费用单,只有一个入账期间 —— 跨月的花销分成每月一张';
    END IF;
    IF p_currency <> base_currency_code() AND v_first <> v_last THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_FOREIGN_ITEMS_ONE_DATE|%|%|%', p_currency, v_first::text, v_last::text
          USING HINT = '外币报销单只有一个汇率,而汇率按花钱那一天取 —— 不同日子的外币花销分开报';
    END IF;

    v_code := next_expense_claim_code(v_last);
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency, description, created_by)
    VALUES (v_code, p_employee_id, v_last, v_total, p_currency, btrim(p_purpose), auth.uid())
    RETURNING id INTO v_id;
    INSERT INTO expense_claim_items (claim_id, line_no, spend_date, amount_ccy, description, no_receipt_reason, created_by)
    SELECT v_id, x.ord::integer, (x.it->>'spend_date')::date, (x.it->>'amount')::numeric, btrim(x.it->>'description'),
           NULLIF(btrim(COALESCE(x.it->>'no_receipt_reason', '')), ''), auth.uid()
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(it, ord);

    -- ★ U1-B(ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE 的报销单那一半,与采购单 APR-10 同一个形状):
    --   审批开着时,按这张单会落到的那一级问一句"提单人与主角之外,有没有人批得动";没有 → 按名拒,整张单不落库
    --   (单号随回滚放回去)。主角要传 —— 报销单的四眼也看【报的是谁】(decide_expense_claim 的 forbid_self_approval)。
    --   【分档读同一份】expense_claim_amount_base 是 decide_expense_claim 分档用的那一支;折不出本位币(没有牌价)时
    --   不在这里另造一句拒绝 —— 那张单在决定时会被 fx_rate_for 按名拒(那句话归它),而在牌价补上之前谁都批不了它。
    IF approvals_enabled() THEN
        SELECT b.amount_base INTO v_base FROM expense_claim_amount_base(v_id) b;
        IF v_base IS NOT NULL THEN
            PERFORM assert_other_decider_for_subject('expense_claim', 'decide_expense_claim_items',
                                                     approval_level_for(v_base), p_employee_id,
                                                     'EXPENSE_CLAIM_NO_OTHER_DECIDER|' || v_code);
        END IF;
    END IF;

    -- CLAIM-RECEIPTS-1(Tim 2026-10-21,Q12):回每一笔的 id —— 表单在提交之后紧接着给每一笔传它的收据(claim_receipt_begin 要那一笔的 id)
    RETURN jsonb_build_object('claim_id', v_id, 'code', v_code, 'status', 'submitted', 'item_count', v_n,
                              'items', (SELECT jsonb_agg(jsonb_build_object('line_no', i.line_no, 'item_id', i.id) ORDER BY i.line_no)
                                          FROM expense_claim_items i WHERE i.claim_id = v_id));
END;
$function$
;

-- db/functions/trail_subject_members.sql
-- AUDIT-TRAIL-1a(Tim 的 Q3 · Q6):一个主语的审计记录【由哪些行组成】—— 根行之外的子行与相关行。
--   每一行说:这张表里 fk_column 等于 parent_table 某一行的 id 的那些行,属于这条记录;match 是额外的固定条件
--   (多态的 approval_log 靠 subject_type 认主)。parent_table 可以是另一张子表(孙行:付款保留金挂在明细行上)。
--   按 ord 依次展开,所以孙行排在它的父行之后。
-- 【子行是在读的时候找出来的】(Q6)—— 不在记录上写父键。找法见 record_trail:今天还在的行按外键查,
--   已经删掉或改过父键的行从 change_log 的影像里查(GIN 索引 idx_change_log_image / idx_change_log_update_old)。
-- 【每一行子行都要再过一次它自己那张表的读规则】(Q4)—— 由 record_trail 调 trail_row_visible 做,不在这里。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M4 与 Q4)多了三列:
--   hop    'down'(默认):table.fk_column = parent 那一行的 id(往下走)。
--          'up'(M4):table.id = parent 那一行的 fk_column(往上走一跳 —— 批次 → 消耗它的加工单、它收货的采购单)。
--   shown  true:这张表的行是这条记录的一部分,它们的每一次改动都进审计记录。
--          false:【垫脚石】—— 只用来够到它下面的行,它自己的改动不进来(Q4:"只限碰到这个批次的那些事")。
--          批次的审计记录经由加工单够到那张单的成本修改、分录与工单的审批,但加工单本身的编辑不在批次上。
--   home   true:这张表的行【住在】这个主语下 —— /settings/change-history 的"Record"一栏沿 home 的那一条往上走
--          (trail_row_record)。同一张表挂在两个主语下时(加工投入既属于加工单、也出现在批次上),只有一处是家。
--   原来旧批次审计记录那 20 支(db/views/batch_audit_trail_all.sql)的每一支都在下面有它的来处 ——
--   fixture 238 逐行对照两边,少一行就红。
CREATE OR REPLACE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        -- 采购单:明细行 · 付款计划 · 保留金 · 条款承诺 · 签发 · 合同条款 · 审批 · 修改史(Tim 的 AT-1a 范围)
        ('purchase_order', 1, 'purchase_order_lines',           'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 2, 'purchase_order_payment_terms',   'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 3, 'purchase_order_line_retentions', 'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 4, 'pricing_term_commitments',       'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 5, 'po_issues',                      'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 6, 'contract_document_terms',        'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 7, 'approval_log',                   'purchase_orders',      'subject_id',             '{"subject_type": "purchase_order"}'::jsonb, 'down', true, true),
        ('purchase_order', 8, 'purchase_order_history',         'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        -- 加工单:投入 · 产出 · 成本条目及其修改史 · 成本分摊 · 损耗;1b-1 加:回滚申请及其审批(Q12)
        ('processing_run', 1, 'processing_inputs',                 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 2, 'processing_outputs',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 3, 'processing_cost_entries',           'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 4, 'processing_cost_entry_history',     'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 5, 'batch_processing_cost_allocations', 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 6, 'processing_run_losses',             'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 7, 'warehouse_requests',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, false),
        ('processing_run', 8, 'approval_log',                      'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        -- 角色:授权(加上 / 拿掉);AUDIT-TRAIL-1d-1 加:授给了谁(Q22 —— 家在账号那一边:授出去的是那个账号)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb, 'down', true, true),
        ('role', 2, 'user_roles',       'roles', 'role_id', '{}'::jsonb, 'down', true, false),

        -- ── 进料批次(1b-1)────────────────────────────────────────────────────────────────────────────
        -- 批次自己的:金属含量 · 化验与化验的金属 · 安全状态 · 价格 · 收货定价申请与它的审批 · 预付款核销 · 条款承诺 ·
        --   库存流水 · 盘点行与盘点的每一次清点 · 加工投入 · 成本分摊 · 销毁证书与签发 · 仓库申请(注销、证书作废)与它的审批 ·
        --   运费分摊 · 付款核销 · 财务附件
        ('inbound_batch',  1, 'inbound_batch_metals',              'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  3, 'assay_result_metals',               'assay_results',               'assay_result_id',  '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  4, 'inbound_batch_safety_states',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  5, 'price_history',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  6, 'receipt_price_requests',            'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  7, 'approval_log',                      'receipt_price_requests',      'subject_id',       '{"subject_type": "receipt_price_request"}'::jsonb, 'down', true, true),
        ('inbound_batch',  8, 'prepayment_applications',           'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  9, 'pricing_term_commitments',          'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 10, 'pricing_term_commitment_metals',    'pricing_term_commitments',    'commitment_id',    '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 11, 'inventory_movements',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 12, 'stocktake_lines',                   'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 13, 'stocktake_counts',                  'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 14, 'processing_inputs',                 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 15, 'batch_processing_cost_allocations', 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 16, 'certificates_of_destruction',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 17, 'cod_issues',                        'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 18, 'warehouse_requests',                'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 19, 'warehouse_requests',                'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 20, 'approval_log',                      'warehouse_requests',          'subject_id',       '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch', 21, 'freight_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 22, 'payment_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 23, 'finance_attachments',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4),只取碰到这个批次的那些事:
        --   它收货的采购单 → 那张单的审批与修改史(旧 approval / po_change 两支)
        ('inbound_batch', 24, 'purchase_orders',                   'inbound_batches',             'purchase_order_id', '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 25, 'approval_log',                      'purchase_orders',             'subject_id',        '{"subject_type": "purchase_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 26, 'purchase_order_history',            'purchase_orders',             'purchase_order_id', '{}'::jsonb, 'down', true,  false),
        --   消耗它的加工单 → 那张单的成本修改史、成本条目(垫脚石)、工单(垫脚石)→ 工单的审批与修改史
        ('inbound_batch', 27, 'processing_runs',                   'processing_inputs',           'run_id',            '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 28, 'processing_cost_entry_history',     'processing_runs',             'run_id',            '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 29, 'processing_cost_entries',           'processing_runs',             'run_id',            '{}'::jsonb, 'down', false, false),
        ('inbound_batch', 30, 'work_orders',                       'processing_runs',             'work_order_id',     '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 31, 'approval_log',                      'work_orders',                 'subject_id',        '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 32, 'work_order_history',                'work_orders',                 'work_order_id',     '{}'::jsonb, 'down', true,  false),
        --   盘点过它的那一次盘点(垫脚石)→ 那次盘点过账的分录
        ('inbound_batch', 33, 'stocktakes',                        'stocktake_lines',             'stocktake_id',      '{}'::jsonb, 'up',  false, false),
        --   分录:直接挂在批次上的(计价、注销)· 预付款核销的 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('inbound_batch', 34, 'journal_entries',                   'inbound_batches',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 35, 'journal_entries',                   'prepayment_applications',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 36, 'journal_entries',                   'processing_cost_entries',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 37, 'journal_entries',                   'processing_runs',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 38, 'journal_entries',                   'stocktakes',                  'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  true,  false),

        -- ── 产出批次(1b-1)────────────────────────────────────────────────────────────────────────────
        ('output_batch',  1, 'output_batch_metals',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  2, 'assay_results',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  3, 'assay_result_metals',               'assay_results',      'assay_result_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  4, 'output_batch_safety_states',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  5, 'inventory_movements',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  6, 'processing_outputs',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  7, 'processing_inputs',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  8, 'stocktake_lines',                   'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 10, 'warehouse_requests',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 11, 'approval_log',                      'warehouse_requests', 'subject_id',      '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch', 12, 'sales_records',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 13, 'sales_record_movements',            'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 14, 'sales_attribution_log',             'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 15, 'invoice_lines',                     'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 16, 'payment_allocations',               'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 17, 'sales_order_reservations',          'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 18, 'shipment_lines',                    'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 19, 'traceability_report_issues',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 20, 'sales_settlements',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4):产出它 / 消耗它的加工单 → 成本修改史、成本条目(垫脚石)、工单 → 审批与修改史;
        --   盘点过它的盘点(垫脚石);它的销售对应的订单行(垫脚石)→ 那一行的订单修改史(旧 so_change 一支)
        ('output_batch', 21, 'processing_runs',                   'processing_outputs', 'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 22, 'processing_runs',                   'processing_inputs',  'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 23, 'processing_cost_entry_history',     'processing_runs',    'run_id',              '{}'::jsonb, 'down', true,  false),
        ('output_batch', 24, 'processing_cost_entries',           'processing_runs',    'run_id',              '{}'::jsonb, 'down', false, false),
        ('output_batch', 25, 'work_orders',                       'processing_runs',    'work_order_id',       '{}'::jsonb, 'up',  false, false),
        ('output_batch', 26, 'approval_log',                      'work_orders',        'subject_id',          '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('output_batch', 27, 'work_order_history',                'work_orders',        'work_order_id',       '{}'::jsonb, 'down', true,  false),
        ('output_batch', 28, 'stocktakes',                        'stocktake_lines',    'stocktake_id',        '{}'::jsonb, 'up',  false, false),
        ('output_batch', 29, 'sales_order_lines',                 'sales_records',      'sales_order_line_id', '{}'::jsonb, 'up',  false, false),
        ('output_batch', 30, 'sales_order_history',               'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true,  false),
        --   分录:注销(直接挂在批次上)· 销售与发货的成本 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('output_batch', 31, 'journal_entries',                   'output_batches',     'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 32, 'journal_entries',                   'sales_records',      'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 33, 'journal_entries',                   'processing_cost_entries', 'source_id',      '{}'::jsonb, 'down', true,  false),
        ('output_batch', 34, 'journal_entries',                   'processing_runs',    'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 35, 'journal_entries',                   'stocktakes',         'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 36, 'journal_entries',                   'journal_entries',    'reversed_by',         '{}'::jsonb, 'up',  true,  false),

        -- ── 工单(1b-1):明细 · 预期产出 · 修改史 · 放行审批 ─────────────────────────────────────────────
        ('work_order', 1, 'work_order_lines',            'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 2, 'work_order_expected_outputs', 'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 3, 'work_order_history',          'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 4, 'approval_log',                'work_orders', 'subject_id',    '{"subject_type": "work_order"}'::jsonb, 'down', true, true),

        -- ── 盘点(1b-1):盘点行 · 每一次清点 · 过账审批 · 过账分录(财务读)─────────────────────────────────
        ('stocktake', 1, 'stocktake_lines',  'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 2, 'stocktake_counts', 'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 3, 'approval_log',     'stocktakes', 'subject_id',   '{"subject_type": "stocktake"}'::jsonb, 'down', true, true),
        ('stocktake', 4, 'journal_entries',  'stocktakes', 'source_id',    '{"source_type": "stocktake"}'::jsonb, 'down', true, false),

        -- ── 设备(1b-1,Q22):保养维修 · 停机 · 保养周期 · 交接班里提到的那次停机 ────────────────────────────
        ('equipment', 1, 'equipment_maintenance',         'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 2, 'equipment_downtime',            'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 3, 'equipment_service_intervals',   'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 4, 'shift_handover_equipment_refs', 'equipment_downtime', 'downtime_id',  '{}'::jsonb, 'down', true, false),

        -- ── 交接班(1b-1,Q23):交接事项 · 提到的停机 ───────────────────────────────────────────────────
        ('shift_handover', 1, 'shift_handover_items',          'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),
        ('shift_handover', 2, 'shift_handover_equipment_refs', 'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),

        -- ── 仓库申请(1b-1,Q12):/inventory 那一块 —— 申请本身与它的审批 ─────────────────────────────────
        ('warehouse_request', 1, 'approval_log', 'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a)· 商务:报价、订单、发货、客户、佣金、供应商、物流 ══
        -- ── 报价:明细(硬删的行从影像里找)· 签发档 · 事件史 ─────────────────────────────────────────
        ('quote', 1, 'quote_lines',  'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 2, 'qt_issues',    'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 3, 'quote_history', 'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        -- ── 销售订单:明细 · 明细的预留 · 发货放行与它的明细、审批 · 签发档 · 事件史 · 合同条款 ──────────────
        --   ★ 预留、发货单明细、订单事件史以前挂在产出批次下面(home = false);它们的【家】是这张订单 / 这张发货单,
        --     所以 /settings/change-history 的 Record 一栏从此指向订单 / 发货单(trail_row_record 只沿 home 走)。
        ('sales_order', 1, 'sales_order_lines',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 2, 'sales_order_reservations', 'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true, true),
        ('sales_order', 3, 'shipping_releases',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 4, 'shipping_release_lines',   'shipping_releases',  'release_id',          '{}'::jsonb, 'down', true, true),
        ('sales_order', 5, 'approval_log',             'shipping_releases',  'subject_id',          '{"subject_type": "shipping_release"}'::jsonb, 'down', true, true),
        ('sales_order', 6, 'so_issues',                'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 7, 'sales_order_history',      'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 8, 'contract_document_terms',  'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        -- ── 发货单(M1:销售或发货的人都读得到):明细 · 送货单签发档 ─────────────────────────────────────
        ('shipment', 1, 'shipment_lines',  'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        ('shipment', 2, 'shipment_issues', 'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        -- ── 客户:联系人 · 附件 · 信用史 · 对账单与它的签发档 · 催收与它挂的单据、承诺
        --   (后四张只给财务读 —— 读不了的人那几行是 Restricted,Q4)────────────────────────────────────
        ('customer', 1, 'counterparty_contacts',      'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 2, 'customer_attachments',       'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 3, 'customer_credit_history',    'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 4, 'customer_statements',        'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 5, 'statement_issues',           'customer_statements', 'statement_id', '{}'::jsonb, 'down', true, true),
        ('customer', 6, 'collection_chases',          'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 7, 'collection_chase_documents', 'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        ('customer', 8, 'collection_promises',        'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        -- ── 供应商:合规证书 · 附件 · 联系人 · 状态变动史 · 审批(送审、批准、驳回)────────────────────────
        ('supplier', 1, 'supplier_compliance',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 2, 'supplier_attachments',    'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 3, 'counterparty_contacts',   'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 4, 'supplier_status_history', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 5, 'approval_log',            'suppliers', 'subject_id',  '{"subject_type": "supplier"}'::jsonb, 'down', true, true),
        -- ── 集装箱:里程碑 · 单据清单 ────────────────────────────────────────────────────────────────
        ('container', 1, 'container_milestones', 'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        ('container', 2, 'container_documents',  'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        -- ── 货代(M3):物流属性(一家一行,主键就是 supplier_id)· 按航段的报价 ──────────────────────────────
        ('forwarder', 1, 'forwarder_details',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('forwarder', 2, 'forwarder_rate_quotes', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        -- ── 航段:它的单据清单;港口:从它出发、到它为止的航段(两个外键,两行)──────────────────────────────
        ('lane', 1, 'lane_document_requirements', 'lanes', 'lane_id',             '{}'::jsonb, 'down', true, true),
        ('port', 1, 'lanes',                      'ports', 'origin_port_id',      '{}'::jsonb, 'down', true, false),
        ('port', 2, 'lanes',                      'ports', 'destination_port_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a)· 主数据与工具:物料、库位、金属价格、公式、任务 ══
        -- ── 物料:附件 · 必须化验的金属(复合主键,叶子)───────────────────────────────────────────────
        ('material', 1, 'material_attachments',     'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        ('material', 2, 'material_required_metals', 'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        -- ── 库位:允许存放的废物分类(Q13:保存只改变动的那几条,一次调用 —— save_storage_location)──────────
        ('storage_location', 1, 'storage_location_allowed_classes', 'storage_locations', 'location_id', '{}'::jsonb, 'down', true, true),
        -- ── 公式:应付金属(叶子)· 修改史 · 条款申请(只给持价格码的人读,别人那一行是 Restricted,Q4)· 申请的审批 ────
        ('pricing_formula', 1, 'pricing_formula_metals',  'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 2, 'pricing_formula_history', 'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 3, 'terms_requests',          'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 4, 'approval_log',            'terms_requests',   'subject_id', '{"subject_type": "terms_request"}'::jsonb, 'down', true, true),
        -- ── 任务(Q3:私人任务也是):步骤 · 参与者 · 修改史(三张表的人都是员工 id,M2)─────────────────────
        ('task', 1, 'task_nodes',        'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 2, 'task_participants', 'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a)· 账上的单据 ══════════════════════════════════
        -- 冲销分录的 source_id 指的是【原分录】(reverse_journal_entry_internal),不是原单据 —— 所以一张单据够到它的冲销,
        --   只走原分录的 reversed_by(往上一跳,M4;批次 ord 39 的同一个做法),绝不按 source_id = 单据 id 去找。
        -- 一张冲销分录的行【不】挂在原分录上(Q33):行(ord 1)排在冲销(ord 2)之前展开,所以只取到根分录自己的行。
        -- ── 分录:行 · 它的冲销(往上)· 它冲的那一张(往下,在冲销分录的页上)· 申请(人工分录 / 冲销)与申请的审批 ──
        ('journal_entry', 1, 'journal_lines',    'journal_entries',  'entry_id',                '{}'::jsonb, 'down', true, true),
        ('journal_entry', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('journal_entry', 3, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'down', true, false),
        ('journal_entry', 4, 'journal_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('journal_entry', 5, 'journal_requests', 'journal_entries',  'target_entry_id',         '{}'::jsonb, 'down', true, false),
        ('journal_entry', 6, 'approval_log',     'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, false),
        -- AUDIT-TRAIL-1c-3:一次折旧的分录带着它记到每一张资产卡上的那一行(/finance/assets 的折旧批次一块读这张分录;
        --   家仍是资产那一页 —— 每一张资产卡自己也有它那一行,Step 0 §a)
        ('journal_entry', 7, 'fixed_asset_depreciation', 'journal_entries', 'journal_entry_id', '{}'::jsonb, 'down', true, false),
        -- ── 发票:行 · 签发档 · 作废 / 贷项申请与它的审批 · 由它开出的贷项通知 · 核销它的收款 · 它的分录与冲销 ──────
        ('invoice', 1, 'invoice_lines',    'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 2, 'invoice_issues',   'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 3, 'invoice_requests', 'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 4, 'approval_log',     'invoice_requests', 'subject_id',              '{"subject_type": "invoice_request"}'::jsonb, 'down', true, true),
        ('invoice', 5, 'credit_notes',     'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 6, 'payment_allocations', 'invoices',      'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 7, 'journal_entries',  'invoices',         'entry_id',                '{}'::jsonb, 'up',   true, false),
        ('invoice', 8, 'journal_entries',  'invoice_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        ('invoice', 9, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        -- ── 贷项通知:行 · 签发档 · 开出它的那张申请与审批 · 它的分录 ──────────────────────────────────────────
        ('credit_note', 1, 'credit_note_lines', 'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 2, 'cn_issues',         'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 3, 'invoice_requests',  'credit_notes',     'result_credit_note_id', '{}'::jsonb, 'down', true, false),
        ('credit_note', 4, 'approval_log',      'invoice_requests', 'subject_id',            '{"subject_type": "invoice_request"}'::jsonb, 'down', true, false),
        ('credit_note', 5, 'journal_entries',   'credit_notes',     'entry_id',              '{}'::jsonb, 'up',   true, false),
        -- ── 收付款:核销行 · 附件 · 冲销它的那一笔(往上)/ 它冲的那一笔(往下,在镜像单上)· 付出它的申请 · 冲它的申请 ·
        --    申请的审批 · 它的分录与冲销 ────────────────────────────────────────────────────────────────────────
        ('payment', 1, 'payment_allocations', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, true),
        ('payment', 2, 'finance_attachments', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 3, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'up',   true, false),
        ('payment', 4, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'down', true, false),
        ('payment', 5, 'payment_requests',    'payments',         'result_payment_id',   '{}'::jsonb, 'down', true, false),
        ('payment', 6, 'payment_requests',    'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 7, 'approval_log',        'payment_requests', 'subject_id',          '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        ('payment', 8, 'journal_entries',     'payments',         'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('payment', 9, 'journal_entries',     'journal_entries',  'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 付款申请(六种:付款 · 付款冲销 · 行内转账 · 转账冲销 · 代扣税缴纳 · 缴纳冲销):审批 · 付出的那一笔 ·
        --    被冲的那一笔(垫脚石:它自己的事不是这张申请的)· 转账 · 缴纳 · 过账的分录与冲销 ──────────────────
        --    ★ 一张"代扣税缴纳"申请没有指向它造出的那一笔缴纳的外键(形状检查让 wht_remittance_id 在这一种上恒为空)——
        --      唯一的路是 申请 → result_journal_entry_id → wht_remittances.journal_entry_id(ord 8)。
        ('payment_request',  1, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, true),
        ('payment_request',  2, 'payments',         'payment_requests', 'result_payment_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  3, 'payments',         'payment_requests', 'payment_id',              '{}'::jsonb, 'up',   false, false),
        ('payment_request',  4, 'bank_transfers',   'payment_requests', 'result_transfer_id',      '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  5, 'bank_transfers',   'payment_requests', 'transfer_id',             '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  6, 'wht_remittances',  'payment_requests', 'wht_remittance_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  7, 'journal_entries',  'payment_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  8, 'wht_remittances',  'journal_entries',  'journal_entry_id',        '{}'::jsonb, 'down', true,  false),
        ('payment_request',  9, 'journal_entries',  'bank_transfers',   'reversal_entry_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request', 10, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true,  false),
        -- ── 费用 / 供应商账单:核销行 · 附件 · 定金冲抵 · 冲销它的那一张(往上)/ 它冲的那一张(往下)· 报销单与它的审批 ·
        --    资本化进资产的那一笔成本 · 它的分录 · 定金冲抵的分录 · 冲销 ────────────────────────────────────────
        ('expense',  1, 'payment_allocations',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  2, 'finance_attachments',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  3, 'prepayment_applications',  'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        ('expense',  4, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('expense',  5, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'down', true, false),
        ('expense',  6, 'expense_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  7, 'approval_log',             'expense_claims',          'subject_id',          '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('expense',  8, 'fixed_asset_cost_entries', 'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  9, 'journal_entries',          'expenses',                'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('expense', 10, 'journal_entries',          'prepayment_applications', 'source_id',           '{}'::jsonb, 'down', true, false),
        ('expense', 11, 'journal_entries',          'journal_entries',         'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- AUDIT-TRAIL-1d-2(Q37):医疗报销付款时建的那张费用单 —— 费用页够得到是哪一张报销单让它生出来的(家仍在报销单那一页)
        ('expense', 12, 'medical_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        -- EXPENSE-MULTILINE-1(Tim 2026-10-20):费用单的行 —— 家在费用单(行没有自己的页面)
        ('expense', 13, 'expense_lines',            'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        -- ── 应付(Q5,M3 · M6):只有钱的那几样 —— 核销 · 运费分摊 · 定金冲抵 · 财务附件 · 价格 · 计价 / 注销 / 定金的分录与冲销 ──
        ('payable', 1, 'payment_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 2, 'freight_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 3, 'prepayment_applications', 'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 4, 'finance_attachments',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 5, 'price_history',           'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 6, 'journal_entries',         'inbound_batches',         'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 7, 'journal_entries',         'prepayment_applications', 'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 8, 'journal_entries',         'journal_entries',         'reversed_by',      '{}'::jsonb, 'up',   true, false),

        -- ══ AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a)· 其余的单据与合同 ══════════════════════════════════
        -- ── 销售(Q14):出库 · 归属客户 · 开票的那一行 · 收款核销 · 附件 · 收入 / 成本分录与它们的冲销 ─────────────────
        --    ★ 销售自己是一个主语的根了 —— /settings/change-history 的 Record 一栏把销售那一行与它的子行归到【这一笔销售】
        --      (以前归到产出批次:产出批次 ord 12 的 home 改成 false,于是从子行往上走到销售就停下)
        ('sale', 1, 'sales_record_movements', 'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 2, 'sales_attribution_log',  'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 3, 'invoice_lines',          'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 4, 'payment_allocations',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 5, 'finance_attachments',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, true),
        ('sale', 6, 'journal_entries',        'sales_records',   'source_id',       '{"source_type": "sale"}'::jsonb, 'down', true, false),
        ('sale', 7, 'journal_entries',        'sales_records',   'cogs_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('sale', 8, 'journal_entries',        'journal_entries', 'reversed_by',     '{}'::jsonb, 'up',   true, false),
        -- ── 运费单:分摊到的批次(家在这里 —— 它是这张单分出去的)· 付它的核销 · 过账分录 · 冲销分录 ───────────────────
        ('freight', 1, 'freight_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, true),
        ('freight', 2, 'payment_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, false),
        ('freight', 3, 'journal_entries',     'freight_documents', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('freight', 4, 'journal_entries',     'freight_documents', 'reversal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('freight', 5, 'journal_entries',     'journal_entries',   'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 资产(财务那一页,Q10):资产卡的修改史 · 成本 · 折旧与折旧基点 · 处置申请与它的审批 · 处置 / 折旧的分录 ·
        --    保养维修、停机、保养间隔(家仍是 equipment —— 加工那一页)─────────────────────────────────────────────
        ('fixed_asset',  1, 'fixed_asset_history',              'fixed_assets',             'fixed_asset_id',      '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  2, 'fixed_asset_cost_entries',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  3, 'fixed_asset_depreciation',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  4, 'fixed_asset_depreciation_anchors', 'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  5, 'asset_disposal_requests',          'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  6, 'approval_log',                     'asset_disposal_requests',  'subject_id',          '{"subject_type": "asset_disposal_request"}'::jsonb, 'down', true, true),
        ('fixed_asset',  7, 'equipment_maintenance',            'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  8, 'equipment_downtime',               'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  9, 'equipment_service_intervals',      'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 10, 'shift_handover_equipment_refs',    'equipment_downtime',       'downtime_id',         '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 11, 'journal_entries',                  'fixed_assets',             'disposal_journal_id', '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 12, 'journal_entries',                  'fixed_asset_depreciation', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 13, 'journal_entries',                  'journal_entries',          'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 对账单:行与每一行的匹配 · 对账记录与它写明的差额 ────────────────────────────────────────────────────
        ('bank_statement', 1, 'bank_statement_lines',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 2, 'bank_line_matches',                  'bank_statement_lines', 'statement_line_id', '{}'::jsonb, 'down', true, true),
        ('bank_statement', 3, 'bank_reconciliations',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 4, 'bank_reconciliation_variance_items', 'bank_reconciliations', 'reconciliation_id', '{}'::jsonb, 'down', true, true),
        -- ── GST 期间:申报那一刻抄下来的每一格 · 申报申请与它的审批。★ Q22:更正期间【不】挂在原期间上(那样更正件之后的
        --    每一次改动都会出现在原件上);更正件自己的记录以"为 GST-… 开的更正"开头,原件页上那一条链接照旧 ──────────────
        ('gst_period', 1, 'gst_return_boxes',    'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 2, 'gst_filing_requests', 'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 3, 'approval_log',        'gst_filing_requests', 'subject_id', '{"subject_type": "gst_filing_request"}'::jsonb, 'down', true, true),
        -- ── 汇率:它的修改史(录入 · 更正 · 撤回 —— 一件事两行:记录开始之后变更记录那一行说,之前修改史那一行说)──────
        ('fx_rate', 1, 'fx_rate_history', 'fx_rates', 'fx_rate_id', '{}'::jsonb, 'down', true, true),
        -- ── 管理包:没有成员(一份新包取代旧包时,旧包自己那几列说"被谁取代";不经 superseded_by 自连 —— 那会把前一份的
        --    整段历史拉到这一份上)
        -- ── 合同:七张条款表 · 它的申请(生效)与申请的审批(没有 pricing.view 的读者那几行是 Restricted,Q21)·
        --    把它挂到采购单 / 销售订单上的那一份快照(家仍在那张订单上)────────────────────────────────────────────
        ('contract',  1, 'contract_grade_specs',           'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  2, 'contract_insurance_obligations', 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  3, 'contract_volume_commitments',    'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  4, 'contract_pricing_terms',         'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  5, 'contract_settlement_terms',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  6, 'contract_refining_charges',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  7, 'contract_penalty_elements',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  8, 'terms_requests',                 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  9, 'approval_log',                   'terms_requests', 'subject_id',  '{"subject_type": "terms_request"}'::jsonb, 'down', true, false),
        ('contract', 10, 'contract_document_terms',        'contracts',      'contract_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a)· 期末、设置与清单页上的记录 ══════════════════════════
        -- ── 锁期(Q25 · Q3 · M7):月结 / 反结的 period_closes 与 finance_settings 之间一个键都没有 —— 整张表属于那一行。
        --    关账在同一笔里写 period_closes 一行、把锁往后挪;反结在同一笔里给那一行盖反结的戳、把锁往回挪 —— 各是一条
        ('finance_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 年结:结转分录(往上)· 反结的冲销分录(往上)──────────────────────────────────────────────────
        ('year_close', 1, 'journal_entries', 'year_closes', 'closing_journal_id',  '{}'::jsonb, 'up', true, false),
        ('year_close', 2, 'journal_entries', 'year_closes', 'reversal_journal_id', '{}'::jsonb, 'up', true, false),
        -- ── 人工分录 / 冲销申请(Q17):它的审批(家在这里 —— 一张还没批的申请没有分录,它唯一的家是它自己)· 过账的那一张 ──
        ('journal_request', 1, 'approval_log',    'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, true),
        ('journal_request', 2, 'journal_entries', 'journal_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        -- ── 报销单(Q20):审批 · 收据(附件)· 批准时记下的那张费用单(往上)。/me 上报销人自己读同样的几张(M8)──────
        ('expense_claim',    1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, true),
        -- CLAIM-RECEIPTS-1(Tim 2026-10-21,Q13 · 委托书:收据进报销单的审计记录):每一笔的收据取代了整张单的附件那条路
        ('expense_claim',    2, 'expense_claim_receipts', 'expense_claims', 'claim_id', '{}'::jsonb, 'down', true, true),
        ('expense_claim',    3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        ('my_expense_claim', 1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('my_expense_claim', 2, 'expense_claim_receipts', 'expense_claims', 'claim_id', '{}'::jsonb, 'down', true, false),
        ('my_expense_claim', 3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        -- EXPENSE-MULTILINE-1(Tim 2026-10-20):报销单的明细 —— 家在报销单那一块(/finance/claims);/me 上本人读同样的几笔
        ('expense_claim',    4, 'expense_claim_items', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('my_expense_claim', 4, 'expense_claim_items', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        -- ── 行内转账:过账分录 · 冲销分录(往上)· 付出它 / 冲它的申请(往下,两把外键 —— 港口的先例)与申请的审批 ──
        ('bank_transfer', 1, 'journal_entries',  'bank_transfers',   'journal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 2, 'journal_entries',  'bank_transfers',   'reversal_entry_id',  '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 3, 'payment_requests', 'bank_transfers',   'result_transfer_id', '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 4, 'payment_requests', 'bank_transfers',   'transfer_id',        '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 5, 'approval_log',     'payment_requests', 'subject_id',         '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        -- ── 代扣税缴纳(Q30):它的分录 · 冲销那一张(经原分录的 reversed_by,往上)· 冲它的申请(wht_remittance_id)·
        --    付出它的申请(那种申请没有指向缴纳的外键 —— 只能经分录:payment_requests.result_journal_entry_id,往下)· 审批 ──
        ('wht_remittance', 1, 'journal_entries',  'wht_remittances',  'journal_entry_id',        '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 3, 'payment_requests', 'wht_remittances',  'wht_remittance_id',       '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 4, 'payment_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 5, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a · §d · §e)· 机制、设置与员工 ══════════════════════════════
        -- ── 账号(M9,Q24):授给它的角色(家在这里,Q22)· 它作为附加账号挂在谁身上 · 那张挂接史 · 它是谁的主账号
        --    (employees.user_id —— M10 只取那一列:那名员工别的每一次编辑不是账号的事)──────────────────────────────
        ('account', 1, 'user_roles',               'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 2, 'employee_accounts',        'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 3, 'employee_account_history', 'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 4, 'employees',                'auth.users', 'user_id', '{}'::jsonb, 'down', true, false),
        -- ── 审批方针(M7 · Q25):修改史整张属于那一行设置(两张表之间没有键 —— 锁期 / period_closes 的同一个做法)──────────
        ('approval_policy', 1, 'finance_settings_history', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 员工(Q28):任职履历 · 调薪申请与它的审批(只给 view_pay 的人读,别人那几行是 Restricted)· 培训(家在培训那一页,Q29)·
        --    附加账号与它的挂接史 · 账号的镜像(Q24 · Q21):主账号与附加账号(往上一跳到 auth.users,M9)与授给它们的角色 ——
        --    每一行照它自己的读规则:授权人人读得到,账号事件与挂接史只给 manage_permissions,别人是 Restricted ────────────────
        ('employee', 1, 'employment_history',       'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 2, 'salary_change_requests',   'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 3, 'approval_log',             'salary_change_requests', 'subject_id',  '{"subject_type": "salary_change_request"}'::jsonb, 'down', true, true),
        ('employee', 4, 'training_records',         'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 5, 'employee_accounts',        'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 6, 'employee_account_history', 'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 7, 'auth.users',               'employees',              'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 8, 'auth.users',               'employee_accounts',      'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 9, 'user_roles',               'auth.users',             'user_id',     '{}'::jsonb, 'down', true, false),
        -- ── 部门 · 培训记录 · 导入批次:没有成员。六本字典:M11 集合,没有成员 ──────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a)· 请假与考勤 ══════════════════════════════════════════
        -- ── 请假:消耗账(批准时扣、取消时还 —— 家在这里)· 审批 ─────────────────────────────────────────────
        --    /me 上本人读同样的两张(M8);两张的读规则都只给 hr.view,所以本人看到的是 Restricted(Q4 · Q14)
        ('leave_request',    1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, true),
        ('leave_request',    2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, true),
        ('my_leave_request', 1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, false),
        ('my_leave_request', 2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, false),
        -- ── 医疗报销:审批 · 付它的那张费用单(往上,M4)· 费用的分录 · 核销 · 冲销它的费用单与分录(只给财务,别人 Restricted)──
        ('medical_claim',    1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, true),
        ('medical_claim',    2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('medical_claim',    5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, false),
        ('my_medical_claim', 2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('my_medical_claim', 5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        -- ── 加班:行(删掉的行从 DELETE 的影像里找)· 审批(送审 · 批准 · 退回)──────────────────────────────────
        ('overtime_batch',   1, 'overtime_lines',      'overtime_batches', 'batch_id',          '{}'::jsonb, 'down', true, true),
        ('overtime_batch',   2, 'approval_log',        'overtime_batches', 'subject_id',        '{"subject_type": "overtime_batch"}'::jsonb, 'down', true, true),
        -- ── 考勤:每人一行(开月 · 补新人 · 记录 · 完成时冻住的那几列 —— 完成那一下的整批改动在界面上是一句)──────────
        ('attendance_period', 1, 'attendance_lines',   'attendance_periods', 'period_id',       '{}'::jsonb, 'down', true, true),
        -- ── 假期发放(清单块)· 假别 · 公共假期(M11 集合):没有成员 ──────────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a)· 工资与评审 ══════════════════════════════════════════
        -- ── 工资期:工资行(每次保存删了重插 —— 一次操作里按员工配对,Q11;家在这里)· 过账 / 撤销的申请与它们的审批 ·
        --    这一期的分录(过账 · 发薪 · CPF · 代扣款)按 source_id + source_type = 'payroll' 找 —— 【不】经 journal_entry_id
        --    往上走:撤销过账会把那一列置空(unpost_payroll_period_internal),往上一跳读的是今天的样子,过账与它的冲销会一起丢掉;
        --    source_id 撤不掉。冲销分录自己的 source_id 是原分录(1c-1),所以它经 reversed_by 往上一跳。分录只给财务(别人 Restricted)
        ('payroll_period',     1, 'payroll_lines',    'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     2, 'payroll_requests', 'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     3, 'approval_log',     'payroll_requests',    'subject_id',        '{"subject_type": "payroll_request"}'::jsonb, 'down', true, true),
        ('payroll_period',     4, 'journal_entries',  'payroll_periods',     'source_id',         '{"source_type": "payroll"}'::jsonb, 'down', true, false),
        ('payroll_period',     5, 'journal_entries',  'journal_entries',     'reversed_by',       '{}'::jsonb, 'up',   true, false),
        -- ── 评审:目标(删掉的目标从 DELETE 的影像里找)· 审批(送审 · 批准 · 本人确认;作废不写审批)──────────────────
        --    批准时改的员工那一行与任职履历【不】挂进来(Q7):它们没有指回评审的键,评审那一段按评审自己的几列说出结论
        --    /my-reviews 上审核人读同样的两张(M12);审批那几行的读规则是 hr.view,不持它的审核人看到的是 Restricted(Q5 · Q4)
        ('performance_review', 1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, true),
        ('performance_review', 2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, true),
        ('my_review',          1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, false),
        ('my_review',          2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, false),
        -- ── MES-1:设备 —— 网关钥匙(发放与撤销;哈希被 never 规则遮住)。收件箱 · 传输日志 · 中断不进变更记录(MES-0 Q14),不在这里 ──
        ('device',             1, 'gateway_keys',     'devices',             'gateway_id',        '{}'::jsonb, 'down', true, true),
        -- ── MES-2:设备 —— 校准记录(记 · 作废;Q33)。地磅单 —— 它的称重(毛重 · 皮重 · 更正)、分出去的份、照片(传 · 撤)。
        --    草稿与确认时改过的值不挂进来:它们的读码是加工(查看),不是地磅单的门;确认队列与地磅单页上直接列它们 ──
        ('device',             2, 'instrument_calibrations', 'devices',      'device_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 1, 'weighings',        'weighbridge_tickets', 'ticket_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 2, 'weighbridge_ticket_shares', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 3, 'weighbridge_ticket_photos', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        -- ── MES-3a(2026-10-06,MES-3a Step 0 Q12 · Q10):执照 —— 它每一类 NEA 废物的库存上限(给 · 改 · 拿掉)。
        --    进料批 / 产出批 —— 它进厂那一刻库存上限的判法(一批一行,只追加)。──
        ('company_licence',    1, 'licence_storage_limits', 'company_compliance', 'licence_id',  '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     40, 'receipt_ceiling_checks', 'inbound_batches',    'inbound_batch_id', '{}'::jsonb, 'down', true, true),
        ('output_batch',      37, 'receipt_ceiling_checks', 'output_batches',     'output_batch_id',  '{}'::jsonb, 'down', true, false),
        -- ── MES-3b(2026-10-07,MES-3b Step 0 Q7 · Q27):每一次印标签(印 · 补印与理由)—— 挂在它印的那样东西下面。
        --    一张表挂三个主语,只有一处是家(trail_row_record 沿 home 往上走):进料批那一支,与 receipt_ceiling_checks 同一个选法 ──
        ('inbound_batch',     41, 'label_prints',           'inbound_batches',    'inbound_batch_id',    '{}'::jsonb, 'down', true, true),
        ('output_batch',      38, 'label_prints',           'output_batches',     'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('storage_location',   2, 'label_prints',           'storage_locations',  'storage_location_id', '{}'::jsonb, 'down', true, false),
        -- ── MES-4a(2026-10-07,MES-4a Step 0 Q33):加工单 —— 记下的值、异常事件、结平、表头更正(都只追加,都按 run_id 挂)。
        --    一道工序 —— 它的字段、挂着的机器、配方(按 operation_type_code 挂在根行的 code 下)与配方的每一版(挂在配方下)。──
        ('processing_run',     9, 'processing_run_values',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    10, 'processing_run_events',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    11, 'processing_run_closures',    'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    12, 'processing_run_corrections', 'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('operation_type',     1, 'operation_type_fields',      'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     2, 'operation_type_equipment',   'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     3, 'process_recipes',            'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     4, 'process_recipe_versions',    'process_recipes',  'recipe_id',           '{}'::jsonb, 'down', true, true),
        -- ── MES-4b(2026-10-07,MES-4b Step 0 Q28):交叉污染抽检 —— 挂在它那一炉(家)与它抽的那一批极片下面(receipt_ceiling_checks 的先例:
        --    一张表挂两个主语,只有一处是家)。没抽的那一种没有批次,只出现在加工单上。──
        ('processing_run',    13, 'contamination_checks',       'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('output_batch',      39, 'contamination_checks',       'output_batches',   'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-1(2026-10-08,MES-5a Step 0 Q31):放电 —— 逐模组结果、通道分配、拆去隔离的模组。家在那一炉(结果与分配挂在放电那一炉,
        --    拆分挂在拆分那一炉);也出现在它们说的那一批上,结果还出现在记下它的放电柜上(device_id;今天手工录入不填它)。──
        ('processing_run',    14, 'discharge_module_results',      'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    15, 'discharge_channel_assignments', 'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    16, 'discharge_module_splits',       'processing_runs', 'split_run_id',     '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     42, 'discharge_module_results',      'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     43, 'discharge_module_splits',       'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('output_batch',      40, 'discharge_module_results',      'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('output_batch',      41, 'discharge_module_splits',       'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('device',             3, 'discharge_module_results',      'devices',         'device_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-2(2026-10-08,MES-5a Step 0 Q31):电表读数住在那台电表下;一张电费单分给一炉的那一份住在那张单下,也出现在那一炉上。──
        ('device',             4, 'meter_readings',                'devices',                 'device_id',     '{}'::jsonb, 'down', true, true),
        ('electricity_allocation', 1, 'electricity_allocation_lines', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    17, 'electricity_allocation_lines',  'processing_runs',         'run_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5b-2(2026-10-09,MES-5b Step 0 Q32 · Q34;MES5B1-V37-NOT-ON-OPERATION-TRAIL,Tim):一张电费单的撤回住在那张单下,
        --    也出现在它覆盖过的每一炉上(经那一炉的那一行往上一跳到那张分摊 —— 垫脚石,自己的改动不进来 —— 再往下到撤回)。
        --    一道工序每一种产出形态的预期得率(V37)住在那道工序下(按 operation_type_code 挂在根行的 code 下,与它的字段同形)。──
        ('electricity_allocation', 2, 'electricity_allocation_reversals', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    18, 'electricity_allocations',          'electricity_allocation_lines', 'allocation_id', '{}'::jsonb, 'up',   false, false),
        ('processing_run',    19, 'electricity_allocation_reversals', 'electricity_allocations',      'allocation_id', '{}'::jsonb, 'down', true, false),
        ('operation_type',     5, 'operation_type_output_forms',      'operation_types',              'operation_type_code', '{}'::jsonb, 'down', true, true),
        -- ── MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划的目标品位与候选批次都住在那份计划下。──
        ('blending_plan',      1, 'blending_plan_targets',            'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        ('blending_plan',      2, 'blending_plan_lines',              'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        -- ── MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品的保管记录住在那份样品下;样品、它的保管记录与化验争议也出现在它们那一批上
        --    (家在样品 / 争议自己那里)。──
        ('sample',             1, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     44, 'samples',                          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     45, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     46, 'assay_disputes',                   'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      42, 'samples',                          'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      43, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('output_batch',      44, 'assay_disputes',                   'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-6a-2(2026-10-10,MES-6a Step 0 Q39):一份化验的指标(残粉 · 箔纯度 · 粒径)与它的金属行同一个形状 ——
        --    住在那份化验挂着的那一批下(化验没有自己的主语;它的金属行也是这样挂的)。──
        ('inbound_batch',     47, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        ('output_batch',      45, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-1(2026-10-15,MES-6b Step 0 Q39):不合格报告也出现在它那一批上(家在报告自己那里);质量验收限的判定住在产出批下
        --    (判定挂在批次上,没有自己的主语);合同的第八张条款表住在合同下。──
        ('inbound_batch',     48, 'nonconformance_reports',           'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      46, 'nonconformance_reports',           'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      47, 'quality_limit_judgements',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, true),
        ('contract',          11, 'contract_quality_limits',          'contracts',                    'contract_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-2(2026-10-15,MES-6b Step 0 Q38 · Q39):一张分析证书 —— 它的字节档案(家在证书)、作废它的 CFO 申请与那张申请的审批。
        --    证书也出现在两个批次主语下(家在证书自己那里):产出批 —— 它自己的证书、字节、作废申请与审批;进料批 —— 吃过这一批的加工单
        --    做出来的产出批上的证书(垫脚石:加工单 → 它的产出腿 → 那一批产出,只走一层;证书说的"来料化学确定度"正是这一批的事)。──
        ('coa',                1, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, true),
        ('coa',                2, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('coa',                3, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch',      48, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      49, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      50, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      51, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch',     49, 'processing_outputs',               'processing_runs',              'run_id',              '{}'::jsonb, 'down', false, false),
        ('inbound_batch',     50, 'output_batches',                   'processing_outputs',           'output_batch_id',     '{}'::jsonb, 'up',   false, false),
        ('inbound_batch',     51, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-7a-2(2026-10-16,MES-7a Step 0 Q20):备件出给保养与退回 —— 没有自己的主语(它没有自己的页)。家在设备(经那一条保养记录);
        --    也出现在进料批下(出的是这一批),连同那张分录(借 6800 / 贷 1200,source_type = maintenance_part,财务读)。──
        ('equipment',          5, 'maintenance_part_issues',          'equipment_maintenance',        'maintenance_id',      '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     52, 'maintenance_part_issues',          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     53, 'journal_entries',                  'maintenance_part_issues',      'source_id',           '{"source_type": "maintenance_part"}'::jsonb, 'down', true, false),
        -- ── MES-7b-1(2026-10-16,MES-7b Step 0 Q12 · Q19):一件事故 —— 之后的事实与批次链接住在这里;交接班的引用住在交接班下(家),
        --    也出现在事故上;来源 incident 的不合格报告也出现在事故上(家在报告自己那里)。批次链接也出现在那一批上(Q19:事故在批次上看得见)。──
        ('incident',           1, 'incident_updates',                 'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, true),
        ('incident',           2, 'incident_batches',                 'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, true),
        ('incident',           3, 'shift_handover_incident_refs',     'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, false),
        ('incident',           4, 'nonconformance_reports',           'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, false),
        ('shift_handover',     3, 'shift_handover_incident_refs',     'shift_handovers',              'handover_id',         '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     54, 'incident_batches',                 'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      52, 'incident_batches',                 'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-7b-2(2026-10-16,MES-7b Step 0 Q19):一次巡检 —— 它的结果、发现与发现的关闭住在这里;引用一条发现的不合格报告也出现在这里
        --    (家在报告自己那里)。一张巡检清单 —— 它的检查项住在这里。──
        ('inspection_run',      1, 'inspection_results',               'inspection_runs',              'run_id',              '{}'::jsonb, 'down', true, true),
        ('inspection_run',      2, 'inspection_findings',              'inspection_runs',              'run_id',              '{}'::jsonb, 'down', true, true),
        ('inspection_run',      3, 'inspection_finding_closures',      'inspection_findings',          'finding_id',          '{}'::jsonb, 'down', true, true),
        ('inspection_run',      4, 'nonconformance_reports',           'inspection_findings',          'inspection_finding_id', '{}'::jsonb, 'down', true, false),
        ('inspection_template', 1, 'inspection_template_items',        'inspection_templates',         'template_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-8a(2026-10-16,MES-8 Step 0 Q22):一份供应商对账单 —— 它的签发档住在这里。一家供应商的评审也出现在它下面
        --    (家在评分卡页那条集合记录里)。──
        ('supplier_statement',  1, 'supplier_statement_issues',        'supplier_statements',          'statement_id',        '{}'::jsonb, 'down', true, true),
        ('supplier',            6, 'supplier_scorecard_reviews',       'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, false),
        -- ── MES-9a(2026-10-19,MES-9 Step 0 §6 · Q21):一家供应商的门户账号 —— 开、撤销、匿名化住在这里 ──
        ('supplier',            7, 'supplier_portal_users',            'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-9c(2026-10-20,MES-9 Step 0 §5 · §6 · Q19 · Q21):门户交上来的证书 —— 交、接受、驳回住在这里 ──
        ('supplier',            8, 'portal_certificate_submissions',   'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-8b-1(2026-10-17,MES-8 Step 0 Q22):一份合规包 —— 它的签发档住在这里。──
        ('compliance_pack',     1, 'compliance_pack_issues',           'compliance_packs',             'pack_id',             '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 5 · expense_claim_status 重建(镜像原样:拿掉 has_receipt)—— 视图的写授权由 apply_migration.sh 随后重放 zzz_function_grants.sql 的 F16 那一段收回;
--   本事务里的自证要先看到它收回,所以这里也收一次(同一句话)──
-- db/views/expense_claim_status.sql
-- ★ CLAIM-RECEIPTS-1(Tim 2026-10-21,Q13):has_receipt 拿掉了 —— 它问的是【整张单】有没有附件(finance_attachments.claim_id,
--   那一列已删);收据现在按笔(expense_claim_receipts),两张页面各自另读那张表、逐笔说。一张单一个"有收据"的布尔值正是
--   逐笔规矩要拆掉的那个说法。拿掉一列要 DROP + CREATE(迁移里这么做)。
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20):表头这一行不再带 account_code / tax_code / no_receipt_reason —— 它们搬到了
--   每一笔明细(expense_claim_items,页面另读);多了 item_count。description 现在是整张单的【用途】(Step 0b Q7)。
--   属主权限与行谓词原样。【明细为什么不并进这张视图】一行一张单是它的全部契约(清单、在途、/me 都按单读);
--   明细是一对多,另读那张表 —— 它的读策略与本视图的行谓词同一条。
-- CLAIM-1：每一笔报销一行，而「付了没有」是从核销额【推导】出来的。
--
-- ★ WITH (security_invoker = off) 与 COMMENT ON VIEW 都是【手工补回来的】★
-- pg_get_viewdef() 只吐 SELECT —— 既不吐 reloptions，也不吐对象注释。
-- 照它重建镜像会把两样都悄悄丢掉（AGENTS.md 为前者记过一次；后者是
-- STATEMENT-1 漏过、CHASE-1-FU 补上的那一条）。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ APR-ROUTE-1 · F1(Tim 的 R5,2026-09-23):这张视图此前把【每一笔】报销
--     交给【任何一个】登录的人 ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它是什么形状】属主权限(security_invoker = off),于是 expense_claims 的 RLS
-- 根本不参与;而函数体【没有任何行谓词】。EMP-SELF-0 §3 以 fusheng(warehouse,
-- 不持 module.finance.view)的真身份实测:看得见 4 行 —— 线上全部 4 行,
-- 跨 2 名员工,带姓名、金额、事由。/me 只是因为页面自己加了
-- `.eq('employee_id', …)` 才没有在屏幕上露出来 —— 一道只在【页面】上的过滤,
-- 对一个直接调 PostgREST 的人什么都不是。
--
-- 【谓词】与 medical_claim_status 逐字同形:财务看全部,其余每个人只看自己的。
--   has_permission('module.finance.view') OR employee_id = current_user_employee()
-- ★ 两个都按【调用者】求值(两者都是 SECURITY DEFINER、读 auth.uid()),
--   所以属主权限不会把它们变成"属主看得见的一切"。
--
-- 【下面 COD-2 那段理由,在这张视图上是【假】的,照直更正】它说"本视图要喂
-- operations_now,加谓词会让没有财务权限的人的行静默消失"。EMP-SELF-0 §3 与
-- APR-ROUTE-1 grilling 各查一遍:`grep expense_claim_status` 在 db/views、
-- db/functions、app、lib 里只命中两处 —— app/me/page.tsx(本人)与
-- app/finance/claims/page.tsx(页闸 module.finance.view)。**没有任何视图或函数
-- 读它。** 于是这一句谓词没有让任何一个合法读者少一行。
-- ☞ 那段话大概是从 collection_promise_status(同一次 COD-2 一起收权的另一张)
--   上抄过来的。它留在下面,因为 REVOKE FROM anon 那一句仍然对 —— 错的只是理由。
--
-- 【一个读者真的少了行:db/fixtures/196 的 F0b】它以 postgres、清空 claims 的身份
-- 读这张视图来自证"视图里有东西"。postgres 没有 JWT → has_permission 恒假、
-- current_user_employee() 为 NULL → 0 行 → F0b 响亮地报"前提不成立"。
-- 同一刀里改成以一个持 module.finance.view 的身份读(Tim 的 Q11)。
--
-- NOTE: introduced by db/migrations/2026-08-28-claim1-employee-expense-claims.sql.

-- AP-RECON-1(2026-09-24):「付清了没有」对着【净额 + 进项税】判(CLAIM-GST-1 起读 amount_ccy + tax_ccy,
-- 落库的那一笔税;此前是 expense_payable_ccy 重算)——
-- CLAIM-GST-1 还在末尾【追加】两列 expense_net_ccy / expense_tax_ccy(费用单上的净额与税):
-- 批准之后,屏幕要说得出员工报的那个总额被拆成了什么 —— 读落库的两个数,不在页面上再算一遍。
-- 只追加、不动既有列序 → 迁移走 CREATE OR REPLACE。
-- 那是总账 2000 上欠员工的全部;只对着净额判,会在那笔税还欠着的时候说"已付"。
-- (报销的税是【从报销额里拆出来】的 —— CLAIM-GST-1,2026-09-24:decide_expense_claim 传
--  p_amount_includes_tax := true,于是 amount_ccy + tax_ccy 恰好等于员工报的那个总额。)

CREATE VIEW public.expense_claim_status WITH (security_invoker = off) AS
SELECT c.id AS claim_id,
    c.code,
    c.employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    c.spend_date,
    c.submitted_at,
    c.amount_ccy,
    c.currency,
    c.description,
    c.status,
    c.decided_at,
    c.decision_notes,
    c.posting_date,
    c.expense_id,
    x.payment_status,
    x.status = 'reversed'::text AS expense_reversed,
    COALESCE(a.settled_ccy, 0::numeric) AS settled_ccy,
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) >= (x.amount_ccy + x.tax_ccy) AS is_paid,
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) < (x.amount_ccy + x.tax_ccy) AS is_owing,
    x.amount_ccy AS expense_net_ccy,
    x.tax_ccy AS expense_tax_ccy,
    ( SELECT count(*) AS count
           FROM expense_claim_items i
          WHERE i.claim_id = c.id) AS item_count
   FROM expense_claims c
     JOIN employees e ON e.id = c.employee_id
     LEFT JOIN expenses x ON x.id = c.expense_id
     LEFT JOIN LATERAL ( SELECT round(sum(pa.allocated_ccy), 2) AS settled_ccy
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id
          WHERE pa.expense_id = c.expense_id AND p.status = 'posted'::text) a ON true
  WHERE has_permission('module.finance.view'::text) OR c.employee_id = current_user_employee();

COMMENT ON VIEW public.expense_claim_status IS
    'CLAIM-1:每一笔报销一行,而【付了没有是推导出来的】—— 与 medical_claim_status 同一条:付款状态归 expenses 所有,存一份副本第一次冲销付款时两边就分家。expense_reversed 单独露出来,因为"批准被撤销"在本刀里【没有】自己的机制:改法是冲销那笔费用(expenses 本来就有冲销路径与 reversed_by_expense),claim 的状态跟着它走 —— 两个撤销机制会对"这笔钱还欠不欠"各说各话。属主权限(security_invoker = off):它横跨 finance 与 hr(employees 有 RLS),invoker 会让读者无权的那一侧静默丢掉行,而行消失在这里意味着"少了一笔欠员工的钱"(OPS-14 修法 (a))。★ APR-ROUTE-1(F1,Tim 的 R5):行谓词写在视图里 —— has_permission(''module.finance.view'') OR employee_id = current_user_employee(),与 medical_claim_status 同形;此前它把每一笔报销交给任何一个登录的人,只靠页面自己的过滤挡着。';

-- ════════════════════════════════════════════════════════════════════════════
-- ★ COD-2(2026-09-08):从 anon 手里收回 —— 这一行必须在镜像里,不能只在迁移里 ★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它此前是什么状态】ANON-0 实测:本视图是属主权限(security_invoker = off,
-- 于是基表的 RLS 根本不参与)、授给了 anon、body 里没有任何权限判据、也不调
-- 任何带门的函数。**它今天回空只因为基表还没有行。** ANON-0 的原话:
-- 它不是在漏,它是【上了膛】—— 第一条真实记录写进来的那一刻它就开了,
-- 而在此之前没有任何检查会说一句话(check_mirrors.py 第 59 行自己写着「不比 GRANT」)。
--
-- 【为什么是 REVOKE,而不是给 body 加一句 has_permission】
--   本文件上面那段注释自己写着:它【刻意只有纯 SQL、一个函数都不调】,
--   因为它要喂 operations_now —— 那是没有财务权限的人也在看的首页。
--   加一句谓词会让那些人的行【静默消失】,而"少了一个逾期承诺"与"报错"
--   完全不是一回事。那正是 OPS-14 修法 (a) 要避开的东西。
--   而 REVOKE 对 authenticated 零代价:anon 从来不是它的合法读者。
--
-- 【为什么这一行住在镜像里】db/views/batch_lineage_all.sql 的抬头记着这个疤:
--   一条只住在迁移里的 REVOKE,重建出来的库【是开着的】——「线上收着,
--   重建出来的库开着」。看着它别再漂回去的是 db/check_grants.py(COD-2)。
REVOKE ALL ON public.expense_claim_status FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.expense_claim_status FROM anon, authenticated, PUBLIC;

-- ── 6 · 存储(与 db/storage/buckets-and-policies.sql 逐字同一份):一个桶 · 两条策略 ──
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('claim-receipts', 'claim-receipts', false, 10485760, ARRAY['application/pdf', 'image/jpeg', 'image/png'])
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "claim receipts upload own registered path" ON storage.objects;
CREATE POLICY "claim receipts upload own registered path"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (((bucket_id = 'claim-receipts'::text) AND public.claim_receipt_can_upload(bucket_id, name)));

DROP POLICY IF EXISTS "claim receipts read by finance.view or own claim" ON storage.objects;
CREATE POLICY "claim receipts read by finance.view or own claim"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (((bucket_id = 'claim-receipts'::text) AND public.claim_receipt_can_read(bucket_id, name)));

-- ── 7 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.claim_receipt_begin(uuid, text, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_receipt_begin(uuid, text, text, bigint) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.claim_receipt_finish(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_receipt_finish(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.claim_receipt_abandon(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_receipt_abandon(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.claim_receipt_remove(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_receipt_remove(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.claim_receipt_can_upload(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_receipt_can_upload(text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.claim_receipt_can_read(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_receipt_can_read(text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.claim_receipt_limits() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_receipt_limits() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_expense_claim_receipt_mutation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_expense_claim_receipt_mutation() TO authenticated, service_role;

-- ── 8 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.cr1_pending_decider_check(p_after boolean DEFAULT true)
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
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim_items',
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

CREATE TEMP TABLE cr1_pending_after ON COMMIT DROP AS
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
    v_recon jsonb;
    k       text;
BEGIN
    -- ① 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'CR1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM cr1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM cr1_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'CR1_PROOF|an account or its roles changed';
    END IF;

    -- ② 在途单据一张不少、一张不多;既有的行逐字未变(finance_attachments 比拿掉 claim_id 之后的);本事务一行变更记录都没写
    IF EXISTS ((SELECT b.k, b.id FROM cr1_pending_before b EXCEPT SELECT a2.k, a2.id FROM cr1_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM cr1_pending_after a2 EXCEPT SELECT b.k, b.id FROM cr1_pending_before b)) THEN
        RAISE EXCEPTION 'CR1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_attachments t ) IS DISTINCT FROM (SELECT finance_attachments FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expense_claims t ) IS DISTINCT FROM (SELECT expense_claims FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expense_claim_items t ) IS DISTINCT FROM (SELECT expense_claim_items FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) IS DISTINCT FROM (SELECT expenses FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expense_lines t ) IS DISTINCT FROM (SELECT expense_lines FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t ) IS DISTINCT FROM (SELECT accounts FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) IS DISTINCT FROM (SELECT journal_entries FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) IS DISTINCT FROM (SELECT journal_lines FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) IS DISTINCT FROM (SELECT payments FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t ) IS DISTINCT FROM (SELECT payment_allocations FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t ) IS DISTINCT FROM (SELECT payment_requests FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM medical_claims t ) IS DISTINCT FROM (SELECT medical_claims FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) IS DISTINCT FROM (SELECT approval_log FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) IS DISTINCT FROM (SELECT permissions FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) IS DISTINCT FROM (SELECT role_permissions FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) IS DISTINCT FROM (SELECT roles FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) IS DISTINCT FROM (SELECT user_roles FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) IS DISTINCT FROM (SELECT finance_settings FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) IS DISTINCT FROM (SELECT ingest_settings FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM account_settings t ) IS DISTINCT FROM (SELECT account_settings FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) IS DISTINCT FROM (SELECT cod_issues FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) IS DISTINCT FROM (SELECT employees FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) IS DISTINCT FROM (SELECT suppliers FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM portal_certificate_submissions t ) IS DISTINCT FROM (SELECT portal_certificate_submissions FROM cr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t ) IS DISTINCT FROM (SELECT document_types FROM cr1_rows_before) THEN
        RAISE EXCEPTION 'CR1_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM cr1_log_before), 0) AND c.txid = txid_current()) THEN
        RAISE EXCEPTION 'CR1_PROOF|this migration wrote change_log rows';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'CR1_PROOF|require_calibrated_since was set or a COD changed';
    END IF;

    -- ③ 清单 ↔ 总账:两边未解释仍是 0.00,而且与迁移之前逐字相同
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    v_recon := list_ledger_reconciliation();
    PERFORM set_config('request.jwt.claims', '', true);
    IF (v_recon - 'base_currency') IS DISTINCT FROM (SELECT j FROM cr1_recon_before)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                   WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'CR1_PROOF|the list-vs-ledger reconciliation moved: %', v_recon;
    END IF;

    -- ④ 结构:新函数在;claim_id 不在;新表开着 RLS、anon 一个权限都没有、authenticated 只读;收据 0 行
    IF to_regprocedure('public.claim_receipt_begin(uuid, text, text, bigint)') IS NULL OR to_regprocedure('public.claim_receipt_finish(uuid)') IS NULL
       OR to_regprocedure('public.claim_receipt_abandon(uuid)') IS NULL OR to_regprocedure('public.claim_receipt_remove(uuid)') IS NULL
       OR to_regprocedure('public.claim_receipt_can_upload(text, text)') IS NULL OR to_regprocedure('public.claim_receipt_can_read(text, text)') IS NULL
       OR to_regprocedure('public.claim_receipt_limits()') IS NULL THEN
        RAISE EXCEPTION 'CR1_PROOF|a receipt function is missing';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'finance_attachments' AND column_name = 'claim_id')
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'expense_claim_status' AND column_name = 'has_receipt') THEN
        RAISE EXCEPTION 'CR1_PROOF|the claim-wide attachment route is still there';
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.expense_claim_receipts'::regclass)
       OR has_table_privilege('anon', 'public.expense_claim_receipts', 'SELECT')
       OR has_table_privilege('authenticated', 'public.expense_claim_receipts', 'INSERT')
       OR has_table_privilege('authenticated', 'public.expense_claim_receipts', 'UPDATE')
       OR has_table_privilege('authenticated', 'public.expense_claim_receipts', 'DELETE')
       OR NOT has_table_privilege('authenticated', 'public.expense_claim_receipts', 'SELECT')
       OR (SELECT count(*) FROM expense_claim_receipts) <> 0 THEN
        RAISE EXCEPTION 'CR1_PROOF|the receipts table is not read-only-under-RLS for authenticated, closed to anon, and empty';
    END IF;

    -- ⑤ 存储:之前的 56 条策略原样 + 两条;之前的 20 个桶原样 + claim-receipts(私有 · 10 MB · PDF / JPEG / PNG);每一个对象逐字未变
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 58
       OR EXISTS (SELECT policyname, cmd, roles, qual, with_check FROM cr1_policies_before
                  EXCEPT SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM pg_policies WHERE schemaname = 'storage')
       OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND policyname IN ('claim receipts upload own registered path',
              'claim receipts read by finance.view or own claim') AND roles = ARRAY['authenticated']::name[]) <> 2
       OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND cmd IN ('UPDATE', 'DELETE', 'ALL')
                   AND COALESCE(qual, '') || COALESCE(with_check, '') LIKE '%claim-receipts%') THEN
        RAISE EXCEPTION 'CR1_PROOF|storage policies: expected the 56 unchanged plus the two receipt policies, and no update / delete on claim-receipts';
    END IF;
    IF (SELECT count(*) FROM storage.buckets) <> 21
       OR EXISTS (SELECT id, name, public, file_size_limit, mimes FROM cr1_buckets_before
                  EXCEPT SELECT id, name, public, file_size_limit, allowed_mime_types::text FROM storage.buckets)
       OR NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'claim-receipts' AND NOT public AND file_size_limit = 10485760
                       AND allowed_mime_types = ARRAY['application/pdf', 'image/jpeg', 'image/png']) THEN
        RAISE EXCEPTION 'CR1_PROOF|buckets: expected the 20 unchanged plus a private claim-receipts (10 MB · PDF / JPEG / PNG)';
    END IF;
    IF EXISTS ((SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects
                EXCEPT SELECT bucket_id, name, size, etag FROM cr1_objects_before)
               UNION ALL
               (SELECT bucket_id, name, size, etag FROM cr1_objects_before
                EXCEPT SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects)) THEN
        RAISE EXCEPTION 'CR1_PROOF|a stored object changed';
    END IF;

    -- ⑥ 328 张表;变更记录覆盖零缺口、豁免 9;遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 328 THEN
        RAISE EXCEPTION 'CR1_PROOF|expected 328 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'CR1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'CR1_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'CR1_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑦ 匿名面与门户面不变
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'CR1_PROOF|anon executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_can_upload_object, portal_certificates, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me, portal_submission_abandon, portal_submission_begin, portal_submission_finish' THEN
        RAISE EXCEPTION 'CR1_PROOF|supplier_portal executes: %', v_bad;
    END IF;

    -- ⑧ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.cr1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'CR1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.cr1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'CR1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.cr1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
