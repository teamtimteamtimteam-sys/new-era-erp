-- db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql
-- MES-9a —— 供应商门户的身份与隔离:admin 或 CCO 在供应商页上给一家供应商的一位联系人开一个门户登录;那个登录在库里是一个【单独的
--   Postgres 角色 supplier_portal】(Supabase Auth 的 access token hook 写进令牌),只够得着按名授给它的两支门户函数,看不见公司的任何内部东西;
--   初始密码当面交、第一次登录必须换;撤销立刻生效。员工的登录与空闲登出不变。(MES 组的第二十三刀,v1.4.60;发布那一行在
--   docs/handbacks/MES-9a.md 的抬头。)由 db/scripts/build_mes9a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-19:MES-9 Step 0 §15 —— Q1 切三刀、Q2 角色取代 MES-0 Q86、Q12 免费档、Q23 不要 MFA;其余 9a 那几条照推荐)
--   ① 角色 supplier_portal(NOLOGIN NOINHERIT,不是任何角色的成员)并授给 authenticator(PostgREST 要切得过去)。不另授任何架构 ——
--      public 的 USAGE 是 PostgreSQL 对 PUBLIC 的默认(Q27:只给干跑证明需要的;门户在 9a 不碰存储)。
--   ② 两张新表:supplier_portal_users(一个门户账号 = 一家供应商 + 它的一位联系人)· account_settings(V38 · V40,单行,全空)。
--   ③ counterparty_contacts 加一列 anonymised_at,"够得着"那条约束对已匿名化的联系人让路(Q20)。
--   ④ 守卫 guard_portal_account_separation 挂在四张表上:门户账号永远不持角色、不是员工;反过来也一样(Q5)。
--   ⑤ 函数:hook(只授 supabase_auth_admin;员工的令牌原样返回,里面失败也原样返回 —— 绝不抛)· portal_require_link(谁都不授)·
--      portal_me / portal_export_my_data(只授 supplier_portal)· 开 / 撤销 / 匿名化 / 显示标签 / V38·V40(员工那一侧,自己查码)。
--   ⑥ 码 action.manage_portal_users(声明 module.suppliers.view)—— 授 admin · cco(两行)。
--   ⑦ 视图 supplier_portal_accounts(供应商页那一块,module.suppliers.view);user_directory 不再列门户账号;pending_values 加 V38 · V40。
--   ⑧ 审计:trail_actor 认得门户账号(「Supplier portal — <供应商名>」);供应商的审计记录挂上门户链接;变更记录可以涂抹匿名化的联系人。
--
-- 【不做什么】不建任何门户账号(第一个真实供应商账号要等付费档、生产域名、V38 · V39 · V40 —— Step 0 §15);不建、不停、不改七个账号中的任何一个;
--   不碰审批开关;授权只多上面那两行;不碰任何存储桶与存储策略;不改任何既有的行(联系人只多一列空的);不回填;require_calibrated_since 保持空。
--   【hook 不由本迁移打开】它是 Supabase 的项目设置(Management API / 后台),在本迁移之后、证明了每一个员工的令牌原样之后才开 ——
--   见 docs/fresh-install-checklist.md 与交回报告;关掉它是一步。
--
-- 【破窗】这一窗什么都不坏:旧应用不读任何新东西;user_directory 少的只有门户账号(线上 0 个);pending_values 多两支(V38 · V40,读
--   action.manage_permissions —— 旧的待补值页照常把它们列出来,只是去处 /settings/accounts 上还没有那块面板,直到部署);hook 在部署之前打开时,
--   一个员工的令牌逐字节不变(自证 ③ 与开 hook 之后的逐账号登录检查),而线上没有门户账号。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了那两行,admin 持目录里每一个码(86);七个账号一个都没被停、角色一个没变,
--   而且对它们每一个,hook 返回的 event 与传进去的逐字节相同;没有任何门户账号;supplier_portal 能执行的恰好是两支门户函数、不是任何角色的成员、
--   由 authenticator 持有;hook 只给 supabase_auth_admin;在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;既有的行逐字未变;
--   anon 能执行的【恰好】两支;员工那几支 DEFINER、调得到;变更记录覆盖零缺口(豁免 8);待补的值 36 支;323 张表;没有一张视图对 anon /
--   authenticated 带写授权;存储策略仍是 52 条;两张 COD 的存储对象一个字节不动。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES9A_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.supplier_portal_users') IS NOT NULL OR to_regclass('public.account_settings') IS NOT NULL
       OR to_regprocedure('public.portal_access_token_hook(jsonb)') IS NOT NULL OR EXISTS (SELECT 1 FROM permissions WHERE code = 'action.manage_portal_users')
       OR EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supplier_portal') THEN
        RAISE EXCEPTION 'MES9A_PRE|MES-9a objects already exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
        RAISE EXCEPTION 'MES9A_PRE|the platform roles authenticator / supabase_auth_admin are missing';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test')) <> 7 THEN
        RAISE EXCEPTION 'MES9A_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 85
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES9A_PRE|expected a catalogue of 85 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'cco') AND is_active AND deleted_at IS NULL) <> 2 THEN
        RAISE EXCEPTION 'MES9A_PRE|the roles admin and cco must exist and be active';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 321 THEN
        RAISE EXCEPTION 'MES9A_PRE|expected 321 public tables';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 34 THEN
        RAISE EXCEPTION 'MES9A_PRE|pending_values should have 34 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 52 THEN
        RAISE EXCEPTION 'MES9A_PRE|expected 52 storage policies';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9A_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'MES9A_PRE|expected the two recorded COD byte strings';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes9a_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes9a_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes9a_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE mes9a_objects_before ON COMMIT DROP AS
SELECT bucket_id, name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects;
CREATE TEMP TABLE mes9a_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) AS suppliers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'anonymised_at')::text, '|' ORDER BY (to_jsonb(t) - 'anonymised_at')::text), '')) FROM counterparty_contacts t ) AS counterparty_contacts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_compliance t ) AS supplier_compliance,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_attachments t ) AS supplier_attachments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_status_history t ) AS supplier_status_history,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_scorecard_reviews t ) AS supplier_scorecard_reviews,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customers t ) AS customers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) AS employees,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employee_accounts t ) AS employee_accounts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM purchase_orders t ) AS purchase_orders,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM po_issues t ) AS po_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) AS certificates_of_destruction,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statements t ) AS supplier_statements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t WHERE code <> 'action.manage_portal_users') AS permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t WHERE permission_code <> 'action.manage_portal_users') AS role_permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) AS roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) AS user_roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) AS finance_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) AS ingest_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM floor_board_settings t ) AS floor_board_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t ) AS document_types;

-- ── 1 · 角色:supplier_portal —— 不能登录、不继承、不是任何角色的成员;authenticator 持有它(PostgREST 按令牌切过去)──
CREATE ROLE supplier_portal NOLOGIN NOINHERIT;
GRANT supplier_portal TO authenticator;

-- ── 2 · 联系人:一列 anonymised_at,"够得着"那条约束对已匿名化的联系人让路(与 db/tables/counterparty_contacts.sql 同一句)──
ALTER TABLE public.counterparty_contacts ADD COLUMN anonymised_at timestamptz;
ALTER TABLE public.counterparty_contacts DROP CONSTRAINT counterparty_contacts_reachable;
ALTER TABLE public.counterparty_contacts ADD CONSTRAINT counterparty_contacts_reachable
    CHECK (email IS NOT NULL OR phone IS NOT NULL OR anonymised_at IS NOT NULL);

-- ── 3 · 守卫(镜像原样):门户账号永远不持角色、不是员工;反过来也一样 ──

-- db/functions/guard_portal_account_separation.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q5,Tim):【一个门户账号永远不是员工、永远不持角色 —— 反过来也一样】。
--   一个触发器函数,挂在四张表上,按 TG_TABLE_NAME 分支:
--     supplier_portal_users  INSERT / 改 user_id:这个账号持着一条没撤销的角色 → PORTAL_ACCOUNT_HAS_ROLE;
--                            挂着一份员工档案(主账号或额外账号)→ PORTAL_ACCOUNT_IS_EMPLOYEE
--     user_roles             INSERT / 改 user_id / 把撤销撤回:这个账号是一个门户账号(有过一条链接,撤销了也算)→ PORTAL_ACCOUNT_NO_ROLES
--     employees              INSERT / 改 user_id:同上 → PORTAL_ACCOUNT_NO_EMPLOYEE
--     employee_accounts      INSERT / 改 user_id:同上 → PORTAL_ACCOUNT_NO_EMPLOYEE
--   【撤销了的门户账号也不许拿角色】一个撤销了的门户账号仍然是一个外部人的登录;给它一个角色 = 把一个外部人变成员工,
--     那必须是一个新账号,不是一次改授权。
-- 【SECURITY DEFINER】它读 supplier_portal_users / user_roles / employees,而做这些写的人(授角色的 admin、建档的人事)
--   不一定读得到它们(supplier_portal_users 的读是 module.suppliers.view)—— 调用者权限会读到零行、放行一次本该拒的写。
--   触发器函数不在 gate 的 B2 之内(返回 trigger)。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.guard_portal_account_separation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.user_id IS NULL THEN
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME = 'supplier_portal_users' THEN
        IF EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = NEW.user_id AND ur.revoked_at IS NULL) THEN
            RAISE EXCEPTION 'PORTAL_ACCOUNT_HAS_ROLE';
        END IF;
        IF EXISTS (SELECT 1 FROM employees e WHERE e.user_id = NEW.user_id)
           OR EXISTS (SELECT 1 FROM employee_accounts ea WHERE ea.user_id = NEW.user_id) THEN
            RAISE EXCEPTION 'PORTAL_ACCOUNT_IS_EMPLOYEE';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME = 'user_roles' THEN
        IF NEW.revoked_at IS NULL AND EXISTS (SELECT 1 FROM supplier_portal_users p WHERE p.user_id = NEW.user_id) THEN
            RAISE EXCEPTION 'PORTAL_ACCOUNT_NO_ROLES';
        END IF;
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users p WHERE p.user_id = NEW.user_id) THEN
        RAISE EXCEPTION 'PORTAL_ACCOUNT_NO_EMPLOYEE';
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 4 · 新表(镜像原样):门户链接 · 账号那一侧的待补的值(V38 · V40,一行,全空)──

-- db/tables/supplier_portal_users.sql
-- MES-9a(2026-10-19,MES-0 Q85 · Q87 · MES-9 Step 0 Q2 · Q5 · Q8 · Q20,Tim):【一个门户账号 = 一家供应商 + 它的一位联系人】。
--
-- 【它是什么】一个 auth.users 账号(与员工一样的登录),外加这一行。这一行在,那个账号的令牌就带 role = supplier_portal
--   (portal_access_token_hook 在每一次签发令牌时查这里),于是它在库里是一个【单独的 Postgres 角色】:
--   它够得着的只有按名字授给 supplier_portal 的东西(db/portal-grants-baseline.tsv,判词八),一样都不从 authenticated 继承。
-- 【一个账号只属于一家】user_id 唯一;同一个人替两家供应商做事 = 两个账号(Step 0 §2)。
--   一位联系人同时最多一个【没撤销的】门户账号(部分唯一索引);撤销之后可以再开一个(新账号、新链接,旧的留着)。
-- 【永远不是员工、永远不持角色】guard_portal_account_separation 在四张表上双向拒(Q5)。
-- 【撤销,不删】revoked_at / revoked_by / revoked_reason(portal_user_revoke:链接撤销 + 删会话;封禁由服务端动作经 auth.admin 做)。
--   应请求匿名化联系人时盖 anonymised_at(portal_contact_anonymise,Q20);账号 id 与记录都留着。
-- 【谁读】供应商页的门户账号那一块:module.suppliers.view(Q7)。Supabase Auth 的 hook 以 supabase_auth_admin 读(只读一条策略)。
--   门户会话自己【不直接读】这张表 —— 它只经 portal_* 函数,而那些函数从 auth.uid() 推出它是谁(没有任何供应商 id 是参数)。
-- 【谁写】只经 portal_user_create_link / portal_user_revoke / portal_contact_anonymise(SECURITY DEFINER,门 action.manage_portal_users)。
--   没有任何 INSERT / UPDATE / DELETE 策略;一次性证明的收尾以 service role 删它自己造的行。
-- 变更记录照常记(豁免仍是 8);它挂在供应商的审计记录下(trail_subject_members 'supplier' 第 7 支)。
--
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.supplier_portal_users (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid NOT NULL UNIQUE REFERENCES auth.users (id) ON DELETE RESTRICT,
    supplier_id     uuid NOT NULL REFERENCES public.suppliers (id) ON DELETE RESTRICT,
    contact_id      uuid NOT NULL REFERENCES public.counterparty_contacts (id) ON DELETE RESTRICT,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    revoked_at      timestamptz,
    revoked_by      uuid,
    revoked_reason  text,
    anonymised_at   timestamptz,
    anonymised_by   uuid,
    CONSTRAINT supplier_portal_users_revoke_reason
        CHECK (revoked_at IS NULL OR NULLIF(btrim(revoked_reason), '') IS NOT NULL),
    CONSTRAINT supplier_portal_users_anonymised_after_revoke
        CHECK (anonymised_at IS NULL OR revoked_at IS NOT NULL)
);

CREATE UNIQUE INDEX supplier_portal_users_one_live_per_contact
    ON public.supplier_portal_users (contact_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_supplier_portal_users_supplier ON public.supplier_portal_users (supplier_id);

COMMENT ON TABLE public.supplier_portal_users IS
    'MES-9a:一个门户账号 = 一家供应商 + 它的一位联系人(Q5)。这一行在,账号的令牌就带 role = supplier_portal(portal_access_token_hook),它在库里只够得着按名授给那个角色的东西(判词八,db/portal-grants-baseline.tsv)。永远不是员工、永远不持角色(guard_portal_account_separation,双向)。撤销不删(portal_user_revoke:撤销 + 删会话;封禁经 auth.admin);应请求匿名化联系人(portal_contact_anonymise)。读 module.suppliers.view;写只经三支 DEFINER 函数(action.manage_portal_users)。';

-- 链接两头的守卫:这个账号不持角色、不是员工(另三张表上挂着反方向那一半)
CREATE TRIGGER trg_supplier_portal_users_separation
    BEFORE INSERT OR UPDATE OF user_id ON public.supplier_portal_users
    FOR EACH ROW EXECUTE FUNCTION public.guard_portal_account_separation();

ALTER TABLE public.supplier_portal_users ENABLE ROW LEVEL SECURITY;
CREATE POLICY "supplier_portal_users select by permission" ON public.supplier_portal_users
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
-- Supabase Auth 的 hook(portal_access_token_hook,调用者权限)以 supabase_auth_admin 跑,它要读得到这一张表 —— 只读,只给它
CREATE POLICY "supplier_portal_users read by the auth hook" ON public.supplier_portal_users
    AS PERMISSIVE FOR SELECT TO supabase_auth_admin
    USING (true);
GRANT SELECT ON public.supplier_portal_users TO supabase_auth_admin;
REVOKE ALL ON public.supplier_portal_users FROM anon;

-- db/tables/account_settings.sql
-- MES-9a(2026-10-19,MES-9 Step 0 §9 · Q24 · Q26,Tim):【账号那一侧的待补的值 —— 单行】。
--   V38  initial_password_valid_days   一个当面交出去的初始密码,在第一次登录之前有效几天。
--        空 = Not yet set:/settings/accounts 与供应商页的门户账号那一块照直说「初始密码不会过期」。
--   V40  password_min_length           项目的密码最短长度(Supabase 的项目设置;今天是 Supabase 的默认 6)。Tim 在 Supabase 改了以后在这里记下那个数。
--   两个都是【第一个真实供应商账号之前】由 Tim 给(MES-9 Step 0 §15);引导为空,不猜。
--   ★ 今天两个都【不被执行】(docs/known-issues.md:MES9A-V38-NOT-ENFORCED · MES9A-V40-IS-A-RECORD)——
--     这里存的是 Tim 定的值,好让待补的值页面在它们还空着时说出来;执行那一半是登记在案的后续。
--   由 action.manage_permissions 经 set_account_setting 改;修改史在变更记录里。
--   RUNTIME CONFIG:Tim 设一次,线上就与本文件不同 —— 那是系统在正常工作。
--
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.account_settings (
    id                          boolean PRIMARY KEY DEFAULT true CHECK (id),
    initial_password_valid_days integer CHECK (initial_password_valid_days IS NULL OR initial_password_valid_days > 0),
    password_min_length         integer CHECK (password_min_length IS NULL OR password_min_length >= 6),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    updated_by                  uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.account_settings IS
    'MES-9a:账号那一侧的待补的值(单行)。V38 = initial_password_valid_days(初始密码在第一次登录之前有效几天);V40 = password_min_length(项目的密码最短长度,Supabase 设置 —— 这里记 Tim 定的数)。引导为空;今天两者都不被执行(known issues MES9A-V38-NOT-ENFORCED · MES9A-V40-IS-A-RECORD)。action.manage_permissions 经 set_account_setting 改。';

INSERT INTO public.account_settings (id) VALUES (true);

CREATE TRIGGER trg_account_settings_updated_at
    BEFORE UPDATE ON public.account_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.account_settings ENABLE ROW LEVEL SECURITY;
-- 读:管账号的人(/settings/accounts)与看供应商的人(供应商页的门户账号那一块要说初始密码会不会过期)。写只经函数。
CREATE POLICY "account_settings select by permission" ON public.account_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['action.manage_permissions'::text, 'module.suppliers.view'::text]));
GRANT SELECT ON public.account_settings TO authenticated;
REVOKE ALL ON public.account_settings FROM anon;

-- ── 5 · 既有三张表上的守卫触发器(与它们的镜像逐字同一句)──
CREATE TRIGGER trg_user_roles_not_portal_account
    BEFORE INSERT OR UPDATE OF user_id, revoked_at ON public.user_roles
    FOR EACH ROW EXECUTE FUNCTION public.guard_portal_account_separation();

CREATE TRIGGER trg_employees_not_portal_account
    BEFORE INSERT OR UPDATE OF user_id ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.guard_portal_account_separation();

CREATE TRIGGER trg_employee_accounts_not_portal_account
    BEFORE INSERT OR UPDATE OF user_id ON public.employee_accounts
    FOR EACH ROW EXECUTE FUNCTION public.guard_portal_account_separation();

-- ── 6 · 权限目录一行(与 db/tables/permissions.sql 逐字同一份)+ 它声明的查看码 ──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.manage_portal_users', 'action', 'Manage supplier portal accounts', '管理供应商门户账号', 'Give a supplier''s contact a sign-in to the supplier portal (an initial password handed over outside the system, which must be changed at first sign-in), revoke one at once, and anonymise the contact behind a revoked one on request. A portal account sees only its own supplier''s records and none of the company''s internal pages. Seeing the portal accounts on a supplier needs only Suppliers (view).', '给一家供应商的一位联系人开一个供应商门户的登录(初始密码在系统之外当面交,第一次登录必须换)、立刻撤销一个,以及应请求把一个已撤销账号背后的联系人匿名化。门户账号只看得见它自己那一家供应商的记录,看不见公司的任何内部页面。看一家供应商有哪些门户账号只要「供应商(查看)」。', 1280);
UPDATE public.permissions SET requires_view_any = ARRAY['module.suppliers.view'] WHERE code = 'action.manage_portal_users';

-- ── 7 · 授权(MES-0 Q87):action.manage_portal_users → admin · cco —— 本刀唯一的授权改动(两行)──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'action.manage_portal_users' FROM roles r WHERE r.code IN ('admin', 'cco')
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 8 · 新函数(镜像原样)──────────────

-- db/functions/portal_access_token_hook.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q2 · Q11,Tim):Supabase 的 custom access token hook —— 【一个门户账号的令牌带 role = supplier_portal】。
--   Supabase Auth 在【每一次】签发令牌(登录、刷新)时以 supabase_auth_admin 的身份调它,传入 {user_id, claims, authentication_method},
--   用它返回的 claims 签令牌;PostgREST 再按令牌里的 role 切换数据库角色(supplier_portal 由 authenticator 持有,迁移里授)。
--
-- 【员工的令牌一个字节都不变 —— 这是本函数的第一条义务】(委托书「Sign-in safety」)
--   · 不是门户账号 → 原样返回 event(claims 逐字不动);
--   · 函数里【任何】失败(user_id 不是 uuid、读不到表、权限没授上……)→ 同样原样返回 event —— 绝不抛:
--     一支抛错的 hook 让【每一个人】都登录不了、刷新不了(AUTH-BLAST-RADIUS 的形状)。
--     代价照直写:失败时一个门户账号拿到的是 role = authenticated 的令牌 —— 它于是是一个【没有角色的会话】
--     (门户账号不许持角色、不许是员工 —— guard_portal_account_separation),只够得着判词七的基线;
--     而每一支 portal_* 只授 supplier_portal,authenticated 调不到(42501),门户于是【看得见地停下】,不会悄悄变宽(Q11);
--     中间件看见一个门户账号拿着不是 supplier_portal 的令牌,会把它登出。
--   · 查表只有一次按唯一索引的查询(supplier_portal_users.user_id UNIQUE)。
-- 【撤销了的门户账号也拿 supplier_portal】撤销 = 链接撤销 + 封禁 + 删会话(portal_user_revoke),所以它本来就拿不到新令牌;
--   万一拿到了(封禁失败的那一瞬),它仍然被关在门户角色里,而门户函数按"已撤销"拒绝 —— 而不是被放成一个员工那一面的无角色会话。
-- 【调用者权限,不是 DEFINER】Supabase 的做法:EXECUTE 只授 supabase_auth_admin,它对 supplier_portal_users 有一条只读策略与 SELECT。
--   authenticated / anon / PUBLIC 都调不到(zzz_function_grants.sql)。
-- 【怎么关掉它 —— 一步】Supabase 项目设置 Authentication → Hooks → "Customize Access Token (JWT) Claims hook" 关掉,
--   或 Management API PATCH /v1/projects/<ref>/config/auth {"hook_custom_access_token_enabled": false}。见 docs/fresh-install-checklist.md。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_access_token_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_portal boolean := false;
BEGIN
    BEGIN
        SELECT true INTO v_portal
          FROM public.supplier_portal_users p
         WHERE p.user_id = (event ->> 'user_id')::uuid;
        IF v_portal IS TRUE AND jsonb_typeof(event -> 'claims') = 'object' THEN
            RETURN jsonb_set(event, '{claims,role}', to_jsonb('supplier_portal'::text));
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN event;
    END;
    RETURN event;
END;
$function$;

-- db/functions/portal_require_link.sql
-- MES-9a(2026-10-19,MES-0 Q85 · MES-9 Step 0 Q8 · Q11,Tim):【每一支门户函数的第一句】—— 这个会话是不是一个还有效的门户会话。
--   依次判,第一条不过就按名拒:
--     ① 数据库角色是 supplier_portal(PostgREST 按令牌切过来的那个;`role` 这个设置在 SECURITY DEFINER 里不变),
--        并且令牌自己的 role 声明也是它 → 否则 PORTAL_ROLE_REQUIRED。hook 被关掉时门户账号拿到的是 authenticated:
--        门户于是看得见地停下,而不是悄悄变宽(Q11)。(authenticated 本来就调不到任何一支 portal_*,这一条是第二道。)
--     ② auth.uid() 有一条门户链接 → 否则 PORTAL_NOT_A_PORTAL_ACCOUNT;
--     ③ 链接没有撤销、账号没有被封 → 否则 PORTAL_ACCESS_REVOKED(Q85:一个被封的号手里的令牌还能用到过期,所以每一次调用都问);
--     ④ 令牌的 session_id 还在 auth.sessions 里 → 否则 PORTAL_SESSION_ENDED(Q8:撤销时删掉它的会话 = 全局登出,下一次调用就拒)。
--   返回链接的 id。【没有任何参数】—— 供应商从来不是一个参数,只从 auth.uid() 推出来(Step 0 §3)。
--   EXECUTE 不授任何人:只由 portal_* 在它们自己的 DEFINER 体内调用。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_require_link()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_uid  uuid := auth.uid();
    v_sid  uuid;
    v_link uuid;
    v_rev  timestamptz;
BEGIN
    IF COALESCE(current_setting('role', true), '') <> 'supplier_portal'
       OR COALESCE(auth.jwt() ->> 'role', '') <> 'supplier_portal' THEN
        RAISE EXCEPTION 'PORTAL_ROLE_REQUIRED';
    END IF;
    SELECT p.id, p.revoked_at INTO v_link, v_rev FROM supplier_portal_users p WHERE p.user_id = v_uid;
    IF v_link IS NULL THEN
        RAISE EXCEPTION 'PORTAL_NOT_A_PORTAL_ACCOUNT';
    END IF;
    IF v_rev IS NOT NULL
       OR EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.banned_until IS NOT NULL AND u.banned_until > now()) THEN
        RAISE EXCEPTION 'PORTAL_ACCESS_REVOKED';
    END IF;
    BEGIN
        v_sid := NULLIF(auth.jwt() ->> 'session_id', '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        v_sid := NULL;
    END;
    IF v_sid IS NULL OR NOT EXISTS (SELECT 1 FROM auth.sessions s WHERE s.id = v_sid AND s.user_id = v_uid) THEN
        RAISE EXCEPTION 'PORTAL_SESSION_ENDED';
    END IF;
    RETURN v_link;
END;
$function$;

-- db/functions/portal_me.sql
-- MES-9a(2026-10-19,MES-9 Step 0 §2 · Q10,Tim):【门户外壳的"你是谁"】—— /portal 顶上那一行:哪一家供应商、哪一位联系人、登录用的邮箱。
--   先过 portal_require_link()(角色 · 链接 · 撤销 · 会话)。只说调用者自己那一家、自己那一位;没有任何参数。
--   一样都不多给:不给供应商的银行、条款、评分、状态史、别的联系人,不给任何员工的名字。
--   EXECUTE 只授 supplier_portal(zzz_function_grants.sql;门户可达面 = db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_me()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link uuid := portal_require_link();
    v_out  jsonb;
BEGIN
    SELECT jsonb_build_object(
               'supplier', jsonb_build_object('code', s.code, 'name', s.legal_name),
               'contact', jsonb_build_object('name', c.name, 'role', c.role),
               'account_email', u.email,
               'linked_at', p.created_at)
      INTO v_out
      FROM supplier_portal_users p
      JOIN suppliers s ON s.id = p.supplier_id
      JOIN counterparty_contacts c ON c.id = p.contact_id
      JOIN auth.users u ON u.id = p.user_id
     WHERE p.id = v_link;
    RETURN v_out;
END;
$function$;

-- db/functions/portal_export_my_data.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q20 · PDPA 待办 3,Tim):【一个门户账号导出系统里关于它自己的一切】—— 个人资料访问请求的那一条路。
--   一个门户账号证明"我是谁"的办法就是登录;登录了,它自己按这一个钮就拿得到(docs/pdpa.md 待办 3 对门户账号由此关闭)。
--   先过 portal_require_link()。内容:它的联系人那一行(名字、职能、邮箱、电话 —— 【员工写的内部备注 notes 不给】,那是员工对对方的
--   内部记录,Step 0 §4 的"internal notes"一栏)、它的门户链接(建立、撤销)、它的账号(登录邮箱、建立时刻、最近一次登录)、它属于哪一家供应商
--   (编号与名字)。9c 的证书提交来了以后,它们也进这一份。别的联系人、别的供应商、任何员工:一个字都没有。
--   EXECUTE 只授 supplier_portal。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_export_my_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link uuid := portal_require_link();
    v_out  jsonb;
BEGIN
    SELECT jsonb_build_object(
               'exported_at', now(),
               'supplier', jsonb_build_object('code', s.code, 'name', s.legal_name),
               'contact', jsonb_build_object('name', c.name, 'role', c.role, 'email', c.email, 'phone', c.phone,
                                             'created_at', c.created_at, 'updated_at', c.updated_at),
               'portal_account', jsonb_build_object('linked_at', p.created_at, 'revoked_at', p.revoked_at),
               'sign_in', jsonb_build_object('email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at))
      INTO v_out
      FROM supplier_portal_users p
      JOIN suppliers s ON s.id = p.supplier_id
      JOIN counterparty_contacts c ON c.id = p.contact_id
      JOIN auth.users u ON u.id = p.user_id
     WHERE p.id = v_link;
    RETURN v_out;
END;
$function$;

-- db/functions/portal_user_create_link.sql
-- MES-9a(2026-10-19,MES-0 Q87 · MES-9 Step 0 Q5 · Q6 · Q7,Tim):【把一个刚建出来的登录账号挂到一家供应商的一位联系人上】。
--   供应商页上「给这位联系人一个门户登录」的第二步:第一步是服务端动作以 service role 建出 auth 账号(初始密码当面交、首次登录必须换,
--   与员工账号同一条路 —— 没有邮件、没有邀请表,Q6);这一步写链接。门 action.manage_portal_users(admin · cco,Q87)。
--   判据(都在库里,屏幕不做第二份):
--     供应商在、没删 → 否则 PORTAL_SUPPLIER_NOT_FOUND;
--     联系人属于这家、没删、没匿名化 → 否则 PORTAL_CONTACT_NOT_OF_SUPPLIER;联系人有邮箱 → 否则 PORTAL_CONTACT_NO_EMAIL(Q5:登录用的就是它的邮箱);
--     账号在、它的邮箱就是这位联系人的邮箱(不分大小写)→ 否则 PORTAL_EMAIL_NOT_CONTACT;
--     这位联系人没有一个没撤销的门户账号 → 否则 PORTAL_CONTACT_ALREADY_LINKED;这个账号没有挂过 → 否则 PORTAL_ACCOUNT_ALREADY_LINKED;
--     账号不持角色、不是员工 → guard_portal_account_separation 按名拒(PORTAL_ACCOUNT_HAS_ROLE / PORTAL_ACCOUNT_IS_EMPLOYEE)。
--   一个账号 = 一家供应商 + 它的一位联系人;同一个人替两家供应商做事 = 两个账号(Step 0 §2)。返回链接的 id。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_user_create_link(p_user_id uuid, p_supplier_id uuid, p_contact_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_email text;
    v_id    uuid;
BEGIN
    PERFORM require_permission('action.manage_portal_users');
    IF NOT EXISTS (SELECT 1 FROM suppliers s WHERE s.id = p_supplier_id AND s.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'PORTAL_SUPPLIER_NOT_FOUND';
    END IF;
    SELECT c.email INTO v_email FROM counterparty_contacts c
     WHERE c.id = p_contact_id AND c.supplier_id = p_supplier_id AND c.deleted_at IS NULL AND c.anonymised_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PORTAL_CONTACT_NOT_OF_SUPPLIER';
    END IF;
    IF NULLIF(btrim(v_email), '') IS NULL THEN
        RAISE EXCEPTION 'PORTAL_CONTACT_NO_EMAIL';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id AND lower(u.email) = lower(btrim(v_email))) THEN
        RAISE EXCEPTION 'PORTAL_EMAIL_NOT_CONTACT';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users p WHERE p.contact_id = p_contact_id AND p.revoked_at IS NULL) THEN
        RAISE EXCEPTION 'PORTAL_CONTACT_ALREADY_LINKED';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users p WHERE p.user_id = p_user_id) THEN
        RAISE EXCEPTION 'PORTAL_ACCOUNT_ALREADY_LINKED';
    END IF;
    INSERT INTO supplier_portal_users (user_id, supplier_id, contact_id, created_by)
    VALUES (p_user_id, p_supplier_id, p_contact_id, auth.uid())
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/portal_user_revoke.sql
-- MES-9a(2026-10-19,MES-0 Q85 · MES-9 Step 0 Q8 · Q20,Tim):【撤销一个门户账号 —— 下一次调用就拒】。
--   撤销 = ① 链接记下撤销(时刻、谁、理由 —— 理由必填,PORTAL_REVOKE_REASON_REQUIRED)② 删掉这个账号在 auth.sessions 里的每一个会话
--   (= 全局登出:刷新令牌随会话级联删掉;已经签出去的访问令牌在过期前仍验得过签,而每一支门户函数都问"会话还在吗"与"撤销了吗",
--   所以它的下一次调用就是 PORTAL_ACCESS_REVOKED)③ 封禁由服务端动作接着经 auth.admin 做(换不了新令牌)—— auth 的封禁不在这里写,
--   与员工账号的停用同一条路(app/settings/accounts/accountActions.ts)。账号与它的记录都留着(Q20:撤销 + 封禁,不删)。
--   门 action.manage_portal_users。已经撤销的再撤 → PORTAL_ALREADY_REVOKED;链接不在 → PORTAL_LINK_NOT_FOUND。
--   返回 {sessions_ended}。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_user_revoke(p_link_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid;
    v_rev  timestamptz;
    v_n    integer;
BEGIN
    PERFORM require_permission('action.manage_portal_users');
    SELECT p.user_id, p.revoked_at INTO v_user, v_rev FROM supplier_portal_users p WHERE p.id = p_link_id FOR UPDATE;
    IF v_user IS NULL THEN
        RAISE EXCEPTION 'PORTAL_LINK_NOT_FOUND';
    END IF;
    IF v_rev IS NOT NULL THEN
        RAISE EXCEPTION 'PORTAL_ALREADY_REVOKED';
    END IF;
    IF NULLIF(btrim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'PORTAL_REVOKE_REASON_REQUIRED';
    END IF;
    UPDATE supplier_portal_users
       SET revoked_at = now(), revoked_by = auth.uid(), revoked_reason = btrim(p_reason)
     WHERE id = p_link_id;
    DELETE FROM auth.sessions s WHERE s.user_id = v_user;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('sessions_ended', v_n, 'user_id', v_user);
END;
$function$;

-- db/functions/portal_contact_anonymise.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q20,Tim):【应请求,把一个已撤销的门户账号背后那位联系人匿名化】。
--   名字换成「Anonymised」,职能、邮箱、电话、备注清空,不再是主联系人,软删,并盖 anonymised_at;链接盖 anonymised_at / anonymised_by。
--   变更记录里关于这位联系人那一行的每一条(新增、每一次修改 —— 包括本函数这一句自己写下的那一条,它的 old 里装着匿名化之前的字)
--   只把 change_log_redactable_columns('counterparty_contacts') 列出的几列涂成 null,盖 redacted_at(anonymise_employee 的同一个做法;
--   change_log 的守卫逐行核对涂抹的形状)。【账号 id 留着】:审计记录里那个账号做过的事照旧挂在它身上(Q20)。
--   登录邮箱(auth.users.email)由服务端动作接着经 auth.admin 换掉 —— auth 架构不由本函数写。
--   门 action.manage_portal_users。没撤销 → PORTAL_ANONYMISE_NEEDS_REVOKE;已经匿名化 → PORTAL_ALREADY_ANONYMISED;链接不在 → PORTAL_LINK_NOT_FOUND。
--   返回 {contact_id, log_rows_redacted}。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_contact_anonymise(p_link_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    l   supplier_portal_users%ROWTYPE;
    v_n integer;
BEGIN
    PERFORM require_permission('action.manage_portal_users');
    SELECT * INTO l FROM supplier_portal_users p WHERE p.id = p_link_id FOR UPDATE;
    IF l.id IS NULL THEN
        RAISE EXCEPTION 'PORTAL_LINK_NOT_FOUND';
    END IF;
    IF l.revoked_at IS NULL THEN
        RAISE EXCEPTION 'PORTAL_ANONYMISE_NEEDS_REVOKE';
    END IF;
    IF l.anonymised_at IS NOT NULL THEN
        RAISE EXCEPTION 'PORTAL_ALREADY_ANONYMISED';
    END IF;
    UPDATE counterparty_contacts
       SET name = 'Anonymised', role = NULL, email = NULL, phone = NULL, notes = NULL, is_primary = false,
           deleted_at = COALESCE(deleted_at, now()), anonymised_at = now(), updated_by = auth.uid()
     WHERE id = l.contact_id;
    UPDATE supplier_portal_users SET anonymised_at = now(), anonymised_by = auth.uid() WHERE id = l.id;
    -- 【必须在上面那句之后】它自己就被 change_log_capture 记了一行,而那一行的 old 里装着匿名化之前的字
    UPDATE change_log c
       SET old = change_log_null_keys(c.old, change_log_redactable_columns(c.table_name)),
           new = change_log_null_keys(c.new, change_log_redactable_columns(c.table_name)),
           redacted_at = clock_timestamp()
     WHERE c.redacted_at IS NULL
       AND c.table_name = 'counterparty_contacts' AND c.row_key ->> 'id' = l.contact_id::text;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('contact_id', l.contact_id, 'log_rows_redacted', v_n);
END;
$function$;

-- db/functions/portal_actor_labels.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q21,Tim):【一个门户账号做的事,"谁做的"那一格写「Supplier portal — <供应商名>」】——
--   页面上的 ActorName(app/components/ActorName.tsx)在一个账号没有员工档案时,先问这里它是不是一个门户账号;
--   审计记录那一侧由 trail_actor 直接认(同一句话,两个读法)。
--   给一串账号 id,回其中【是门户账号的那几个】与它的供应商名。供应商名是一个显示标签(AGENTS.md 常设裁定 3:标签跟着单据走,
--   看得见那一行的人就看得见是谁做的);不回联系人的名字、邮箱或任何别的东西。不是门户账号的 id 一行都不回。
--   判据:调用者是一个登录了的会话(auth.uid())。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_actor_labels(p_user_ids uuid[])
 RETURNS TABLE(user_id uuid, supplier_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|session';
    END IF;
    RETURN QUERY
        SELECT p.user_id, s.legal_name
          FROM supplier_portal_users p JOIN suppliers s ON s.id = p.supplier_id
         WHERE p.user_id = ANY (p_user_ids);
END;
$function$;

-- db/functions/set_account_setting.sql
-- MES-9a(2026-10-19,MES-9 Step 0 §9 · Q24 · Q26,Tim):【给 / 清 V38 与 V40】—— 两个账号那一侧的待补的值,一次一个。
--   V38 initial_password_valid_days  一个当面交出去的初始密码,在第一次登录之前有效几天(正整数)。
--   V40 password_min_length          项目的密码最短长度(Supabase 的项目设置,今天是 6)—— Tim 在 Supabase 改了之后,在这里记下他定的那个数(≥ 6)。
--   门 action.manage_permissions(建账号、管账号的那个人)。键不认识 → ACCOUNT_SETTING_UNKNOWN|<键>;值不合形状 → ACCOUNT_SETTING_INVALID|<键>
--   (只是形状,不是一个替人挑的数)。p_value 为空 = 清掉。返回改后的那一行。
--   ★ 两个值【今天都不被执行】:V38 给了之后,屏幕照直说它是多少天、而系统还不按它拒绝登录(MES9A-V38-NOT-ENFORCED);
--     V40 是 Supabase 那一侧的设置,这里记的是 Tim 定的数,不改 Supabase(MES9A-V40-IS-A-RECORD)。见 docs/known-issues.md。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.set_account_setting(p_key text, p_value integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r account_settings%ROWTYPE;
BEGIN
    PERFORM require_permission('action.manage_permissions');
    IF p_key = 'initial_password_valid_days' THEN
        IF p_value IS NOT NULL AND p_value <= 0 THEN
            RAISE EXCEPTION 'ACCOUNT_SETTING_INVALID|%', p_key;
        END IF;
        UPDATE account_settings SET initial_password_valid_days = p_value, updated_by = auth.uid() WHERE id RETURNING * INTO r;
    ELSIF p_key = 'password_min_length' THEN
        IF p_value IS NOT NULL AND p_value < 6 THEN
            RAISE EXCEPTION 'ACCOUNT_SETTING_INVALID|%', p_key;
        END IF;
        UPDATE account_settings SET password_min_length = p_value, updated_by = auth.uid() WHERE id RETURNING * INTO r;
    ELSE
        RAISE EXCEPTION 'ACCOUNT_SETTING_UNKNOWN|%', COALESCE(p_key, '');
    END IF;
    RETURN to_jsonb(r);
END;
$function$;

-- ── 9 · 换掉的函数(镜像原样,同签名):涂抹名单 · 谁做的 · 供应商的审计记录 ──

-- db/functions/change_log_redactable_columns.sql
-- HISTORY-1:匿名化时 change_log 里【允许被涂成 null】的列 —— 按源表。
-- 名单与 anonymise_employee 清掉的列【逐字同一份】(外加 greeting_name,Tim 的 Q9);
-- 两边任何一边加列,另一边要在同一个提交里跟上 —— fixture 234 的涂抹那一臂钉着这份对应。
-- ★ U1-A(Tim 的 UNBLOCK-1 Q11,2026-10-05):加四张表 —— 调薪申请、工资行、请假单、医疗报销上【人写的字】。
--   金额不在名单里(擦文字,留金额:金额是有法定保存期的账,而人一匿名化,它们就只属于"一位前员工")。
--   anonymise_employee 在基表上擦的正是这几列(不许为空的那几列写成 'ANONYMISED',记录里一律涂成 null);fixture 247 的 AN 臂钉着这份对应。
CREATE OR REPLACE FUNCTION public.change_log_redactable_columns(p_table text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_table
        WHEN 'employees' THEN ARRAY[
            'legal_name', 'preferred_name', 'first_name', 'last_name', 'greeting_name',
            'identity_no', 'work_email', 'work_phone', 'work_pass_no', 'work_pass_type',
            'work_pass_issue_date', 'work_pass_expiry_date', 'residency_status',
            'monthly_salary', 'notes', 'separation_notes', 'position_id', 'user_id']
        WHEN 'employment_history' THEN ARRAY['old_monthly_salary', 'new_monthly_salary', 'notes']
        -- U1-A(UNBLOCK-1 Q11):四张表上【人写的字】—— 理由、说明、备注、单号;金额一个都不在名单里(Q11:擦文字,留金额)
        WHEN 'salary_change_requests' THEN ARRAY['reason', 'decision_notes', 'withdraw_reason']
        WHEN 'payroll_lines' THEN ARRAY['notes']
        WHEN 'leave_requests' THEN ARRAY['reason', 'certificate_ref', 'decision_notes', 'exception_reason']
        WHEN 'medical_claims' THEN ARRAY['description', 'receipt_ref', 'decision_notes']
        -- MES-9a(MES-9 Step 0 Q20):一位应请求匿名化的联系人(portal_contact_anonymise)—— 名字、职能、邮箱、电话、备注
        WHEN 'counterparty_contacts' THEN ARRAY['name', 'role', 'email', 'phone', 'notes']
        ELSE ARRAY[]::text[]
    END;
$function$;

-- db/functions/trail_actor.sql
-- AUDIT-TRAIL-1a(Tim 的 Q14 · Q17 · Q18):"谁做的" —— 一份答法,两个读法共用。返回 {"state": …, "name": …}:
--   person     有一个人:称呼名,没有就用法定名(Q14;与 ActorName 同一个取法)。停用的账号照样印名字,不加任何字(Q17)。
--   anonymised 那个人已经被匿名化 —— 名字被抹掉是设计,界面说 "A former employee"。
--   system     没有登录会话的写:迁移、服务任务、fixture(Q17 · Q18,一律 "System (automatic)")。
--   removed    记下的是一个账号,而账号与人都已经不在了(Q17,"Removed account")。
--   unlinked   账号还在,但写入那一刻它不属于任何人(只有测试账号会这样)。
--   unknown    "记录开始之前"的那一段,当时那张表没有记人(p_kind = 'prelog' 且没有账号)—— 界面说 "Not recorded",不猜。
-- p_kind:change_log.actor_kind('user' / 'no_session'),或 'prelog'(从生命周期戳拼回来的行:只有账号,人按今天的链接认)。
-- 人名取自 employees(已被硬删的,取 change_log 里它最后一份影像)。【属主身份】EXECUTE 已从 authenticated 收回。
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29 的折入 1,推翻 AT-1a 决定 1):
--   restricted 在系统别的页面上看到"受限"的读者,在审计记录里也看到 Restricted —— 与 ActorName 同一条规矩
--              (app/components/ActorName.tsx):不持 module.hr.view 的读者只认得出【他自己】;别人一律受限,
--              包括已匿名化的人与没有挂人的账号(那两种在 ActorName 里同样画成"受限")。
--              System (automatic)、Removed account、Not recorded 不是人名,照常说。
-- MES-9a(2026-10-19,MES-9 Step 0 Q21,Tim):
--   portal     账号不属于任何人,而它是一个【供应商门户账号】—— 界面说「Supplier portal — <供应商名>」。供应商名是一个显示标签
--              (常设裁定 3),所以它不跟着 module.hr.view 变成 Restricted —— 看得见那一行的人就看得见是哪一家的门户做的。
--   两个读法(每一页的 record_trail · /settings/change-history 的 change_log_rows)与引用值里的人(trail_ref_label)
--   都经过这里,所以一处改,处处同一个答案。
CREATE OR REPLACE FUNCTION public.trail_actor(p_kind text, p_account uuid, p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp  jsonb;
    v_id   uuid := p_employee;
    v_hide boolean := NOT has_permission('module.hr.view');
BEGIN
    IF p_kind = 'no_session' THEN
        RETURN jsonb_build_object('state', 'system');
    END IF;
    IF v_id IS NULL AND p_kind = 'prelog' AND p_account IS NOT NULL THEN
        v_id := account_person(p_account);
    END IF;
    IF v_id IS NULL AND p_account IS NOT NULL THEN
        SELECT jsonb_build_object('state', 'portal', 'name', s.legal_name) INTO v_emp
          FROM supplier_portal_users p JOIN suppliers s ON s.id = p.supplier_id
         WHERE p.user_id = p_account;
        IF v_emp IS NOT NULL THEN
            RETURN v_emp;
        END IF;
    END IF;
    IF v_id IS NULL THEN
        IF p_account IS NULL THEN
            RETURN jsonb_build_object('state', CASE WHEN p_kind = 'prelog' THEN 'unknown' ELSE 'removed' END);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_account) THEN
            RETURN jsonb_build_object('state', 'removed');
        END IF;
        RETURN jsonb_build_object('state', CASE WHEN v_hide THEN 'restricted' ELSE 'unlinked' END);
    END IF;
    IF v_hide AND v_id IS DISTINCT FROM current_user_employee() THEN
        RETURN jsonb_build_object('state', 'restricted');
    END IF;
    SELECT to_jsonb(e) INTO v_emp FROM employees e WHERE e.id = v_id;
    IF v_emp IS NULL THEN
        SELECT CASE WHEN c.op = 'DELETE' THEN c.old ELSE c.new END INTO v_emp
          FROM change_log c
         WHERE c.table_name = 'employees' AND c.row_key = jsonb_build_object('id', v_id) AND c.op IN ('INSERT', 'DELETE')
         ORDER BY c.seq DESC LIMIT 1;
    END IF;
    IF v_emp IS NULL THEN
        RETURN jsonb_build_object('state', 'removed');
    END IF;
    IF v_emp ->> 'anonymised_at' IS NOT NULL
       OR COALESCE(NULLIF(v_emp ->> 'preferred_name', ''), NULLIF(v_emp ->> 'legal_name', '')) IS NULL THEN
        RETURN jsonb_build_object('state', 'anonymised');
    END IF;
    RETURN jsonb_build_object('state', 'person',
        'name', COALESCE(NULLIF(v_emp ->> 'preferred_name', ''), v_emp ->> 'legal_name'));
END;
$function$;

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
        ('expense_claim',    2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('expense_claim',    3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        ('my_expense_claim', 1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('my_expense_claim', 2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        ('my_expense_claim', 3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
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
        -- ── MES-8b-1(2026-10-17,MES-8 Step 0 Q22):一份合规包 —— 它的签发档住在这里。──
        ('compliance_pack',     1, 'compliance_pack_issues',           'compliance_packs',             'pack_id',             '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 10 · 新视图与换掉的视图(镜像原样)──

-- db/views/supplier_portal_accounts.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q7 · Q24,Tim):【一家供应商的门户账号 —— 供应商页上那一块读它】。
--   每一条门户链接一行:挂在哪一位联系人上(今天的名字与邮箱)、登录用的邮箱、开的时刻与人、撤销(时刻 · 人 · 理由)、匿名化、
--   最近一次登录、【还没换掉初始密码】(user_metadata.must_change_password —— 中间件按它把人扣在 /set-password)、是否被封。
--   【属主视图】它要读 auth.users(登录邮箱、最近登录、封禁、那一个标记),而 auth 不在 PostgREST 暴露的架构里;
--   谓词写在视图体里:module.suppliers.view(Q7:看那一块的码就是供应商页的门)。与 user_directory 同一个做法。
--   没有任何密码、令牌、会话的东西出来。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.

CREATE VIEW public.supplier_portal_accounts WITH (security_invoker = off) AS
 SELECT p.id,
    p.supplier_id,
    p.user_id,
    p.contact_id,
    c.name AS contact_name,
    c.email AS contact_email,
    u.email::text AS account_email,
    p.created_at,
    p.created_by,
    p.revoked_at,
    p.revoked_by,
    p.revoked_reason,
    p.anonymised_at,
    u.last_sign_in_at,
    COALESCE((u.raw_user_meta_data ->> 'must_change_password'::text) = 'true'::text, false) AS must_change_password,
    (u.banned_until IS NOT NULL AND u.banned_until > now()) AS banned
   FROM supplier_portal_users p
     JOIN counterparty_contacts c ON c.id = p.contact_id
     LEFT JOIN auth.users u ON u.id = p.user_id
  WHERE has_permission('module.suppliers.view'::text);

COMMENT ON VIEW public.supplier_portal_accounts IS
    'MES-9a:一家供应商的门户账号(供应商页那一块)。属主视图(读 auth.users 的登录邮箱、最近登录、封禁与 must_change_password),谓词 module.suppliers.view 写在视图体里。不出任何密码、令牌或会话。';

REVOKE ALL ON public.supplier_portal_accounts FROM authenticated, anon;
GRANT SELECT ON public.supplier_portal_accounts TO authenticated;

-- db/views/pending_values.sql
-- MES-1(2026-10-06,MES-0 §5 · Q92 · Q93;MES-1 Step 0 Q1 · Q2,Tim):【还没给的标准值】—— /settings/pending-values 读它。
--   一支一个值(像 operations_now 那样),每一支带着它自己的权限码;读者只看得到他持码的那几支(末尾的 WHERE)。
--   每一行是一件具体还空着的事:哪一个值(value_code,对应 docs/mes-pending-values.md 里那一行)、空在哪一条记录上、去哪儿填。
--   给了值,那一行就自己消失(这张视图不存任何东西)。
-- 【MES-1 播两支】
--   V5  网关的心跳间隔 —— 每一台没停用、间隔为空的网关一行。由集成商在网关调试时给(MES-0 §5.1 V5)。
--   V6  传输异常的工作时间 —— 读班次的起止时刻(shifts.starts_at / ends_at,为空是设计如此:没人说过几点到几点)。
--       每一个启用、而起止为空的班次一行。由 Tim 给(V6)。
-- 【MES-2 加两支】(2026-10-06,MES-2 Step 0 Q12 · Q30,Tim)
--   V8   校准到期前多少天开始提醒 —— 一个值,ingest_settings.calibration_lead_days 为空时一行(去处:/operation/calibration)。
--        由校准机构 / 仪器厂商给,仪器安装时(MES-0 §5.1)。没给:到期前的提醒不上牌,过期照样上牌。
--   V33  每一台【在用的】仪器(秤 · 地磅 · 电表 · 在线仪表,interface_status 不是 reserved,没停用)的量程 —— 量程为空的每台一行
--        (去处:它的设备页)。由仪器厂商给(规格 §8.2)。没给:确认读数时不判量程(WEIGHING_ABOVE_CAPACITY 只在给了时拒)。
-- 【MES-3a 加五支】(2026-10-06,MES-0 §5.1 V2 · V3 · V4 · V29;MES-3a Step 0 Q21 · Q31,Tim)
--   V2   一张执照对一类 NEA 废物的库存上限 —— 今天在效的那张执照 × 每一个启用的类别,没有 licence_storage_limits 行的一行
--        (去处:/purchasing/licences;门 module.suppliers.view)。由 NEA 执照条件给。类别列表是空的时它也是空的(V29 先来)。
--   V29  NEA 废物类别 —— 类别列表里一个启用的都没有时一行;有了之后,每一种没删、种类吃得下状态轴(电池料)而没有类别的物料一行
--        (去处:/settings/dictionaries 或那个物料;门 module.materials.view)。由 NEA 执照给。
--   V3   每一个启用的安全状态的滞留提醒天数 —— dwell_warning_days 为空的每个一行(去处:/settings/dictionaries;门 module.materials.view)。
--        由 Tim 与 WSH 负责人给,或执照的贮存条件。
--   V4   每一个启用的安全状态要不要隔离 —— requires_quarantine 为空的每个一行(同上)。引导只定了两个(鼓包或漏液 = 要,已放电 = 不要)。
--   V34  隔离库位 —— 有任何一个状态要隔离,而一个在用的隔离库位都没有时一行(去处:/inventory/locations;门 module.inventory.view)。
--        没有它,鼓包或漏液的料收不进来(QUARANTINE_LOCATION_REQUIRED)。由 Tim / 仓库在第一批这样的料到之前给。
-- 【MES-3b 加三支】(2026-10-07,MES-0 §5.1 V30 · V31;MES-3b Step 0 Q29 · V35,Tim)
--   V30  每一个启用的危险品 UN 编号的包装标记文字、包装说明、标签尺寸 —— 三样里有任何一样为空的每个编号一行
--        (去处:/settings/dictionaries;门 module.materials.view)。由有 DG 资质的货代在第一次出口之前给。
--   V31  每一种没删的电池料(种类吃得下状态轴)的 HS 编码 —— 为空的每种一行(去处:那个物料;门 module.materials.view)。
--        由报关行在第一次出口之前给。
--   V35  每一种没删的电池料的危险品 UN 编号 —— 没选的每种一行(同上)。由货代与 Tim 在第一次出口或第一次危险品发货之前给。
--        没给:标签与发货单上提示"没给",不拒(Q15)。
-- 【MES-4a 加两支、改一支】(2026-10-07,MES-0 §5.1 V1 · V7;MES-4a Step 0 Q35,Tim)
--   V1   每一道启用的【转化型】工序的物料平衡容差(投入的百分比)—— balance_tolerance_pct 为空的每道一行(去处:那道工序的页面;
--        门 module.processing.view)。由 Tim 与 cto 在每一段调试结束时给。没给:任何不为零的余数都要书面说明才能结平(Q46)。
--        状态改变型(放电)不列 —— 它投入恒等于产出,没有容差可言。
--   V36  每一个启用的、声明了【有范围】(has_range)而上下限都空着的参数 —— 一个字段一行(去处:那道工序的页面)。由设备厂商或
--        工艺工程师在那一段调试时给。没给:那个字段的值照记,不判越界。引导的字段一个都没声明有范围,所以今天是零行。
--   V6   【改了去处,一支答两个值】班次的起止时刻 —— MES-1 的 V6(传输异常的工作时间)与 MES-0 的 V7(加工单的班次时刻)读的是
--        同一组列(shifts.starts_at / ends_at),一支一行就够,两行说的会是同一件事。去处从 /operation/handovers(那一页只读班次,
--        改不了时刻)搬到 /settings/dictionaries(MES-4a 给班次加了一种"时刻"字段)。
-- 【MES-4b 加两支】(2026-10-07,MES-0 §5.1 V10 · V11;MES-4b Step 0 Q29,Tim)
--   V10  每一道启用的、勾了「Electrolyte evaporates in this step」而电解液份额为空的工序 —— 一道一行(去处:那道工序的页面;
--        门 module.processing.view)。由电芯供应商的规格书 / 工艺工程师在第一批极片分离之前给。引导一道都没勾,所以今天是零行。
--        没给:那一段的电解液挥发只能量出来,算不出来(ELECTROLYTE_SHARE_NOT_SET)。
--   V11  每一条启用的交叉污染流的警戒线(contamination_streams.warning_pct)—— 为空的每条一行(去处:/settings/dictionaries;
--        门 module.processing.view)。由 Tim / 第一份黑粉承购合同的规格在第一份承购合同之前给。没给:抽检照记,判不了超没超(NULL)。
-- 【MES-5a-1 加一支】(2026-10-08,MES-0 §5.1 V9;MES-5a Step 0 Q8 · Q32,Tim)
--   V9   放电通过电压(materials.discharge_pass_voltage_v,按物料 —— 模组的终止电压取决于串联节数)。【只在这种物料的一批已经有了
--        放电结果之后才列】,免得页面一下子被每一种装电芯的物料填满(去处:物料编辑页;门 module.materials.view)。由 Bosch 文档 /
--        模组规格书在放电调试时给。没给:结果照记,判定照收,那一格是"判不了"(contradicts_pass_voltage 为 NULL)。
-- 【MES-5a-2 加一支】(2026-10-08,MES-0 §5.1 V25;MES-5a Step 0 Q25 · Q32,Tim)
--   V25  共用池的电怎么摊(electricity_settings.shared_pool_rule)—— 有一台没停用、没挂机器的电表(共用池),而规则为空时一行
--        (去处:/finance/electricity;门 module.finance.view)。由 Tim 在电表接上之后的第一张电费单时给。没给:不计量的电与
--        共用池量到的电在每一次分摊里都留在间接费用 6200。今天线上一台电表都没有,所以是零行。
-- 【MES-6a-1 加两支】(2026-10-09,MES-0 §5.1 V14 · V16;MES-6a Step 0 Q14 · Q22 · Q42,Tim)
--   V16  没有合同天数的样品留多少天(quality_settings.internal_retention_days)—— 为空、而且有一份没处置、留样日 Not yet set 的样品时一行
--        (去处:/quality/samples 的设定;门 module.quality.view)。由 Tim / 质量在第一份要留的样品时给。没给:那样的样品没有留样日,不进提醒。
--        只有一份没处置的 not_set 样品时才列 —— V9 的先例:没人能动手的行不列。
--   V14  仲裁费怎么分(contract_settlement_terms.arbitration_fee_rule,只卖方合同有)—— 每一份【有过一件开着或已结案的争议】(经那件争议的
--        销售单的合同副本认合同)、而它的结算口径里规则为空的合同一行(去处:那份合同;门 module.customers.view —— 条款自己的读码)。
--        由对手方合同在签约时给。没给:争议照立,仲裁费照记,对手方那一份算不出来(NULL)。
--   (V15 没有支:F / Cl 的惩罚阈值是逐份合同的条款,声明了 per_element 却没填时结算按名拒 PENALTY_ELEMENTS_NOT_FILED;V17 归 MES-6b。)
-- 【MES-6b-1 加一支】(2026-10-15,MES-0 §5.1 V17;MES-6a Step 0 Q5;MES-6b Step 0 Q37,Tim)
--   V17  水分与粒径(以及任何一个化验指标)的验收限,逐份卖方合同 —— 每一份没删的卖方合同,【至少挂了一张销售单】、而它的结算口径里
--        quality_limit_basis 为空(或还没有结算口径)的一行(去处:那份合同;门 module.customers.view —— 条款自己的读码)。由 Tim / 那份承购合同给。
--        V9 的先例:还没有一张销售单挂上来的合同不列(没人能对它动手的行不列;从此新生效的卖方合同都必须先声明,见 contract_activation_missing)。
--        没给:那张单上的预留与化验不判质量验收限(judge_quality_limits 只认 per_parameter),不开不合格报告。
-- 【MES-7a-2 加一支】(2026-10-16,MES-0 §5.1 V21;MES-7a Step 0 Q17,Tim)
--   V21  备件的最低库存(materials.safety_stock_qty,按备件物料 —— 已经在驱动 safety_stock_below 那条提醒)。【只在这种备件已经收过至少一批
--        时才列】—— V9 的先例:一种还没收过货的备件,没人能对它动手。给它的人:cto,或设备供应商在验收时给的推荐备件清单。
--        没给:那种备件低于多少都不提醒(safety_stock_below 只认填了的物料)。
-- 【MES-7b-1 加一支】(2026-10-16,MES-0 §5.1 V19;MES-7b Step 0 Q10 · Q11 · Q20,Tim)
--   V19  NEA 书面报告的期限(工作日数,safety_settings.nea_report_working_days)—— 【空着,或者还没对着执照确认】时一行(去处:/safety/incidents
--        的设定面板;门 module.safety.view)。Q11:引导存 2、未确认(出处是仓库里那条义务的记录),所以这一行从第一天起就在,直到有人
--        对着 NEA 执照确认。没给:期限算不出来;给了没确认:期限照算,标"未确认"。
-- 【MES-7b-2 加两支】(2026-10-16,MES-0 §5.1 V18 · V20;MES-7b Step 0 Q13 · Q16 · Q20,Tim)—— 两支都是 module.safety.view,
--   字典是空的时各自【一行】(V29 的先例:没有东西可补的时候,也说出"还没有")。
--   V18  巡检清单的频率(天)与检查项 —— 一张启用的清单都没有时一行(去处:/safety/inspections);有了之后,每一张启用的、频率空着的清单一行
--        (去处:那张清单)。由安全工程公司 / WSH 主任给。
--   V20  每一个监测参数的排放限值 —— 参数字典一行都没有时一行(去处:/settings/dictionaries);有了之后,每一个启用的、没有限值的参数一行。
--        由 NEA 执照给。没有限值的参数照样记得进结果,读作"不判定"。
-- 【MES-8a 加两支】(2026-10-16,MES-0 §5.1 V23 · V24;MES-8 Step 0 Q4 · Q5 · Q27,Tim)—— 两支都是 module.suppliers.view,去处都是 /suppliers/scorecards。
--   V23  供应商评分的权重、等级线与评审周期 —— supplier_score_settings 那一行里三样有一样空着就一行(引导三样全空,所以从第一天起就有这一行)。
--        由 Tim 与 cco 给。没给:评审照记,读"Not graded — V23 not set";周期没给 → supplier_review_due 一行都不出。
--   V24  每一个等级的预付上限 % 与抽样级别 —— 有了等级线之后,每一个两样里缺一样的等级一行(没有等级线就没有等级,V23 先来)。由 Tim 与 cco 给。
-- 【MES-9a 加两支】(2026-10-19,MES-9 Step 0 §9 · Q24 · Q26,Tim)—— 两支都是 action.manage_permissions,去处都是 /settings/accounts;
--   两支都是从第一天起就一行(account_settings 一行、全空)。
--   V38  初始密码在第一次登录之前有效几天 —— 没给:/settings/accounts 与供应商页的门户账号那一块照直说「初始密码不会过期」。
--   V40  项目的密码最短长度(Supabase 的设置,今天 6)—— Tim 在 Supabase 改了以后在这里记下那个数。两者今天都不被执行(known issues)。
-- 【规矩】之后每一刀加它自己的那几支,并在【同一个提交里】往 docs/mes-pending-values.md 加它们的行(Tim,Q2)。
-- 【属主视图】读 devices / shifts 不过 RLS,所以每一支的码在末尾的 WHERE 里问一次。

CREATE OR REPLACE VIEW public.pending_values WITH (security_invoker = off) AS
 SELECT p.value_code,
    p.permission,
    p.item_id,
    p.item_code,
    p.item_label,
    p.href
   FROM ( SELECT 'V5'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = 'gateway'::text AND d.retired_at IS NULL AND d.heartbeat_interval_s IS NULL
        UNION ALL
         SELECT 'V6'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            sh.code AS item_code,
            sh.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM shifts sh
          WHERE sh.is_active AND sh.starts_at IS NULL AND sh.ends_at IS NULL
        UNION ALL
         SELECT 'V8'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            'calibration_lead_days'::text AS item_code,
            'Calibration reminder lead days'::text AS item_label,
            '/operation/calibration'::text AS href
           FROM ingest_settings st
          WHERE st.id AND st.calibration_lead_days IS NULL
        UNION ALL
         SELECT 'V33'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = ANY (ARRAY['scale'::text, 'weighbridge'::text, 'meter'::text, 'inline_instrument'::text])
            AND d.retired_at IS NULL AND d.interface_status <> 'reserved'::text AND d.capacity IS NULL
        UNION ALL
         SELECT 'V2'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            c.code AS item_code,
            (cc.cert_no || ' · '::text) || c.name_en AS item_label,
            '/purchasing/licences'::text AS href
           FROM company_compliance cc
             CROSS JOIN nea_waste_categories c
          WHERE cc.id = storage_licence_in_force((now() AT TIME ZONE 'Asia/Singapore'::text)::date) AND c.is_active
            AND NOT (EXISTS ( SELECT 1
                   FROM licence_storage_limits l
                  WHERE l.licence_id = cc.id AND l.category_code = c.code))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            'nea_waste_categories'::text AS item_code,
            'NEA waste categories'::text AS item_label,
            '/settings/dictionaries'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.nea_waste_category_code IS NULL
            AND (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V3'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.dwell_warning_days IS NULL
        UNION ALL
         SELECT 'V4'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.requires_quarantine IS NULL
        UNION ALL
         SELECT 'V34'::text AS value_code,
            'module.inventory.view'::text AS permission,
            NULL::uuid AS item_id,
            'quarantine_location'::text AS item_code,
            'Quarantine location'::text AS item_label,
            '/inventory/locations'::text AS href
          WHERE (EXISTS ( SELECT 1
                   FROM inbound_safety_states st
                  WHERE st.is_active AND st.requires_quarantine IS TRUE))
            AND NOT (EXISTS ( SELECT 1
                   FROM storage_locations l
                  WHERE l.is_active AND l.is_quarantine))
        UNION ALL
         SELECT 'V30'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            g.code AS item_code,
            g.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM dangerous_goods_codes g
          WHERE g.is_active AND (g.marking_text IS NULL OR g.packing_instruction IS NULL OR g.label_size IS NULL)
        UNION ALL
         SELECT 'V31'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.hs_code IS NULL
        UNION ALL
         SELECT 'V35'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.dg_code IS NULL
        UNION ALL
         SELECT 'V1'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            ot.code AS item_code,
            ot.name_en AS item_label,
            '/operation/operation-types/'::text || ot.code AS href
           FROM operation_types ot
             JOIN operation_kinds k ON k.code = ot.kind_code
          WHERE ot.is_active AND k.produces_outputs AND ot.balance_tolerance_pct IS NULL
        UNION ALL
         SELECT 'V36'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            (f.operation_type_code || '/'::text) || f.field_code AS item_code,
            f.name_en AS item_label,
            '/operation/operation-types/'::text || f.operation_type_code AS href
           FROM operation_type_fields f
             JOIN operation_types ot ON ot.code = f.operation_type_code
          WHERE f.is_active AND ot.is_active AND f.has_range AND f.range_min IS NULL AND f.range_max IS NULL
        UNION ALL
         SELECT 'V10'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            ot.code AS item_code,
            ot.name_en AS item_label,
            '/operation/operation-types/'::text || ot.code AS href
           FROM operation_types ot
          WHERE ot.is_active AND ot.electrolyte_loss_applies AND ot.electrolyte_share_pct IS NULL
        UNION ALL
         SELECT 'V11'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            cs.code AS item_code,
            cs.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM contamination_streams cs
          WHERE cs.is_active AND cs.warning_pct IS NULL
        UNION ALL
         SELECT 'V9'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
          WHERE m.deleted_at IS NULL AND m.discharge_pass_voltage_v IS NULL AND (EXISTS ( SELECT 1
                   FROM discharge_module_results r
                     LEFT JOIN inbound_batches ib ON ib.id = r.inbound_batch_id
                     LEFT JOIN output_batches ob ON ob.id = r.output_batch_id
                  WHERE COALESCE(ib.material_id, ob.material_id) = m.id))
        UNION ALL
         SELECT 'V25'::text AS value_code,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            'shared_pool_rule'::text AS item_code,
            'Shared-pool electricity rule'::text AS item_label,
            '/finance/electricity'::text AS href
           FROM electricity_settings es
          WHERE es.id AND es.shared_pool_rule IS NULL AND (EXISTS ( SELECT 1
                   FROM devices d
                  WHERE d.kind = 'meter'::text AND d.equipment_id IS NULL AND d.retired_at IS NULL))
        UNION ALL
         SELECT 'V37'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            (tf.operation_type_code || '/'::text) || tf.form_code AS item_code,
            (ot.name_en || ' · '::text) || COALESCE(mf.name_en, tf.form_code) AS item_label,
            '/operation/operation-types/'::text || tf.operation_type_code AS href
           FROM operation_type_output_forms tf
             JOIN operation_types ot ON ot.code = tf.operation_type_code
             LEFT JOIN material_forms mf ON mf.code = tf.form_code
          WHERE ot.is_active AND tf.expected_yield_pct IS NULL AND (EXISTS ( SELECT 1
                   FROM processing_run_flow_all f
                  WHERE f.operation_type_code = tf.operation_type_code AND f.flow = 'consumption'::text AND f.era_mes4a))
        UNION ALL
         SELECT 'V16'::text AS value_code,
            'module.quality.view'::text AS permission,
            NULL::uuid AS item_id,
            'internal_retention_days'::text AS item_code,
            'Internal sample retention (days)'::text AS item_label,
            '/quality/samples'::text AS href
           FROM quality_settings qs
          WHERE qs.id AND qs.internal_retention_days IS NULL AND (EXISTS ( SELECT 1
                   FROM samples s
                  WHERE s.retain_until_source = 'not_set'::text AND NOT (EXISTS ( SELECT 1
                           FROM sample_events e
                          WHERE e.sample_id = s.id AND e.event_kind = 'disposed'::text))))
        UNION ALL
         SELECT 'V14'::text AS value_code,
            'module.customers.view'::text AS permission,
            c.id AS item_id,
            c.code AS item_code,
            c.title AS item_label,
            '/contracts/'::text || c.id::text AS href
           FROM contracts c
          WHERE c.deleted_at IS NULL AND (EXISTS ( SELECT 1
                   FROM assay_disputes d
                     JOIN contract_document_terms t ON t.sales_order_id = d.sales_order_id
                  WHERE t.contract_id = c.id AND (d.status = ANY (ARRAY['open'::text, 'resolved'::text])))) AND NOT (EXISTS ( SELECT 1
                   FROM contract_settlement_terms cst
                  WHERE cst.contract_id = c.id AND cst.arbitration_fee_rule IS NOT NULL))
        UNION ALL
         SELECT 'V17'::text AS value_code,
            'module.customers.view'::text AS permission,
            c.id AS item_id,
            c.code AS item_code,
            c.title AS item_label,
            '/contracts/'::text || c.id::text AS href
           FROM contracts c
          WHERE c.deleted_at IS NULL AND c.customer_id IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM contract_document_terms t
                  WHERE t.contract_id = c.id AND t.sales_order_id IS NOT NULL)) AND NOT (EXISTS ( SELECT 1
                   FROM contract_settlement_terms cst
                  WHERE cst.contract_id = c.id AND cst.quality_limit_basis IS NOT NULL))
        UNION ALL
         SELECT 'V21'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            ('/materials/'::text || m.id::text) || '/edit'::text AS href
           FROM materials m
          WHERE m.deleted_at IS NULL AND m.kind_code = 'spare_part'::text AND m.safety_stock_qty IS NULL AND (EXISTS ( SELECT 1
                   FROM inbound_batches b
                  WHERE b.material_id = m.id))
        UNION ALL
         SELECT 'V19'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            'nea_report_working_days'::text AS item_code,
            'NEA written-report deadline (working days)'::text AS item_label,
            '/safety/incidents'::text AS href
           FROM safety_settings ss
          WHERE ss.id AND (ss.nea_report_working_days IS NULL OR ss.nea_report_days_confirmed_at IS NULL)
        UNION ALL
         SELECT 'V18'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            'inspection_templates'::text AS item_code,
            'Inspection checklists'::text AS item_label,
            '/safety/inspections'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM inspection_templates t
                  WHERE t.is_active))
        UNION ALL
         SELECT 'V18'::text AS value_code,
            'module.safety.view'::text AS permission,
            t.id AS item_id,
            t.code AS item_code,
            t.name AS item_label,
            '/safety/inspections/templates/'::text || t.id::text AS href
           FROM inspection_templates t
          WHERE t.is_active AND t.frequency_days IS NULL
        UNION ALL
         SELECT 'V20'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            'environmental_parameters'::text AS item_code,
            'Monitored environmental parameters'::text AS item_label,
            '/settings/dictionaries'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM environmental_parameters ep))
        UNION ALL
         SELECT 'V20'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            ep.code AS item_code,
            ep.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM environmental_parameters ep
          WHERE ep.is_active AND ep.limit_value IS NULL
        UNION ALL
         SELECT 'V23'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            NULL::uuid AS item_id,
            'supplier_score_settings'::text AS item_code,
            'Supplier scorecard weights, grade lines and review window'::text AS item_label,
            '/suppliers/scorecards'::text AS href
           FROM supplier_score_settings ss
          WHERE ss.id AND (ss.weights IS NULL OR ss.grade_lines IS NULL OR ss.review_window_days IS NULL)
        UNION ALL
         SELECT 'V24'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            NULL::uuid AS item_id,
            gl.value ->> 'grade'::text AS item_code,
            'Grade '::text || (gl.value ->> 'grade'::text) AS item_label,
            '/suppliers/scorecards'::text AS href
           FROM supplier_score_settings ss
             CROSS JOIN LATERAL jsonb_array_elements(ss.grade_lines) gl(value)
          WHERE ss.id AND ss.grade_lines IS NOT NULL
            AND ((((ss.grade_caps -> (gl.value ->> 'grade'::text)) ->> 'prepayment_cap_pct'::text) IS NULL)
                 OR (((ss.grade_caps -> (gl.value ->> 'grade'::text)) ->> 'sampling_level'::text) IS NULL))
        UNION ALL
         SELECT 'V26'::text AS value_code,
            'module.compliance.view'::text AS permission,
            NULL::uuid AS item_id,
            'compliance_settings'::text AS item_code,
            'NEA return format and frequency'::text AS item_label,
            '/compliance/packs'::text AS href
           FROM compliance_settings cs
          WHERE cs.id AND (cs.nea_return_format IS NULL OR cs.nea_return_frequency IS NULL)
        UNION ALL
         SELECT 'V27'::text AS value_code,
            'module.compliance.view'::text AS permission,
            NULL::uuid AS item_id,
            'compliance_settings'::text AS item_code,
            'EU recycling-efficiency method and targets'::text AS item_label,
            '/compliance/packs'::text AS href
           FROM compliance_settings cs
          WHERE cs.id AND (cs.eu_efficiency_method IS NULL OR cs.eu_efficiency_targets IS NULL)
        UNION ALL
         SELECT 'V28'::text AS value_code,
            'action.manage_permissions'::text AS permission,
            NULL::uuid AS item_id,
            'floor_board_settings'::text AS item_code,
            'Wall-display refresh interval and tiles'::text AS item_label,
            '/display'::text AS href
           FROM floor_board_settings fb
          WHERE fb.id AND (fb.refresh_seconds IS NULL OR fb.tiles IS NULL)
            AND (EXISTS ( SELECT 1
                   FROM user_roles ur
                     JOIN roles r ON r.id = ur.role_id
                     JOIN auth.users u ON u.id = ur.user_id
                  WHERE r.code = 'floor_display'::text AND ur.revoked_at IS NULL AND r.is_active AND u.deleted_at IS NULL
                    AND (u.banned_until IS NULL OR u.banned_until < now())))
        UNION ALL
         SELECT 'V38'::text AS value_code,
            'action.manage_permissions'::text AS permission,
            NULL::uuid AS item_id,
            'account_settings'::text AS item_code,
            'Initial password validity (days)'::text AS item_label,
            '/settings/accounts'::text AS href
           FROM account_settings acs
          WHERE acs.id AND acs.initial_password_valid_days IS NULL
        UNION ALL
         SELECT 'V40'::text AS value_code,
            'action.manage_permissions'::text AS permission,
            NULL::uuid AS item_id,
            'account_settings'::text AS item_code,
            'Password minimum length'::text AS item_label,
            '/settings/accounts'::text AS href
           FROM account_settings acs
          WHERE acs.id AND acs.password_min_length IS NULL) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7);MES-4b 加 V10(勾了电解液挥发的工序的电解液份额)与 V11(交叉污染流的警戒线)。MES-5a-1 加 V9(物料的放电通过电压,只在那种物料有了放电结果之后才列);MES-5a-2 加 V25(共用池的电怎么摊,有共用池电表而规则为空时一行)。MES-5b-1 加 V37(每道工序 × 每种产出形态的预期质量得率;只在那道工序有了至少一张 MES-4a 之后的消耗炉次时才列 —— V9 的先例:没人能动手的行不列)。MES-6a-1 加 V16(没有合同天数的样品留多少天;只在有一份没处置、留样日 Not yet set 的样品时才列)与 V14(仲裁费怎么分;每一份有过一件开着或已结案的争议而规则为空的合同一行)。MES-6b-1 加 V17(卖方合同的质量验收限;每一份挂了销售单而口径没声明的卖方合同一行)。MES-7a-2 加 V21(备件的最低库存;每一种收过至少一批而最低库存为空的备件物料一行)。MES-7b-1 加 V19(NEA 书面报告的工作日数;空着或还没对着执照确认时一行)。MES-7b-2 加 V18(巡检清单的频率与检查项;一张启用的清单都没有时一行,之后每一张频率空着的启用清单一行)与 V20(监测参数的排放限值;字典空着时一行,之后每一个没有限值的启用参数一行)。MES-8a 加 V23(供应商评分的权重、等级线与评审周期;三样里有一样空着就一行)与 V24(每一个等级的预付上限与抽样级别;有了等级线之后,每一个缺其中一样的等级一行)。MES-8b-1 加 V26(NEA 申报的格式与频率)与 V27(欧盟回收效率的方法与目标)—— 两支都是从第一天起就一行(合规包的设定一行、全空),读 module.compliance.view。MES-8b-2 加 V28(车间大屏自己刷新的间隔与画哪几块牌子;设定那一行有一样空着、并且有一个在用的 floor_display 账号时一行 —— 没有大屏就没有人能动手,读 action.manage_permissions)。MES-9a 加 V38(初始密码在第一次登录之前有效几天)与 V40(项目的密码最短长度)—— 两支都从第一天起就一行(account_settings 一行、全空),读 action.manage_permissions,去处 /settings/accounts。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- db/views/user_directory.sql
-- 系统账号目录:权限管理界面唯一需要读 auth 架构的地方。
--
-- 【选视图而不是 SECURITY DEFINER 函数】:与 2b 已确立的属主权限视图机制一致;
-- PostgREST 对视图支持过滤/排序/分页(界面要按邮箱搜、按时间排);而且权限检查
-- 写在 WHERE 里,天然满足"没有权限的人拿到【零行而不是报错】"。
--
-- auth.users 不在 PostgREST 暴露的架构里;本视图建在 public 且以属主身份读取,
-- 是把 auth 数据按一条明确谓词引出来的唯一出口。
--
-- ★ APR-ROUTE-1 Batch B(2026-09-23,R3):一个账号可以是某人的【额外账号】。
--   员工那一列先查主账号、再回落到 employee_accounts —— 与 account_person() 同一个先后。
--   ☞ 这里【直接连表】而不调 account_person():本视图是属主权限,而属主替得了【表】,
--     替不了【函数的 EXECUTE】(AGENTS.md「属主权限视图替得了表」那一节)——
--     account_person 已从 authenticated 收回,读这张视图的人会撞 42501。
--   新增的末列 account_kind:'primary' | 'additional' | NULL(没关联任何人)。
--   /settings/accounts 靠它决定这一行给哪一块控件。
--
-- ★ HISTORY-1(2026-09-28,Tim 的 Q22 · Q2):新增末列 disabled —— 账号被停用(auth.users.banned_until 在将来)。
--   /settings/accounts 靠它决定这一行给「停用」还是「重新启用」,并画出「已停用」。
--   判据与 real_role_grants 的第 ③ 条同一句话的反面(banned_until IS NULL OR banned_until < now() 为"未封禁")。
--
-- ★ MES-9a(2026-10-19,MES-9 Step 0 Q5 · Q7,Tim):【供应商门户账号不在这里】—— 它们不是员工账号:不持角色、不挂员工档案(两样都被
--   guard_portal_account_separation 拒),在供应商页上由持 action.manage_portal_users 的人开、撤销。列在这一页会给一个
--   【永远按不成】的「授角色」与「挂员工」。/settings/accounts 顶上照直说门户账号在哪儿管。
-- NOTE: introduced by db/migrations/2026-08-02-perm3-banking-and-directory.sql.

CREATE OR REPLACE VIEW public.user_directory WITH (security_invoker = off) AS
 SELECT u.id AS user_id,
    u.email::text AS email,
    u.created_at,
    u.last_sign_in_at,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('role_id', r.id, 'code', r.code, 'name_en', r.name_en, 'name_zh', r.name_zh) ORDER BY r.sort_order, r.code) AS jsonb_agg
           FROM user_roles ur
             JOIN roles r ON r.id = ur.role_id
          WHERE ur.user_id = u.id AND ur.revoked_at IS NULL AND r.deleted_at IS NULL), '[]'::jsonb) AS roles,
        CASE
            WHEN ep.id IS NOT NULL THEN 'primary'::text
            WHEN ea.employee_id IS NOT NULL THEN 'additional'::text
            ELSE NULL::text
        END AS account_kind,
    (u.banned_until IS NOT NULL AND u.banned_until > now()) AS disabled
   FROM auth.users u
     LEFT JOIN employees ep ON ep.user_id = u.id AND ep.deleted_at IS NULL
     LEFT JOIN employee_accounts ea ON ea.user_id = u.id
     LEFT JOIN employees e ON e.id = COALESCE(ep.id, ea.employee_id) AND e.deleted_at IS NULL
  WHERE has_permission('action.manage_permissions'::text) AND NOT (EXISTS ( SELECT 1
           FROM supplier_portal_users p
          WHERE p.user_id = u.id));

-- ── 11 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.supplier_portal_users
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.supplier_portal_users
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.account_settings
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.account_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 12 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.portal_user_create_link(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_user_create_link(uuid, uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_user_revoke(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_user_revoke(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_contact_anonymise(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_contact_anonymise(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_actor_labels(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_actor_labels(uuid[]) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.set_account_setting(text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_account_setting(text, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_me() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_me() TO supplier_portal;
REVOKE EXECUTE ON FUNCTION public.portal_export_my_data() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_export_my_data() TO supplier_portal;
REVOKE EXECUTE ON FUNCTION public.portal_require_link() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_access_token_hook(jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_access_token_hook(jsonb) TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.guard_portal_account_separation() FROM PUBLIC, anon;

-- ── 13 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes9a_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes9a_pending_after ON COMMIT DROP AS
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
    -- ① 授权:恰好多了那两行;目录 86 个码,admin 持每一个;每一个动作码的持有人都持它声明的查看码
    IF (SELECT count(*) FROM permissions) <> 86
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES9A_PROOF|admin does not hold every one of the 86 codes';
    END IF;
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v_bad FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'action.manage_portal_users';
    IF v_bad IS DISTINCT FROM 'admin,cco' THEN
        RAISE EXCEPTION 'MES9A_PROOF|action.manage_portal_users is held by % (ruled: admin,cco)', COALESCE(v_bad, '<nobody>');
    END IF;
    SELECT string_agg(r.code || ':' || p.code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MES9A_PROOF|an action code is held without its declared view: %', v_bad;
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变;没有任何门户账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES9A_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM mes9a_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM mes9a_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'MES9A_PROOF|an account or its roles changed';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users) THEN RAISE EXCEPTION 'MES9A_PROOF|no portal account may exist'; END IF;

    -- ③ 七个真账号:hook 返回的 event 与传进去的逐字节相同(员工的令牌一个字节都不变)
    FOR a IN SELECT id, email FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test') ORDER BY email LOOP
        v_ev := jsonb_build_object('user_id', a.id, 'authentication_method', 'password',
                    'claims', jsonb_build_object('aud', 'authenticated', 'exp', 2000000000, 'iat', 1900000000, 'sub', a.id, 'email', a.email,
                                                 'phone', '', 'role', 'authenticated', 'aal', 'aal1', 'session_id', gen_random_uuid(),
                                                 'is_anonymous', false, 'app_metadata', jsonb_build_object('provider', 'email'),
                                                 'user_metadata', '{}'::jsonb, 'amr', '[]'::jsonb));
        v_j := portal_access_token_hook(v_ev);
        RAISE NOTICE 'MES9A hook % unchanged = %', a.email, (v_j = v_ev);
        IF v_j IS DISTINCT FROM v_ev THEN
            RAISE EXCEPTION 'MES9A_PROOF|the hook changed the claims of %', a.email;
        END IF;
    END LOOP;

    -- ④ 门户角色:不能登录、不继承、不绕过 RLS;不是任何角色的成员;authenticator 持有它;能执行的恰好是两支门户函数
    IF (SELECT rolcanlogin OR rolinherit OR rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname = 'supplier_portal') THEN
        RAISE EXCEPTION 'MES9A_PROOF|supplier_portal must be NOLOGIN NOINHERIT, no superuser / bypassrls / createrole / createdb';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member = 'supplier_portal'::regrole)
       OR NOT pg_has_role('authenticator', 'supplier_portal', 'MEMBER') THEN
        RAISE EXCEPTION 'MES9A_PROOF|supplier_portal must be a member of nothing and held by authenticator';
    END IF;
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_export_my_data, portal_me' THEN
        RAISE EXCEPTION 'MES9A_PROOF|supplier_portal executes: %', v_bad;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'public' AND has_table_privilege('supplier_portal', c.oid, 'SELECT,INSERT,UPDATE,DELETE')) THEN
        RAISE EXCEPTION 'MES9A_PROOF|supplier_portal holds a privilege on a public relation';
    END IF;
    IF NOT has_function_privilege('supabase_auth_admin', 'public.portal_access_token_hook(jsonb)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.portal_access_token_hook(jsonb)', 'EXECUTE') OR has_function_privilege('anon', 'public.portal_access_token_hook(jsonb)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.portal_require_link()', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.portal_me()', 'EXECUTE') THEN
        RAISE EXCEPTION 'MES9A_PROOF|function grants on the hook / portal functions are wrong';
    END IF;
    IF NOT has_table_privilege('supabase_auth_admin', 'public.supplier_portal_users', 'SELECT') THEN
        RAISE EXCEPTION 'MES9A_PROOF|supabase_auth_admin cannot read supplier_portal_users (the hook would fall back for everyone)';
    END IF;

    -- ⑤ 在途单据一张不少、一张不多;既有的行逐字未变;存储对象一个都没动
    IF EXISTS ((SELECT b.k, b.id FROM mes9a_pending_before b EXCEPT SELECT a2.k, a2.id FROM mes9a_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM mes9a_pending_after a2 EXCEPT SELECT b.k, b.id FROM mes9a_pending_before b)) THEN
        RAISE EXCEPTION 'MES9A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) IS DISTINCT FROM (SELECT suppliers FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'anonymised_at')::text, '|' ORDER BY (to_jsonb(t) - 'anonymised_at')::text), '')) FROM counterparty_contacts t ) IS DISTINCT FROM (SELECT counterparty_contacts FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_compliance t ) IS DISTINCT FROM (SELECT supplier_compliance FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_attachments t ) IS DISTINCT FROM (SELECT supplier_attachments FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_status_history t ) IS DISTINCT FROM (SELECT supplier_status_history FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_scorecard_reviews t ) IS DISTINCT FROM (SELECT supplier_scorecard_reviews FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customers t ) IS DISTINCT FROM (SELECT customers FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) IS DISTINCT FROM (SELECT employees FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employee_accounts t ) IS DISTINCT FROM (SELECT employee_accounts FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) IS DISTINCT FROM (SELECT inbound_batches FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM purchase_orders t ) IS DISTINCT FROM (SELECT purchase_orders FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM po_issues t ) IS DISTINCT FROM (SELECT po_issues FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) IS DISTINCT FROM (SELECT cod_issues FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) IS DISTINCT FROM (SELECT certificates_of_destruction FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statements t ) IS DISTINCT FROM (SELECT supplier_statements FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) IS DISTINCT FROM (SELECT journal_entries FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) IS DISTINCT FROM (SELECT journal_lines FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) IS DISTINCT FROM (SELECT payments FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) IS DISTINCT FROM (SELECT expenses FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) IS DISTINCT FROM (SELECT approval_log FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t WHERE code <> 'action.manage_portal_users') IS DISTINCT FROM (SELECT permissions FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t WHERE permission_code <> 'action.manage_portal_users') IS DISTINCT FROM (SELECT role_permissions FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) IS DISTINCT FROM (SELECT roles FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) IS DISTINCT FROM (SELECT user_roles FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) IS DISTINCT FROM (SELECT finance_settings FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) IS DISTINCT FROM (SELECT ingest_settings FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM floor_board_settings t ) IS DISTINCT FROM (SELECT floor_board_settings FROM mes9a_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t ) IS DISTINCT FROM (SELECT document_types FROM mes9a_rows_before) THEN
        RAISE EXCEPTION 'MES9A_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS ((SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects
                EXCEPT SELECT bucket_id, name, size, etag FROM mes9a_objects_before)
               UNION ALL
               (SELECT bucket_id, name, size, etag FROM mes9a_objects_before
                EXCEPT SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects)) THEN
        RAISE EXCEPTION 'MES9A_PROOF|a stored object changed';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 52 THEN
        RAISE EXCEPTION 'MES9A_PROOF|storage policies are no longer 52';
    END IF;

    -- ⑥ V38 · V40 那一行在、全空;两支待补的值从第一天起各一行
    IF (SELECT count(*) FROM account_settings) <> 1
       OR EXISTS (SELECT 1 FROM account_settings WHERE initial_password_valid_days IS NOT NULL OR password_min_length IS NOT NULL) THEN
        RAISE EXCEPTION 'MES9A_PROOF|account_settings must be one empty row';
    END IF;

    -- ⑦ 本事务往变更记录只写了:目录一行(新增与它的查看码)、两行授权、设定那一行(按 txid 认)
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes9a_log_before), 0) AND c.txid = txid_current()
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'account_settings'))
                OR (c.op = 'UPDATE' AND c.table_name = 'permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES9A_PROOF|unexpected change_log rows: %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes9a_log_before), 0) AND c.txid = txid_current()
          AND c.table_name = 'role_permissions') <> 2 THEN
        RAISE EXCEPTION 'MES9A_PROOF|expected exactly 2 role_permissions rows written';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9A_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑧ 结构:323 张表;待补的值 36 支
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 323 THEN
        RAISE EXCEPTION 'MES9A_PROOF|expected 323 public tables';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 36 THEN
        RAISE EXCEPTION 'MES9A_PROOF|pending-value arms 36 expected';
    END IF;

    -- ⑨ 匿名面与员工那几支函数
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES9A_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.portal_user_create_link(uuid, uuid, uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.portal_user_create_link(uuid, uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.portal_user_create_link(uuid, uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('supplier_portal', 'public.portal_user_create_link(uuid, uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES9A_PROOF|public.portal_user_create_link(uuid, uuid, uuid): expected SECURITY DEFINER, authenticated yes, anon and supplier_portal no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.portal_user_revoke(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.portal_user_revoke(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.portal_user_revoke(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('supplier_portal', 'public.portal_user_revoke(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES9A_PROOF|public.portal_user_revoke(uuid, text): expected SECURITY DEFINER, authenticated yes, anon and supplier_portal no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.portal_contact_anonymise(uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.portal_contact_anonymise(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.portal_contact_anonymise(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('supplier_portal', 'public.portal_contact_anonymise(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES9A_PROOF|public.portal_contact_anonymise(uuid): expected SECURITY DEFINER, authenticated yes, anon and supplier_portal no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.portal_actor_labels(uuid[])'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.portal_actor_labels(uuid[])'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.portal_actor_labels(uuid[])'::regprocedure, 'EXECUTE')
       OR has_function_privilege('supplier_portal', 'public.portal_actor_labels(uuid[])'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES9A_PROOF|public.portal_actor_labels(uuid[]): expected SECURITY DEFINER, authenticated yes, anon and supplier_portal no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.set_account_setting(text, integer)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.set_account_setting(text, integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.set_account_setting(text, integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('supplier_portal', 'public.set_account_setting(text, integer)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES9A_PROOF|public.set_account_setting(text, integer): expected SECURITY DEFINER, authenticated yes, anon and supplier_portal no';
    END IF;
    IF has_table_privilege('anon', 'public.supplier_portal_users', 'SELECT') OR has_table_privilege('anon', 'public.account_settings', 'SELECT') THEN
        RAISE EXCEPTION 'MES9A_PROOF|anon can read a new table';
    END IF;

    -- ⑩ 变更记录:覆盖零缺口(两张新表记,豁免仍是 8);遮蔽零缺口
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES9A_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'MES9A_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;

    -- ⑪ F16:没有一张视图对 anon / authenticated 带写授权
    v_n := (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES9A_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑫ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes9a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES9A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes9a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES9A_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes9a_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
