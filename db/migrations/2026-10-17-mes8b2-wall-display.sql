-- db/migrations/2026-10-17-mes8b2-wall-display.sql
-- MES-8b-2 —— 车间大屏:一个新的 floor_display 角色看一块只读的牌子(加工、安全与库存此刻各有几件事在等人 —— 只有数,没有钱、没有名字、
--   没有健康信息),只挂这个角色的屏空闲时不被登出,别的账号照旧;价格敞口页把物料种类没说的库存列出来,而不是丢掉(F18)。
--   (MES 组的第二十二刀,v1.4.58;发布那一行在 docs/handbacks/MES-8b-2.md 的抬头。)由 db/scripts/build_mes8b2_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-17:MES-8 Step 0 的 Q19 · Q20 · Q29,以及 Q21–Q24 里 8b-2 那一半,照推荐裁定;F18 与月结页 390 px 的并入)
--   ① 角色 floor_display(不是系统角色)与码 data.view_floor_board(data 类,不声明查看码)—— 授 floor_display · admin · cfo(三行);
--      本刀【不建任何账号】(Q29:一块屏一个账号,由 admin 经 /settings/accounts 建)。
--   ② 一张新表 floor_board_settings(单行;V28 = 自己刷新的间隔与画哪几块牌子,全空引导,两样一起给一起清)。
--   ③ 视图 operations_arms_all(operations_now 的全部支,不按读者过滤 —— 基视图,不给人读);operations_now 换成"它 + 按读者的那一句过滤"
--      (列、列序、每一行都与之前相同 —— 支的定义从此只有一份,floor_board() 从它计数)。
--   ④ 函数 floor_board_arms(大屏画哪 23 支,纯函数)· floor_board(只吐计数,门 data.view_floor_board)· session_is_floor_display_only
--      (空闲豁免与"别的页一律拒"的唯一判据)· set_floor_board_settings(给 / 清 V28,门 action.manage_permissions)。
--   ⑤ pending_values 加 V28 一支(有一个在用的大屏账号、设定有一样空着时一行;线上没有大屏账号 → 0 行)。
--   ⑥ F18:inventory_metal_exposure 把【物料种类没说】的在库批列进 kind_not_stated(代码与 kg),不估值,complete 因此为 false;
--      种类说了而不可投料的照旧不进来。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权只多上面那三行;不给任何物料定种类;不给 V28;不写、不改任何一批、任何流水、价、
--   含量、盘点、事故、巡检、分录、包、证书(两张已签发的 COD 的字节与档案一个字不动);不回填;require_calibrated_since 保持空。
--   线上由本迁移造出的只有:一个角色、一个码、三行授权、一张设定表(那一行全空)、一张基视图、四支函数,与 V28 那一支。
--
-- 【破窗】(Q23:这一窗什么都不坏)旧应用读 operations_now 的行与之前逐行相同;读 inventory_metal_exposure 多两个键(旧页面不认,
--   照旧不画种类没说的批 —— 就是今天的样子,直到部署);旧应用的待补值页不认 V28,但线上没有大屏账号,那一支一行都不出;
--   空闲豁免是【应用代码】(中间件),部署之前一个大屏会话仍会被登出 —— 线上没有这样的会话。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了那三行,admin 持目录里每一个码(85);没有任何人挂 floor_display;
--   七个账号一个都没被停、角色一个没变,而且对它们每一个,session_is_floor_display_only() 都是假(空闲登出照旧);在途单据一张不少、一张不多,
--   每一张仍有一个不是它当事人的决定人;既有的行逐字未变(见 DIGEST_TABLES);anon 能执行的【恰好】两支;员工函数 DEFINER、调得到;
--   那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 119);支 72(基视图)、待补的值 34 支;321 张表;
--   没有一张视图对 anon / authenticated 带写授权;基视图对 authenticated 关着;两张 COD 的存储对象一个字节不动。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子(开场读数,docs/surveys/MES-8b-2/live-readings.sql)──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES8B2_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.floor_board_settings') IS NOT NULL OR to_regclass('public.operations_arms_all') IS NOT NULL
       OR to_regprocedure('public.floor_board()') IS NOT NULL OR to_regprocedure('public.session_is_floor_display_only()') IS NOT NULL
       OR EXISTS (SELECT 1 FROM permissions WHERE code = 'data.view_floor_board') OR EXISTS (SELECT 1 FROM roles WHERE code = 'floor_display') THEN
        RAISE EXCEPTION 'MES8B2_PRE|MES-8b-2 objects already exist';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test')) <> 7 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 84
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected a catalogue of 84 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'cfo') AND is_active AND deleted_at IS NULL) <> 2 THEN
        RAISE EXCEPTION 'MES8B2_PRE|the roles admin and cfo must exist and be active';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 63 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected 63 document types';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected 119 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 72 THEN
        RAISE EXCEPTION 'MES8B2_PRE|operations_now should have 72 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 33 THEN
        RAISE EXCEPTION 'MES8B2_PRE|pending_values should have 33 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 320 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected 320 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B2_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected the two recorded COD byte strings';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes8b2_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes8b2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes8b2_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE mes8b2_cod_objects_before ON COMMIT DROP AS
SELECT name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects WHERE bucket_id = 'cod-documents';
CREATE TEMP TABLE mes8b2_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t ) AS output_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t ) AS inventory_movements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t ) AS processing_runs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_inputs t ) AS processing_inputs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_outputs t ) AS processing_outputs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_records t ) AS sales_records,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM metal_prices t ) AS metal_prices,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_metals t ) AS inbound_batch_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t ) AS output_batch_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM substances t ) AS substances,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t ) AS materials,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM material_kinds t ) AS material_kinds,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) AS suppliers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM purchase_orders t ) AS purchase_orders,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customers t ) AS customers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM stocktakes t ) AS stocktakes,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM incidents t ) AS incidents,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM environmental_results t ) AS environmental_results,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_templates t ) AS inspection_templates,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_runs t ) AS inspection_runs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_findings t ) AS inspection_findings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM compliance_packs t ) AS compliance_packs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM compliance_settings t ) AS compliance_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_score_settings t ) AS supplier_score_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) AS certificates_of_destruction,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) AS employees,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t WHERE code <> 'data.view_floor_board') AS permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t WHERE permission_code <> 'data.view_floor_board') AS role_permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t WHERE code <> 'floor_display') AS roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) AS user_roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t ) AS document_types,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) AS ingest_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) AS finance_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM safety_settings t ) AS safety_settings;

-- ── 1 · 新表(镜像原样):车间大屏的设定(V28,一行,全空)─────────────────────

-- db/tables/floor_board_settings.sql
-- MES-8b-2(2026-10-17,MES-0 §5.1 V28 · Q83;MES-8 Step 0 Q20,Tim):【车间大屏的待补的值 —— 单行】。
--   V28  refresh_seconds · tiles   大屏多久自己刷新一次、画哪几块牌子(按什么顺序)。两样一起给,一起清(CHECK)。
--   【引导一律为空】:没有人说过大屏挂在哪儿、要看什么、多久刷新 —— 不猜一个间隔,也不替人挑牌子。
--   为空时大屏画全部车间支(floor_board_arms() 的二十三支,按加工 · 安全 · 库存分节),顶上写「refreshed at hh:mm」与一颗刷新钮,
--   【不自动刷新】(Q20)。给了之后只画 tiles 里那几块(按 tiles 的顺序),并每 refresh_seconds 秒自己刷新一次。
--   tiles 只能是 floor_board_arms() 里的支(set_floor_board_settings 按名拒);改它只改大屏画什么,不改任何一支的计数。
--   由 action.manage_permissions(建大屏账号的那个人,admin)经 set_floor_board_settings 改;修改史在变更记录里(本刀不加审计主语,Q22)。
--   RUNTIME CONFIG:Tim 设一次,线上就与本文件不同 —— 那是系统在正常工作(compliance_settings 的先例)。
--
-- NOTE: introduced by db/migrations/2026-10-17-mes8b2-wall-display.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.floor_board_settings (
    id              boolean PRIMARY KEY DEFAULT true CHECK (id),
    refresh_seconds integer CHECK (refresh_seconds IS NULL OR refresh_seconds > 0),
    tiles           text[] CHECK (tiles IS NULL OR cardinality(tiles) > 0),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid(),
    CONSTRAINT floor_board_settings_pair CHECK ((refresh_seconds IS NULL) = (tiles IS NULL))
);

COMMENT ON TABLE public.floor_board_settings IS
    'MES-8b-2:车间大屏的设定(单行)。V28 = refresh_seconds · tiles(自己刷新的间隔与画哪几块牌子),一起给一起清。引导为空:画全部车间支、不自动刷新(Q20)。action.manage_permissions 经 set_floor_board_settings 改。';
COMMENT ON COLUMN public.floor_board_settings.refresh_seconds IS
    'V28:大屏每隔多少秒自己刷新一次。空 = Not yet set(大屏只有「refreshed at」与刷新钮,不自动刷新 —— 不猜一个间隔)。';
COMMENT ON COLUMN public.floor_board_settings.tiles IS
    'V28:大屏画哪几块牌子,按这个顺序 —— 每一项是 floor_board_arms() 里的一支(operations_arms_all 的 item_type)。空 = Not yet set(画全部车间支)。';

INSERT INTO public.floor_board_settings (id) VALUES (true);

CREATE TRIGGER trg_floor_board_settings_updated_at
    BEFORE UPDATE ON public.floor_board_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.floor_board_settings ENABLE ROW LEVEL SECURITY;
-- 读:大屏的码(大屏自己经 floor_board() 读,不直接读表)或 action.manage_permissions(设它的人)。写只经函数。
CREATE POLICY "floor_board_settings select by permission" ON public.floor_board_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('data.view_floor_board'::text) OR has_permission('action.manage_permissions'::text));
GRANT SELECT ON public.floor_board_settings TO authenticated;
REVOKE ALL ON public.floor_board_settings FROM anon;

-- ── 2 · 权限目录一行(与 db/tables/permissions.sql 逐字同一份)· 角色一行(与 db/tables/roles.sql 逐字同一份)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('data.view_floor_board', 'data', 'View the floor board', '查看车间大屏', 'The wall display (/display): live counts of what is waiting on the plant floor in processing, safety and stock — counts only, no money, no names, no health details. A session holding only this code through only the floor_display role is not signed out when idle and opens nothing else.', '车间大屏(/display):加工、安全与库存里正在等人处理的事的实时计数 —— 只有数,没有钱、没有名字、没有健康信息。一个只经 floor_display 这一个角色持这一个码的会话,空闲时不被登出,也打不开别的任何一页。', 290);
INSERT INTO public.roles (code, name_en, name_zh, description_en, description_zh, is_system, sort_order) VALUES
    ('floor_display', 'Floor display', '车间大屏', 'A wall screen on the plant floor: one account per screen, holding only this role. It opens only the floor board (/display) — live counts from processing, safety and stock, no money, no names, no health details — and is not signed out when idle. Any other role or code on the account removes both.', '车间墙上的一块屏:一块屏一个账号,只挂这一个角色。它只打得开大屏(/display)—— 加工、安全与库存的实时计数,没有钱、没有名字、没有健康信息 —— 并且空闲时不被登出。账号上多一个角色或这个角色多一个码,两样都没有了。', false, 110);

-- ── 3 · 授权(MES-0 Q90 · 常设裁定):data.view_floor_board → floor_display · admin · cfo —— 本刀唯一的授权改动(三行)──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'data.view_floor_board' FROM roles r WHERE r.code IN ('admin', 'cfo', 'floor_display')
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 4 · 基视图(镜像原样):operations_now 的全部支,不按读者过滤;不给人读 ──

-- db/views/operations_arms_all.sql
-- ★ MES-8b-2(2026-10-17,MES-8 Step 0 Q20,Tim):operations_now 的【全部支】,不按读者过滤 —— 基视图,不给人读(REVOKE ALL)。
--   为什么拆出来:operations_now 在最后一句按【调用者】的码逐支裁决(has_permission 解析 auth.uid()),所以一支 SECURITY DEFINER 函数
--   读 operations_now 也只拿到【调用者】看得见的那几支 —— 一块只持 data.view_floor_board 的大屏读它是零行。floor_board() 要的是
--   【数】,不是那几行:它从这一张基视图按支计数,只吐计数(不吐 subject、item_code、名字或钱)。
--   支的定义因此【只有这一份】:operations_now = 本视图 + 那一句按读者的过滤,floor_board() = 本视图 + 按支计数。
--   ★ 加一支 = 改【本文件】· lib/reminders.ts · docs/dashboard-arm-inventory.md · messages(scripts/check-reminder-arms.mjs 读本文件)。
--   下面是 operations_now.sql 原来的抬头,随支的定义一起搬过来(原样)。
--
-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
-- ★ MES-8b-1(2026-10-17,MES-8 Step 0 Q15,Tim):加一支,门 action.compliance_pack(冻包的人 —— 提醒是给能动手的人的)。
--   compliance_pack_not_frozen —— 从 system_start_date 那个月起,每一个【已关账】(月末 < locked_before)而没有一份在册合规包的月,一行。
--     item_id 空(一个月不是一行记录);item_code = YYYY-MM;subject = 'Compliance pack';item_date = 那个月的月末。冻了就消失。
--     月结页同一件事只是一行警告(compliance_pack_month_status),【从不挡关账】(MES-0 Q48 的形状)。
-- ★ MES-8a(2026-10-16,MES-8 Step 0 Q27,Tim):加一支,门 action.supplier_review(记评审的人 —— 提醒是给能动手的人的)。
--   supplier_review_due —— 一家批准过 / 在用的进货供应商,而它最近一次没被取代的评审的日子 + V23 的评审周期 ≤ 今天(doc_kind = due,
--     item_date = 那一天到期的日子),或一次评审都没有(doc_kind = never_reviewed,item_date = 建档那一天)。
--     ★【V23 的周期空着时这一支一行都不出】(Q27 —— V18 的先例:没有数,就没有提醒;不猜一个周期)。
--     item_id = 那家供应商;item_code = 供应商代码;subject = 它的名字(标签跟着单据走)。
-- ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q10 · Q11,Tim):加两支,门都是 module.safety.view,都读 incident_current_all(事故现在的值:
-- ★ MES-7b-2(2026-10-16,MES-7b Step 0 Q13 · Q14 · Q20,Tim):加两支,门都是 module.safety.view。
--   inspection_due —— 一张启用的巡检清单【有频率】(V18)而该巡了:还没巡过(doc_kind = never_run,item_date = 建清单那一天),或最近一次没被
--     更正过的巡检的日子 + 频率 ≤ 今天(doc_kind = due,item_date = 那一天到期的日子)。频率空着的清单不进来 —— 没有日子可数(V18 那一行在
--     待补的值页上)。判据住在 inspection_template_due_all(清单页读同一份)。item_id = 那张清单;item_code = 清单代号;subject = 清单名字。
--   inspection_finding_open —— 一条还没关闭的巡检发现。item_id = 那条发现;doc_kind = 它那一次巡检的 id(门牌指巡检页上那一条);
--     item_code = 巡检编号;subject = 那一项的字;item_date = 记下发现的那一天(首页数它开了几天;人选的到期日在巡检页上说)。
--     关掉它那张任务不关闭它(Q14)—— 只有记一次关闭才让它消失。
--   更正过的"要不要通报"说了算;一件更正成不用通报的事故两支都消失)。关闭【不】清掉它们 —— 法定的义务不因"关闭"而结束。
--   incident_nea_notify_due —— 一件要通报 NEA 的事故,还没有记下通报("立即":没有天数,只是挂着直到记下)。item_id = 那件事故;
--     item_code = 事故编号;subject = 种类的英文名;item_date = 事故日(新加坡日期)。
--   incident_report_due —— 一件要通报 NEA 的事故,还没有记下交了书面报告。item_date = 期限(事故日之后第 V19 个工作日);期限算不出来或
--     没有设定时退回事故日(item_date 在每一支上都不为空 —— 首页拿它算等了几天)。doc_kind 借来装期限的状态(computed · not_set ·
--     cannot_compute):只有 computed 时 item_date 才是期限 —— 门牌据此说"算不出来",不把事故日说成期限。
-- ★ MES-6b-2(2026-10-15,MES-6b Step 0 Q32 · Q38,Tim):加一支 coa_facts_changed —— 一张已签发的分析证书,而它那一批在签发之后多了一份
--   (没删的)化验、或开了一张不合格报告。证书【永远不会被自动作废】(Q32):这一格只把它摆到持 action.issue_coa 的人面前(签发与提作废申请
--   的是同一批人),由人决定要不要经 CFO 作废、重开一张。item_id = 那张证书;item_code = 证书号;subject = 批号 · 最早那一件新事的编号
--   (化验号或报告编号);item_date = 那件事的日子。证书作废之后它消失(重开的那一张从它自己的签发时刻重新算)。
-- ★ MES-6b-1(2026-10-15,MES-6b Step 0 Q6 · Q23 · Q38,Tim):加三支,门都是 module.quality.view。
--   ncr_open —— 一张开着的不合格报告(它扣着那一批)。item_id = 那张报告;item_code = 报告编号;subject = 批号;item_date = 开单日。
--   quality_hold_reserved —— 一批在质量暂扣里的产出批还挂着没释放的预留(Q23:预留照留,发不出去)。一张单 × 一批 × 扣着它的那张报告一行;
--     item_id = 那张销售单(门牌指它,释放预留在那一页);subject = 批号 · 报告编号;item_date = 最早那一笔预留的日子。
--     判据 batch_quality_hold(以读者身份调用的 INVOKER 函数)—— 所以这一支另外要 module.output.view(arm_permission_any):不合格报告与产出批的
--     读策略都认它,读者不会因为读不到而少看一行;质量那一侧之外,销售那一侧也看得见(arm_permission_widen:module.sales.view)。
--   quality_prompt_ncr —— 【提示人去开一张】(Q6:只有 V17 越限自动开):一批进料的品位违反(contract_grade_breaches —— 那张视图自己要
--     module.suppliers.view,今天每一个持质量查看码的角色都持它)、一批产出批的交叉污染抽检过了 V11 的警戒线(当前的、没被更正的那一条)、
--     一批的一个模组最新的放电结论是失败(没拆走)。一批一行;那一批上有一张开单时刻不早于那件事的不合格报告(任何状态)之后消失。
--     item_id = 那一批;doc_kind = 'inbound' / 'output'(门牌按它指 /quality/ncr/new 的那一批);subject = 那件事的出处(化验单号 · 流 · 模组号)。
-- ★ MES-6a-1(2026-10-09,MES-6a Step 0 Q15 · Q17,Tim):加三支,门都是 module.quality.view。
--   sample_retention_due —— 一份样品的留样日已经过了、还没处置(Q15)。item_id = 那份样品;subject = 批号;item_date = 留样日。
--     留样日 Not yet set 的样品不进来(没有日子可过)。
--   assay_dispute_open —— 一件开着的化验争议(它挡着进料的应用 / 定价过账与卖方结算)。item_id = 那件争议;item_code = 批号;
--     subject = 两份结果的单号。
--   assay_results_disagree —— 卖方:两方结果差得超过了合同的容差,而没有人立过争议(MES-0 Q62;assay_disagreements_all)。
--     item_id = 那一批产出批;subject = 销售单号。买方没有这一支(买方合同不带容差 —— Q17)。
-- ★ MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23;MES-5a Step 0 Q18,Tim):加两支,都读 discharge_batch_status_all,门 module.processing.view。
--   discharge_unverified —— 一批做过一炉没回滚的深度放电(verifies_by_unit 的工序),却还没有开着"已放电并核实"
--   (逐模组的结论还没凑满:没记模组数、结果没记完、有模组要再放电)。item_id = 那一批最晚的那一炉;subject = 批号。
--   discharge_quarantine_pending —— 一批里有模组最新一条结论是"失败、处置为隔离",还没拆走。item_id = 那一批最晚的那一炉(拆分从那一页上起);
--   subject = 批号。拆走、或更正了那一条,它就消失。
-- ★ MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q24,Tim):加一支 contamination_check_missing —— 一个班、一条流没有抽检
--   (那一天那一班有一张 MES-4a 起记的、已提交没回滚的单产出了这条流的极片,而同一天同一班任何一张单上都没有一条当前的抽检,
--   两种都算 —— contamination_shift_status_all 的 check_state = 'missing')。门 module.processing.view;item_id = 那一格最早的那一炉
--   (fixture 47:一行提醒要指着一条真实的行),subject = 流。记一条"没抽"(带理由)也关掉它。
-- ★ MES-4a(2026-10-07,MES-0 Q48;MES-4a Step 0 Q22,Tim):加一支 processing_balance_unclosed —— 物料平衡还没结的加工单
--   (MES-4a 起记的、转化型的、已提交没回滚的、最新结平不当前的;processing_run_balance_all 的 balance_state = 'open')。
--   门 module.processing.view;点进去是那张加工单(平衡面板在上面)。只是提醒:月末那一行也只警告,不挡关账。
-- ★ ROLE-1 Batch 2a(2026-09-24,Q9):加一支 supplier_pending_approval —— 等 CFO 批的供应商
--   (action.supplier_approve;只有持这个码的人看得见,点进去由 set_supplier_status 裁)。
--   等了多久从【最后一次送审】起算(supplier_status_history),没有那一行时退回 updated_at。
-- ★ PAY-REQ-1(2026-09-23):加一支 payment_request_pending —— 等 CFO 批的付款申请
--   (module.finance.view;finance 与 cfo 都看得见,点进去由 decide_payment_request 裁谁能批)。
-- ★ PAYROLL-APR-1(2026-09-24):加一支 payroll_request_pending —— 等 CFO 批的工资过账 / 撤销申请
--   (data.view_pay:看得见工资数的人才看得见这一格;点进去由 decide_payroll_request 裁谁能批)。
--   item_id 是【工资期】的 id,不是申请的 —— 申请没有自己的页面,它住在工资期页上。
-- ★ ROLE-1 Batch 4b(2026-09-25):加一支 receipt_price_request_pending —— 等 CFO 批的收货定价申请
--   (data.view_purchase_prices,Tim 的 Q10:看得见采购价的人都看得见这一格;点进去由
--   decide_receipt_price_request 裁谁能批)。item_id 是【收货】的 id —— 申请住在收货页上。
-- ★ APR-5b(2026-09-25):加两支。shipping_release_pending —— 等 CFO 批的发货放行(module.sales.view:
--   读得到放行的人都看得见这一格;点进去由 decide_shipping_release 裁谁能批);item_id 是【订单】的 id ——
--   放行住在订单页上。shipping_release_ready —— 放行过、还有没发完的订单(action.ship_goods:仓库的信号;
--   剩余与发货队列读同一张 sales_order_line_releasable_all;点进去是 /logistics/shipping)。
-- ★ APR-6(2026-09-25):加一支 journal_request_pending —— 等 CFO 批的手工凭证 / 冲销申请
--   (module.finance.view:读得到凭证的人都看得见这一格;点进去由 decide_journal_request 裁谁能批)。
--   item_id 是【申请】的 id —— 一张手工凭证在批准之前还没有分录,申请住在凭证列表页上(/finance/journal)。
--   subject 是摘要 / 冲销理由(申请没有对手方)。
-- ★ APR-7(2026-09-25):加一支 warehouse_request_pending —— 等 CFO 批的注销 / 回滚 / 证书作废申请
--   (module.finance.view:与 decide_warehouse_request 的门同一个码;点进去由它裁谁能批)。item_id 是【申请】的 id ——
--   申请住在库存页上(/inventory#wr-<id>);subject 是提单人的理由。
-- ★ APR-8(2026-09-26):加一支 terms_request_pending —— 等 CFO 批的定价公式 / 合同生效申请
--   (module.pricing.view:公式页的门,cfo 持;点进去由 decide_terms_request 裁谁能批)。item_id 是【申请】的 id;
--   doc_kind 分开两处住址:formula → 公式列表页(/tools/pricing/formulas#tr-<id>),contract → 合同页(/contracts#tr-<id>)。
--   subject 是提单人的理由。
-- ★ APR-9(2026-09-27):加两支。asset_disposal_pending —— 等 CFO 批的固定资产处置申请(module.finance.view:与
--   decide_asset_disposal_request 的门同一个码;item_id 是【申请】的 id,住在资产页 /finance/assets#adr-<id>)。
--   salary_change_pending —— 等批的调薪申请(data.view_pay:看得见工资的人 —— 财务、CFO、cco;谁能批由
--   decide_salary_change_request 按人裁)。★ item_id 是【员工】的 id:申请住在那个人的档案页
--   (/hr/employees/<id>#salary-requests);item_code 是 label,subject 是提单人的理由。月薪数不进这张视图。
-- ★ APR-10(2026-09-27):加一支 gst_filing_pending —— 等 CFO 批的 GST 申报申请(module.finance.view:与
--   decide_gst_filing_request 的门同一个码)。★ item_id 是【期间】的 id:申请住在那一期的页面上
--   (/finance/gst/<id>#gst-filing);item_code 是 label,subject 是提单人的附言(可空)。
--
-- 【为什么是一张视图而不是九个页面各查各的】仪表盘的每一块牌子背后都是"有多少件
-- 事在等"这一类问题;九个问题九处写,就是九份会各自漂移的实现。hr_alerts 已经证明
-- 过这个形状:一个 UNION,每一种等待状态一支,页面只负责画。
--
-- 【属主权限 + 每支自带 permission 列,外层一次性把关】(OPS-14 修法 (a))。
-- 本视图横跨六个模块,invoker 会让 RLS 把读者无权模块的行【静默丢掉】—— 行消失
-- 在这里意味着"那个数少算了",而不是报错。属主权限读全量,外层
-- WHERE has_permission(a.permission) 按【调用者】逐支裁决:无权的支【整支缺席】,
-- 不是零。谓词写一次而不是九遍 —— hr_alerts 的注释说过,复述 N 遍只会给下一个
-- 加支的人留一个漏写的机会;这里每支【声明】自己的权限码,外层【执行】它。
--
-- 【缺席 ≠ 零,页面必须自己分辨】视图对无权读者不发一行,于是"没有行"有两种
-- 含义:真的零,或者你看不见。app/page.tsx 先查权限再渲染每块牌子 —— 无权显示
-- 「受限」(common.restricted),绝不显示 0。这是仪表盘最容易犯、且任何 gate 都
-- 查不出的那个错(0 与"你看不见"在屏幕上一模一样 —— moduleGuard 的老病换了件衣服)。
--
-- 【item_type 写成 'x'::text 字面量】check-i18n 的 sqlLiteralAs 解析器现读本文件,
-- dashboard.item.* 的后缀集合就是这里的支列表 —— 加一支,键检查自动跟着变宽。
--
-- 【两笔贵的读数,按界所限】(OPS-16 报告点名的两处):
--   * fx_rate_gaps 按 (日期,币种) 对每组跑 fx_rate_asof,本身不受期间约束 ——
--     这里限 rate_date >= CURRENT_DATE - 45:仪表盘答"最近有没有漏",完整历史
--     归 /finance/month-end 按月翻。谓词落在分组键上,能下推进聚合。
--   * 银行对账这支【只数报表侧的未匹配行】(bank_statement_lines,行数 = 导入量,
--     天然有界)。bank_reconciliation_status 的账簿侧 LATERAL 要扫 journal_lines
--     全表 —— 那是对账页的活,不上人人都开的首页。
--
-- 【不在此列的】批次毛利 —— 有未决的设计问题(哪些限定词随数字走、已过账 COGS
-- 还是当前成本),自成一切,谓词已录在 AGENTS.md 常设决定 2。月结的七个信号 ——
-- /finance/month-end 是它们的枢纽,首页放一个入口,不复制信号。
--
-- NOTE: introduced by db/migrations/2026-08-09-ops18-operations-now-and-the-dashboard.sql.
-- EXEC-3a(2026-08-16):再【两】支 —— work_order_overdue 与
-- work_order_variance_beyond(WO-1c 记下的两个候选)。差异那一支的两个阈值
-- 现读 processing_settings,【两个数不是一个】(投入超耗是成本问题、
-- 产出短交是收率问题,合成一个数等于说它们一样严重)。
-- 【本刀一度加了资质那两支,而它们 CMP-2 就已经在了】—— 清单文件里那行
-- "Candidate, not built" 是过时的,重复分支由 fixture 37C 与 30A 当场抓住,
-- fu1 撤掉。见 db/migrations/2026-08-16-exec3a-fu1-*.sql。
-- 【batch_margin 撤了】:一个卖出去的批次毛利偏低是一个【状态】,没有清除动作 ——
-- 看板装的是待办,毛利的家是 /margin;可处理的那一半已经是 arm 15。
--
-- EXEC-1a(2026-08-16):两支高管臂 —— metal_quote_stale(行情陈旧,阈值现读
-- pricing_settings.metal_quote_stale_days,按 price_date 不按 created_at)与
-- orders_unfulfilled(confirmed / partially_shipped 的订单)。规格见
-- docs/dashboard-arm-inventory.md;【谁要看哪一支】见 docs/exec-views-plan.md。
--
-- OPS-19(2026-08-09):补上原始定稿漏掉的四支(awaiting_assay / batch_unpriced /
-- invoice_overdue / ar_over_90 + ap_over_90),并新增 output_unsold_aging —— sales
-- 这一行唯一够得着的支(它没有 module.finance.view,当初猜的 AR 支对它同样是「受限」)。
-- assay_unapplied 的粒度同时从"一份未执行化验一行"改成"一个批次一行",与
-- awaiting_assay 同源同粒度、互斥;live 该支当时为 0,故不改变任何现有数字。
--
-- ── SUP-TYPE-1a(2026-08-18):qualification_missing 收窄到【供货的】供应商 ──
-- EXEC-3a 在 2026-08-16-exec3a-four-executive-arms.sql:349 写着:判据是"一张都没有"
-- 而不是"缺某一类",因为没有一张"谁必须持哪张证"的要求矩阵;并且明写着
-- **"有了'这家需要合规文件'的标记之后,这一支应当收窄到它"**。
-- **那个标记现在有了(suppliers.supplies_goods),这一支已经收窄,那句话到此退休。**
-- 提交信息改不了历史文件,所以退休记录写在这里 —— 沿着引用走过来的人在这里落地。
--
-- 【为什么必须收窄:实测过的永久亮灯】SUP-TYPE-0 把它走了一遍:把一个只收钱、
-- 不供货的往来户沿合法路径推到 status='active',这一支当场亮起、days_waiting 一路
-- 长下去,而它永远不会灭 —— 房东不会去办危废证。收窄之后同样的走法【不再亮】,
-- 而一个没有证书的【真供应商】仍然照亮(fixture 89 两边都钉)。
--
-- CMP-1(2026-08-09):两支资质臂。qualification_expiring 到【类型自己的 lead days】就上牌,
-- 过期后【不落牌、无 -30 天下限】—— 工作证过期 30 天人已走,证书过期两年而进场仍可能,
-- 它就还站在那儿(live 那张 2024 年就过期的 Article 18 正是证据)。续期(valid_until
-- 前移)即安静。qualification_missing 是"一张证都没有"的缺席臂(与 awaiting_assay /
-- assay_unapplied 的分立同理)。disposition='ignore' 的类型不上牌。
-- 【规格在 docs/dashboard-arm-inventory.md】每一支是什么意思、挂哪个权限码、界在
-- 哪里、以及【哪些支被考虑过又被排除、为什么】都在那里。
-- 定稿只存在于一次对话里,代价是四支 —— 所以规矩是:
-- 【加一支 = 在同一个提交里往那份清单加一行】。
--
-- MAR-1(2026-08-10):支的权限从【一个码】放宽到【一个谓词】—— permission(必须有)
-- + permission_any(任意其一,由 arm_permission_any 一处声明,SELECT 与 WHERE 共用)。
-- 起因是批次毛利跨两个模块(prices AND (finance OR processing)),而没有任何 live 角色
-- 同时持有后两者。合成一个新权限码那条路被否掉:那会是谁能看毛利的第二份定义,
-- 与 batch_margin 自己的谓词必然漂开。fixture 45 三种读者各钉一次。
-- ASY-P1(2026-08-17):awaiting_assay 那一支【换了问题】。原来问的是"这个批次一份
-- 化验都没有"(batch_assay_status.assay_count = 0),它看不见"化验做了一半",
-- 也灭不掉料已耗尽那两盏灯(线上 IN-2026-0011 / IN-2026-0153,remaining_qty = 0)。
-- 现在读 batch_required_assay_gaps:物料声明了要验哪些金属、其中至少一种还没有被
-- 一份【已应用的】化验覆盖、并且【还取得到样】。subject 从供应商名换成【缺哪几种
-- 金属】—— subject 这一列在每一支里放的都是那一支最该让人看见的事实,而能让人
-- 下一步动起来的是缺哪几种。判据与理由住在那张视图里,不在这里。
-- LINKS-1(2026-08-11):每支多带一个 item_id —— 支从"指向一张列表"变成"指向那一件事"。
-- 【item_id 指的是谁】承载【补救动作】的那张页面所对应的行。十七支里它就是等待中的
-- 那一行;两支里是它的父:bank_unmatched(行没有页面,匹配动作在对账工作台上 →
-- 对账单)与 margin_cost_not_allocated(补救是给加工单分摊成本 → 加工单)。
-- 于是同一支的几行可以共用一个 item_id,那是对的,不是重复 —— fixture 47 因此断言
-- 的是"item_id 落在这一支该落的那张表里",不是"一行一个 id",也不是互不相同。
-- 【SO-3a:应收也成了两种单据】ar_over_90 的 doc_kind 从此非空('sale' 销售记录 /
-- 'invoice' 订单流发票),item_id 相应二选一 —— 门牌各是应收单据页与发票页,
-- app/page.tsx 按 doc_kind 分支,认不出的种类不给链接(与 ap 同一条)。
-- 【doc_kind 是披露】应付账款本来就是两种单据(ap_open_items 自己就按它分支,
-- 应付列表页也一直照它画链接),这张视图先前只是没说出口。其余十八支主体只有一种,
-- 该列为 NULL。【fx_rate_gap 没有 item_id】它的主体是一条不存在的牌价行,缺的东西
-- 没有 id —— 它指向按币种过滤的列表,那是"诚实过滤的列表"那类答案,不是按码搜索。
-- 每支的门牌与"补救是否在那张页面上"这条判据,写在 docs/dashboard-arm-inventory.md。
-- NOTE: item_id / doc_kind added by
-- db/migrations/2026-08-11-links1-operations-now-item-id.sql(列集变了 → DROP + CREATE)。
-- SS-1(2026-08-13):第二十支 safety_stock_below —— 物料的可用量低于它自己的
-- 安全库存阈值。【阈值 NULL 的物料一次都不响】:NULL 是"还没有人决定要盯它",
-- 不是"阈值为零",而把不响读成"查过了没问题"正是 METAL-1 的那一课。
-- 可用量来自 material_stock_available(一处求和,暂扣不算 —— 阈值问的是"还有多少
-- 能用的货",一次暂扣若能掩盖缺货,这个告警就在最该说话的时刻哑掉)。
-- item_date 用【最后一次库存移动】退回今天:阈值告警是持续状态,没有发生日;
-- 去算"哪天跌破的"要在首页翻整段流水史,那条界不允许(credit_over_limit 同形)。

-- LOG-5a(2026-08-20):第 23–26 支 —— 物流的四支告警。全部是【臂】(算出来、
-- 会自愈),不是 notifications 的事件。末尾的 WHERE 多了一个【放宽】算子
-- arm_permission_widen():它与收窄用的 arm_permission_any() 方向相反,
-- 对除 free_time_expiring 以外的每一支都返回 NULL(fixture 102G 逐支断言)。
-- LOG-5d(2026-08-20):同一种里程碑之内,算数的是【最后被录入】的那一条
-- (recorded_at DESC, id DESC)。此前按 event_date DESC 排,于是一条把日期
-- 改【早】的更正永远排不到前面、一次都不会生效(线上 CTR-2026-0009)。
-- EQP-2c(2026-08-21):第 27–28 支 —— 保养【到期】与【将到期】,两支不是一支。
-- 列契约一字未动。规格见 docs/dashboard-arm-inventory.md;推导与它的基线
-- (那两条"低读数有两种意思"的事实)整段写在 equipment_service_status 的视图注释里。
-- 【放宽】两支都走 arm_permission_widen(processing OR finance)—— 机器卡在财务、
-- 干活的人在加工,而它们底下每一张表/视图的读者都是这两个码的 OR。
-- CMPL-1(2026-08-30)追加两支:
--   · company_licence_expiring —— **形状逐字取自 qualification_expiring**,只是把
--     supplier_compliance 换成 company_compliance(少一跳供应商)。它读的仍是
--     certificate_types 自带的 warn_lead_days 与 disposition,所以 gwc 加进字典那天
--     它的到期提醒【自动就有】。**没有另起一套到期机制。**
--   · import_permit_unverified —— 是进口货、而那张进口准证还没有人核过。
--     **它不拦任何东西**:拦的那一半由 nea_import 的 block 处置在收货上做
--     (supplier_receiving_blocked → trg_inbound_batches_po_receivable),
--     这一支说的是"这一票还欠一次人工核对"。理由见 db/tables/inbound_batches.sql 的列注。
-- MES-1(2026-10-06,MES-1 Step 0 Q16 · Q17 · Q23,Tim):第 48–49 支 ——
--   · gateway_silent:一台网关此刻在沉默 —— 它的心跳间隔给了,而最后一次听到它已经超过那个间隔(gateway_health.status = silent)。
--     一次都没听到过的("Not yet heard from")与间隔没给的("Not yet set")【不上牌】:前者是还没调试的正常状态(Q16),
--     后者是沉默无从判断(Q17)。item_id = 那台网关(/operation/devices/[id])。
--   · capture_inbox_failed:收件箱里有转换失败的行 —— 按设备合成一块(item_id = 设备,subject = 设备名 · 失败行数,
--     item_date = 最早的那一行)。不为 awaiting_transform 上牌:那是每一个还没接上转换器的类的正常状态(Q23)。
--   两支都只要 module.processing.view;规格在 docs/dashboard-arm-inventory.md。
-- MES-2(2026-10-06,MES-0 Q13;MES-2 Step 0 Q29 · Q32,Tim):第 50–52 支 ——
--   · capture_draft_pending:一张网关送来的草稿还没人确认 —— 一张一行,item_date = 落草稿那一天,所以 days_waiting 就是它的年龄
--     (草稿永不过期,MES-0 Q13)。门是 action.confirm_capture(能确认它的人才需要被催)。手工录入的草稿生下来就确认了,不上牌。
--   · instrument_calibration_due:一台【在用的】仪器(interface_status 不是 reserved,没停用)今天不在校准期内 —— 过期、没通过、
--     或从来没校过。item_date = 有效期(从来没校过的取它登记那一天)。
--   · instrument_calibration_approaching:在期内、有效期落在 V8 给的提前天数里。V8(calibration_lead_days)没给 → 这一支恒为空,
--     过期本身照样由上一支上牌(每一条记录自己的有效期是必填的)。
--   后两支读 instrument_calibration_now(属主视图,一份挑法、一句判据),门是 module.processing.view。
-- MES-3a(2026-10-06,MES-0 Q13 · Q35 · Q34;MES-3a Step 0 Q13 · Q16 · Q20,Tim):第 53–55 支 —— 三支都【只提醒,不拒】——
--   · storage_ceiling_exceeded:今天在效的执照下,一类 NEA 废物(或总量)的存量超过了给了的上限(storage_ceiling_status.status = exceeded)。
--     收货在超之前就被拒了,所以走到这里的是别的路:加工把料变成了另一类、回滚还回了料、上限被调低了。item_id = 执照,
--     item_code = 类别(总量是 *),门 module.inventory.view。
--   · safety_state_dwell:一批还在厂里的货,身上一条开着的状态待满了它的 dwell_warning_days(V3;没给的不上牌)。
--     一批 × 一条状态一行;item_date = 那条状态被记下的那一天,所以 days_waiting 就是它待了多久。doc_kind = inbound / output,
--     门逐行:进料 module.inbound.view,产出 module.output.view。
--   · quarantine_required:一批身上开着一条要隔离的状态(鼓包或漏液),却还有货放在非隔离库位(quarantine_exposure)。
--     一批 × 一个库位桶一行;doc_kind 与门同上;item_date = 那条状态被记下的那一天。
CREATE VIEW public.operations_arms_all AS
 SELECT item_type,
    permission,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date
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
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
        UNION ALL
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text AND w.scheduled_date IS NOT NULL AND w.scheduled_date < CURRENT_DATE
        UNION ALL
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
                CASE
                    WHEN f.side = 'input'::text THEN (((('input overrun · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                    ELSE (((('output shortfall · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan AND f.planned_or_expected_qty > 0::numeric AND (f.side = 'input'::text AND (w2.status = ANY (ARRAY['released'::text, 'closed'::text])) AND f.actual_qty > (f.planned_or_expected_qty * (1::numeric + (( SELECT ps.wo_input_overrun_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)) OR f.side = 'output'::text AND w2.status = 'closed'::text AND f.actual_qty < (f.planned_or_expected_qty * (1::numeric - (( SELECT ps.wo_output_shortfall_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)))
        UNION ALL
         SELECT 'free_time_expiring'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            ((((q.free_days - (CURRENT_DATE - arr.event_date))::text) || ' left of '::text) || q.free_days::text) || COALESCE(' — '::text || f.legal_name, ''::text) AS subject,
            arr.event_date AS item_date
           FROM containers c
             LEFT JOIN suppliers f ON f.id = c.forwarder_id
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'arrived'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) arr ON true
             JOIN forwarder_rate_quotes q ON q.supplier_id = c.forwarder_id AND q.lane_id = c.lane_id AND q.deleted_at IS NULL AND c.departure_date >= q.valid_from AND c.departure_date <= q.valid_to
          WHERE c.deleted_at IS NULL AND q.free_days IS NOT NULL AND (q.free_days - (CURRENT_DATE - arr.event_date)) <= 2
        UNION ALL
         SELECT 'container_no_arrival'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            dep.event_date::text AS subject,
            dep.event_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'departed'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) dep ON true
          WHERE c.deleted_at IS NULL AND (CURRENT_DATE - dep.event_date) >= 14 AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m2
                  WHERE m2.container_id = c.id AND m2.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_eta_overdue'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            c.expected_arrival_date::text AS subject,
            c.expected_arrival_date AS item_date
           FROM containers c
          WHERE c.deleted_at IS NULL AND c.expected_arrival_date IS NOT NULL AND c.expected_arrival_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m3
                  WHERE m3.container_id = c.id AND m3.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_documents_late'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            p.n::text || ' pending'::text AS subject,
            c.departure_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT count(*) AS n
                   FROM container_documents d
                  WHERE d.container_id = c.id AND d.status = 'pending'::text) p ON true
          WHERE c.deleted_at IS NULL AND p.n > 0 AND (CURRENT_DATE - c.departure_date) >= 7
        UNION ALL
         SELECT 'equipment_service_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess.equipment_code AS item_code,
            (ess.service_kind || ' — '::text) || ess.equipment_description AS subject,
            ess.baseline_date AS item_date
           FROM equipment_service_status ess
          WHERE ess.monitored AND ess.disposition = 'warn'::text AND ess.equipment_status <> 'disposed'::text AND ess.is_due
        UNION ALL
         SELECT 'equipment_service_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess_1.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess_1.equipment_code AS item_code,
            (ess_1.service_kind || ' — '::text) || ess_1.equipment_description AS subject,
            ess_1.baseline_date AS item_date
           FROM equipment_service_status ess_1
          WHERE ess_1.monitored AND ess_1.disposition = 'warn'::text AND ess_1.equipment_status <> 'disposed'::text AND ess_1.is_approaching
        UNION ALL
         SELECT 'gateway_silent'::text AS item_type,
            'module.processing.view'::text AS permission,
            gh.gateway_id AS item_id,
            NULL::text AS doc_kind,
            gh.code AS item_code,
            gh.name AS subject,
            gh.last_heard_at::date AS item_date
           FROM gateway_health gh
          WHERE gh.status = 'silent'::text
        UNION ALL
         SELECT 'capture_inbox_failed'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.device_id AS item_id,
            NULL::text AS doc_kind,
            f.device_code AS item_code,
            (f.device_name || ' · '::text) || f.failed_rows::text AS subject,
            f.first_failed AS item_date
           FROM ( SELECT b.device_id,
                    d.code AS device_code,
                    d.name AS device_name,
                    count(*) AS failed_rows,
                    min(b.received_at)::date AS first_failed
                   FROM ingest_inbox b
                     JOIN devices d ON d.id = b.device_id
                  WHERE b.status = 'failed'::text
                  GROUP BY b.device_id, d.code, d.name) f
        UNION ALL
         SELECT 'capture_draft_pending'::text AS item_type,
            'action.confirm_capture'::text AS permission,
            cd.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(dv.code, cd.data_class) AS item_code,
            (COALESCE(dv.name, cd.data_class) || ' · '::text) || COALESCE((cd.proposed ->> 'weight_kg'::text) || ' kg'::text, cd.data_class) AS subject,
            cd.created_at::date AS item_date
           FROM capture_drafts cd
             LEFT JOIN devices dv ON dv.id = cd.device_id
          WHERE cd.status = 'pending'::text
        UNION ALL
         SELECT 'instrument_calibration_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ic.device_id AS item_id,
            NULL::text AS doc_kind,
            ic.code AS item_code,
            (ic.name || ' · '::text) || ic.status AS subject,
            COALESCE(ic.valid_until, ic.registered_at::date) AS item_date
           FROM instrument_calibration_now ic
          WHERE ic.in_use AND ic.status <> 'in_calibration'::text
        UNION ALL
         SELECT 'instrument_calibration_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ic.device_id AS item_id,
            NULL::text AS doc_kind,
            ic.code AS item_code,
            ic.name AS subject,
            ic.valid_until AS item_date
           FROM instrument_calibration_now ic
          WHERE ic.in_use AND ic.approaching
        UNION ALL
         SELECT 'storage_ceiling_exceeded'::text AS item_type,
            'module.inventory.view'::text AS permission,
            sc.licence_id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(sc.category_code, '*'::text) AS item_code,
            (((sc.cert_no || ' · '::text) || sc.name_en) || ' · '::text) || round(sc.on_hand_t, 3)::text || ' / '::text || sc.limit_tonnes::text || ' t'::text AS subject,
            (now() AT TIME ZONE 'Asia/Singapore'::text)::date AS item_date
           FROM storage_ceiling_status sc
          WHERE sc.status = 'exceeded'::text
        UNION ALL
         SELECT 'safety_state_dwell'::text AS item_type,
                CASE dw.batch_kind
                    WHEN 'inbound'::text THEN 'module.inbound.view'::text
                    ELSE 'module.output.view'::text
                END AS permission,
            dw.batch_id AS item_id,
            dw.batch_kind AS doc_kind,
            dw.batch_code AS item_code,
            dw.name_en AS subject,
            dw.recorded_on AS item_date
           FROM safety_state_dwell dw
          WHERE dw.dwell_status = 'past'::text AND dw.on_site
        UNION ALL
         SELECT 'quarantine_required'::text AS item_type,
                CASE qe.batch_kind
                    WHEN 'inbound'::text THEN 'module.inbound.view'::text
                    ELSE 'module.output.view'::text
                END AS permission,
            qe.batch_id AS item_id,
            qe.batch_kind AS doc_kind,
            qe.batch_code AS item_code,
            (qe.name_en || ' · '::text) || COALESCE(qe.location_code, 'unspecified'::text) AS subject,
            qe.recorded_on AS item_date
           FROM quarantine_exposure qe
        UNION ALL
         SELECT 'promise_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            ps.promise_id AS item_id,
            NULL::text AS doc_kind,
            ps.chase_code AS item_code,
            ps.customer_name AS subject,
            ps.promised_date AS item_date
           FROM collection_promise_status ps
          WHERE ps.is_overdue
        UNION ALL
         SELECT 'wht_due'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            to_char(w.period_month::timestamp without time zone, 'YYYY-MM'::text) AS item_code,
            (to_char(w.unremitted_base, 'FM999G999G990D00'::text) || ' '::text) || (( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base)) AS subject,
            w.due_date AS item_date
           FROM wht_liability_by_month w
          WHERE w.unremitted_base > 0::numeric AND (w.due_date - CURRENT_DATE) <= 7
        UNION ALL
         SELECT 'company_licence_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(cc.cert_no, ct.code) AS item_code,
            ct.name_en AS subject,
            cc.valid_until AS item_date
           FROM company_compliance cc
             JOIN certificate_types ct ON ct.code = cc.cert_type_code
          WHERE cc.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND cc.valid_until IS NOT NULL AND cc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'import_permit_unverified'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            ib.code AS item_code,
            s.legal_name AS subject,
            ib.arrival_date AS item_date
           FROM inbound_batches ib
             JOIN suppliers s ON s.id = ib.supplier_id
          WHERE ib.deleted_at IS NULL AND ib.imported IS TRUE AND ib.import_permit_verified_at IS NULL
        UNION ALL
         SELECT 'payment_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            pr.id AS item_id,
            NULL::text AS doc_kind,
            pr.code AS item_code,
            COALESCE(s.legal_name, e.legal_name, c.legal_name) AS subject,
            pr.created_at::date AS item_date
           FROM payment_requests pr
             LEFT JOIN suppliers s ON s.id = pr.supplier_id
             LEFT JOIN employees e ON e.id = pr.employee_id
             LEFT JOIN customers c ON c.id = pr.customer_id
          WHERE pr.status = 'submitted'::text
        UNION ALL
         SELECT 'supplier_pending_approval'::text AS item_type,
            'action.supplier_approve'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            s.legal_name AS subject,
            COALESCE(( SELECT max(h.changed_at) AS max
                   FROM supplier_status_history h
                  WHERE h.supplier_id = s.id AND h.to_status = 'pending_review'::text), s.updated_at)::date AS item_date
           FROM suppliers s
          WHERE s.status = 'pending_review'::supplier_status AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'payroll_request_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            q.payroll_period_id AS item_id,
            NULL::text AS doc_kind,
            q.label AS item_code,
            pp.code AS subject,
            q.created_at::date AS item_date
           FROM payroll_requests q
             JOIN payroll_periods pp ON pp.id = q.payroll_period_id
          WHERE q.status = 'submitted'::text
        UNION ALL
         SELECT 'receipt_price_request_pending'::text AS item_type,
            'data.view_purchase_prices'::text AS permission,
            rq.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            rq.label AS item_code,
            ib.code AS subject,
            rq.created_at::date AS item_date
           FROM receipt_price_requests rq
             JOIN inbound_batches ib ON ib.id = rq.inbound_batch_id
          WHERE rq.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            iq.invoice_id AS item_id,
            NULL::text AS doc_kind,
            iq.label AS item_code,
            c.legal_name AS subject,
            iq.created_at::date AS item_date
           FROM invoice_requests iq
             JOIN invoices i ON i.id = iq.invoice_id
             JOIN customers c ON c.id = i.customer_id
          WHERE iq.status = 'submitted'::text
        UNION ALL
         SELECT 'shipping_release_pending'::text AS item_type,
            'module.sales.view'::text AS permission,
            sr.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            sr.label AS item_code,
            c.legal_name AS subject,
            sr.created_at::date AS item_date
           FROM shipping_releases sr
             JOIN sales_orders so ON so.id = sr.sales_order_id
             JOIN customers c ON c.id = so.customer_id
          WHERE sr.status = 'submitted'::text
        UNION ALL
         SELECT 'journal_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            jq.id AS item_id,
            NULL::text AS doc_kind,
            jq.label AS item_code,
            jq.memo AS subject,
            jq.created_at::date AS item_date
           FROM journal_requests jq
          WHERE jq.status = 'submitted'::text
        UNION ALL
         SELECT 'warehouse_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            wq.id AS item_id,
            NULL::text AS doc_kind,
            wq.label AS item_code,
            wq.reason AS subject,
            wq.created_at::date AS item_date
           FROM warehouse_requests wq
          WHERE wq.status = 'submitted'::text
        UNION ALL
         SELECT 'terms_request_pending'::text AS item_type,
            'module.pricing.view'::text AS permission,
            tq.id AS item_id,
                CASE
                    WHEN tq.contract_id IS NOT NULL THEN 'contract'::text
                    ELSE 'formula'::text
                END AS doc_kind,
            tq.label AS item_code,
            tq.reason AS subject,
            tq.created_at::date AS item_date
           FROM terms_requests tq
          WHERE tq.status = 'submitted'::text
        UNION ALL
         SELECT 'asset_disposal_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            dq.id AS item_id,
            NULL::text AS doc_kind,
            dq.label AS item_code,
            dq.reason AS subject,
            dq.created_at::date AS item_date
           FROM asset_disposal_requests dq
          WHERE dq.status = 'submitted'::text
        UNION ALL
         SELECT 'salary_change_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            sq.employee_id AS item_id,
            NULL::text AS doc_kind,
            sq.label AS item_code,
            sq.reason AS subject,
            sq.created_at::date AS item_date
           FROM salary_change_requests sq
          WHERE sq.status = 'submitted'::text
        UNION ALL
         SELECT 'gst_filing_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            gq.period_id AS item_id,
            NULL::text AS doc_kind,
            gq.label AS item_code,
            gq.note AS subject,
            gq.created_at::date AS item_date
           FROM gst_filing_requests gq
          WHERE gq.status = 'submitted'::text
        UNION ALL
         SELECT 'processing_balance_unclosed'::text AS item_type,
            'module.processing.view'::text AS permission,
            b.run_id AS item_id,
            NULL::text AS doc_kind,
            b.run_code AS item_code,
            b.operation_type_code AS subject,
            b.process_date AS item_date
           FROM processing_run_balance_all b
          WHERE b.balance_state = 'open'::text
        UNION ALL
         SELECT 'contamination_check_missing'::text AS item_type,
            'module.processing.view'::text AS permission,
            cs.first_run_id AS item_id,
            NULL::text AS doc_kind,
            cs.first_run_code AS item_code,
            cs.stream_code AS subject,
            cs.process_date AS item_date
           FROM contamination_shift_status_all cs
          WHERE cs.check_state = 'missing'::text
        UNION ALL
         SELECT 'discharge_unverified'::text AS item_type,
            'module.processing.view'::text AS permission,
            ds.latest_run_id AS item_id,
            NULL::text AS doc_kind,
            ds.latest_run_code AS item_code,
            ds.batch_code AS subject,
            ds.latest_run_date AS item_date
           FROM discharge_batch_status_all ds
          WHERE ds.latest_run_id IS NOT NULL AND NOT ds.currently_verified
        UNION ALL
         SELECT 'discharge_quarantine_pending'::text AS item_type,
            'module.processing.view'::text AS permission,
            ds.latest_run_id AS item_id,
            NULL::text AS doc_kind,
            ds.latest_run_code AS item_code,
            ds.batch_code AS subject,
            ds.latest_run_date AS item_date
           FROM discharge_batch_status_all ds
          WHERE ds.failed_quarantine > 0 AND ds.latest_run_id IS NOT NULL
        UNION ALL
         SELECT 'shipping_release_ready'::text AS item_type,
            'action.ship_goods'::text AS permission,
            q.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            q.order_code AS item_code,
            q.customer_name AS subject,
            q.released_on AS item_date
           FROM ( SELECT so.id AS sales_order_id,
                    so.code AS order_code,
                    c.legal_name AS customer_name,
                    max(r.decided_at)::date AS released_on
                   FROM shipping_releases r
                     JOIN shipping_release_lines rl ON rl.release_id = r.id
                     JOIN invoice_lines il ON il.id = rl.invoice_line_id
                     JOIN sales_orders so ON so.id = r.sales_order_id
                     JOIN customers c ON c.id = so.customer_id
                  WHERE r.status = 'approved'::text AND NOT il.invoice_voided
                    AND so.deleted_at IS NULL
                    AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
                    AND (( SELECT ra.releasable_qty
                           FROM sales_order_line_releasable_all ra
                          WHERE ra.invoice_line_id = il.id)) > COALESCE(( SELECT sum(sl.qty) AS sum
                           FROM shipment_lines sl
                          WHERE sl.sales_order_line_id = rl.sales_order_line_id), 0::numeric)
                  GROUP BY so.id, so.code, c.legal_name) q
        UNION ALL
         SELECT 'sample_retention_due'::text AS item_type,
            'module.quality.view'::text AS permission,
            sr.id AS item_id,
            NULL::text AS doc_kind,
            sr.code AS item_code,
            sr.batch_code AS subject,
            sr.retain_until AS item_date
           FROM ( SELECT s.id,
                    s.code,
                    COALESCE(ib.code, ob.code) AS batch_code,
                    s.retain_until
                   FROM samples s
                     LEFT JOIN inbound_batches ib ON ib.id = s.inbound_batch_id
                     LEFT JOIN output_batches ob ON ob.id = s.output_batch_id
                  WHERE s.retain_until IS NOT NULL AND s.retain_until < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                           FROM sample_events e
                          WHERE e.sample_id = s.id AND e.event_kind = 'disposed'::text))) sr
        UNION ALL
         SELECT 'assay_dispute_open'::text AS item_type,
            'module.quality.view'::text AS permission,
            d.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(ib.code, ob.code) AS item_code,
            (ao.code || ' / '::text) || ac.code AS subject,
            d.created_at::date AS item_date
           FROM assay_disputes d
             LEFT JOIN inbound_batches ib ON ib.id = d.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = d.output_batch_id
             JOIN assay_results ao ON ao.id = d.our_assay_id
             JOIN assay_results ac ON ac.id = d.counterparty_assay_id
          WHERE d.status = 'open'::text
        UNION ALL
         SELECT 'assay_results_disagree'::text AS item_type,
            'module.quality.view'::text AS permission,
            ad.output_batch_id AS item_id,
            NULL::text AS doc_kind,
            ad.batch_code AS item_code,
            ad.sales_order_code AS subject,
            ad.latest_assay_date AS item_date
           FROM assay_disagreements_all ad
        UNION ALL
         SELECT 'ncr_open'::text AS item_type,
            'module.quality.view'::text AS permission,
            n.id AS item_id,
            NULL::text AS doc_kind,
            n.code AS item_code,
            COALESCE(ib.code, ob.code) AS subject,
            n.opened_at::date AS item_date
           FROM nonconformance_reports n
             LEFT JOIN inbound_batches ib ON ib.id = n.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = n.output_batch_id
          WHERE n.status = 'open'::text
        UNION ALL
         SELECT 'quality_hold_reserved'::text AS item_type,
            'module.quality.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            (h.batch_code || ' · '::text) || h.ncr_code AS subject,
            min(r.created_at)::date AS item_date
           FROM sales_order_reservations r
             JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             JOIN sales_orders so ON so.id = l.sales_order_id
             CROSS JOIN LATERAL batch_quality_hold(NULL::uuid, r.output_batch_id) h(ncr_id, ncr_code, batch_code)
          WHERE r.released_at IS NULL AND r.consumed_at IS NULL AND so.deleted_at IS NULL
          GROUP BY so.id, so.code, h.batch_code, h.ncr_code
        UNION ALL
         SELECT 'coa_facts_changed'::text AS item_type,
            'action.issue_coa'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            (ob.code || ' · '::text) || f.what AS subject,
            f.found_on AS item_date
           FROM certificates_of_analysis c
             JOIN output_batches ob ON ob.id = c.output_batch_id
             CROSS JOIN LATERAL ( SELECT x.what,
                    x.found_on
                   FROM ( SELECT a.code AS what,
                            a.created_at AS found_at,
                            a.created_at::date AS found_on
                           FROM assay_results a
                          WHERE a.output_batch_id = c.output_batch_id AND a.deleted_at IS NULL AND a.created_at > c.issued_at
                        UNION ALL
                         SELECT n.code,
                            n.opened_at,
                            n.opened_at::date AS opened_at_date
                           FROM nonconformance_reports n
                          WHERE n.output_batch_id = c.output_batch_id AND n.opened_at > c.issued_at) x
                  ORDER BY x.found_at, x.what
                 LIMIT 1) f
          WHERE c.status = 'issued'::text
        UNION ALL
         SELECT 'quality_prompt_ncr'::text AS item_type,
            'module.quality.view'::text AS permission,
            q.batch_id AS item_id,
            q.batch_kind AS doc_kind,
            q.batch_code AS item_code,
            q.evidence AS subject,
            q.found_on AS item_date
           FROM ( SELECT 'inbound'::text AS batch_kind,
                    gb.inbound_batch_id AS batch_id,
                    gb.inbound_batch_code AS batch_code,
                    min(ar.code) AS evidence,
                    min(gb.assay_date) AS found_on,
                    min(ar.created_at) AS found_at
                   FROM contract_grade_breaches gb
                     JOIN assay_results ar ON ar.id = gb.assay_result_id
                  GROUP BY gb.inbound_batch_id, gb.inbound_batch_code
                UNION ALL
                 SELECT 'output'::text,
                    cc.output_batch_id,
                    ob2.code,
                    min(cc.stream_code),
                    min(cc.sampled_at)::date,
                    min(cc.recorded_at)
                   FROM contamination_checks cc
                     JOIN output_batches ob2 ON ob2.id = cc.output_batch_id AND ob2.deleted_at IS NULL
                  WHERE cc.above_warning IS TRUE AND NOT (EXISTS ( SELECT 1
                           FROM contamination_checks x
                          WHERE x.corrects_id = cc.id))
                  GROUP BY cc.output_batch_id, ob2.code
                UNION ALL
                 SELECT dm.batch_kind,
                    dm.batch_id,
                    COALESCE(ib3.code, ob3.code),
                    min(dm.module_ref),
                    min(dm.verdict_at)::date,
                    min(dm.verdict_at)
                   FROM discharge_module_current_all dm
                     LEFT JOIN inbound_batches ib3 ON ib3.id = dm.batch_id AND dm.batch_kind = 'inbound'::text
                     LEFT JOIN output_batches ob3 ON ob3.id = dm.batch_id AND dm.batch_kind = 'output'::text
                  WHERE dm.verdict = 'fail'::text AND NOT dm.split_out
                    AND COALESCE(ib3.deleted_at, ob3.deleted_at) IS NULL AND COALESCE(ib3.id, ob3.id) IS NOT NULL
                  GROUP BY dm.batch_kind, dm.batch_id, ib3.code, ob3.code) q
          WHERE NOT (EXISTS ( SELECT 1
                   FROM nonconformance_reports n2
                  WHERE (n2.inbound_batch_id = q.batch_id OR n2.output_batch_id = q.batch_id) AND n2.opened_at >= q.found_at))
        UNION ALL
         SELECT 'incident_nea_notify_due'::text AS item_type,
            'module.safety.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            k.name_en AS subject,
            c.occurred_on AS item_date
           FROM incident_current_all c
             JOIN incident_kinds k ON k.code = c.kind_code
          WHERE c.nea_reportable AND c.notified_at IS NULL
        UNION ALL
         SELECT 'incident_report_due'::text AS item_type,
            'module.safety.view'::text AS permission,
            c.id AS item_id,
            c.deadline_state AS doc_kind,
            c.code AS item_code,
            k.name_en AS subject,
            COALESCE(c.report_deadline, c.occurred_on) AS item_date
           FROM incident_current_all c
             JOIN incident_kinds k ON k.code = c.kind_code
          WHERE c.nea_reportable AND c.report_submitted_at IS NULL
        UNION ALL
         SELECT 'inspection_due'::text AS item_type,
            'module.safety.view'::text AS permission,
            t.id AS item_id,
            d.due_state AS doc_kind,
            t.code AS item_code,
            t.name AS subject,
            COALESCE(d.next_due_on, (t.created_at AT TIME ZONE 'Asia/Singapore'::text)::date) AS item_date
           FROM inspection_templates t
             JOIN inspection_template_due_all d ON d.id = t.id
          WHERE t.is_active AND d.due_state = ANY (ARRAY['due'::text, 'never_run'::text])
        UNION ALL
         SELECT 'inspection_finding_open'::text AS item_type,
            'module.safety.view'::text AS permission,
            f.id AS item_id,
            f.run_id::text AS doc_kind,
            r.code AS item_code,
            s.item_text AS subject,
            (f.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date AS item_date
           FROM inspection_findings f
             JOIN inspection_runs r ON r.id = f.run_id
             JOIN inspection_results s ON s.id = f.result_id
          WHERE NOT (EXISTS ( SELECT 1
                   FROM inspection_finding_closures c
                  WHERE c.finding_id = f.id))
        UNION ALL
         SELECT 'supplier_review_due'::text AS item_type,
            'action.supplier_review'::text AS permission,
            s.id AS item_id,
            CASE WHEN lr.recorded_at IS NULL THEN 'never_reviewed'::text ELSE 'due'::text END AS doc_kind,
            s.code AS item_code,
            s.legal_name AS subject,
            COALESCE(((lr.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date + ss.review_window_days),
                     (s.created_at AT TIME ZONE 'Asia/Singapore'::text)::date) AS item_date
           FROM suppliers s
             JOIN supplier_score_settings ss ON ss.id AND ss.review_window_days IS NOT NULL
             LEFT JOIN supplier_latest_reviews lr ON lr.supplier_id = s.id
          WHERE s.deleted_at IS NULL AND s.supplies_goods AND (s.status = ANY (ARRAY['approved'::supplier_status, 'active'::supplier_status]))
            AND (lr.recorded_at IS NULL OR ((lr.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date + ss.review_window_days) <= (now() AT TIME ZONE 'Asia/Singapore'::text)::date)
        UNION ALL
         SELECT 'compliance_pack_not_frozen'::text AS item_type,
            'action.compliance_pack'::text AS permission,
            NULL::uuid AS item_id,
            'not_frozen'::text AS doc_kind,
            to_char(m.m, 'YYYY-MM'::text) AS item_code,
            'Compliance pack'::text AS subject,
            (m.m + '1 mon -1 days'::interval)::date AS item_date
           FROM finance_settings fs
             CROSS JOIN LATERAL generate_series(date_trunc('month'::text, fs.system_start_date::timestamp without time zone), date_trunc('month'::text, fs.locked_before::timestamp without time zone), '1 mon'::interval) m(m)
          WHERE fs.system_start_date IS NOT NULL AND fs.locked_before IS NOT NULL
            AND (m.m + '1 mon'::interval)::date <= fs.locked_before
            AND NOT (EXISTS ( SELECT 1
                   FROM compliance_packs cp
                  WHERE cp.period_month = m.m::date AND cp.superseded_at IS NULL))) a;

COMMENT ON VIEW public.operations_arms_all IS
    'MES-8b-2:operations_now 的全部支,不按读者过滤。operations_now 与 floor_board() 都从这里读 —— 支的定义只有这一份。基视图,不给人读。';

REVOKE ALL ON public.operations_arms_all FROM authenticated, anon;

-- ── 5 · 新函数(镜像原样)──────────────

-- db/functions/floor_board_arms.sql
-- MES-8b-2(2026-10-17,MES-8 Step 0 Q20,Tim):【车间大屏画哪几支 —— 一份闭合的清单】。大屏「只有计数,来自 operations_now 的加工、安全与库存那几支」。
--   判据(fixture 273 BOARD 按它逐支核对 operations_arms_all,多一支少一支都红):
--     ① 门是 module.processing.view · module.safety.view · module.inventory.view 的【每一支】(加工 13 · 安全 4 · 库存 2);
--     ② 外加四支车间上的事、门却是别的码:capture_draft_pending(采集的确认队列,门 action.confirm_capture —— 加工那一侧的采集)、
--        stocktake_open(开着的盘点,门 module.stocktakes.view)、safety_state_dwell 与 quarantine_required(库存安全 —— 鼓包 / 漏液的批
--        还不在隔离库位、一条安全状态待过了 V3,门按批是进料 / 产出的查看码;它们画在 /inventory/storage-safety 上)。
--   一共二十三支。【只给计数】:floor_board() 按支数行,不吐 subject、item_code、名字、钱或健康信息。
--   V28 的 tiles 只能从这里挑(set_floor_board_settings 按名拒)。纯函数,不读任何表。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b2-wall-display.sql.
CREATE OR REPLACE FUNCTION public.floor_board_arms()
 RETURNS TABLE(item_type text, section text, sort_order integer)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT a.item_type, a.section, a.sort_order FROM (VALUES
        ('work_order_overdue',                 'processing', 10),
        ('work_order_variance_beyond',         'processing', 20),
        ('processing_balance_unclosed',        'processing', 30),
        ('contamination_check_missing',        'processing', 40),
        ('discharge_unverified',               'processing', 50),
        ('discharge_quarantine_pending',       'processing', 60),
        ('capture_draft_pending',              'processing', 70),
        ('capture_inbox_failed',               'processing', 80),
        ('gateway_silent',                     'processing', 90),
        ('equipment_service_due',              'processing', 100),
        ('equipment_service_approaching',      'processing', 110),
        ('instrument_calibration_due',         'processing', 120),
        ('instrument_calibration_approaching', 'processing', 130),
        ('allocation_stale',                   'processing', 140),
        ('incident_nea_notify_due',            'safety',     210),
        ('incident_report_due',                'safety',     220),
        ('inspection_due',                     'safety',     230),
        ('inspection_finding_open',            'safety',     240),
        ('quarantine_required',                'inventory',  310),
        ('safety_state_dwell',                 'inventory',  320),
        ('storage_ceiling_exceeded',           'inventory',  330),
        ('safety_stock_below',                 'inventory',  340),
        ('stocktake_open',                     'inventory',  350)
    ) a(item_type, section, sort_order);
$function$;

-- db/functions/floor_board.sql
-- MES-8b-2(2026-10-17,MES-0 Q83 · MES-8 Step 0 Q19 · Q20,Tim):【车间大屏读的那一支】—— 每一支车间支此刻有几件事在等人,只有数。
--   门 data.view_floor_board(floor_display 与 admin、cfo 持)。SECURITY DEFINER:读 operations_arms_all(基视图,不给人读)按支计数 ——
--   不能读 operations_now,那张视图按【调用者】的码逐支裁决,一块只持大屏码的屏读它是零行。
--   ★【只吐计数】:每一块牌子 {section, item_type, count};不吐 subject、item_code、item_id、日子、名字、钱或健康信息(fixture 273 COUNTS
--     逐键核对返回的形状 —— 多一个键就红)。
--   ★ V28(floor_board_settings):没给时画 floor_board_arms() 的全部二十三支,按分节的顺序,refresh_seconds 为空 —— 页面不自动刷新;
--     给了之后只画 tiles 里那几支、按 tiles 的顺序,并带回 refresh_seconds。
--   as_of = 这一次数的时刻(页面据此写「refreshed at hh:mm」,新加坡时间)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b2-wall-display.sql.
CREATE OR REPLACE FUNCTION public.floor_board()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_refresh integer;
    v_tiles   text[];
    v_board   jsonb;
BEGIN
    PERFORM require_permission('data.view_floor_board');
    SELECT s.refresh_seconds, s.tiles INTO v_refresh, v_tiles FROM floor_board_settings s WHERE s.id;

    WITH counts AS (
        SELECT a.item_type, count(*) AS n
          FROM operations_arms_all a
         WHERE a.item_type IN (SELECT f.item_type FROM floor_board_arms() f)
         GROUP BY a.item_type
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('section', f.section, 'item_type', f.item_type, 'count', COALESCE(c.n, 0))
                              ORDER BY CASE WHEN v_tiles IS NULL THEN f.sort_order ELSE array_position(v_tiles, f.item_type) END), '[]'::jsonb)
      INTO v_board
      FROM floor_board_arms() f
      LEFT JOIN counts c ON c.item_type = f.item_type
     WHERE v_tiles IS NULL OR f.item_type = ANY (v_tiles);

    RETURN jsonb_build_object(
        'as_of', now(),
        'tiles', v_board,
        'refresh_seconds', v_refresh,
        'settings_set', v_tiles IS NOT NULL AND v_refresh IS NOT NULL);
END;
$function$;

-- db/functions/session_is_floor_display_only.sql
-- MES-8b-2(2026-10-17,MES-0 Q83 · MES-8 Step 0 Q19,Tim):【这个会话是不是一块大屏】—— 空闲登出的唯一一处豁免,与「别的页一律拒」,判据都只在这里。
--   真 ⇔ 会话的角色【恰好】是 {floor_display} 且码【恰好】是 {data.view_floor_board}。
--   角色一侧与 current_user_permissions() 用同一组条件(授权没撤 · 角色在用 · 角色没删),所以"有哪些角色"与"有哪些码"不会各说各话。
--   多一个角色(哪怕那个角色一个码都没有)或 floor_display 多一个码 → 假:这个账号照常空闲登出、照常按码进页面。
--   ★ IDLE-DRAFT 那条「一个值,不分角色」只在这一种情形下被 Q83 取代(Tim 2026-10-17 的 Q19),别的一律照旧。
--   ★ 判据在【服务端】:由会话自己的 auth.uid() 求值,浏览器送来的任何东西都不参与(中间件只在一次请求已经判成空闲过期时才问它,
--     页面只在会话的码恰好是那一个时才问它 —— 别的会话一次都不多问)。
--   没有会话 → 假。读的只是调用者自己的授权,所以对 authenticated 开放。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b2-wall-display.sql.
CREATE OR REPLACE FUNCTION public.session_is_floor_display_only()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT auth.uid() IS NOT NULL
       AND COALESCE((SELECT array_agg(DISTINCT r.code ORDER BY r.code)
                       FROM user_roles ur
                       JOIN roles r ON r.id = ur.role_id
                      WHERE ur.user_id = auth.uid()
                        AND ur.revoked_at IS NULL
                        AND r.is_active
                        AND r.deleted_at IS NULL), ARRAY[]::text[]) = ARRAY['floor_display']::text[]
       AND current_user_permissions() = ARRAY['data.view_floor_board']::text[];
$function$;

-- db/functions/set_floor_board_settings.sql
-- MES-8b-2(2026-10-17,MES-0 §5.1 V28 · MES-8 Step 0 Q20,Tim):【给 / 清 V28】—— 大屏自己刷新的间隔(秒)与画哪几块牌子(按顺序)。
--   门 action.manage_permissions(建大屏账号的人 —— 本刀不加新码,Q29)。两样【一起给、一起清】:只给一半按名拒
--   (FLOOR_BOARD_SETTINGS_PAIR_INCOMPLETE —— 一个只有牌子没有间隔的大屏,读起来像设好了而它不会自己刷新)。
--   牌子只能是 floor_board_arms() 里的支(FLOOR_BOARD_TILE_UNKNOWN|<支>),不许重复(FLOOR_BOARD_TILE_DUPLICATE|<支>),不许空(FLOOR_BOARD_TILES_EMPTY);
--   间隔必须是正数(FLOOR_BOARD_REFRESH_INVALID)—— 只是形状,不是一个替人挑的数。返回改后的那一行。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b2-wall-display.sql.
CREATE OR REPLACE FUNCTION public.set_floor_board_settings(p_refresh_seconds integer, p_tiles text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_bad text;
    r     floor_board_settings%ROWTYPE;
BEGIN
    PERFORM require_permission('action.manage_permissions');
    IF (p_refresh_seconds IS NULL) <> (p_tiles IS NULL) THEN
        RAISE EXCEPTION 'FLOOR_BOARD_SETTINGS_PAIR_INCOMPLETE';
    END IF;
    IF p_refresh_seconds IS NOT NULL THEN
        IF p_refresh_seconds <= 0 THEN
            RAISE EXCEPTION 'FLOOR_BOARD_REFRESH_INVALID';
        END IF;
        IF cardinality(p_tiles) IS NULL OR cardinality(p_tiles) = 0 THEN
            RAISE EXCEPTION 'FLOOR_BOARD_TILES_EMPTY';
        END IF;
        SELECT t INTO v_bad FROM unnest(p_tiles) t
         WHERE t IS NULL OR NOT EXISTS (SELECT 1 FROM floor_board_arms() f WHERE f.item_type = t) LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'FLOOR_BOARD_TILE_UNKNOWN|%', COALESCE(v_bad, '');
        END IF;
        SELECT t INTO v_bad FROM unnest(p_tiles) t GROUP BY t HAVING count(*) > 1 LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'FLOOR_BOARD_TILE_DUPLICATE|%', v_bad;
        END IF;
    END IF;
    UPDATE floor_board_settings SET refresh_seconds = p_refresh_seconds, tiles = p_tiles, updated_by = auth.uid()
     WHERE id RETURNING * INTO r;
    RETURN to_jsonb(r);
END;
$function$;

-- ── 6 · 换掉的函数(镜像原样,同签名):F18 —— 物料种类没说的在库批列出来,不再丢掉 ──

-- db/functions/inventory_metal_exposure.sql
-- MES-8b-1(2026-10-17,MES-0 Q81;MES-8 Step 0 Q12 · Q13,Tim):【还在库的料里,可计价金属按最新的价值多少 —— 美元,带每一个价的日子】。
--   ★ 只算可计价金属(substances.role = 'payable_metal')—— 惩罚元素与别的物质不进来。
--   ★ 每一个金属:Σ 在库量(kg,进料批与产出批的流水之和 —— MES-5b 的同一个真源)× 含量 % × 那个金属【今天(新加坡日期)或之前】最新的一条
--     metal_prices(美元 / 吨),逐行带出那条价的日子(Q12)。价比那一批含量的日子还旧时,那一批记作 price_older_than_content(Step 0 Q12:标出来,不改数)。
--   ★ 只看可能含金属的料:物料种类 may_ever_be_processed(电池料、电子废料)—— 备件、耗材、包装没有含量,列进来只会是一屏的"not measured"。
--   ★ 一批一种可计价金属都没有含量:「not measured」—— 列出它的 kg,不估值;一批有别的金属的含量而缺这一种:这一种对它「not measured」。
--   ★ 一个金属一条价都没有:「no price」—— 金属吨数照列,不估值。同一个最新日子上有几条价(不同的指数):「price ambiguous」—— 不替人挑一条。
--   ★ 单位不是 kg 的批不合计,另列(unit not kg)。
--   ★ 不折算(Q81:USD,换算的那一条裁定还开着 —— BLOCKERS-0 Q1/Q2),不设阈值(Q12)。
--   ★ 门(Q13,AGENTS.md 常设决定 2):data.view_prices AND (module.finance.view OR module.processing.view);不满足按名拒,页面先画「受限」。
--     (一份"一行都没有"的敞口与一次拒绝是两件事 —— 返回集合的函数用零行表示受限就分不开,CLEANUP-A。)
-- ★ MES-8b-2 F18(2026-10-17,Tim 裁定 MES8B1-EXPOSURE-SKIPS-UNKINDED-STOCK):【物料种类没说】不是「不可投料」。
--   materials.kind_code 刻意可空(「留空的意思就是没有人决定过」),而上面那条"只看可能含金属的料"原本写成内连 material_kinds ——
--   于是种类没说的批既不估值、也不进 not measured、也不进 unit not kg,从这一节里【整批消失】(线上 23 批)。
--   现在:种类没说、在库的批单列一栏 kind_not_stated(代码与 kg;单位不是 kg 的照列数量与单位),【不估值】,
--   只要有一批,complete 就是 false。种类【说了】而那一种不可投料的(备件、耗材、包装)照旧不进来 —— 那是一个决定,不是缺席。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql;
--   F18 by db/migrations/2026-10-17-mes8b2-wall-display.sql.
CREATE OR REPLACE FUNCTION public.inventory_metal_exposure()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_metals jsonb;
    v_unmeasured jsonb;
    v_not_kg jsonb;
    v_kind_not_stated jsonb;
    v_total numeric;
    v_complete boolean;
BEGIN
    PERFORM require_permission('data.view_prices');
    IF NOT (has_permission('module.finance.view') OR has_permission('module.processing.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view · module.processing.view';
    END IF;

    WITH stock AS (          -- 每一批在库量(流水之和),只看可能含金属的料、没删的批、量 > 0
        SELECT 'inbound'::text AS kind, b.id, b.code, b.unit, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
        UNION ALL
        SELECT 'output'::text, b.id, b.code, b.unit, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
    ), live AS (
        SELECT * FROM stock WHERE qty > 0
    ), content AS (          -- 可计价金属的含量,带含量的日子(新加坡日期)
        SELECT 'inbound'::text AS kind, c.inbound_batch_id AS id, c.metal, c.content_pct,
               (c.updated_at AT TIME ZONE 'Asia/Singapore')::date AS content_on
          FROM inbound_batch_metals c JOIN substances s ON s.code = c.metal AND s.role = 'payable_metal'
        UNION ALL
        SELECT 'output'::text, c.output_batch_id, c.metal, c.content_pct, (c.updated_at AT TIME ZONE 'Asia/Singapore')::date
          FROM output_batch_metals c JOIN substances s ON s.code = c.metal AND s.role = 'payable_metal'
    ), measured AS (         -- 单位是 kg、至少有一种可计价金属的含量的批
        SELECT l.* FROM live l WHERE l.unit = 'kg' AND EXISTS (SELECT 1 FROM content c WHERE c.kind = l.kind AND c.id = l.id)
    ), latest AS (           -- 每一个可计价金属今天或之前最新的那一天,与那一天上的几条价
        SELECT s.code AS metal, s.sort_order, d.price_date,
               (SELECT count(*) FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date) AS n_prices,
               (SELECT p.price_usd_per_tonne FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date
                 ORDER BY p.price_index NULLS FIRST LIMIT 1) AS price,
               (SELECT p.price_index FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date
                 ORDER BY p.price_index NULLS FIRST LIMIT 1) AS price_index,
               (SELECT p.source FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date
                 ORDER BY p.price_index NULLS FIRST LIMIT 1) AS price_source
          FROM substances s
          LEFT JOIN LATERAL (SELECT max(p.price_date) AS price_date FROM metal_prices p
                              WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date <= v_today) d ON true
         WHERE s.role = 'payable_metal'
    ), per AS (              -- 一个金属 × 一批:那一批这个金属的吨数
        SELECT m.kind, m.id, m.code, m.qty, c.metal, c.content_pct, c.content_on,
               m.qty * c.content_pct / 100 AS metal_kg
          FROM measured m JOIN content c ON c.kind = m.kind AND c.id = m.id
    ), lines AS (
        SELECT lt.metal, lt.sort_order, lt.price_date, lt.n_prices, lt.price, lt.price_index, lt.price_source,
               CASE WHEN lt.price_date IS NULL THEN 'no_price' WHEN lt.n_prices > 1 THEN 'price_ambiguous' ELSE 'priced' END AS state,
               (SELECT count(*) FROM per p WHERE p.metal = lt.metal) AS batches,
               (SELECT COALESCE(sum(p.qty), 0) FROM per p WHERE p.metal = lt.metal) AS material_kg,
               (SELECT COALESCE(sum(p.metal_kg), 0) FROM per p WHERE p.metal = lt.metal) AS metal_kg,
               (SELECT count(*) FROM per p WHERE p.metal = lt.metal AND lt.price_date IS NOT NULL AND lt.price_date < p.content_on) AS price_older_than_content,
               (SELECT COALESCE(sum(m.qty), 0) FROM measured m WHERE NOT EXISTS (SELECT 1 FROM per p WHERE p.kind = m.kind AND p.id = m.id AND p.metal = lt.metal)) AS not_measured_kg,
               (SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', p.kind, 'code', p.code, 'kg', round(p.qty, 3), 'content_pct', p.content_pct,
                                                             'content_on', p.content_on, 'metal_kg', round(p.metal_kg, 3),
                                                             'price_older_than_content', lt.price_date IS NOT NULL AND lt.price_date < p.content_on)
                                          ORDER BY p.code), '[]'::jsonb) FROM per p WHERE p.metal = lt.metal) AS batch_lines
          FROM latest lt
    )
    SELECT jsonb_agg(jsonb_build_object(
               'metal', l.metal, 'state', l.state, 'price_date', l.price_date,
               'price_usd_per_tonne', CASE WHEN l.state = 'priced' THEN l.price END,
               'price_index', CASE WHEN l.state = 'priced' THEN l.price_index END,
               'price_source', CASE WHEN l.state = 'priced' THEN l.price_source END,
               'prices_on_that_date', l.n_prices,
               'batches', l.batches, 'material_kg', round(l.material_kg, 3), 'metal_kg', round(l.metal_kg, 3),
               'value_usd', CASE WHEN l.state = 'priced' THEN round(l.metal_kg / 1000 * l.price, 2) END,
               'price_older_than_content', l.price_older_than_content,
               'not_measured_kg', round(l.not_measured_kg, 3),
               'batch_lines', l.batch_lines) ORDER BY l.sort_order, l.metal),
           sum(CASE WHEN l.state = 'priced' THEN round(l.metal_kg / 1000 * l.price, 2) END),
           bool_and(l.state = 'priced' OR l.metal_kg = 0)
      INTO v_metals, v_total, v_complete
      FROM lines l;

    WITH stock AS (
        SELECT 'inbound'::text AS kind, b.id, b.code, b.unit, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
        UNION ALL
        SELECT 'output'::text, b.id, b.code, b.unit, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', s.kind, 'code', s.code, 'kg', round(s.qty, 3)) ORDER BY s.code)
                    FILTER (WHERE s.unit = 'kg' AND NOT EXISTS (SELECT 1 FROM inbound_batch_metals c JOIN substances x ON x.code = c.metal AND x.role = 'payable_metal'
                                                                  WHERE s.kind = 'inbound' AND c.inbound_batch_id = s.id)
                                              AND NOT EXISTS (SELECT 1 FROM output_batch_metals c JOIN substances x ON x.code = c.metal AND x.role = 'payable_metal'
                                                                  WHERE s.kind = 'output' AND c.output_batch_id = s.id)), '[]'::jsonb),
           COALESCE(jsonb_agg(jsonb_build_object('kind', s.kind, 'code', s.code, 'qty', round(s.qty, 3), 'unit', s.unit) ORDER BY s.code)
                    FILTER (WHERE s.unit <> 'kg'), '[]'::jsonb)
      INTO v_unmeasured, v_not_kg
      FROM stock s WHERE s.qty > 0;

    -- F18:物料种类没说的在库批 —— 列出来,不估值(它可能含金属,也可能不含;没有人说过它是哪一种料)。
    WITH stock AS (
        SELECT 'inbound'::text AS kind, b.code, b.unit, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id
          JOIN materials m ON m.id = b.material_id
         WHERE b.deleted_at IS NULL AND m.kind_code IS NULL GROUP BY b.id, b.code, b.unit
        UNION ALL
        SELECT 'output'::text, b.code, b.unit, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id
          JOIN materials m ON m.id = b.material_id
         WHERE b.deleted_at IS NULL AND m.kind_code IS NULL GROUP BY b.id, b.code, b.unit
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', s.kind, 'code', s.code,
                                                 'kg', CASE WHEN s.unit = 'kg' THEN round(s.qty, 3) END,
                                                 'qty', round(s.qty, 3), 'unit', s.unit) ORDER BY s.code, s.kind), '[]'::jsonb)
      INTO v_kind_not_stated
      FROM stock s WHERE s.qty > 0;

    RETURN jsonb_build_object(
        'as_of', v_today,
        'metals', COALESCE(v_metals, '[]'::jsonb),
        'value_usd_priced', round(COALESCE(v_total, 0), 2),
        'complete', COALESCE(v_complete, true) AND jsonb_array_length(v_unmeasured) = 0 AND jsonb_array_length(v_not_kg) = 0
                    AND jsonb_array_length(v_kind_not_stated) = 0,
        'not_measured', v_unmeasured,
        'not_measured_kg', (SELECT COALESCE(round(sum((x ->> 'kg')::numeric), 3), 0) FROM jsonb_array_elements(v_unmeasured) x),
        'unit_not_kg', v_not_kg,
        'kind_not_stated', v_kind_not_stated,
        'kind_not_stated_kg', (SELECT COALESCE(round(sum((x ->> 'kg')::numeric), 3), 0) FROM jsonb_array_elements(v_kind_not_stated) x));
END;
$function$;

-- ── 7 · 换掉的视图(镜像原样):operations_now = 基视图 + 按读者的过滤;待补的值 +V28 ──

-- db/views/operations_now.sql
-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行;每一支按【读者】的码裁决。
-- ★ MES-8b-2(2026-10-17,MES-8 Step 0 Q20,Tim):支的定义搬进了 db/views/operations_arms_all.sql(连同原来的抬头,原样);
--   本视图只剩【按读者过滤】那一句与两列推导(permission_any · days_waiting)—— 列、列序与每一行都与搬之前逐字相同。
--   搬的理由:大屏的 floor_board() 要从同一份支的定义上【计数】,而读本视图的 SECURITY DEFINER 函数仍然只拿到调用者看得见的那几支
--   (has_permission 解析的是调用者)。加一支改 operations_arms_all.sql。
-- WHERE has_permission(a.permission) 按【调用者】逐支裁决:无权的支【整支缺席】,
--   arm_permission_widen 放宽、arm_permission_any 收窄(lib/modules.ts 的 allows() 同形)。
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
   FROM operations_arms_all a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

GRANT SELECT ON public.operations_now TO authenticated;

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
                    AND (u.banned_until IS NULL OR u.banned_until < now())))) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7);MES-4b 加 V10(勾了电解液挥发的工序的电解液份额)与 V11(交叉污染流的警戒线)。MES-5a-1 加 V9(物料的放电通过电压,只在那种物料有了放电结果之后才列);MES-5a-2 加 V25(共用池的电怎么摊,有共用池电表而规则为空时一行)。MES-5b-1 加 V37(每道工序 × 每种产出形态的预期质量得率;只在那道工序有了至少一张 MES-4a 之后的消耗炉次时才列 —— V9 的先例:没人能动手的行不列)。MES-6a-1 加 V16(没有合同天数的样品留多少天;只在有一份没处置、留样日 Not yet set 的样品时才列)与 V14(仲裁费怎么分;每一份有过一件开着或已结案的争议而规则为空的合同一行)。MES-6b-1 加 V17(卖方合同的质量验收限;每一份挂了销售单而口径没声明的卖方合同一行)。MES-7a-2 加 V21(备件的最低库存;每一种收过至少一批而最低库存为空的备件物料一行)。MES-7b-1 加 V19(NEA 书面报告的工作日数;空着或还没对着执照确认时一行)。MES-7b-2 加 V18(巡检清单的频率与检查项;一张启用的清单都没有时一行,之后每一张频率空着的启用清单一行)与 V20(监测参数的排放限值;字典空着时一行,之后每一个没有限值的启用参数一行)。MES-8a 加 V23(供应商评分的权重、等级线与评审周期;三样里有一样空着就一行)与 V24(每一个等级的预付上限与抽样级别;有了等级线之后,每一个缺其中一样的等级一行)。MES-8b-1 加 V26(NEA 申报的格式与频率)与 V27(欧盟回收效率的方法与目标)—— 两支都是从第一天起就一行(合规包的设定一行、全空),读 module.compliance.view。MES-8b-2 加 V28(车间大屏自己刷新的间隔与画哪几块牌子;设定那一行有一样空着、并且有一个在用的 floor_display 账号时一行 —— 没有大屏就没有人能动手,读 action.manage_permissions)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.floor_board_settings
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.floor_board_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 9 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.floor_board() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.floor_board() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.session_is_floor_display_only() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.session_is_floor_display_only() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.set_floor_board_settings(integer, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_floor_board_settings(integer, text[]) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.floor_board_arms() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.floor_board_arms() TO authenticated, service_role;

-- ── 10 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes8b2_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes8b2_pending_after ON COMMIT DROP AS
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
    k       text;
    a       record;
    v_ex    boolean;
BEGIN
    -- ① 授权:恰好多了那三行;目录 85 个码,admin 持每一个;floor_display 只持那一个;没有任何人挂 floor_display
    IF (SELECT count(*) FROM permissions) <> 85
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES8B2_PROOF|admin does not hold every one of the 85 codes';
    END IF;
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v_bad FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'data.view_floor_board';
    IF v_bad IS DISTINCT FROM 'admin,cfo,floor_display' THEN
        RAISE EXCEPTION 'MES8B2_PROOF|data.view_floor_board is held by % (ruled: admin,cfo,floor_display)', COALESCE(v_bad, '<nobody>');
    END IF;
    IF (SELECT string_agg(rp.permission_code, ',') FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'floor_display')
         IS DISTINCT FROM 'data.view_floor_board'
       OR (SELECT is_system OR NOT is_active FROM roles WHERE code = 'floor_display') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|floor_display must be an active, non-system role holding exactly data.view_floor_board';
    END IF;
    IF EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = 'floor_display') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|no account may hold floor_display (Q29: an admin creates one per screen later)';
    END IF;
    SELECT string_agg(r.code || ':' || p.code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B2_PROOF|an action code is held without its declared view: %', v_bad;
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES8B2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM mes8b2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM mes8b2_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'MES8B2_PROOF|an account or its roles changed';
    END IF;

    -- ③ 七个真账号:每一个的会话问 session_is_floor_display_only() 都是假 —— 空闲登出照旧(Q19:只有大屏豁免)
    FOR a IN SELECT id, email FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test') ORDER BY email LOOP
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', a.id), true);
        v_ex := session_is_floor_display_only();
        RAISE NOTICE 'MES8B2 idle-exempt % = %', a.email, v_ex;
        IF v_ex IS NOT FALSE THEN
            RAISE EXCEPTION 'MES8B2_PROOF|% would be exempt from the idle logout', a.email;
        END IF;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ④ 在途单据一张不少、一张不多;既有的行逐字未变;两张 COD 的存储对象一个字节不动
    IF EXISTS ((SELECT b.k, b.id FROM mes8b2_pending_before b EXCEPT SELECT a2.k, a2.id FROM mes8b2_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM mes8b2_pending_after a2 EXCEPT SELECT b.k, b.id FROM mes8b2_pending_before b)) THEN
        RAISE EXCEPTION 'MES8B2_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) IS DISTINCT FROM (SELECT inbound_batches FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t ) IS DISTINCT FROM (SELECT output_batches FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t ) IS DISTINCT FROM (SELECT inventory_movements FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t ) IS DISTINCT FROM (SELECT processing_runs FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_inputs t ) IS DISTINCT FROM (SELECT processing_inputs FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_outputs t ) IS DISTINCT FROM (SELECT processing_outputs FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_records t ) IS DISTINCT FROM (SELECT sales_records FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM metal_prices t ) IS DISTINCT FROM (SELECT metal_prices FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_metals t ) IS DISTINCT FROM (SELECT inbound_batch_metals FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t ) IS DISTINCT FROM (SELECT output_batch_metals FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM substances t ) IS DISTINCT FROM (SELECT substances FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t ) IS DISTINCT FROM (SELECT materials FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM material_kinds t ) IS DISTINCT FROM (SELECT material_kinds FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) IS DISTINCT FROM (SELECT journal_entries FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) IS DISTINCT FROM (SELECT journal_lines FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) IS DISTINCT FROM (SELECT payments FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) IS DISTINCT FROM (SELECT expenses FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) IS DISTINCT FROM (SELECT suppliers FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM purchase_orders t ) IS DISTINCT FROM (SELECT purchase_orders FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customers t ) IS DISTINCT FROM (SELECT customers FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM stocktakes t ) IS DISTINCT FROM (SELECT stocktakes FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM incidents t ) IS DISTINCT FROM (SELECT incidents FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM environmental_results t ) IS DISTINCT FROM (SELECT environmental_results FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_templates t ) IS DISTINCT FROM (SELECT inspection_templates FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_runs t ) IS DISTINCT FROM (SELECT inspection_runs FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_findings t ) IS DISTINCT FROM (SELECT inspection_findings FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM compliance_packs t ) IS DISTINCT FROM (SELECT compliance_packs FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM compliance_settings t ) IS DISTINCT FROM (SELECT compliance_settings FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_score_settings t ) IS DISTINCT FROM (SELECT supplier_score_settings FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) IS DISTINCT FROM (SELECT certificates_of_destruction FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) IS DISTINCT FROM (SELECT cod_issues FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) IS DISTINCT FROM (SELECT approval_log FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) IS DISTINCT FROM (SELECT employees FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t WHERE code <> 'data.view_floor_board') IS DISTINCT FROM (SELECT permissions FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t WHERE permission_code <> 'data.view_floor_board') IS DISTINCT FROM (SELECT role_permissions FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t WHERE code <> 'floor_display') IS DISTINCT FROM (SELECT roles FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) IS DISTINCT FROM (SELECT user_roles FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t ) IS DISTINCT FROM (SELECT document_types FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) IS DISTINCT FROM (SELECT ingest_settings FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) IS DISTINCT FROM (SELECT finance_settings FROM mes8b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM safety_settings t ) IS DISTINCT FROM (SELECT safety_settings FROM mes8b2_rows_before) THEN
        RAISE EXCEPTION 'MES8B2_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS ((SELECT name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects WHERE bucket_id = 'cod-documents'
                EXCEPT SELECT name, size, etag FROM mes8b2_cod_objects_before)
               UNION ALL
               (SELECT name, size, etag FROM mes8b2_cod_objects_before
                EXCEPT SELECT name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects WHERE bucket_id = 'cod-documents')) THEN
        RAISE EXCEPTION 'MES8B2_PROOF|a COD object changed';
    END IF;

    -- ⑤ V28 那一行在、两样全空;线上没有大屏账号,所以 V28 那一支的条件不成立
    IF (SELECT count(*) FROM floor_board_settings) <> 1
       OR EXISTS (SELECT 1 FROM floor_board_settings WHERE refresh_seconds IS NOT NULL OR tiles IS NOT NULL) THEN
        RAISE EXCEPTION 'MES8B2_PROOF|the settings row must exist with V28 empty (nothing is guessed)';
    END IF;

    -- ⑥ 本事务往变更记录只写了:目录一行、角色一行、三行授权、设定那一行(按 txid 认)
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes8b2_log_before), 0) AND c.txid = txid_current()
       AND NOT (c.op = 'INSERT' AND c.table_name IN ('permissions', 'roles', 'role_permissions', 'floor_board_settings'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES8B2_PROOF|unexpected change_log rows: %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes8b2_log_before), 0) AND c.txid = txid_current()
          AND c.table_name = 'role_permissions') <> 3 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|expected exactly 3 role_permissions rows written';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B2_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑦ 结构:321 张表;支 72 在基视图里,operations_now 读基视图;基视图不给人读;待补的值 34 支;floor_board_arms 23 支、每一支都在基视图里
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 321 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|expected 321 public tables';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_arms_all'::regclass), 'AS item_type', 'g')) <> 72
       OR position('operations_arms_all' IN pg_get_viewdef('public.operations_now'::regclass)) = 0
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 34 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|arms 72 in the base view, operations_now reading it, pending-value arms 34 expected';
    END IF;
    IF has_table_privilege('authenticated', 'public.operations_arms_all', 'SELECT') OR has_table_privilege('anon', 'public.operations_arms_all', 'SELECT') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|the arms view must be readable by nobody but its owner';
    END IF;
    SELECT string_agg(f.item_type, ', ') INTO v_bad FROM floor_board_arms() f
     WHERE position(quote_literal(f.item_type) || '::text AS item_type' IN pg_get_viewdef('public.operations_arms_all'::regclass)) = 0;
    IF v_bad IS NOT NULL OR (SELECT count(*) FROM floor_board_arms()) <> 23 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|the floor board lists an arm that does not exist: %', v_bad;
    END IF;

    -- ⑧ 匿名面与函数面
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES8B2_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.floor_board()'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.floor_board()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.floor_board()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|public.floor_board(): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.session_is_floor_display_only()'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.session_is_floor_display_only()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.session_is_floor_display_only()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|public.session_is_floor_display_only(): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.set_floor_board_settings(integer, text[])'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.set_floor_board_settings(integer, text[])'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.set_floor_board_settings(integer, text[])'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|public.set_floor_board_settings(integer, text[]): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.floor_board_arms()'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.floor_board_arms()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.floor_board_arms()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|public.floor_board_arms(): expected a plain function, authenticated yes, anon no';
    END IF;
    IF has_table_privilege('anon', 'public.floor_board_settings', 'SELECT') THEN RAISE EXCEPTION 'MES8B2_PROOF|anon can read floor_board_settings'; END IF;

    -- ⑨ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑩ 变更记录:覆盖零缺口(新表记,豁免仍是 8);遮蔽零缺口(规则仍 119 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑪ F16:没有一张视图对 anon / authenticated 带写授权
    v_n := (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑫ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes8b2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES8B2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes8b2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes8b2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
