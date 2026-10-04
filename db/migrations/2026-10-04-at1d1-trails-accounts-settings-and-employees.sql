-- db/migrations/2026-10-04-at1d1-trails-accounts-settings-and-employees.sql
-- AUDIT-TRAIL-1d-1 —— 机制、设置与员工的审计记录(v1.4.33 的一部分,未发布)。
-- 由 db/scripts/build_at1d1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AT-1d Step 0 的 Q1–Q38,Tim 2026-10-04 全部照建议裁定;这是 1d-1 那一刀)
--   ① 机制,四件一次建好(后两刀只加登记行):
--      M9  trail_log_only_tables():只在变更记录里出现的表(auth.users)—— 一份安全投影(id · email · created_at · banned_until)
--          与一个声明的读码(action.manage_permissions);trail_current_image / trail_row_visible 认它。
--      M10 trail_member_columns():成员只取声明的几列(账号页上那名员工只取 user_id 一列)。
--      M11 record_trail:root_rule = 'collection' —— 一张表整张是一条记录(六本字典)。
--      M12 trail_root_gate():root_rule = 'gate:<名字>' —— 比表的读规则更窄的门(reviewer;第一个用户是 1d-3)。
--      Q13 change_log_rows:每一行再过一次它自己那张表的读规则,过不了就整份受限(与 record_trail 同一判)。
--   ② trail_subjects:十二个主语 —— account · approval_policy · employee · department · training_record · import_batch ·
--      六本字典(dictionary_*)。trail_subject_members:它们的成员;角色多一个成员 user_roles(Q22,家在账号那一边)。
--      trail_prelog_sources:Q12 的那几样(账号建立、授权与收回、附加账号、审批方针修改史、导入批次、员工 / 履历 / 调薪申请 /
--      部门 / 培训的建立与戳)。trail_ref_label:账号带回名字、培训记录、导入批次的名字。
--   ③ save_employee(新,SECURITY INVOKER):员工那一行与它的履历一笔事务(Q8)。
--   ④ deleted_records:角色 · 员工 · 部门 · 培训记录四类(Q25 · Q26)。
--
-- 【不做什么】不改任何表、策略、表上的授权、触发器;不写任何业务行;不加新权限码;不碰审批开关与名册;不建、不停、不删任何账号。
--
-- 【破窗】写的路一条都不坏:
--   · 函数同签名原地替换;record_trail 的返回列不变;三支新的登记函数与 save_employee 是新的 —— 旧应用不叫它们,
--     旧的员工表单照旧直写两次(表的策略照旧放行)。
--   · deleted_records 是 CREATE OR REPLACE VIEW,列不变,多四类行:旧的 /settings/deleted 会把它们列成原样的键名、没有链接
--     (1b-3 / 1c-2 的同一个形状),直到部署。
--   · /settings/change-history 在部署之前就按行的读规则遮(Q13)—— 今天两个读者(admin、cfo)看到的差别:cfo 不持
--     manage_permissions,账号事件(今天 0 行)与 COD 校验计数那几行会是受限;角色页的旧应用读到授权的新行(user_roles 成员)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;change_log 的行数
--   没变;每一张在途单据都还有一个【不是它自己当事人】的决定人;六十八个主语;执行权;并以 admin@(唯一持 manage_permissions 的账号)
--   把新主语在线上的每一条记录读一遍(一条被拒 = 坏了),外加 cto 那个角色的页上读得到它被授给的那一笔。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子(1c-3 的形状,五十六个主语;record_trail 已经有 op_key)──────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1D1_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM trail_subjects()) <> 56 THEN
        RAISE EXCEPTION 'AT1D1_PRE|expected the 56 subjects of 1c-3, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = 'public.record_trail(text, text, integer)'::regprocedure
                      AND 'op_key' = ANY (p.proargnames)) THEN
        RAISE EXCEPTION 'AT1D1_PRE|record_trail does not return op_key';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1d1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE at1d1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1d1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;

-- ── 1 · 登记表与读法的内层:原地替换(同一签名,镜像原样)──────────────────────────────

-- db/functions/trail_log_only_tables.sql
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q2 —— M9):【只在变更记录里出现】的表 —— 它不在 public 里,
--   读法(record_trail)平常够不到它,而它的事件(账号建立、停用、恢复……)只写在 change_log 里(record_account_event)。
--   第一个、也是唯一一个:auth.users,每个账号的审计记录(/settings/accounts,AT-0 的 Q24)。
--   每一行说三件事:
--     schema_name · rel_name  它真正住在哪里(trail_current_image 照这个名字去读今天那一份);
--     image_columns           【只许读这几列】—— 一份固定的安全投影。整行 to_jsonb(auth 那一行)会把 encrypted_password
--                             与六支令牌列带进审计记录的上下文(Step 0 C §A3 实测),所以这里逐列点名,别的一列都不碰;
--     read_code               谁读得到这种行:一个【声明出来的】码,代替那张表的读策略(它不在 public 里,
--                             trail_row_visible 读不到它的策略)—— 与 user_directory 的谓词同一个码。
-- 【读它的人】trail_current_image · trail_row_visible · record_trail(都是属主身份)· scripts/check-trail-wording.mjs(解析投影,
--   当作这张表的"列")。加一行之前先问:那张表有没有一列不该进审计记录?有,就不要放进 image_columns。
CREATE OR REPLACE FUNCTION public.trail_log_only_tables()
 RETURNS TABLE(table_name text, schema_name text, rel_name text, image_columns text[], read_code text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('auth.users', 'auth', 'users', ARRAY['id', 'email', 'created_at', 'banned_until'], 'action.manage_permissions')
    ) AS l(table_name, schema_name, rel_name, image_columns, read_code);
$function$;

-- db/functions/trail_member_columns.sql
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q3 —— M10):一个成员【只取声明的几列】—— M6(root_columns)用在成员上。
--   (subject, ord) 对上 trail_subject_members() 里的那一行;columns 是那张表上属于这条记录的列:
--   一次改动一列都不沾 → 整条不算;沾了 → 只留这几列;"记录开始之前"那一段只拼落在这几列上的戳,不拼"建立"
--   (那一行的建立不是这条记录的事)。
--   第一个用户:账号的审计记录里那个员工 —— 账号绑在谁身上(employees.user_id)是账号的事,而那名员工别的每一次编辑
--   (地址、职位、证件……)不是。不限列,账号的审计记录就会把人事的每一次改动都搬过来(Step 0 C §A3)。
-- 【为什么另立一张表,不是 trail_subject_members 多一列】那张表的返回类型一变,每一支在 fixture 里临时改写它的
--   (fixture 237 / 241 证 M3–M7 的做法)都会因为"不能改返回类型"而起不来;一张旁表不碰任何既有的签名。
CREATE OR REPLACE FUNCTION public.trail_member_columns()
 RETURNS TABLE(subject text, ord integer, columns text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('account', 4, ARRAY['user_id'])
    ) AS c(subject, ord, columns);
$function$;

-- db/functions/trail_root_gate.sql
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q5 —— M12):一道【比那张表的读规则更窄】的门。
--   trail_subjects 的 root_rule 写成 'gate:<名字>':根行先过它自己那张表的读规则(与 'table' 相同),【再】过这里点名的那一道。
--   为什么要更窄:/my-reviews/[id](审核人那一页,没有模块门)上的那条记录 —— performance_reviews 的读规则在评审批准之后
--   也放【被评审的那个人】进来,于是只靠表的规则(M8),被评审的人读得到审核人在批准之前的每一次起草(Step 0 Q5)。
--   这一页的门是"你是这一份的审核人",审计记录的门必须是同一个。
-- 【闭合集合】只认下面列出的名字;认不出的名字一律 false(拒) —— 登记表里写错一个字,结果是"谁都读不了",不是"谁都读得了"。
--   reviewer:根行(performance_reviews)的 reviewer_employee_id 就是读者自己(current_user_employee() —— 主账号或附加账号)。
--   AT-1d-3 的 my_review 是它的第一个用户;本刀先建好,fixture 244 用一个临时主语证它。
-- 【属主身份】EXECUTE 已从 authenticated 收回(只有 record_trail 调它)。
CREATE OR REPLACE FUNCTION public.trail_root_gate(p_gate text, p_table text, p_image jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_gate = 'reviewer' AND p_table = 'performance_reviews'
            THEN COALESCE(p_image ->> 'reviewer_employee_id' = current_user_employee()::text, false)
        ELSE false
    END;
$function$;

-- db/functions/trail_current_image.sql
-- AUDIT-TRAIL-1a:一行【今天】的整份样子 —— 还在就读那一行;已经被硬删,就取 change_log 里它最后一份完整影像
--   (DELETE 的 old,或 INSERT 的 new)。两处都没有 → NULL。第二个返回值说它是不是已经不在了。
-- 给 record_trail 用:判这一行过不过它自己那张表的读规则(Q4)、以及给子行一个"这是哪一行"的上下文(第几行、哪个物料)。
-- 【属主身份】按表名动态读任意一张表;EXECUTE 已从 authenticated 收回。
-- AUDIT-TRAIL-1d-1(M9):trail_log_only_tables() 登记的表(auth.users)不在 public 里 —— 照登记的 schema 去读,
--   并且【只读那一份安全投影】(id · email · created_at · banned_until),绝不 to_jsonb 整行(那会把口令散列与令牌带进上下文)。
--   这种表在 change_log 里没有行影像(它的事件是 record_account_event 写的 ACCOUNT_* 那几种),所以读不到就是 NULL,不回落。
CREATE OR REPLACE FUNCTION public.trail_current_image(p_table text, p_key jsonb, OUT image jsonb, OUT gone boolean)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_where text;
    v_lo    record;
BEGIN
    gone := false;
    SELECT l.* INTO v_lo FROM trail_log_only_tables() l WHERE l.table_name = p_table;
    IF FOUND THEN
        IF p_key IS NULL OR NOT (p_key ? 'id') THEN
            image := NULL;
            RETURN;
        END IF;
        EXECUTE format('SELECT jsonb_build_object(%s) FROM %I.%I t WHERE t.id::text = $1 LIMIT 1',
                       (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_lo.image_columns) c),
                       v_lo.schema_name, v_lo.rel_name)
           INTO image USING p_key ->> 'id';
        RETURN;
    END IF;
    IF p_key IS NULL OR to_regclass(format('public.%I', p_table)) IS NULL THEN
        image := NULL;
        RETURN;
    END IF;
    SELECT string_agg(format('t.%I::text = %L', k.key, k.value), ' AND ')
      INTO v_where FROM jsonb_each_text(p_key) k;
    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE %s LIMIT 1', p_table, v_where) INTO image;
    IF image IS NOT NULL THEN
        RETURN;
    END IF;
    SELECT CASE WHEN c.op = 'DELETE' THEN c.old ELSE c.new END INTO image
      FROM change_log c
     WHERE c.table_name = p_table AND c.row_key = p_key AND c.op IN ('INSERT', 'DELETE')
     ORDER BY c.seq DESC
     LIMIT 1;
    gone := image IS NOT NULL;
END;
$function$;

-- db/functions/trail_row_visible.sql
-- AUDIT-TRAIL-1a(Tim 的 Q4 · Q5):【当前读者】能不能读这一行 —— 按【这一行自己那张表】的读规则,不按父记录的。
--   record_trail 是 SECURITY DEFINER(change_log 对应用角色没有任何授权),而 DEFINER 里做不了 SET ROLE,
--   所以这里把那张表的 SELECT 策略(permissive 的 SELECT 与 ALL,给 authenticated 或 public 的)用 OR 拼起来,
--   对着那一行重新求一次值。这样做是对的,因为实测(AUDIT-TRAIL-0 reader-masking.md §1.6):线上 287 条读策略
--   0 条 restrictive、0 条依赖数据库角色 —— 全部经 has_permission() / current_user_employee() 从登录的 JWT 认人。
--   restrictive 策略若将来出现,在这里用 AND 接上(已经写好)。
--   · 表没开 RLS → 看 authenticated 有没有任何一列的 SELECT 权限;
--   · authenticated 连一列都读不了(cod_verification_failures 那种没有读策略的表)→ 看不见;
--   · 这一行已被硬删 → 对它最后一份影像求同一个值(jsonb_populate_record,别名就是表名,于是带表名限定的列引用照样解析)。
--   ☞ 已知边界(reader-masking.md §1.6 已记):策略里 EXISTS 子查询读的别的表,在 DEFINER 里不再过那张表的 RLS。
--     线上两处这种策略的子查询都自己写全了条件,所以结果相同。
-- 【属主身份】EXECUTE 已从 authenticated 收回 —— 否则它就是一支"任意一行你看不看得见"的探针。
-- AUDIT-TRAIL-1d-1(M9):trail_log_only_tables() 登记的表(auth.users)不在 public 里,它的策略这里读不到 ——
--   它的读规则是登记表里【声明的那个码】(action.manage_permissions,与 user_directory 同一个谓词)。
CREATE OR REPLACE FUNCTION public.trail_row_visible(p_table text, p_key jsonb, p_image jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rls   boolean;
    v_perm  text;
    v_restr text;
    v_where text;
    v_ok    boolean;
    v_live  boolean;
    v_code  text;
BEGIN
    SELECT l.read_code INTO v_code FROM trail_log_only_tables() l WHERE l.table_name = p_table;
    IF FOUND THEN
        RETURN p_key IS NOT NULL AND has_permission(v_code);
    END IF;
    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
     WHERE c.relname = p_table AND c.relkind = 'r';
    IF NOT FOUND OR p_key IS NULL THEN
        RETURN false;
    END IF;
    IF NOT has_any_column_privilege('authenticated', format('public.%I', p_table), 'SELECT') THEN
        RETURN false;
    END IF;
    IF NOT v_rls THEN
        RETURN true;
    END IF;
    SELECT string_agg('(' || p.qual || ')', ' OR ') INTO v_perm
      FROM pg_policies p
     WHERE p.schemaname = 'public' AND p.tablename = p_table AND p.permissive = 'PERMISSIVE'
       AND p.cmd IN ('SELECT', 'ALL') AND p.roles && ARRAY['authenticated', 'public']::name[]
       AND p.qual IS NOT NULL;
    IF v_perm IS NULL THEN
        RETURN false;
    END IF;
    SELECT string_agg('(' || p.qual || ')', ' AND ') INTO v_restr
      FROM pg_policies p
     WHERE p.schemaname = 'public' AND p.tablename = p_table AND p.permissive = 'RESTRICTIVE'
       AND p.cmd IN ('SELECT', 'ALL') AND p.roles && ARRAY['authenticated', 'public']::name[]
       AND p.qual IS NOT NULL;
    v_perm := '(' || v_perm || ')' || COALESCE(' AND (' || v_restr || ')', '');

    SELECT string_agg(format('%I.%I::text = %L', p_table, k.key, k.value), ' AND ')
      INTO v_where FROM jsonb_each_text(p_key) k;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%1$I %1$I WHERE %2$s)', p_table, v_where) INTO v_live;
    IF v_live THEN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%1$I %1$I WHERE %2$s AND (%3$s))', p_table, v_where, v_perm)
           INTO v_ok;
        RETURN COALESCE(v_ok, false);
    END IF;
    IF p_image IS NULL THEN
        RETURN false;
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM jsonb_populate_record(NULL::public.%1$I, $1) %1$I WHERE (%2$s))',
                   p_table, v_perm)
       INTO v_ok USING p_image;
    RETURN COALESCE(v_ok, false);
END;
$function$;

-- db/functions/trail_subjects.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):审计记录的【主语登记表】。页面只说"哪一种记录、哪一条",从不说表名;
--   表名、根键、以及【这一页自己的查看权限码】只住在这里(服务端)。不在这里的主语 → TRAIL_SUBJECT_UNKNOWN。
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M1 · M3 · M6)多了三列:
--   view_codes   【任一】即可进(M1)—— 与页面守卫同一组码。一页只认一个码时就是一个元素的数组。
--                warehouse_request:/inventory 那一块(module.inventory.view)与财务(module.finance.view)都读它。
--   root_rule    (AUDIT-TRAIL-1d-1 多了两种:'collection' —— M11,一张表整张是一条记录;'gate:<名字>' —— M12,比表的规则更窄)
--                'table'(默认):根行还要过它自己那张表的读规则,过不了 → TRAIL_NOT_PERMITTED。
--                'page'(M3):页面的码就是门;根行自己的那几次改动照子行的规矩走 —— 读者过不了根表的读规则,
--                那几条就是 Restricted(Q4)。equipment 用它:根表 fixed_assets 只给财务读,而这一页给加工的人。
--   root_columns 非空(M6):根行只取这几列的改动(一块面板只管它自己编辑的那几个字段,Q25 的同一条规矩)。
--                NULL = 整行。1b-3 的三个阈值面板会用到它;本刀先建好,fixture 237 用一个临时主语证它。
-- view_codes 与页面守卫逐字同一组码:
--   purchase_order → /purchasing/orders/[id]        requireModule(MOD.purchasing) = module.purchasing.view
--   processing_run → /operation/processing/[id]     requireModule(MOD.processing) = module.processing.view
--   role           → /settings/roles/[id]           requireManagePermissions()     = action.manage_permissions
--   inbound_batch  → /inbound/[id]/edit             requireModule(MOD.inbound)     = module.inbound.view
--   output_batch   → /output/[id]/edit              requireModule(MOD.output)      = module.output.view
--   work_order     → /operation/orders/[id]         requireModule(MOD.processing)  = module.processing.view
--   stocktake      → /stocktakes/[id]               requireModule(MOD.stocktakes)  = module.stocktakes.view
--   equipment      → /operation/equipment/[id]      requireModule(MOD.processing)  = module.processing.view
--   shift_handover → /operation/handovers/[id]      requireModule(MOD.processing)  = module.processing.view
--   warehouse_request → /inventory 的申请一块        requireModule(MOD.inventory)   = module.inventory.view(+ 财务)
-- AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a 的商务那一半):
--   quote          → /sales/quotes/[id]              requireModule(MOD.sales)       = module.sales.view
--   sales_order    → /sales/orders/[id]              requireModule(MOD.sales)       = module.sales.view
--   shipment       → /sales/shipments/[id]           action.ship_goods,否则 requireModule(MOD.sales)(M1:任一)
--   customer       → /sales/customers/[id]           requireModule(MOD.customers)   = module.customers.view
--   commission_agreement → /sales/commissions/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   supplier       → /suppliers/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   container      → /logistics/containers/[id]      requireModule(MOD.logistics)   = module.logistics.view
--   forwarder      → /logistics/forwarders/[id]      requireModule(MOD.logistics)   = module.logistics.view
--                    根表是 suppliers(读规则 module.suppliers.view)—— M3:页面的码是门,根行自己的改动逐行判
--   lane · port    → /logistics/lanes(只有清单页,按条合起来,见 app/components/trail/ListTrail.tsx)module.logistics.view
--   company_licence → /purchasing/licences(只有清单页)门是 module.purchasing.view,而这张表的读规则是
--                    module.suppliers.view —— 这一块只画在持 suppliers.view 的那一支里(页面本来就那样分),所以登记后者
-- AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a 的主数据与工具):
--   material       → /materials/[id]/edit(只有这一页,Q2)requireModule(MOD.materials) = module.materials.view
--   storage_location → /inventory/locations/[id]/edit(只有这一页)requireModule(MOD.inventory) = module.inventory.view
--   metal_price    → /tools/pricing/metal-prices/[id]/edit(只有这一页)requireEditPermission('action.metal_prices')
--   pricing_formula → /tools/pricing/formulas/[id]/edit(只有这一页)requireModule(MOD.pricing) = module.pricing.view
--   task           → /tools/tasks/[id]                requireModule(MOD.tasks)       = module.tasks.view
--                    私人任务也读得到(Q3):根行要过 tasks 自己的读规则(团队任务 · 自己的 · 或持 module.tasks.view_all)——
--                    那正是"谁打得开这一页"的同一个判据,而遮蔽那一步本来就先问任务隐私
--   processing_settings → /operation/orders 的工单阈值面板          module.processing.view;M6:只取面板编辑的两列
--   pricing_settings    → /tools/pricing/metal-prices 的异常阈值面板  module.pricing.view;M6:只取那一列
--   receiving_settings  → /purchasing/discrepancies 的收货阈值面板   module.inbound.view(面板只画在这一支里);M6:三列
--                    三张都是单行表,主键 id boolean —— M5:页面传 'true',读法按根行自己的类型重建那个键
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第一刀:账上的单据):
--   journal_entry   → /finance/journal/[id]             requireModule(MOD.finance)     = module.finance.view
--   invoice         → /finance/invoices/[id]            requireModule(MOD.finance)     = module.finance.view
--   credit_note     → /finance/credit-notes/[id]        requireModule(MOD.finance)     = module.finance.view
--   payment         → /finance/payments/[id]            requireModule(MOD.finance)     = module.finance.view
--   payment_request → /finance/payment-requests/[id]    requireModule(MOD.finance)     = module.finance.view
--                    (行内转账、代扣税缴纳与它们的冲销也住在这一页 —— 它们没有自己的页,Q17)
--   expense         → /finance/expenses/[id]            requireModule(MOD.finance)     = module.finance.view
--   payable         → /finance/payables/[batchId]       requireModule(MOD.finance)     = module.finance.view
--                    根表是 inbound_batches(读规则 module.inbound.view)—— M3:页面的码是门(Q5,forwarder 的先例);
--                    M6:只取应付那几列(数量、单价、供应商、采购单、计价状态、到货日、注销三列)—— 批次的仓库那一面
--                    (化验、安全状态、库位……)住在 /inbound/[id]/edit 的 inbound_batch 上,不在应付页上再说一遍。
--                    注销那三列必须在里面:M6 丢掉 root_columns 之外的戳(record_trail),不在里面注销就看不见(Q5 的横幅)。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第二刀:其余的单据与合同):
--   sale            → /finance/receivables/[saleId]     requireModule(MOD.finance)     = module.finance.view
--   freight         → /finance/freight/[id]             requireModule(MOD.finance)     = module.finance.view
--                    (根表的读规则是 inbound.view OR finance.view,再加一条 finance.edit 的 ALL —— 页面的码过得了,不需要 M3)
--   fixed_asset     → /finance/assets/[id]              requireModule(MOD.finance)     = module.finance.view
--                    根表与 equipment 同一张 fixed_assets(supplier / forwarder 的先例:一张表两个主语,Q10)——
--                    equipment 的门是加工,这一页的门是财务;根表的读规则就是 finance.view,所以是 'table'
--   bank_statement  → /finance/bank/statements/[id]     requireModule(MOD.finance)     = module.finance.view
--                    删掉的对账单也读得到(Q6:持 data.view_deleted 的人只读打开;根表的读规则不过滤已删的行)
--   gst_period      → /finance/gst/[periodId]           requireModule(MOD.finance)     = module.finance.view
--   fx_rate         → /finance/fx/[id]/edit(只有这一页,Q2)requireModule(MOD.finance) = module.finance.view
--                    撤回了的汇率也读得到(Q7:页面对本来的读者只读打开)
--   management_pack → /finance/packs/[id]               requireModule(MOD.finance)     = module.finance.view
--   contract        → /contracts/[id]                   requireModule(MOD.suppliers)   = module.suppliers.view
--                    根表的读规则按方向:卖方合同要 customers.view、买方合同要 suppliers.view —— 页面在 RLS 下读、读不到就 404,
--                    所以 'table' 与页面同一个答案(看不见的合同对他而言不存在)
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第三刀:期末、设置与清单页上的记录):
--   finance_lock    → /finance/settings 锁期面板之下 · /finance/close 关账史之下(Q25 · Q29)  module.finance.view
--                    根表 finance_settings(单行,id boolean —— M5,页面传 'true');M6:只取 locked_before 一列;
--                    月结 / 反结(period_closes)经 M7 整张表属于这一行(两张表之间一个键都没有,Q3)
--   finance_gst     → /finance/settings GST 面板之下                                       module.finance.view
--                    同一行(M5);M6:只取 gst_registered、gst_registration_no 两列 —— 两块面板各看各的(Q25);
--                    这一行上没有面板的六列(gst_rate_pct · system_start_date · 三个财年列 · default_allocation_basis)
--                    哪一块都不取,只在 /settings/change-history 上找得到(Q4);审批方针那四列归 AT-1d(Q2)
--   company_profile → /finance/company                                                     requireModule(MOD.finance)
--                    单行(M5),整行 —— 一块面板编辑整行;银行那五列按 HISTORY-1 的规则对不持 data.view_banking 的人遮
--   year_close      → /finance/close 年结那一块(清单块,ListTrail)                          module.finance.view
--   journal_request → /finance/journal 每一张申请卡片里(Q17,一张一块)                     module.finance.view
--   expense_claim   → /finance/claims 每一张报销单一块(Q20)                                module.finance.view
--   my_expense_claim → /me 报销人自己那几张(Q20 的另一半)—— ★ M8:没有页面码(view_codes 为空数组),
--                    根行自己那张表的读规则就是门(expense_claims:module.finance.view 或者【这张单说的就是你】);
--                    只许与 'table' 同用(record_trail 里拒绝 'page' —— 那会对每一个人敞开)。
--                    审批留痕那一支(approval_log 的 expense_claim)不给本人开口子,所以本人看到的是 Restricted(Q4)
--   bank_transfer   → /finance/bank 转账那一块(清单块)                                     module.finance.view
--   wht_remittance  → /finance/wht 缴纳那一块(清单块)                                      module.finance.view
--   cash_forecast · cash_forecast_line → /finance/cash-forecast(清单块,Q16:冻结 + 作废旧的一张是一次操作)
--   bank_import_profile → /finance/bank/import(清单块,删掉的也读)                         module.finance.view
--   (重估 / 折旧 / 工资付款 / 加工成本结算的批次与批量汇率【不】另立主语:它们各自的清单块读 journal_entry · expense ·
--    fx_rate 那几个现成主语,Q16 的 op_key 把一次操作并成一条 —— Q18 · Q19)
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第一刀:机制、设置与员工):
--   account         → /settings/accounts 每一行一块(Q24)        requireManagePermissions()     = action.manage_permissions
--                    ★ M9:根表 auth.users 不在 public 里 —— trail_log_only_tables() 给它一份安全投影与声明的读码;
--                    事件(建立 / 停用 / 恢复 / 失败 / 回滚)住在 change_log(record_account_event)
--   approval_policy → /settings/approvals(Q25,1c 的 Q2 挪过来)requireFunction(FN.approvals) = action.manage_permissions
--                    同一行 finance_settings(M5);M6:只取它编辑的四列;修改史 finance_settings_history 经 M7 整张属于这一行。
--                    根表的读规则是 module.finance.view —— 'table':读者两个码都要(线上唯一持 manage_permissions 的 admin 两个都有,Q23)
--   employee        → /hr/employees/[id]                        requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这就是你】—— 与页面同一个答案
--   department      → /hr/departments/[id]/edit(只有这一页)   requireModule(MOD.hr)          = module.hr.view
--   training_record → /hr/training/[id]/edit(只有这一页,Q29) requireModule(MOD.hr)          = module.hr.view
--   import_batch    → /settings/import 的批次一块(清单块,Q24) can('action.bulk_import')      = action.bulk_import
--   dictionary_*    → /settings/dictionaries 每一段一块(Q4)    每一段自己的查看码(registry.ts 的 viewPermission)
--                    ★ M11:'collection' —— 没有根行,那张字典表的每一行、change_log 里它的每一行都属于这一块;根键照写那张表的主键
--                    (code),record_trail 不用它。
--   ☞ M12('gate:reviewer')本刀没有主语用它(它的第一个用户是 AT-1d-3 的 /my-reviews);fixture 244 用一个临时主语证它。
-- 【后面几刀加主语】加一行这里、在 trail_subject_members 里登记它的子行与相关行、需要的话在
--   trail_prelog_sources 里登记"记录开始之前"的来源,然后在 lib/trail/ 里补它的措辞 —— 见 docs/change-log.md §9。
CREATE OR REPLACE FUNCTION public.trail_subjects()
 RETURNS TABLE(subject text, view_codes text[], root_table text, root_key text, root_rule text, root_columns text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_order',    ARRAY['module.purchasing.view'],    'purchase_orders',    'id', 'table', NULL::text[]),
        ('processing_run',    ARRAY['module.processing.view'],    'processing_runs',    'id', 'table', NULL),
        ('role',              ARRAY['action.manage_permissions'], 'roles',              'id', 'table', NULL),
        ('inbound_batch',     ARRAY['module.inbound.view'],       'inbound_batches',    'id', 'table', NULL),
        ('output_batch',      ARRAY['module.output.view'],        'output_batches',     'id', 'table', NULL),
        ('work_order',        ARRAY['module.processing.view'],    'work_orders',        'id', 'table', NULL),
        ('stocktake',         ARRAY['module.stocktakes.view'],    'stocktakes',         'id', 'table', NULL),
        ('equipment',         ARRAY['module.processing.view'],    'fixed_assets',       'id', 'page',  NULL),
        ('shift_handover',    ARRAY['module.processing.view'],    'shift_handovers',    'id', 'table', NULL),
        ('warehouse_request', ARRAY['module.inventory.view', 'module.finance.view'], 'warehouse_requests', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-2
        ('quote',             ARRAY['module.sales.view'],         'quotes',             'id', 'table', NULL),
        ('sales_order',       ARRAY['module.sales.view'],         'sales_orders',       'id', 'table', NULL),
        ('shipment',          ARRAY['module.sales.view', 'action.ship_goods'], 'shipments', 'id', 'table', NULL),
        ('customer',          ARRAY['module.customers.view'],     'customers',          'id', 'table', NULL),
        ('commission_agreement', ARRAY['module.suppliers.view'],  'commission_agreements', 'id', 'table', NULL),
        ('supplier',          ARRAY['module.suppliers.view'],     'suppliers',          'id', 'table', NULL),
        ('container',         ARRAY['module.logistics.view'],     'containers',         'id', 'table', NULL),
        ('forwarder',         ARRAY['module.logistics.view'],     'suppliers',          'id', 'page',  NULL),
        ('lane',              ARRAY['module.logistics.view'],     'lanes',              'id', 'table', NULL),
        ('port',              ARRAY['module.logistics.view'],     'ports',              'id', 'table', NULL),
        ('company_licence',   ARRAY['module.suppliers.view'],     'company_compliance', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-3
        ('material',          ARRAY['module.materials.view'],     'materials',          'id', 'table', NULL),
        ('storage_location',  ARRAY['module.inventory.view'],     'storage_locations',  'id', 'table', NULL),
        ('metal_price',       ARRAY['action.metal_prices'],       'metal_prices',       'id', 'table', NULL),
        ('pricing_formula',   ARRAY['module.pricing.view'],       'pricing_formulas',   'id', 'table', NULL),
        ('task',              ARRAY['module.tasks.view'],         'tasks',              'id', 'table', NULL),
        ('processing_settings', ARRAY['module.processing.view'],  'processing_settings', 'id', 'table',
            ARRAY['wo_input_overrun_pct', 'wo_output_shortfall_pct']),
        ('pricing_settings',  ARRAY['module.pricing.view'],       'pricing_settings',   'id', 'table',
            ARRAY['metal_price_change_warn_pct']),
        ('receiving_settings', ARRAY['module.inbound.view'],      'receiving_settings', 'id', 'table',
            ARRAY['grn_short_pct', 'grn_over_pct', 'grn_assay_tolerance_pct']),
        -- AUDIT-TRAIL-1c-1
        ('journal_entry',     ARRAY['module.finance.view'],       'journal_entries',    'id', 'table', NULL),
        ('invoice',           ARRAY['module.finance.view'],       'invoices',           'id', 'table', NULL),
        ('credit_note',       ARRAY['module.finance.view'],       'credit_notes',       'id', 'table', NULL),
        ('payment',           ARRAY['module.finance.view'],       'payments',           'id', 'table', NULL),
        ('payment_request',   ARRAY['module.finance.view'],       'payment_requests',   'id', 'table', NULL),
        ('expense',           ARRAY['module.finance.view'],       'expenses',           'id', 'table', NULL),
        ('payable',           ARRAY['module.finance.view'],       'inbound_batches',    'id', 'page',
            ARRAY['supplier_id', 'purchase_order_id', 'quantity', 'unit', 'unit_price', 'pricing_status', 'arrival_date',
                  'deleted_at', 'deleted_by', 'delete_reason']),
        -- AUDIT-TRAIL-1c-2
        ('sale',              ARRAY['module.finance.view'],       'sales_records',      'id', 'table', NULL),
        ('freight',           ARRAY['module.finance.view'],       'freight_documents',  'id', 'table', NULL),
        ('fixed_asset',       ARRAY['module.finance.view'],       'fixed_assets',       'id', 'table', NULL),
        ('bank_statement',    ARRAY['module.finance.view'],       'bank_statements',    'id', 'table', NULL),
        ('gst_period',        ARRAY['module.finance.view'],       'gst_periods',        'id', 'table', NULL),
        ('fx_rate',           ARRAY['module.finance.view'],       'fx_rates',           'id', 'table', NULL),
        ('management_pack',   ARRAY['module.finance.view'],       'management_packs',   'id', 'table', NULL),
        ('contract',          ARRAY['module.suppliers.view'],     'contracts',          'id', 'table', NULL),
        -- AUDIT-TRAIL-1c-3
        ('finance_lock',      ARRAY['module.finance.view'],       'finance_settings',   'id', 'table', ARRAY['locked_before']),
        ('finance_gst',       ARRAY['module.finance.view'],       'finance_settings',   'id', 'table',
            ARRAY['gst_registered', 'gst_registration_no']),
        ('company_profile',   ARRAY['module.finance.view'],       'company_profile',    'id', 'table', NULL),
        ('year_close',        ARRAY['module.finance.view'],       'year_closes',        'id', 'table', NULL),
        ('journal_request',   ARRAY['module.finance.view'],       'journal_requests',   'id', 'table', NULL),
        ('expense_claim',     ARRAY['module.finance.view'],       'expense_claims',     'id', 'table', NULL),
        ('my_expense_claim',  ARRAY[]::text[],                    'expense_claims',     'id', 'table', NULL),
        ('bank_transfer',     ARRAY['module.finance.view'],       'bank_transfers',     'id', 'table', NULL),
        ('wht_remittance',    ARRAY['module.finance.view'],       'wht_remittances',    'id', 'table', NULL),
        ('cash_forecast',     ARRAY['module.finance.view'],       'cash_forecasts',     'id', 'table', NULL),
        ('cash_forecast_line', ARRAY['module.finance.view'],      'cash_forecast_lines', 'id', 'table', NULL),
        ('bank_import_profile', ARRAY['module.finance.view'],     'bank_import_profiles', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-1
        ('account',           ARRAY['action.manage_permissions'], 'auth.users',         'id', 'table', NULL),
        ('approval_policy',   ARRAY['action.manage_permissions'], 'finance_settings',   'id', 'table',
            ARRAY['approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code']),
        ('employee',          ARRAY['module.hr.view'],            'employees',          'id', 'table', NULL),
        ('department',        ARRAY['module.hr.view'],            'departments',        'id', 'table', NULL),
        ('training_record',   ARRAY['module.hr.view'],            'training_records',   'id', 'table', NULL),
        ('import_batch',      ARRAY['action.bulk_import'],        'import_batches',     'id', 'table', NULL),
        ('dictionary_substances',          ARRAY['module.materials.view'], 'substances',             'code', 'collection', NULL),
        ('dictionary_battery_chemistries', ARRAY['module.materials.view'], 'battery_chemistries',    'code', 'collection', NULL),
        ('dictionary_material_kinds',      ARRAY['module.materials.view'], 'material_kinds',         'code', 'collection', NULL),
        ('dictionary_inbound_safety_states', ARRAY['module.materials.view'], 'inbound_safety_states', 'code', 'collection', NULL),
        ('dictionary_laboratories',        ARRAY['module.inbound.view'],   'laboratories',           'code', 'collection', NULL),
        ('dictionary_inbound_source_reasons', ARRAY['module.inbound.view'], 'inbound_source_reasons', 'code', 'collection', NULL)
    ) AS s(subject, view_codes, root_table, root_key, root_rule, root_columns);
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
        ('employee', 9, 'user_roles',               'auth.users',             'user_id',     '{}'::jsonb, 'down', true, false)
        -- ── 部门 · 培训记录 · 导入批次:没有成员。六本字典:M11 集合,没有成员 ──────────────────────────────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- db/functions/trail_prelog_sources.sql
-- AUDIT-TRAIL-1a(Tim 的 Q1):变更记录开始【之前】的历史从哪里拼回来 —— 每张表一行或几行。
--   kind = 'created':这一行本身就是一件事(领域历史表的一行、一次签发、一条授权、一张单据的创建)。
--        at_column / by_column 是它发生的时刻与做它的人;影像取这一行今天的值
--        (历史表只增不改,所以就是当时的值;单据本身则是今天的值 —— 分界线上的说明句替读者说清楚)。
--   kind = 'stamp':一对生命周期戳(关闭、删除、分摊、释放……)。只知道它【之后】是什么,不知道之前 ——
--        所以拼出来的是一次只有"新值"的改动,changed 列 = at/by + extra 列。
--   by_column 为 NULL:这张表当时没有记人 —— 界面说"Not recorded",不猜。
-- AUDIT-TRAIL-1b-1(M2):by_kind 说 by_column 里存的是【谁的 id】:
--   'account'  一个登录账号(auth.uid() 写的 —— 绝大多数);经 account_person() 认人。
--   'employee' 一个员工 id(current_user_employee() 写的:交接班的确认人;1b-3 的任务那一族全是这种)。
--   记成 account 的员工 id 会被当成一个找不到的账号,读成"Removed account" —— 那是一句错话,不是一次"不知道"。
-- 【绝不重复】(Q1)record_trail 只拼 at_column 早于 change_log_began_at() 的,并且 change_log 里已经记着
--   这一行的 INSERT(created)或这一戳的改动(stamp)时一律跳过 —— 同一件事不会出现两次。
-- 【为什么采购单的取消、批准不在 stamp 里】它们各有一行领域历史(purchase_order_history 'cancelled'、approval_log),
--   再拼一次戳就是两次。同理:工单的关闭 / 取消(work_order_history)、仓库申请与收货定价申请的决定(approval_log)
--   都不登记戳。
-- 【一个例外,Tim 的 Q11】盘点的 posted_at:22/09/2026 之前过账的盘点【只有】这一戳(那时过账还不写 approval_log)。
--   之后过账的同一笔事务里两边都有 —— 时刻相同,归成一条,界面把"过账"与"批准"并成一句(lib/trail/render.ts)。
CREATE OR REPLACE FUNCTION public.trail_prelog_sources()
 RETURNS TABLE(table_name text, kind text, at_column text, by_column text, extra text[], by_kind text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_orders',                'created', 'created_at',   'created_by',   NULL::text[], 'account'),
        ('purchase_orders',                'stamp',   'closed_at',    NULL,           ARRAY['status'], 'account'),
        ('purchase_orders',                'stamp',   'deleted_at',   'deleted_by',   ARRAY['delete_reason'], 'account'),
        ('purchase_order_lines',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('purchase_order_payment_terms',   'created', 'created_at',   NULL,           NULL, 'account'),
        ('purchase_order_payment_terms',   'stamp',   'expected_date_set_at', 'expected_date_set_by', ARRAY['expected_date'], 'account'),
        ('purchase_order_line_retentions', 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('purchase_order_line_retentions', 'stamp',   'released_at',  'released_by',  ARRAY['released_amount_ccy', 'withheld_amount_ccy', 'withholding_reason'], 'account'),
        ('pricing_term_commitments',       'created', 'committed_at', 'committed_by', NULL, 'account'),
        ('po_issues',                      'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('contract_document_terms',        'created', 'linked_at',    'linked_by',    NULL, 'account'),
        ('approval_log',                   'created', 'decided_at',   'actor_user_id', NULL, 'account'),
        ('purchase_order_history',         'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('processing_runs',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('processing_runs',                'stamp',   'allocated_at', 'allocated_by', ARRAY['allocation_basis', 'capitalized_cost_base', 'capitalization_entry_id'], 'account'),
        ('processing_runs',                'stamp',   'deleted_at',   'deleted_by',   ARRAY['status', 'delete_reason'], 'account'),
        ('processing_inputs',              'created', 'created_at',   NULL,           NULL, 'account'),
        ('processing_outputs',             'created', 'created_at',   NULL,           NULL, 'account'),
        ('processing_cost_entry_history',  'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('batch_processing_cost_allocations', 'created', 'created_at', 'created_by',  NULL, 'account'),
        ('processing_run_losses',          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('roles',                          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('roles',                          'stamp',   'deleted_at',   NULL,           ARRAY['is_active'], 'account'),
        ('role_permissions',               'created', 'created_at',   'created_by',   NULL, 'account'),
        -- ── 批次(1b-1)────────────────────────────────────────────────────────────────────────────────
        -- 时刻取建行的那一刻(created_at):同一笔事务写下的行 now() 相同,于是收货与它的入库流水归成一条
        ('inbound_batches',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('inbound_batches',                'stamp',   'deleted_at',   'deleted_by',   ARRAY['delete_reason'], 'account'),
        ('inbound_batches',                'stamp',   'import_permit_verified_at', 'import_permit_verified_by', ARRAY['import_permit_ref'], 'account'),
        ('inbound_batches',                'stamp',   'source_reason_recorded_at', 'source_reason_recorded_by', ARRAY['source_reason_code', 'source_reason_note'], 'account'),
        ('output_batches',                 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('output_batches',                 'stamp',   'deleted_at',   'deleted_by',   ARRAY['delete_reason'], 'account'),
        ('inbound_batch_metals',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('output_batch_metals',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('assay_results',                  'created', 'created_at',   'created_by',   NULL, 'account'),
        ('assay_results',                  'stamp',   'applied_at',   'applied_by',   NULL, 'account'),
        ('assay_results',                  'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('assay_result_metals',            'created', 'created_at',   NULL,           NULL, 'account'),
        ('inbound_batch_safety_states',    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('output_batch_safety_states',     'created', 'created_at',   'created_by',   NULL, 'account'),
        ('price_history',                  'created', 'created_at',   'created_by',   NULL, 'account'),
        ('receipt_price_requests',         'created', 'created_at',   'created_by',   NULL, 'account'),
        ('receipt_price_requests',         'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('prepayment_applications',        'created', 'created_at',   'created_by',   NULL, 'account'),
        ('inventory_movements',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('stocktake_lines',                'created', 'counted_at',   'created_by',   NULL, 'account'),
        ('stocktake_counts',               'created', 'counted_at',   'counted_by',   NULL, 'account'),
        ('certificates_of_destruction',    'created', 'created_at',   'issued_by',    NULL, 'account'),
        ('certificates_of_destruction',    'stamp',   'voided_at',    'voided_by',    ARRAY['void_reason'], 'account'),
        ('cod_issues',                     'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('warehouse_requests',             'created', 'created_at',   'created_by',   NULL, 'account'),
        ('warehouse_requests',             'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('freight_allocations',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('payment_allocations',            'created', 'created_at',   NULL,           NULL, 'account'),
        ('finance_attachments',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('finance_attachments',            'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('journal_entries',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('sales_records',                  'created', 'created_at',   'created_by',   NULL, 'account'),
        ('sales_record_movements',         'created', 'created_at',   NULL,           NULL, 'account'),
        ('sales_attribution_log',          'created', 'attributed_at', 'attributed_by', NULL, 'account'),
        ('invoice_lines',                  'created', 'created_at',   NULL,           NULL, 'account'),
        ('sales_order_reservations',       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('sales_order_reservations',       'stamp',   'released_at',  'released_by',  ARRAY['release_reason'], 'account'),
        ('sales_order_reservations',       'stamp',   'consumed_at',  'consumed_by',  NULL, 'account'),
        ('shipment_lines',                 'created', 'created_at',   NULL,           NULL, 'account'),
        ('traceability_report_issues',     'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('sales_settlements',              'created', 'computed_at',  'computed_by',  NULL, 'account'),
        ('sales_order_history',            'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('work_order_history',             'created', 'changed_at',   'changed_by',   NULL, 'account'),
        -- ── 工单 · 盘点(1b-1)──────────────────────────────────────────────────────────────────────────
        ('work_orders',                    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('work_order_lines',               'created', 'created_at',   NULL,           NULL, 'account'),
        ('work_order_expected_outputs',    'created', 'created_at',   NULL,           NULL, 'account'),
        ('stocktakes',                     'created', 'created_at',   'created_by',   NULL, 'account'),
        ('stocktakes',                     'stamp',   'cancelled_at', 'cancelled_by', ARRAY['status', 'cancel_reason'], 'account'),
        ('stocktakes',                     'stamp',   'posted_at',    NULL,           ARRAY['status'], 'account'),
        -- ── 设备 · 交接班(1b-1)────────────────────────────────────────────────────────────────────────
        ('fixed_assets',                   'created', 'created_at',   'created_by',   NULL, 'account'),
        ('equipment_maintenance',          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('equipment_downtime',             'created', 'created_at',   'created_by',   NULL, 'account'),
        ('equipment_downtime',             'stamp',   'ended_at',     NULL,           NULL, 'account'),
        ('equipment_service_intervals',    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('shift_handovers',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('shift_handovers',                'stamp',   'acknowledged_at', 'acknowledged_by', NULL, 'employee'),
        ('shift_handover_items',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('shift_handover_equipment_refs',  'created', 'created_at',   'created_by',   NULL, 'account'),
        -- ── AUDIT-TRAIL-1b-2 · 商务 ────────────────────────────────────────────────────────────────────
        -- 报价 / 订单:单据的建单那一刻【与】它事件史的 created 行都登记 —— 两者是同一笔事务写的(实测 created_at =
        --   changed_at,逐条),于是归成一条,界面把两者并成一句(lib/trail/render.ts);没有事件史的那两张测试订单
        --   (ZZ2B-SO1/2)因此也有一条"建单"。签发档(qt_issues · so_issues)【不登记】:事件史的 issued 已经记着(Step 0
        --   §a,Tim 的裁定)。订单的 confirmed / closed / cancelled 戳【不登记】:事件史里都有。
        --   预留的三个戳(建 · 放回 · 用掉)1b-1 已为批次页登记;在订单页上它们与事件史的 reserved / released / shipped
        --   是同一笔事务、同一时刻(实测),归成一条,界面并成一句。
        ('quotes',                         'created', 'created_at',   'created_by',   NULL, 'account'),
        ('quote_lines',                    'created', 'created_at',   NULL,           NULL, 'account'),
        ('quote_history',                  'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('sales_orders',                   'created', 'created_at',   'created_by',   NULL, 'account'),
        ('sales_order_lines',              'created', 'created_at',   NULL,           NULL, 'account'),
        ('shipping_releases',              'created', 'created_at',   'created_by',   NULL, 'account'),
        ('shipping_releases',              'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('shipping_release_lines',         'created', 'created_at',   NULL,           NULL, 'account'),
        ('shipments',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('shipment_issues',                'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('customers',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('counterparty_contacts',          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('counterparty_contacts',          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('customer_attachments',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('customer_attachments',           'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('customer_credit_history',        'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('customer_statements',            'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('customer_statements',            'stamp',   'superseded_at', NULL,          ARRAY['superseded_reason', 'superseded_by'], 'account'),
        ('statement_issues',               'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('collection_chases',              'created', 'created_at',   'chased_by',    NULL, 'account'),
        ('collection_chases',              'stamp',   'superseded_at', NULL,          ARRAY['superseded_reason', 'superseded_by'], 'account'),
        ('collection_chase_documents',     'created', 'created_at',   NULL,           NULL, 'account'),
        ('collection_promises',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('collection_promises',            'stamp',   'outcome_recorded_at', 'outcome_recorded_by', ARRAY['outcome', 'outcome_note'], 'account'),
        ('commission_agreements',          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('commission_agreements',          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        -- 供应商:批准那一戳登记 —— supplier_status_history 与 approval_log 的供应商那一支都是 24/09 才有的(ROLE-1 Batch 2a),
        --   而在那之前批准过的供应商只剩这一戳;之后批准的,同一笔事务里三边同一时刻,归成一条,审批并进状态那一句。
        ('suppliers',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('suppliers',                      'stamp',   'approved_at',  'approved_by',  NULL, 'account'),
        ('supplier_compliance',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('supplier_compliance',            'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('supplier_attachments',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('supplier_attachments',           'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('supplier_status_history',        'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('containers',                     'created', 'created_at',   'created_by',   NULL, 'account'),
        ('container_milestones',           'created', 'recorded_at',  'recorded_by',  NULL, 'account'),
        ('container_documents',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('forwarder_details',              'created', 'created_at',   'created_by',   NULL, 'account'),
        ('forwarder_rate_quotes',          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('forwarder_rate_quotes',          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('lanes',                          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('lanes',                          'stamp',   'checklist_reviewed_at', NULL,  NULL, 'account'),
        ('lanes',                          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('lane_document_requirements',     'created', 'created_at',   'created_by',   NULL, 'account'),
        ('lane_document_requirements',     'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('ports',                          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('ports',                          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('company_compliance',             'created', 'created_at',   'created_by',   NULL, 'account'),
        ('company_compliance',             'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        -- ── AUDIT-TRAIL-1b-3 · 主数据与工具 ────────────────────────────────────────────────────────────
        -- 物料、库位、金属价格:没有历史表,只有建行那一刻与删除那一戳(这几张表从来没有记过【谁】删的 —— by 为 NULL,
        --   界面说 "Not recorded",横幅只说日期,Q8)
        ('materials',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('materials',                      'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('material_attachments',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('material_attachments',           'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('material_required_metals',       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('storage_locations',              'created', 'created_at',   'created_by',   NULL, 'account'),
        ('storage_location_allowed_classes', 'created', 'created_at', 'created_by',   NULL, 'account'),
        ('metal_prices',                   'created', 'created_at',   'created_by',   NULL, 'account'),
        ('metal_prices',                   'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        -- 公式:修改史(create / update / delete / restore / metal_set / metal_clear)是主线。公式本身的建行那一刻与它的应付金属
        --   【也】登记 —— 与 1b-2 的报价 / 订单同一个做法:修改史由 AFTER 触发器在同一笔事务里写,时刻相同,归成一条,界面并成
        --   一句(lib/trail/render.ts);而线上那一张公式早于修改史(修改史 0 行),不登记它就一条"建立"都没有。
        --   删除那一戳【不】登记:修改史的 delete 记着。
        ('pricing_formulas',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('pricing_formula_metals',         'created', 'created_at',   'created_by',   NULL, 'account'),
        ('pricing_formula_history',        'created', 'changed_at',   'changed_by',   NULL, 'account'),
        -- 条款申请:提出 · 撤回;决定由审批留痕说(approval_log 已登记,decided_at 那一戳不再登记)
        ('terms_requests',                 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('terms_requests',                 'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        -- 任务(M2:步骤与修改史里的人是【员工 id】):修改史只在团队任务上写(私人任务一行都不写,trg_tasks_history),
        --   所以私人任务"记录开始之前"那一段只能来自建行与戳 —— 任务的建立与删除、步骤的建立与打勾。
        --   团队任务上同一件事两边都有(步骤加上 = node_added,打勾 = node_done):同一笔事务、同一时刻,归成一条,
        --   界面按步骤认,只说一次(fixture 240 的 N 臂)。参与者【不】登记:每一次进出修改史都记着,
        --   唯一不记的是归属人自己那头一行 —— 那是有意的("变更记录记的是改动,不是初始状态")。
        ('tasks',                          'created', 'created_at',   'created_by',   NULL, 'account'),
        ('tasks',                          'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('task_nodes',                     'created', 'created_at',   'created_by',   NULL, 'employee'),
        ('task_nodes',                     'stamp',   'done_at',      'done_by',      ARRAY['done'], 'employee'),
        ('task_history',                   'created', 'changed_at',   'changed_by',   NULL, 'employee'),
        -- AUDIT-TRAIL-1c-1:账上的单据。★ Q9(Tim 2026-10-03):下面三个戳是那几件事【唯一】的记录,按 Q11 的例外登记 ——
        --   invoices.voided_at(线上三次作废都早于发票申请,没有申请、没有审批留痕)· payment_requests.paid_at(没有任何
        --   历史表记"付了")· expense_claims.decided_at(线上两张已决定的报销单,approval_log 里一行 expense_claim 都没有)。
        --   之后有审批留痕的那几次,两边同一笔事务、同一刻,归成一条,界面把审批并进那一句(render.ts 的 foldApprovals)。
        --   申请的决定(decided_at)其余一律【不】登记 —— approval_log 记着它,再拼一次戳就是两次。
        ('journal_lines',                  'created', 'created_at',   NULL,           NULL, 'account'),
        ('journal_requests',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('journal_requests',               'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('invoices',                       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('invoices',                       'stamp',   'voided_at',    'voided_by',    ARRAY['status', 'void_reason'], 'account'),
        ('invoice_issues',                 'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('invoice_requests',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('invoice_requests',               'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('credit_notes',                   'created', 'created_at',   'created_by',   NULL, 'account'),
        ('credit_note_lines',              'created', 'created_at',   NULL,           NULL, 'account'),
        ('cn_issues',                      'created', 'issued_at',    'issued_by',    NULL, 'account'),
        ('payments',                       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('payment_requests',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('payment_requests',               'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status'], 'account'),
        ('payment_requests',               'stamp',   'paid_at',      'paid_by',      ARRAY['status', 'result_payment_id', 'result_transfer_id', 'result_journal_entry_id'], 'account'),
        ('bank_transfers',                 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('bank_transfers',                 'stamp',   'reversed_at',  'reversed_by',  ARRAY['reversal_entry_id'], 'account'),
        ('wht_remittances',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('expenses',                       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('expense_claims',                 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('expense_claims',                 'stamp',   'decided_at',   'decided_by',   ARRAY['status', 'decision_notes', 'expense_id'], 'account'),
        ('expense_claims',                 'stamp',   'withdrawn_at', NULL,           ARRAY['status'], 'account'),
        ('fixed_asset_cost_entries',       'created', 'created_at',   'created_by',   NULL, 'account'),
        -- AUDIT-TRAIL-1c-2:其余的单据与合同。★ Q9(Tim 2026-10-03)的另外两个戳在这一刀登记 ——
        --   freight_documents.reversed_at(线上 4 张运费单全部冲销过,那是那件事唯一的记录)· bank_statements.reconciled_at
        --   (BS-2026-0002 对过账,却没有一行 bank_reconciliations —— 只有这一戳)。有对账记录的那几次,两边同一笔、同一刻
        --   (reconciled_at),归成一条,界面只说一次。
        --   修改史是主线的两张(fixed_asset_history、fx_rate_history):一件事两行(1b-3 的规矩)—— 记录开始之后变更记录那一行说,
        --   之前修改史那一行说;资产卡与汇率自己的建行那一刻【也】登记,同一笔、同一刻,界面并成一句(报价 / 订单的先例)。
        --   撤回汇率那一下【不】登记成戳(fx_rates 没有 deleted_by;withdraw_fx_rate 在同一笔里写一行 'withdrawn' 修改史,
        --   那一行就是这件事的记录 —— 再拼一次戳就是两次)。
        ('freight_documents',              'created', 'created_at',   'created_by',   NULL, 'account'),
        ('freight_documents',              'stamp',   'reversed_at',  'reversed_by',  ARRAY['status', 'reversal_reason', 'reversal_entry_id'], 'account'),
        ('fixed_asset_history',            'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('fixed_asset_depreciation',       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('fixed_asset_depreciation_anchors', 'created', 'created_at', 'created_by',   NULL, 'account'),
        ('asset_disposal_requests',        'created', 'created_at',   'created_by',   NULL, 'account'),
        ('asset_disposal_requests',        'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('bank_statements',                'created', 'created_at',   'created_by',   NULL, 'account'),
        ('bank_statements',                'stamp',   'reconciled_at', 'reconciled_by', ARRAY['status'], 'account'),
        ('bank_statements',                'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('bank_statement_lines',           'created', 'created_at',   NULL,           NULL, 'account'),
        ('bank_line_matches',              'created', 'created_at',   'created_by',   NULL, 'account'),
        ('bank_reconciliations',           'created', 'reconciled_at', 'reconciled_by', NULL, 'account'),
        ('bank_reconciliations',           'stamp',   'superseded_at', NULL,          ARRAY['superseded_reason'], 'account'),
        ('bank_reconciliation_variance_items', 'created', 'created_at', 'created_by', NULL, 'account'),
        ('gst_periods',                    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('gst_periods',                    'stamp',   'filed_at',     'filed_by',     ARRAY['status', 'filed_on', 'filed_reference'], 'account'),
        ('gst_return_boxes',               'created', 'created_at',   NULL,           NULL, 'account'),
        ('gst_filing_requests',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('gst_filing_requests',            'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('fx_rates',                       'created', 'created_at',   'created_by',   NULL, 'account'),
        ('fx_rate_history',                'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('management_packs',               'created', 'produced_at',  'produced_by',  NULL, 'account'),
        ('management_packs',               'stamp',   'superseded_at', NULL,          ARRAY['superseded_by', 'superseded_reason'], 'account'),
        ('contracts',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_grade_specs',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_insurance_obligations', 'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_volume_commitments',    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_pricing_terms',         'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_settlement_terms',      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_refining_charges',      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('contract_penalty_elements',      'created', 'created_at',   'created_by',   NULL, 'account'),
        -- AUDIT-TRAIL-1c-3:期末、设置与清单页上的记录。
        --   ★ finance_settings 与 company_profile【什么都不登记】:它们只有一对整行共用的 updated_at / updated_by,
        --     说不出改的是哪一块面板的哪一列(Step 0 §c)—— 记录开始之前没有任何一条"谁注册了 GST、何时"的记录,照直不说。
        --   锁期面板记录开始之前的内容就是 period_closes:关账的那一刻(created)与反结的那一戳(stamp)。
        --   年结同形;现金预测:冻结那一刻 + 被取代那一戳(superseded_by 是【一张预测的 id】,不是人 —— 所以戳上不记人);
        --   导入模板:建立 + 删除那一戳(表里没有 deleted_by)。报销单、人工分录申请、转账、缴纳在 1c-1 已经登记。
        ('period_closes',                  'created', 'closed_at',    'closed_by',    NULL, 'account'),
        ('period_closes',                  'stamp',   'reopened_at',  'reopened_by',  ARRAY['reopen_reason'], 'account'),
        ('year_closes',                    'created', 'closed_at',    'closed_by',    NULL, 'account'),
        ('year_closes',                    'stamp',   'reopened_at',  'reopened_by',  ARRAY['reopen_reason', 'reversal_journal_id'], 'account'),
        ('cash_forecasts',                 'created', 'frozen_at',    'frozen_by',    NULL, 'account'),
        ('cash_forecasts',                 'stamp',   'superseded_at', NULL,          ARRAY['superseded_by', 'superseded_reason'], 'account'),
        ('cash_forecast_lines',            'created', 'created_at',   'created_by',   NULL, 'account'),
        ('bank_import_profiles',           'created', 'created_at',   'created_by',   NULL, 'account'),
        ('bank_import_profiles',           'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        -- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q12):这几样是那几件事【唯一】的记录,按 Q11 / 1c Q9 的例外登记 ——
        --   账号的建立(auth.users.created_at;没有记人 —— "Not recorded")· 授权与收回(user_roles 的两对戳:线上 9 次授予、
        --   2 次收回全在记录开始之前)· 附加账号的挂接(employee_accounts 与它的挂接史:同一笔、同一刻,界面说一次)·
        --   审批方针的修改史(22/09/2026 那一次开审批)· 导入批次。
        --   员工:建立 + 删除那一戳(表里没有 deleted_by)+ 匿名化那一戳;任职履历:每一行就是一件事。★ 薪资执行写的那一行
        --   created_by 记的是【提出申请的人】,不是批准执行的人(salary_change_execute_internal,Q31)—— 线上记录开始之前
        --   一行这种都没有(调薪申请 0 行);之后那一刻的"谁"由变更记录说(批准的人)。
        --   调薪申请:提出 + 撤回;决定由审批留痕说(decided_at / executed_at 不登记)。部门、培训记录:建立 + 删除那一戳。
        ('auth.users',                     'created', 'created_at',   NULL,           NULL, 'account'),
        ('user_roles',                     'created', 'granted_at',   'granted_by',   NULL, 'account'),
        ('user_roles',                     'stamp',   'revoked_at',   'revoked_by',   ARRAY['revoke_reason'], 'account'),
        ('employee_accounts',              'created', 'linked_at',    'linked_by',    NULL, 'account'),
        ('employee_account_history',       'created', 'changed_at',   'actor_user_id', NULL, 'account'),
        ('finance_settings_history',       'created', 'changed_at',   'changed_by',   NULL, 'account'),
        ('import_batches',                 'created', 'imported_at',  'imported_by',  NULL, 'account'),
        ('employees',                      'created', 'created_at',   'created_by',   NULL, 'account'),
        ('employees',                      'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('employees',                      'stamp',   'anonymised_at', 'anonymised_by', NULL, 'account'),
        ('employment_history',             'created', 'created_at',   'created_by',   NULL, 'account'),
        ('salary_change_requests',         'created', 'created_at',   'created_by',   NULL, 'account'),
        ('salary_change_requests',         'stamp',   'withdrawn_at', 'withdrawn_by', ARRAY['status', 'withdraw_reason'], 'account'),
        ('departments',                    'created', 'created_at',   'created_by',   NULL, 'account'),
        ('departments',                    'stamp',   'deleted_at',   NULL,           NULL, 'account'),
        ('training_records',               'created', 'created_at',   'created_by',   NULL, 'account'),
        ('training_records',               'stamp',   'deleted_at',   NULL,           NULL, 'account')
    ) AS p(table_name, kind, at_column, by_column, extra, by_kind);
$function$;

-- db/functions/trail_ref_label.sql
-- AUDIT-TRAIL-1a(Tim 的 Q12 · Q13 · Q40):一个被引用的值 → 屏幕上认得出的名字。数据库解析,界面只负责造句。
--   返回 {"label": …, "gone": bool, "person": {…}}(person 只在 p_table = 'auth.users' 时有):
--   · 单据(document_types 登记的表)→ 单据编号(PO-2026-0010);客户 / 供应商 → 法定名;物料 → 名称;
--     员工 → 称呼名,没有就法定名;批次 → 编号 · 物料名(外加 unit);采购单明细行 → 采购单编号 line N;
--     字典(有 name_en 的表)→ name_en;币种 → 代码;其余依次试 name / legal_name / title / label。
--   · 一个都没有 → label 为 NULL,界面说 "a <thing>"。【绝不回落到 uuid 或内部代码】。
--   · 那一行已经被硬删 → 取 change_log 里它最后一份完整影像,gone = true(界面加 "(since deleted)");
--     连影像都没有(早于变更记录,或从未存在)→ label NULL + gone = true(界面说 "a … that has since been deleted")。
--   · 'auth.users':一个登录账号 → 那个人(trail_actor 同一套答法)。
-- AUDIT-TRAIL-1b-1:
--   · 加工单多带一个 ended(它已经回滚了)—— 批次页上"用在加工 PROC-…"那一条据此加一句灰字
--     "This processing was later rolled back"(旧批次记录的 run_voided,Q5)。
--   · 交接班 → "DD/MM/YYYY · 班次";停机 → "机器编号 · DD/MM/YYYY HH:MM"(新加坡时间)—— 两张表都没有编号或名字,
--     以前只能说 "a handover" / "a downtime"。
-- AUDIT-TRAIL-1b-2:订单 / 报价明细行 → "SO-… line N";港口 → "代码 名称";航段 → "起运港 → 目的港";
--   执照与合规证书 → "种类 · 编号";附件 → 文件名;集装箱单据 → 单据种类 —— 这几张表都没有编号或 name 一类的列。
--   物料多带一个 unit(与批次同一个做法):订单 / 报价明细行的数量据此说成 "10 kg"。
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 的 Q12 · Q33):
--   · 员工 → 走 trail_actor(与"谁做的"同一份答法):不持 module.hr.view 的读者只认得出他自己,别人一律 Restricted ——
--     与 ActorName、与每一页的人名同一条规矩(§9.7 早就说"每一个指着人的值都走同一个函数",而此前这一支直接把名字交了出去)。
--     付款、费用、报销单、付款申请上的 employee_id 都是这一种。匿名化了的人说 "A former employee"(以前是一个空名字)。
--   · 单据(document_types 里 link_mode = 'detail' 的)多带一个 href(详情页的路径)—— 审计记录里"被 JE-… 冲销"那一行
--     是一个链接(Q33),路径来自登记表,界面不拼路由。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §g · Q14):这几张表没有编号或名字,以前只能说 "a …":
--   · 销售 → "OUT-2026-0186 sale 01/08/2026"(卖的那一批 + 售出日;与 "PO-… line N" 同一种说法),外加 href 指向它的应收页
--     (Q14:销售没有 code 列,所以【不】进 document_types —— 进了,全站搜索会对它拼一句 SELECT code,当场报错;
--      Record 一栏的名字与链接由这里与 trail_row_record 给,与单据同一个形状);
--   · 汇率 → "USD · TT selling rate · 01/08/2026";对账单行 → "BS-… line N";分录行 → "JE-… · 科目";申报格 → "Box 1";
--     对账记录 → "BS-… reconciliation DD/MM/YYYY";折旧 → "FA-… · period ending DD/MM/YYYY"。
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a):这几张也没有编号或名字 ——
--   · 财务设置那一行 → "Finance settings";公司资料那一行 → "Company profile"(两张都是单行表,id = true);
--   · 月结 → "Period ending DD/MM/YYYY";年结 → "Year ending DD/MM/YYYY";
--   · 行内转账 → "Transfer DD/MM/YYYY · Cash at Bank – SGD → Cash at Bank – USD"(两头按科目表的名字说,不说 1000 / 1010)。
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a):
--   · 登录账号('auth.users')多带一个 label —— 认得出的那个人的名字(trail_actor 同一份答法:不持 hr.view 的读者只认得出
--     自己):/settings/change-history 的 Record 一栏(授权、附加账号的家是账号,Q22)读 label,不读 person。认不出就没有名字,
--     界面说 "a login account" —— 【不】回落到邮箱(那是账号的身份数据,不是它的名字)。
--   · 培训记录 → 培训的名字;导入批次 → 文件名(两张表都没有 name / title / label 一类的列)。
-- 【属主身份】按表名动态读;EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_ref_label(p_table text, p_column text, p_value text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_img   jsonb;
    v_gone  boolean := false;
    v_label text;
    v_doc   boolean;
    v_extra text;
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_table = 'auth.users' THEN
        IF p_value !~ '^[0-9a-fA-F-]{36}$' THEN
            RETURN NULL;
        END IF;
        v_img := trail_actor('prelog', p_value::uuid, NULL);
        RETURN jsonb_build_object('person', v_img, 'label', CASE WHEN v_img ->> 'state' = 'person' THEN v_img ->> 'name' END);
    END IF;
    IF to_regclass(format('public.%I', p_table)) IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_table = 'employees' AND p_column = 'id' THEN
        IF p_value !~ '^[0-9a-fA-F-]{36}$' THEN
            RETURN NULL;
        END IF;
        -- label 一并带回(只在认得出名字时):/settings/change-history 的 Record 一栏读 label,不读 person
        v_img := trail_actor('prelog', NULL, p_value::uuid);
        RETURN jsonb_build_object('person', v_img, 'gone', false,
                                  'label', CASE WHEN v_img ->> 'state' = 'person' THEN v_img ->> 'name' END);
    END IF;
    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.%I::text = $1 LIMIT 1', p_table, p_column)
       INTO v_img USING p_value;
    IF v_img IS NULL THEN
        v_gone := true;
        SELECT CASE WHEN c.op = 'DELETE' THEN c.old ELSE c.new END INTO v_img
          FROM change_log c
         WHERE c.table_name = p_table AND c.row_key = jsonb_build_object(p_column, p_value)
           AND c.op IN ('INSERT', 'DELETE')
         ORDER BY c.seq DESC LIMIT 1;
        IF v_img IS NULL THEN
            RETURN jsonb_build_object('label', NULL, 'gone', true);
        END IF;
    END IF;
    v_doc := EXISTS (SELECT 1 FROM document_types d WHERE d.table_name = p_table);
    v_label := CASE
        WHEN p_table = 'employees' THEN
            CASE WHEN v_img ->> 'anonymised_at' IS NULL
                 THEN COALESCE(NULLIF(v_img ->> 'preferred_name', ''), v_img ->> 'legal_name') END
        WHEN p_table IN ('suppliers', 'customers') THEN v_img ->> 'legal_name'
        WHEN p_table = 'materials' THEN v_img ->> 'name'
        WHEN p_table = 'currencies' THEN v_img ->> 'code'
        WHEN p_table = 'training_records' THEN v_img ->> 'training_name'
        WHEN p_table = 'import_batches' THEN v_img ->> 'file_name'
        WHEN p_table = 'purchase_order_lines' THEN
            (SELECT po.code FROM purchase_orders po WHERE po.id::text = v_img ->> 'purchase_order_id')
            || ' line ' || (v_img ->> 'line_no')
        WHEN v_doc AND v_img ? 'code' THEN v_img ->> 'code'
        WHEN v_img ? 'name_en' THEN v_img ->> 'name_en'
        WHEN v_img ? 'name' THEN v_img ->> 'name'
        WHEN v_img ? 'legal_name' THEN v_img ->> 'legal_name'
        WHEN v_img ? 'title' THEN v_img ->> 'title'
        WHEN v_img ? 'label' THEN v_img ->> 'label'
    END;
    IF p_table = 'shift_handovers' THEN
        v_label := to_char((v_img ->> 'handover_date')::date, 'DD/MM/YYYY')
                   || COALESCE(' · ' || (SELECT s.name_en FROM shifts s WHERE s.code = v_img ->> 'shift_code'), '');
    ELSIF p_table = 'equipment_downtime' THEN
        v_label := COALESCE((SELECT fa.code FROM fixed_assets fa WHERE fa.id::text = v_img ->> 'equipment_id') || ' · ', '')
                   || to_char(((v_img ->> 'started_at')::timestamptz) AT TIME ZONE 'Asia/Singapore', 'DD/MM/YYYY HH24:MI');
    ELSIF p_table IN ('sales_order_lines', 'quote_lines', 'invoice_lines') THEN
        -- AUDIT-TRAIL-1b-2:订单 / 报价的明细行 → "SO-2026-0001 line 1"(与采购单明细同一种说法)
        -- AUDIT-TRAIL-1c-1:发票明细行同一种说法(贷项通知的每一行冲的是发票的哪一行)
        v_label := CASE p_table
            WHEN 'sales_order_lines' THEN (SELECT so.code FROM sales_orders so WHERE so.id::text = v_img ->> 'sales_order_id')
            WHEN 'invoice_lines' THEN (SELECT i.code FROM invoices i WHERE i.id::text = v_img ->> 'invoice_id')
            ELSE (SELECT q.code FROM quotes q WHERE q.id::text = v_img ->> 'quote_id') END
            || ' line ' || (v_img ->> 'line_no');
    ELSIF p_table = 'ports' THEN
        -- 港口 → "SGSIN Singapore"(航段页、货代页上的同一种写法)
        v_label := concat_ws(' ', v_img ->> 'code', v_img ->> 'name');
    ELSIF p_table = 'lanes' THEN
        -- 航段没有名字 → "起运港 → 目的港"(两头各按港口那一句说)
        v_label := COALESCE((SELECT concat_ws(' ', pt.code, pt.name) FROM ports pt WHERE pt.id::text = v_img ->> 'origin_port_id'), '?')
                   || ' → ' ||
                   COALESCE((SELECT concat_ws(' ', pt.code, pt.name) FROM ports pt WHERE pt.id::text = v_img ->> 'destination_port_id'), '?');
    ELSIF p_table IN ('company_compliance', 'supplier_compliance') THEN
        -- 执照 / 证书 → "证书种类 · 编号"
        v_label := concat_ws(' · ', (SELECT ct.name_en FROM certificate_types ct WHERE ct.code = v_img ->> 'cert_type_code'),
                             NULLIF(v_img ->> 'cert_no', ''));
    ELSIF p_table IN ('customer_attachments', 'supplier_attachments') THEN
        v_label := v_img ->> 'file_name';
    ELSIF p_table = 'container_documents' THEN
        v_label := v_img ->> 'document_type';
    ELSIF p_table = 'sales_records' THEN
        v_label := COALESCE((SELECT ob.code FROM output_batches ob WHERE ob.id::text = v_img ->> 'output_batch_id') || ' sale ', 'Sale ')
                   || to_char((v_img ->> 'sale_date')::date, 'DD/MM/YYYY');
        RETURN jsonb_build_object('label', v_label, 'gone', v_gone)
               || CASE WHEN p_column = 'id' AND NOT v_gone
                       THEN jsonb_build_object('href', '/finance/receivables/' || p_value) ELSE '{}'::jsonb END;
    ELSIF p_table = 'fx_rates' THEN
        v_label := concat_ws(' · ', v_img ->> 'currency',
                             CASE v_img ->> 'rate_type' WHEN 'tt_buy' THEN 'TT buying rate' WHEN 'tt_sell' THEN 'TT selling rate'
                                                        WHEN 'mid' THEN 'Mid rate' END,
                             to_char((v_img ->> 'rate_date')::date, 'DD/MM/YYYY'));
    ELSIF p_table = 'journal_lines' THEN
        -- 对账单的一行匹配到的那一行分录 → "JE-2026-0001 · Cash at Bank – SGD"(分录号 · 科目)
        v_label := concat_ws(' · ', (SELECT je.code FROM journal_entries je WHERE je.id::text = v_img ->> 'entry_id'),
                             (SELECT a.name_en FROM accounts a WHERE a.id::text = v_img ->> 'account_id'));
    ELSIF p_table = 'bank_statement_lines' THEN
        v_label := (SELECT bs.code FROM bank_statements bs WHERE bs.id::text = v_img ->> 'statement_id') || ' line ' || (v_img ->> 'line_no');
    ELSIF p_table = 'gst_return_boxes' THEN
        v_label := 'Box ' || regexp_replace(v_img ->> 'box', '^box', '');
    ELSIF p_table = 'bank_reconciliations' THEN
        v_label := (SELECT bs.code FROM bank_statements bs WHERE bs.id::text = v_img ->> 'statement_id')
                   || ' reconciliation ' || to_char(((v_img ->> 'reconciled_at')::timestamptz) AT TIME ZONE 'Asia/Singapore', 'DD/MM/YYYY');
    ELSIF p_table = 'fixed_asset_depreciation' THEN
        v_label := (SELECT fa.code FROM fixed_assets fa WHERE fa.id::text = v_img ->> 'asset_id')
                   || ' · period ending ' || to_char((v_img ->> 'period_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'finance_settings' THEN
        v_label := 'Finance settings';
    ELSIF p_table = 'company_profile' THEN
        v_label := 'Company profile';
    ELSIF p_table = 'period_closes' THEN
        v_label := 'Period ending ' || to_char((v_img ->> 'period_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'year_closes' THEN
        v_label := 'Year ending ' || to_char((v_img ->> 'year_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'bank_transfers' THEN
        v_label := 'Transfer ' || to_char((v_img ->> 'transfer_date')::date, 'DD/MM/YYYY') || ' · '
                   || COALESCE((SELECT a.name_en FROM accounts a WHERE a.code = v_img ->> 'from_account'), '?') || ' → '
                   || COALESCE((SELECT a.name_en FROM accounts a WHERE a.code = v_img ->> 'to_account'), '?');
    ELSIF p_table = 'processing_runs' THEN
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone, 'ended', v_img ->> 'deleted_at' IS NOT NULL);
    END IF;
    IF p_table = 'materials' THEN
        -- AUDIT-TRAIL-1b-2:物料带回它的单位 —— 订单 / 报价的明细行没有单位列,"10"要说成"10 kg"
        --   只在影像里真有单位时才带(一份早于变更记录、只剩名字的影像不说单位 —— 与"名字 + gone"那一形状逐字相同)
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
               || CASE WHEN v_img ->> 'unit' IS NOT NULL THEN jsonb_build_object('unit', v_img ->> 'unit') ELSE '{}'::jsonb END;
    END IF;
    IF p_table IN ('inbound_batches', 'output_batches') THEN
        IF v_img ->> 'material_id' IS NOT NULL THEN
            SELECT m.name INTO v_extra FROM materials m WHERE m.id::text = v_img ->> 'material_id';
            IF v_extra IS NOT NULL THEN
                v_label := v_label || ' · ' || v_extra;
            END IF;
        END IF;
        -- 批次的数量单位随名字一起带回 —— 加工单的"用了 300"要说成"300 kg",而投入 / 产出行自己没有单位列
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone, 'unit', v_img ->> 'unit');
    END IF;
    RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
           || COALESCE((SELECT jsonb_build_object('href', d.route || '/' || p_value) FROM document_types d
                         WHERE d.table_name = p_table AND d.link_mode = 'detail' AND p_column = 'id' AND NOT v_gone
                         ORDER BY d.key LIMIT 1), '{}'::jsonb);
END;
$function$;

-- db/functions/record_trail.sql
-- AUDIT-TRAIL-1a(Tim 的 Q1–Q6 · Q12 · Q13 · Q17 · Q40):一页底部"Audit trail"的【唯一】读法。
--
-- 【页面只说"哪一种记录、哪一条"】p_subject 是 trail_subjects() 里的一个主语,不是表名;p_id 是那条记录的 id。
--   不认识的主语 → TRAIL_SUBJECT_UNKNOWN。页面自己的查看权限码不在身上、或那条根记录过不了它自己那张表的读规则
--   (包括根本不存在)→ TRAIL_NOT_PERMITTED。★ 拒绝一律 RAISE,【绝不返回空列表】—— 空列表读起来是"什么都没发生过"。
--
-- 【哪些行】根行 + trail_subject_members() 登记的子行、孙行、相关行(Q3)。子行是【读的时候】找的(Q6):
--   今天还在的行按外键查;删掉了的、或父键被改过的,从 change_log 的影像里查(两条 GIN 部分索引)。
--   ☞ 为什么不能只按影像里的外键找:一次编辑只记改了的那几列,改一条明细行的单价,那一行记录里没有 purchase_order_id。
--     所以先收齐【这条记录有哪些行的主键】,再按 (表, 主键) 取那些行的全部记录。
--
-- 【每一行再过一次它自己那张表的读规则】(Q4)trail_row_visible。过不了的行照样占一个位置(时间还在),
--   其余一律为空、row_hidden = true —— 界面在"做了什么"与"谁"的位置印 Restricted。
-- 【遮蔽】过得了的行走 change_log_mask_row —— 与 /settings/change-history 同一步、同一份 HISTORY-1 规则,不加规则。
--
-- 【一次操作 = 一笔事务 = 一条记录】(Q2)按 txid 分组,entry_no 从新到旧编号。
-- 【变更记录开始之前】(Q1)trail_prelog_sources() 登记的领域历史与生命周期戳,凡是早于 change_log_began_at() 的,
--   拼成 prelog = true 的行(没有 seq);同一时刻写下的归成一条(同一笔事务的 now() 相同)。它们永远排在所有
--   变更记录之后,界面在两者之间画分界线。change_log 已经记着的(那一行的 INSERT、那一戳的改动)一律不再拼 —— 不会出现两次。
--
-- 【每一行带回】actor(trail_actor)、ctx(这一行今天的样子,已遮蔽 —— 子行的"第几行、哪个物料"从这里取)、
--   refs(trail_refs:每一个指着别处的值 → 名字)。界面把这些造成英文句子(Q40)。
-- 【分页】p_entries 条记录(默认 20,1..500),more 说后面还有没有更旧的。
-- 【SECURITY DEFINER 的理由】change_log 对应用角色没有任何授权(HISTORY-1);读权限在函数体里由上面三道判定。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M1–M6):
--   M1 一页可以认【任一】个码(trail_subjects.view_codes;has_any_permission)。
--   M2 "记录开始之前"的人可以记成员工 id(trail_prelog_sources.by_kind = 'employee')—— 交给 trail_actor 的员工那一格。
--   M3 root_rule = 'page':页面的码就是门,根行不再过它自己那张表的读规则;根行自己的改动照子行的规矩逐行判(Q4)。
--   M4 hop = 'up':从一行往上走到它指着的那一行(批次 → 消耗它的加工单);shown = false 的是【垫脚石】——
--      只用来够到它下面的行,它自己不进审计记录,也不判读规则、不拼"之前"那一段(Q4:只限碰到这条记录的事)。
--   M5 根键按根行【自己的类型】重建(jsonb_build_object(root_key, image -> root_key)):单行设置表的主键是
--      boolean,change_log 里存的是 {"id": true};按文字 'true' 去对,永远对不上 —— 审计记录会【空着而不报错】。
--   M6 root_columns 非空:根行只取这几列(改动取交集,一列都不沾的那次改动整条不算;新增 / 删除的影像只留这几列)。
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 的 Q3 · Q16):
--   M7 hop = 'all'(fk_column 为空):一张【没有外键】的表整张属于一个单行设置主语 —— 那张表今天的每一行,加上 change_log
--      里它的每一行(按 match 过滤)。只在父表就是这个主语的根表时生效(一个单行设置表:M5 的那一种);挂在别处的一行
--      'all' 不展开任何东西。第一个用户是 1c-3 的锁期面板(月结 / 反结的 period_closes 与 finance_settings 之间
--      一个键都没有);本刀先建好,fixture 241 用一个临时主语证它。
--   Q16 op_key:每一行带回它属于哪一次操作 —— 记录开始之后是那笔事务('L' || txid),之前是那一刻('P' || 时刻)。
--      entry_no 只在【一条】记录里排得出先后;一个清单页把几条记录合起来时(ListTrail),同一次操作碰到几条记录就会
--      各出一条 —— 一次批量录汇率是 N 条、一次冻结预测(新一张 + 旧一张作废)是两条。op_key 让它们并成一条。
--      ☞ 返回列多了一列,CREATE OR REPLACE 换不了返回类型 —— 迁移里是 DROP + CREATE(同一笔事务;授权由
--        apply_migration.sh 回放 zzz_function_grants 给回去)。
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 的 Q20):
--   M8 view_codes 为【空数组】:这一个主语没有页面码 —— 根行自己那张表的读规则就是唯一的门(/me 上报销人读自己那几张报销单:
--      expense_claims 的读规则是 module.finance.view 或者【这张单说的就是你】)。只许与 root_rule = 'table' 同用:
--      空的码配 'page' 等于对每一个登录的人敞开,所以那样登记的主语一律 TRAIL_NOT_PERMITTED。NULL 不是"没有码",照旧被拒。
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q2–Q5 —— M9 · M10 · M11 · M12):
--   M9  根表可以是一张【只在变更记录里出现】的表(trail_log_only_tables():auth.users)—— trail_current_image 读它那一份
--       安全投影,trail_row_visible 用登记表里声明的码判;它的"建立"在记录开始之后是一行 ACCOUNT_CREATE,不是 INSERT,
--       所以"记录开始之前"那一段的建立在两者任一存在时都不再拼(否则账号建立会说两次)。
--   M10 成员可以【只取声明的几列】(trail_member_columns(),M6 用在成员上):一次改动一列都不沾 → 不算;沾了 → 只留这几列;
--       之前那一段只拼落在这几列上的戳,不拼那一行的建立。根行的 root_columns 是同一条路(下标 1)。
--   M11 root_rule = 'collection':一个【集合】主语 —— 没有根行;那张表今天的每一行,加上 change_log 里它的每一行,都属于
--       这条记录,每一行各过它自己的读规则(Q4)。p_id 不用。假期表、六本字典、假别、评分刻度(AT-1d Step 0 的 Q4)。
--   M12 root_rule = 'gate:<名字>':根行先过它那张表的读规则('table' 那一道),【再】过 trail_root_gate 点名的那一道 ——
--       比表的规则更窄(/my-reviews 只给审核人,不给被评审的人)。与 M8(没有页面码)同用是允许的:门比 'table' 更窄,
--       不会更宽。
CREATE OR REPLACE FUNCTION public.record_trail(p_subject text, p_id text, p_entries integer DEFAULT 20)
 RETURNS TABLE(entry_no integer, prelog boolean, seq bigint, occurred_at timestamp with time zone, table_name text, row_key jsonb, op text, actor jsonb, changed_columns text[], old jsonb, new jsonb, ctx jsonb, refs jsonb, row_hidden boolean, row_restricted boolean, more boolean, op_key text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    s        record;
    m        record;
    p        record;
    r        record;
    v_limit  integer := LEAST(GREATEST(COALESCE(p_entries, 20), 1), 500);
    v_root   jsonb;
    v_img    record;
    v_tabs   text[] := ARRAY[]::text[];
    v_keys   jsonb[] := ARRAY[]::jsonb[];
    v_vis    boolean[] := ARRAY[]::boolean[];
    v_ctx    jsonb[] := ARRAY[]::jsonb[];
    v_crefs  jsonb[] := ARRAY[]::jsonb[];
    v_rr     jsonb;
    v_pids   text[];
    v_pk     text[];
    v_found  jsonb[];
    v_found2 jsonb[];
    v_k      jsonb;
    i        integer;
    v_pseudo jsonb := '[]'::jsonb;
    v_at     timestamptz;
    v_cols   text[];
    v_new    jsonb;
    v_op     text;
    v_mask   jsonb;
    v_began  timestamptz := change_log_began_at();
    v_total  integer;
    v_shown  boolean[] := ARRAY[]::boolean[];
    v_rcols  text[];
    v_fkv    text[];
    v_cimg   record;
    v_icols  jsonb[] := ARRAY[]::jsonb[];
    v_mcols  jsonb;
    v_c      text[];
    v_coll   boolean;
    v_gate   text;
BEGIN
    SELECT ts.* INTO s FROM trail_subjects() ts WHERE ts.subject = p_subject;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRAIL_SUBJECT_UNKNOWN|%', COALESCE(p_subject, '');
    END IF;
    v_coll := s.root_rule = 'collection';
    v_gate := CASE WHEN s.root_rule LIKE 'gate:%' THEN substr(s.root_rule, 6) END;
    IF cardinality(s.view_codes) = 0 THEN
        -- M8:没有页面码 —— 根行的读规则是门,而那只在 'table'(或比它更窄的 M12 门)时才问
        IF s.root_rule IS DISTINCT FROM 'table' AND v_gate IS NULL THEN
            RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
        END IF;
    ELSIF NOT has_any_permission(s.view_codes) THEN
        RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
    END IF;
    v_rcols := s.root_columns;
    IF v_coll THEN
        -- M11:集合 —— 那张表今天的每一行 + change_log 里它的每一行;没有根行,每一行各过它自己的读规则
        v_pk := trail_pk_columns(s.root_table);
        EXECUTE format('SELECT array_agg(jsonb_build_object(%s)) FROM public.%I t',
                       (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_pk) c), s.root_table)
           INTO v_found;
        SELECT array_agg(DISTINCT c.row_key) INTO v_found2
          FROM change_log c WHERE c.table_name = s.root_table AND c.row_key IS NOT NULL;
        FOR v_k IN SELECT DISTINCT x FROM unnest(COALESCE(v_found, ARRAY[]::jsonb[]) || COALESCE(v_found2, ARRAY[]::jsonb[])) x
                    WHERE x IS NOT NULL LOOP
            v_tabs := array_append(v_tabs, s.root_table);
            v_keys := array_append(v_keys, v_k);
            v_shown := array_append(v_shown, true);
            v_icols := array_append(v_icols, NULL::jsonb);
        END LOOP;
    ELSE
        v_root := jsonb_build_object(s.root_key, p_id);
        SELECT * INTO v_img FROM trail_current_image(s.root_table, v_root);
        IF v_img.image IS NULL
           OR ((s.root_rule = 'table' OR v_gate IS NOT NULL) AND NOT trail_row_visible(s.root_table, v_root, v_img.image))
           OR (v_gate IS NOT NULL AND NOT trail_root_gate(v_gate, s.root_table, v_img.image)) THEN
            RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
        END IF;
        -- M5:根键按它自己的类型重建(boolean / 数字主键),否则与 change_log 的 row_key 永远对不上
        IF v_img.image ? s.root_key THEN
            v_root := jsonb_build_object(s.root_key, v_img.image -> s.root_key);
        END IF;
        v_tabs := ARRAY[s.root_table];
        v_keys := ARRAY[v_root];
        v_shown := ARRAY[true];
        v_icols := ARRAY[to_jsonb(v_rcols)];
    END IF;

    -- ① 这条记录有哪些行(按 ord 展开,孙行在父行之后;hop = 'up' 往上走一跳,shown = false 的只作垫脚石)
    FOR m IN SELECT tm.* FROM trail_subject_members() tm WHERE tm.subject = p_subject ORDER BY tm.ord LOOP
        v_found := NULL;
        v_found2 := NULL;
        IF m.hop = 'all' THEN
            -- M7:整张表属于这个单行设置主语(父表必须就是根表)
            CONTINUE WHEN m.parent_table IS DISTINCT FROM s.root_table;
            v_pk := trail_pk_columns(m.table_name);
            EXECUTE format('SELECT array_agg(jsonb_build_object(%s)) FROM public.%I t WHERE to_jsonb(t) @> $1',
                           (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_pk) c), m.table_name)
               INTO v_found USING m.match;
            SELECT array_agg(DISTINCT c.row_key) INTO v_found2
              FROM change_log c
             WHERE c.table_name = m.table_name AND c.row_key IS NOT NULL AND COALESCE(c.new, c.old) @> m.match;
        ELSIF m.hop = 'up' THEN
            -- 父行今天那份(或它最后一份影像)里的那一列 → 被指着的那一行的 id
            v_fkv := ARRAY[]::text[];
            FOR v_k IN SELECT u.k FROM unnest(v_tabs, v_keys) AS u(t, k) WHERE u.t = m.parent_table LOOP
                SELECT * INTO v_cimg FROM trail_current_image(m.parent_table, v_k);
                IF v_cimg.image ->> m.fk_column IS NOT NULL THEN
                    v_fkv := array_append(v_fkv, v_cimg.image ->> m.fk_column);
                END IF;
            END LOOP;
            CONTINUE WHEN cardinality(v_fkv) = 0;
            SELECT array_agg(DISTINCT jsonb_build_object('id', x.v)) INTO v_found
              FROM unnest(v_fkv) AS x(v)
             WHERE (trail_current_image(m.table_name, jsonb_build_object('id', x.v))).image @> m.match;
        ELSE
            SELECT array_agg(DISTINCT u.k ->> 'id') INTO v_pids
              FROM unnest(v_tabs, v_keys) AS u(t, k) WHERE u.t = m.parent_table AND u.k ? 'id';
            CONTINUE WHEN v_pids IS NULL;
            v_pk := trail_pk_columns(m.table_name);
            EXECUTE format('SELECT array_agg(jsonb_build_object(%s)) FROM public.%I t WHERE t.%I::text = ANY ($1) AND to_jsonb(t) @> $2',
                           (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_pk) c),
                           m.table_name, m.fk_column)
               INTO v_found USING v_pids, m.match;
            SELECT array_agg(DISTINCT c.row_key) INTO v_found2
              FROM unnest(v_pids) AS pid(v)
              JOIN change_log c ON c.table_name = m.table_name
                               AND (COALESCE(c.new, c.old) @> (jsonb_build_object(m.fk_column, pid.v) || m.match)
                                    OR (c.op = 'UPDATE' AND c.old @> jsonb_build_object(m.fk_column, pid.v)));
        END IF;
        -- M10:这一个成员只取声明的几列(NULL = 整行)
        SELECT to_jsonb(mc.columns) INTO v_mcols FROM trail_member_columns() mc WHERE mc.subject = p_subject AND mc.ord = m.ord;
        FOR v_k IN SELECT DISTINCT x FROM unnest(COALESCE(v_found, ARRAY[]::jsonb[]) || COALESCE(v_found2, ARRAY[]::jsonb[])) x
                    WHERE x IS NOT NULL LOOP
            IF NOT EXISTS (SELECT 1 FROM unnest(v_tabs, v_keys) u(t, k) WHERE u.t = m.table_name AND u.k = v_k) THEN
                v_tabs := array_append(v_tabs, m.table_name);
                v_keys := array_append(v_keys, v_k);
                v_shown := array_append(v_shown, m.shown);
                v_icols := array_append(v_icols, v_mcols);
            END IF;
        END LOOP;
    END LOOP;

    -- ② 每一行:过不过它自己那张表的读规则;今天的样子(遮蔽之后);"记录开始之前"的那一段从哪里拼
    FOR i IN 1 .. cardinality(v_tabs) LOOP
        IF NOT v_shown[i] THEN
            -- 垫脚石:不判、不取上下文、不拼"之前"(它自己不进这条记录)
            v_vis := array_append(v_vis, false);
            v_ctx := array_append(v_ctx, NULL::jsonb);
            v_crefs := array_append(v_crefs, '{}'::jsonb);
            CONTINUE;
        END IF;
        SELECT * INTO v_img FROM trail_current_image(v_tabs[i], v_keys[i]);
        v_vis := array_append(v_vis, (i = 1 AND NOT v_coll AND (s.root_rule = 'table' OR v_gate IS NOT NULL))
                                     OR COALESCE(trail_row_visible(v_tabs[i], v_keys[i], v_img.image), false));
        IF v_vis[i] AND v_img.image IS NOT NULL THEN
            v_mask := change_log_mask_row(v_tabs[i], v_keys[i], NULL, v_img.image);
            v_ctx := array_append(v_ctx, COALESCE(NULLIF(v_mask -> 'new', 'null'::jsonb), '{}'::jsonb)
                                         || jsonb_build_object('$gone', v_img.gone));
            v_crefs := array_append(v_crefs, trail_refs(v_tabs[i], NULL, NULL, v_ctx[i]));
        ELSE
            v_ctx := array_append(v_ctx, NULL::jsonb);
            v_crefs := array_append(v_crefs, '{}'::jsonb);
        END IF;
        CONTINUE WHEN v_img.image IS NULL OR v_img.gone;
        FOR p IN SELECT ps.* FROM trail_prelog_sources() ps WHERE ps.table_name = v_tabs[i] LOOP
            v_at := NULLIF(v_img.image ->> p.at_column, '')::timestamptz;
            CONTINUE WHEN v_at IS NULL OR v_at >= v_began;
            -- M6 · M10:根行 / 成员只管声明的那几列 —— 别的列上的戳不属于这一块;限了列的成员不拼它那一行的建立
            v_c := CASE WHEN v_icols[i] IS NULL OR jsonb_typeof(v_icols[i]) <> 'array' THEN NULL
                        ELSE ARRAY(SELECT jsonb_array_elements_text(v_icols[i])) END;
            CONTINUE WHEN v_c IS NOT NULL AND ((p.kind = 'stamp' AND NOT (p.at_column = ANY (v_c))) OR (p.kind = 'created' AND i > 1));
            IF p.kind = 'created' THEN
                -- M9:登记的只在变更记录里出现的表,建立那一下记成 ACCOUNT_CREATE(record_account_event),不是 INSERT
                CONTINUE WHEN EXISTS (SELECT 1 FROM change_log c
                                       WHERE c.table_name = v_tabs[i] AND c.row_key = v_keys[i] AND c.op IN ('INSERT', 'ACCOUNT_CREATE'));
                v_op := 'INSERT';
                v_cols := NULL;
                v_new := v_img.image;
            ELSE
                CONTINUE WHEN EXISTS (SELECT 1 FROM change_log c
                                       WHERE c.table_name = v_tabs[i] AND c.row_key = v_keys[i]
                                         AND (p.at_column = ANY (c.changed_columns)
                                              OR (c.op = 'INSERT' AND c.new ->> p.at_column IS NOT NULL)));
                v_op := 'UPDATE';
                v_cols := ARRAY[p.at_column] || COALESCE(ARRAY[p.by_column], ARRAY[]::text[]) || COALESCE(p.extra, ARRAY[]::text[]);
                v_cols := ARRAY(SELECT c FROM unnest(v_cols) c WHERE c IS NOT NULL);
                SELECT jsonb_object_agg(c, v_img.image -> c) INTO v_new FROM unnest(v_cols) c WHERE v_img.image ? c;
            END IF;
            v_pseudo := v_pseudo || jsonb_build_array(jsonb_build_object(
                'i', i, 'at', v_at, 'op', v_op, 'cols', to_jsonb(v_cols), 'new', v_new,
                'account', CASE WHEN p.by_column IS NULL OR p.by_kind = 'employee' THEN NULL ELSE v_img.image -> p.by_column END,
                'employee', CASE WHEN p.by_column IS NOT NULL AND p.by_kind = 'employee' THEN v_img.image -> p.by_column END));
        END LOOP;
    END LOOP;

    -- ③ 变更记录 + 拼回来的那一段,按记录(事务)编号,从新到旧
    SELECT count(DISTINCT g) INTO v_total FROM (
        SELECT 'L' || c.txid AS g
          FROM unnest(v_tabs, v_keys, v_shown, v_icols) WITH ORDINALITY u(t, k, sh, ic, i)
          JOIN change_log c ON c.table_name = u.t AND c.row_key = u.k
         WHERE u.sh AND (u.ic IS NULL OR jsonb_typeof(u.ic) <> 'array' OR c.op <> 'UPDATE'
                         OR c.changed_columns && ARRAY(SELECT jsonb_array_elements_text(u.ic)))
        UNION ALL
        SELECT 'P' || (x ->> 'at') FROM jsonb_array_elements(v_pseudo) x) z;

    FOR r IN
        WITH k AS (
            SELECT u.t, u.k, u.ic, u.i::integer AS i FROM unnest(v_tabs, v_keys, v_shown, v_icols) WITH ORDINALITY u(t, k, sh, ic, i) WHERE u.sh),
        allr AS (
            SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.txid AS a_g, k.i AS a_i, c.op AS a_op,
                   c.actor_kind AS a_kind, c.actor_account AS a_account, c.actor_employee AS a_employee,
                   c.changed_columns AS a_cols, c.old AS a_old, c.new AS a_new, false AS a_pre
              FROM k JOIN change_log c ON c.table_name = k.t AND c.row_key = k.k
             WHERE k.ic IS NULL OR jsonb_typeof(k.ic) <> 'array' OR c.op <> 'UPDATE'
                OR c.changed_columns && ARRAY(SELECT jsonb_array_elements_text(k.ic))
            UNION ALL
            SELECT NULL::bigint, (x ->> 'at')::timestamptz, 'P' || (x ->> 'at'), (x ->> 'i')::integer, x ->> 'op',
                   'prelog', (x ->> 'account')::uuid, (x ->> 'employee')::uuid,
                   CASE WHEN jsonb_typeof(x -> 'cols') = 'array'
                        THEN ARRAY(SELECT jsonb_array_elements_text(x -> 'cols')) END,
                   NULL::jsonb, x -> 'new', true
              FROM jsonb_array_elements(v_pseudo) x),
        ent AS (
            SELECT a_g AS e_g, bool_or(a_pre) AS e_pre, max(a_seq) AS e_mx, max(a_at) AS e_at FROM allr GROUP BY a_g),
        num AS (
            SELECT e_g, row_number() OVER (ORDER BY e_pre, e_mx DESC NULLS LAST, e_at DESC, e_g)::integer AS e_n FROM ent)
        SELECT allr.*, num.e_n FROM allr JOIN num ON num.e_g = allr.a_g
         WHERE num.e_n <= v_limit
         ORDER BY num.e_n, allr.a_seq NULLS LAST, allr.a_i
    LOOP
        entry_no := r.e_n;
        prelog := r.a_pre;
        seq := r.a_seq;
        occurred_at := r.a_at;
        more := v_total > v_limit;
        op_key := r.a_g;
        IF NOT v_vis[r.a_i] THEN
            table_name := NULL; row_key := NULL; op := NULL; actor := NULL; changed_columns := NULL;
            old := NULL; new := NULL; ctx := NULL; refs := NULL;
            row_hidden := true;
            row_restricted := true;
        ELSE
            table_name := v_tabs[r.a_i];
            row_key := v_keys[r.a_i];
            op := r.a_op;
            actor := trail_actor(r.a_kind, r.a_account, r.a_employee);
            changed_columns := r.a_cols;
            v_mask := change_log_mask_row(v_tabs[r.a_i], v_keys[r.a_i], r.a_old, r.a_new);
            old := NULLIF(v_mask -> 'old', 'null'::jsonb);
            new := NULLIF(v_mask -> 'new', 'null'::jsonb);
            -- M6 · M10:根行 / 限了列的成员只留声明的那几列
            IF v_icols[r.a_i] IS NOT NULL AND jsonb_typeof(v_icols[r.a_i]) = 'array' THEN
                v_c := ARRAY(SELECT jsonb_array_elements_text(v_icols[r.a_i]));
                changed_columns := CASE WHEN r.a_cols IS NULL THEN NULL
                                        ELSE ARRAY(SELECT c FROM unnest(r.a_cols) c WHERE c = ANY (v_c)) END;
                SELECT jsonb_object_agg(e.key, e.value) INTO old FROM jsonb_each(old) e WHERE e.key = ANY (v_c);
                SELECT jsonb_object_agg(e.key, e.value) INTO new FROM jsonb_each(new) e WHERE e.key = ANY (v_c);
            END IF;
            row_restricted := (v_mask ->> 'row_restricted')::boolean;
            ctx := v_ctx[r.a_i];
            -- 这一行今天那份的名字(每个主键只解析一次)+ 这一次记录里新旧值的名字,按列合并
            v_rr := trail_refs(v_tabs[r.a_i], old, new, NULL);
            SELECT COALESCE(jsonb_object_agg(kk, COALESCE(v_crefs[r.a_i] -> kk, '{}'::jsonb) || COALESCE(v_rr -> kk, '{}'::jsonb)),
                            '{}'::jsonb)
              INTO refs
              FROM (SELECT jsonb_object_keys(v_crefs[r.a_i]) AS kk UNION SELECT jsonb_object_keys(v_rr)) z;
            row_hidden := false;
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$;

-- db/functions/change_log_rows.sql
-- HISTORY-1(Tim 的 Q10 · Q26 · Q6):变更记录的【唯一】全局读法。/settings/change-history 读它。
-- AUDIT-TRAIL-1a(Tim 的 Q5 · Q30 · Q31 · Q40):仍是这一支、仍是这一道门;加了读法,没有放宽。
--
-- 【门】data.view_change_log(只授 admin 与 cfo,不捆进任何别的角色)。没有它 → PERMISSION_DENIED。
-- 【遮蔽】逐行走 change_log_mask_row —— 与每一页底部的审计记录(record_trail)【同一步】(Q5),规则仍是
--   HISTORY-1 的 change_log_mask_rules():读者在源屏幕上看不见的值换成 {"$restricted": true},本来就是 null 的留 null;
--   任务四张表先问 change_log_task_visible(),不过 → 整份影像受限(row_restricted = true)。
-- 【筛选】日期(按库时区 Asia/Singapore,to 含当天)· 表(p_table 一张,或 p_tables 一组 —— "Area"与"Record type")·
--   记录(p_record:主键里任一值等于它;p_record_ids:主键里任一值在这一组里 —— 按单据号或名字找到的,见
--   change_log_find_records)· 人(账号 id 或员工 id 任一相等)· 只看无会话的写 · 只看"Removed account"的写。
-- 【分页】按 seq 倒序,键集分页(p_before)。p_by_entry = false:每页 p_limit 行(HISTORY-1 的原样);
--   p_by_entry = true:每页 p_limit 笔【事务】(一次操作一条,Q2),返回这些事务里符合筛选的全部行,
--   p_before 比的是一笔事务里最大的 seq。
-- 【每一行多带回】txid · actor(trail_actor:人名 / System (automatic) / Removed account …)·
--   belongs_to(trail_row_record:这一行属于哪张单据 / 哪条记录)· refs(trail_refs:每个引用值 → 名字)。
--   任务隐私受限的行不带 belongs_to 与 refs —— 任务标题本身就是被藏起来的东西。
-- 【它仍然列出每一次写入】(Q31):系统的、冒烟的、账号事件的,一行不少。
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q13):【每一行再过一次它自己那张表的读规则】—— 与每一页底部的审计记录
--   (record_trail 的第三道)同一个判法、同一支函数(trail_row_visible,对这一行今天的样子;已经删掉的,对它最后的影像)。
--   过不了 → 整份影像受限(row_restricted = true,与任务隐私同一个形状:界面说这一类记录被改过、内容受限)。
--   为什么:这一页的门是 data.view_change_log;以前只按 HISTORY-1 的列规则遮,而几张表是按【行】管的 ——
--   调薪申请要 hr.view 加 data.view_pay,评审与 KPI 要 data.view_reviews,账号事件要 manage_permissions。
--   一个持 view_change_log 而没有 view_pay 的人,以前在这里读得到每一笔调薪的金额。今天持这个码的两个人(admin、cfo)
--   两样都有,所以那时没有人读到 —— 它是一个躺着的洞,不是一次泄漏。同一行在同一次调用里只判一次(v_vis_cache)。
-- 【SECURITY DEFINER 的理由】change_log 对应用角色没有任何授权;读 auth.users 取邮箱与账号是否还在。
CREATE OR REPLACE FUNCTION public.change_log_rows(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_table text DEFAULT NULL::text, p_record text DEFAULT NULL::text, p_actor uuid DEFAULT NULL::uuid, p_no_session boolean DEFAULT false, p_before bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 50, p_tables text[] DEFAULT NULL::text[], p_removed_account boolean DEFAULT false, p_by_entry boolean DEFAULT false, p_record_ids text[] DEFAULT NULL::text[])
 RETURNS TABLE(seq bigint, occurred_at timestamp with time zone, table_name text, row_key jsonb, op text, actor_account uuid, actor_email text, actor_employee uuid, actor_employee_code text, actor_employee_name text, actor_kind text, db_role text, changed_columns text[], old jsonb, new jsonb, redacted_at timestamp with time zone, row_restricted boolean, txid bigint, actor jsonb, belongs_to jsonb, refs jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    r        record;
    v_mask   jsonb;
    v_limit  integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
    v_txids  bigint[];
    v_vkey   text;
    v_vis    boolean;
    v_cache  jsonb := '{}'::jsonb;
    v_cimg   record;
BEGIN
    PERFORM require_permission('data.view_change_log');

    IF COALESCE(p_by_entry, false) THEN
        SELECT array_agg(g.g_tx ORDER BY g.g_mx DESC) INTO v_txids FROM (
            SELECT c.txid AS g_tx, max(c.seq) AS g_mx
              FROM change_log c
             WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
               AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
               AND (p_table IS NULL OR c.table_name = p_table)
               AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
               AND (p_record IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = p_record))
               AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
               AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
               AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
               AND (NOT COALESCE(p_removed_account, false)
                    OR (c.actor_kind = 'user' AND c.actor_employee IS NULL
                        AND NOT EXISTS (SELECT 1 FROM auth.users u2 WHERE u2.id = c.actor_account)))
             GROUP BY c.txid
            HAVING p_before IS NULL OR max(c.seq) < p_before
             ORDER BY max(c.seq) DESC
             LIMIT v_limit) g;
        IF v_txids IS NULL THEN
            RETURN;
        END IF;
    END IF;

    FOR r IN
        SELECT c.seq AS c_seq, c.occurred_at AS c_at, c.table_name AS c_table, c.row_key AS c_key,
               c.op AS c_op, c.actor_account AS c_account, u.email::text AS c_email,
               c.actor_employee AS c_employee, e.code AS c_emp_code,
               COALESCE(e.preferred_name, e.legal_name) AS c_emp_name,
               c.actor_kind AS c_kind, c.db_role AS c_role, c.changed_columns AS c_cols,
               c.old AS c_old, c.new AS c_new, c.redacted_at AS c_redacted, c.txid AS c_tx
          FROM change_log c
          LEFT JOIN auth.users u ON u.id = c.actor_account
          LEFT JOIN employees e ON e.id = c.actor_employee
         WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
           AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
           AND (p_table IS NULL OR c.table_name = p_table)
           AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
           AND (p_record IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = p_record))
           AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
           AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
           AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
           AND (NOT COALESCE(p_removed_account, false)
                OR (c.actor_kind = 'user' AND c.actor_employee IS NULL AND u.id IS NULL))
           AND (CASE WHEN COALESCE(p_by_entry, false) THEN c.txid = ANY (v_txids)
                     ELSE (p_before IS NULL OR c.seq < p_before) END)
         ORDER BY c.seq DESC
         LIMIT CASE WHEN COALESCE(p_by_entry, false) THEN NULL ELSE v_limit END
    LOOP
        seq := r.c_seq;
        occurred_at := r.c_at;
        table_name := r.c_table;
        row_key := r.c_key;
        op := r.c_op;
        actor_account := r.c_account;
        actor_email := r.c_email;
        actor_employee := r.c_employee;
        actor_employee_code := r.c_emp_code;
        actor_employee_name := r.c_emp_name;
        actor_kind := r.c_kind;
        db_role := r.c_role;
        changed_columns := r.c_cols;
        redacted_at := r.c_redacted;
        txid := r.c_tx;
        actor := trail_actor(r.c_kind, r.c_account, r.c_employee);

        v_mask := change_log_mask_row(r.c_table, r.c_key, r.c_old, r.c_new);
        old := NULLIF(v_mask -> 'old', 'null'::jsonb);
        new := NULLIF(v_mask -> 'new', 'null'::jsonb);
        row_restricted := (v_mask ->> 'row_restricted')::boolean;
        -- Q13:这一行过不过它自己那张表的读规则(每一行只判一次)
        v_vkey := r.c_table || '|' || COALESCE(r.c_key::text, '');
        IF v_cache ? v_vkey THEN
            v_vis := (v_cache ->> v_vkey)::boolean;
        ELSE
            SELECT * INTO v_cimg FROM trail_current_image(r.c_table, r.c_key);
            v_vis := COALESCE(trail_row_visible(r.c_table, r.c_key, COALESCE(v_cimg.image, r.c_new, r.c_old)), false);
            v_cache := v_cache || jsonb_build_object(v_vkey, v_vis);
        END IF;
        IF NOT v_vis AND NOT row_restricted THEN
            old := change_log_restrict(r.c_old, NULL);
            new := change_log_restrict(r.c_new, NULL);
            row_restricted := true;
        END IF;
        IF row_restricted OR r.c_table = 'auth.users' THEN
            belongs_to := NULL;
            refs := '{}'::jsonb;
        ELSE
            belongs_to := trail_row_record(r.c_table, r.c_key, old, new);
            refs := trail_refs(r.c_table, old, new, r.c_key);
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$;

-- db/functions/save_employee.sql
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q8):员工表单的【一次】保存 —— 员工那一行与它的任职履历,【一笔事务】。
--   以前是两次请求(app/hr/employees/actions.ts:先写 employees,再另起一次请求写 employment_history,线上实测相隔 0.5–0.9 秒),
--   于是一次"入职"在审计记录里是两条("Employee added"与"Hired"),而第二次请求失败时履历会安静地缺一行。
--   与 1b-3 Q13 的 save_storage_location 同一个处置:修写的那一头 —— 一次调用,只写变了的。
-- 【参数】p_id 为空 = 新建(返回新员工的 id);否则编辑那一名(返回同一个 id)。
--   p_fields:表单写的那 25 列(app/hr/employees/actions.ts 的 readForm,去掉 effective_date 与 user_id)。没给的列按 NULL 写 ——
--   表单每一次都交齐。
--   p_history:要补的那一行履历(change_type、生效日、职位文本、部门、类型、状态、说明),为空就不补 —— 推断哪一种变动、
--   说明怎么写仍在页面那一侧(inferChangeType / describeChanges),这里只负责让它与员工那一行【同生共死】。
-- 【账号关联不在这里】那是另一个权限(action.manage_permissions)的另一次调用(set_user_employee_link,它自己一笔事务)——
--   Step 0 的 Q8 照建议:关联仍是它自己的那一次。
-- 【SECURITY INVOKER】按调用者的身份跑:employees / employment_history 的读写策略与守卫(module.hr.edit;月薪只经
--   set_initial_salary,guard_employee_salary_write)照常管 —— 这支函数不放宽任何东西,它只把两次写入装进一笔。
--   ★ 但一开头先 require_permission('module.hr.edit'):被 RLS 的 USING 挡住的 UPDATE 不报错,它是一次【成功的空操作】
--     (AGENTS.md「写那一半更坏」)—— 不先问,一个没有编辑权的人点保存会得到一句"保存成功"。
-- 【一列都没变就不留痕】不在这里逐列比旧值:那要读几列被遮蔽的列(证件号、工作邮箱、月薪 —— 列级 SELECT 授权里没有它们),
--   调用者身份下读不得(实测 42501);而变更记录的触发器本来就不为"改了等于没改"写行(fixture 234 A3)—— 同一个结果,不多读一列。
CREATE OR REPLACE FUNCTION public.save_employee(p_id uuid, p_fields jsonb, p_history jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    f    employees%ROWTYPE;
    v_id uuid := p_id;
BEGIN
    PERFORM require_permission('module.hr.edit');
    IF p_fields IS NULL OR jsonb_typeof(p_fields) <> 'object' THEN
        RAISE EXCEPTION 'EMPLOYEE_FIELDS_REQUIRED';
    END IF;
    f := jsonb_populate_record(NULL::employees, p_fields);
    IF v_id IS NULL THEN
        INSERT INTO employees (legal_name, first_name, last_name, preferred_name, department_id, position_id, manager_id,
                               employment_type, work_category, is_site_staff, hire_date, probation_end_date, employment_status,
                               separation_date, separation_type, separation_notes, work_email, work_phone, residency_status,
                               identity_no, work_pass_type, work_pass_no, work_pass_issue_date, work_pass_expiry_date, notes)
        VALUES (f.legal_name, f.first_name, f.last_name, f.preferred_name, f.department_id, f.position_id, f.manager_id,
                f.employment_type, f.work_category, COALESCE(f.is_site_staff, false), f.hire_date, f.probation_end_date, f.employment_status,
                f.separation_date, f.separation_type, f.separation_notes, f.work_email, f.work_phone, f.residency_status,
                f.identity_no, f.work_pass_type, f.work_pass_no, f.work_pass_issue_date, f.work_pass_expiry_date, f.notes)
        RETURNING id INTO v_id;
    ELSE
        UPDATE employees e SET
               (legal_name, first_name, last_name, preferred_name, department_id, position_id, manager_id,
                employment_type, work_category, is_site_staff, hire_date, probation_end_date, employment_status,
                separation_date, separation_type, separation_notes, work_email, work_phone, residency_status,
                identity_no, work_pass_type, work_pass_no, work_pass_issue_date, work_pass_expiry_date, notes)
             = (f.legal_name, f.first_name, f.last_name, f.preferred_name, f.department_id, f.position_id, f.manager_id,
                f.employment_type, f.work_category, COALESCE(f.is_site_staff, false), f.hire_date, f.probation_end_date, f.employment_status,
                f.separation_date, f.separation_type, f.separation_notes, f.work_email, f.work_phone, f.residency_status,
                f.identity_no, f.work_pass_type, f.work_pass_no, f.work_pass_issue_date, f.work_pass_expiry_date, f.notes)
         WHERE e.id = v_id;
        IF NOT FOUND AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = v_id AND e.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', v_id;
        END IF;
    END IF;
    IF p_history IS NOT NULL AND jsonb_typeof(p_history) = 'object' THEN
        INSERT INTO employment_history (employee_id, effective_date, change_type, job_title, department_id,
                                        employment_type, employment_status, notes)
        VALUES (v_id, NULLIF(p_history ->> 'effective_date', '')::date, p_history ->> 'change_type', p_history ->> 'job_title',
                NULLIF(p_history ->> 'department_id', '')::uuid, p_history ->> 'employment_type', p_history ->> 'employment_status',
                NULLIF(p_history ->> 'notes', ''));
    END IF;
    RETURN v_id;
END;
$function$;

-- ── 1b · 四支新函数的执行权(与 db/views/zzz_function_grants.sql 同一份裁定;那份兜底由 apply_migration.sh 在 COMMIT 之前才回放,
--      而下面的自证要先看到这一刀自己的授权 —— 新函数生下来对 PUBLIC 可执行,anon 就在 PUBLIC 里)───────────────────────
REVOKE EXECUTE ON FUNCTION public.trail_log_only_tables() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.trail_member_columns() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.trail_root_gate(text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.save_employee(uuid, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_log_only_tables() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.trail_member_columns() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_employee(uuid, jsonb, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.trail_root_gate(text, text, jsonb) TO service_role;

-- ── 2 · 删掉的记录:多四类(Q25 · Q26)—— 视图原样从镜像来 ──────────────────────────────

-- db/views/deleted_records.sql
-- AUDEL-3:全站被软删的记录,一条一行 —— 编号、种类、时刻、谁、为什么,
-- 以及台账上那条注销/冲销流水。被回滚的加工单也在这里(它的"删除"就是它的冲销)。
--
-- 【地面:RLS 根本不过滤已删的行】七张带 delete_reason 的表,SELECT 策略全部只是
-- has_permission('module.X.view') —— 没有任何一条带 deleted_at IS NULL。过滤发生在
-- 【应用查询】里。所以这一刀不需要动任何策略、也不需要新权限码。
--
-- 【每一行跟着它自己模块的读权限】permission 列 + 外层 has_permission(调用者)——
-- 无权的那一类【整类缺席】,不是显示成零。这是 /margin 那一课:为跨模块页面合成
-- 一个新权限码,会是"谁能看什么"的第二份定义,与各模块的策略必然漂开。
--
-- 【属主权限,不是 invoker】跨七个模块;invoker 会让 RLS 静默丢行,而行消失在这里
-- 的意思会变成"没有东西被删过"(OPS-14 的 xmodule 那一课)。
--
-- 【只读,永不提供恢复】撤销删除是一个没有人做过的决定 —— 注销流水已经进台账、
-- 回滚的投入已经还回去。一个按钮会替所有人默默把那个决定做掉。
--
-- 【record_kind 的取值就是下面那几个字面量】—— check-i18n 的 deleted.kind. 前缀
-- 现读本文件,加一支就自动被查到。
--
-- NOTE: introduced by db/migrations/2026-08-17-audel3-a-place-to-see-what-was-deleted.sql.
--
-- ★ AUDIT-TRAIL-1b-3(Tim 的 Q9 · Q8,2026-09-29):多了四类 —— 客户 · 供应商 · 物料 · 定价公式。
--   这四张表【从来没有记过谁删的】(没有 deleted_by、没有 delete_reason)。"谁"只能从 change_log 里那一次
--   把 deleted_at 置上的改动读出来(变更记录 28/09/2026 23:58 才开始);读不到就是 NULL —— 页面与横幅只说日期,
--   【不】拿 updated_by 去猜(Q8:updated_by 是最后一个碰过它的人,不一定是删它的人)。
--   属主权限照旧,所以视图读得到 change_log(应用角色对它没有任何授权);行一级仍由每一支自己的 permission 裁决。
--   detail 那一格放名字(这几类记录没有数量可说;编号旁边的名字是人认得它的方式)。
--
-- ★ AUDIT-TRAIL-1c-2(Tim 的 Q6,2026-10-03):多了一类 —— 对账单。删掉的对账单以前在详情页与对账工作台上 404、
--   在清单上被藏起来,于是它【一处都看不见】。它同样从来没有记过谁删的(没有 deleted_by、没有理由;删是一句直写的
--   update),"谁"照上面四类的办法从 change_log 读,读不到(早于变更记录 —— 线上那一张 BS-2026-0001 是 30/07/2026 删的)
--   就只说日期。门是 module.finance.view(那张表的读规则);detail 那一格放它覆盖的期间。
--
-- ★ AUDIT-TRAIL-1d-1(Tim 的 Q25 · Q26,2026-10-04):多了四类 —— 角色 · 员工 · 部门 · 培训记录。它们的页以前过滤掉已删的、404,
--   这里也没有它们(AT-0 说"删掉的部门会到 /settings/deleted"—— 那句话不成立,Step 0 量过)。四张表都没有 deleted_by、没有理由,
--   "谁"照上面几类的办法从 change_log 读;读不到(早于变更记录 —— 线上 15 名删掉的员工全是 ZZ-* 的测试行,一个删掉的角色
--   operations)就只说日期。门:角色是 action.manage_permissions(角色页的门);另外三类是 module.hr.view。
--   detail 那一格放名字(员工:称呼名,没有就法定名 —— 能进这一类的人都持 hr.view,与员工页同一个答案);培训记录没有编号,
--   code 留空,名字在 detail。

CREATE OR REPLACE VIEW public.deleted_records AS
 SELECT record_kind,
    permission,
    record_id,
    code,
    deleted_at,
    deleted_by,
    delete_reason,
    movement_id,
    detail
   FROM ( SELECT 'inbound_batch'::text AS record_kind,
            'module.inbound.view'::text AS permission,
            b.id AS record_id,
            b.code,
            b.deleted_at,
            b.deleted_by,
            b.delete_reason,
            ( SELECT m.id
                   FROM inventory_movements m
                  WHERE m.inbound_batch_id = b.id AND m.movement_type = 'writeoff'::text
                  ORDER BY m.occurred_at DESC
                 LIMIT 1) AS movement_id,
            (b.quantity || ' '::text) || COALESCE(b.unit, ''::text) AS detail
           FROM inbound_batches b
          WHERE b.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'output_batch'::text AS text,
            'module.output.view'::text AS text,
            b.id,
            b.code,
            b.deleted_at,
            b.deleted_by,
            b.delete_reason,
            ( SELECT m.id
                   FROM inventory_movements m
                  WHERE m.output_batch_id = b.id AND (m.movement_type = ANY (ARRAY['writeoff'::text, 'reversal_void'::text]))
                  ORDER BY m.occurred_at DESC
                 LIMIT 1) AS id,
            (b.quantity || ' '::text) || COALESCE(b.unit, ''::text) AS text
           FROM output_batches b
          WHERE b.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'processing_run'::text AS text,
            'module.processing.view'::text AS text,
            r.id,
            r.code,
            r.deleted_at,
            r.deleted_by,
            r.delete_reason,
            NULL::uuid AS uuid,
            r.status
           FROM processing_runs r
          WHERE r.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'stocktake'::text AS text,
            'module.stocktakes.view'::text AS text,
            s.id,
            s.code,
            s.deleted_at,
            s.deleted_by,
            s.delete_reason,
            NULL::uuid AS uuid,
            s.status
           FROM stocktakes s
          WHERE s.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'purchase_order'::text AS text,
            'module.purchasing.view'::text AS text,
            p.id,
            p.code,
            p.deleted_at,
            p.deleted_by,
            p.delete_reason,
            NULL::uuid AS uuid,
            p.status
           FROM purchase_orders p
          WHERE p.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'sales_order'::text AS text,
            'module.sales.view'::text AS text,
            o.id,
            o.code,
            o.deleted_at,
            o.deleted_by,
            o.delete_reason,
            NULL::uuid AS uuid,
            o.status
           FROM sales_orders o
          WHERE o.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'quote'::text AS text,
            'module.sales.view'::text AS text,
            q.id,
            q.code,
            q.deleted_at,
            q.deleted_by,
            q.delete_reason,
            NULL::uuid AS uuid,
            q.status
           FROM quotes q
          WHERE q.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'customer'::text AS text,
            'module.customers.view'::text AS text,
            c.id,
            c.code,
            c.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'customers'::text AND l.row_key = jsonb_build_object('id', c.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            c.legal_name
           FROM customers c
          WHERE c.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'supplier'::text AS text,
            'module.suppliers.view'::text AS text,
            s.id,
            s.code,
            s.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'suppliers'::text AND l.row_key = jsonb_build_object('id', s.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            s.legal_name
           FROM suppliers s
          WHERE s.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'material'::text AS text,
            'module.materials.view'::text AS text,
            m.id,
            m.code,
            m.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'materials'::text AND l.row_key = jsonb_build_object('id', m.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            m.name
           FROM materials m
          WHERE m.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'pricing_formula'::text AS text,
            'module.pricing.view'::text AS text,
            f.id,
            f.code,
            f.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'pricing_formulas'::text AND l.row_key = jsonb_build_object('id', f.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            f.name
           FROM pricing_formulas f
          WHERE f.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'bank_statement'::text AS text,
            'module.finance.view'::text AS text,
            bs.id,
            bs.code,
            bs.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'bank_statements'::text AND l.row_key = jsonb_build_object('id', bs.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            (to_char(bs.period_start::timestamp without time zone, 'DD/MM/YYYY'::text) || ' – '::text) || to_char(bs.period_end::timestamp without time zone, 'DD/MM/YYYY'::text)
           FROM bank_statements bs
          WHERE bs.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'role'::text AS text,
            'action.manage_permissions'::text AS text,
            ro.id,
            ro.code,
            ro.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'roles'::text AND l.row_key = jsonb_build_object('id', ro.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            ro.name_en
           FROM roles ro
          WHERE ro.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'employee'::text AS text,
            'module.hr.view'::text AS text,
            em.id,
            em.code,
            em.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'employees'::text AND l.row_key = jsonb_build_object('id', em.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            COALESCE(NULLIF(em.preferred_name, ''::text), em.legal_name)
           FROM employees em
          WHERE em.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'department'::text AS text,
            'module.hr.view'::text AS text,
            dp.id,
            dp.code,
            dp.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'departments'::text AND l.row_key = jsonb_build_object('id', dp.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            dp.name_en
           FROM departments dp
          WHERE dp.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'training_record'::text AS text,
            'module.hr.view'::text AS text,
            tr.id,
            NULL::text,
            tr.deleted_at,
            ( SELECT l.actor_account
                   FROM change_log l
                  WHERE l.table_name = 'training_records'::text AND l.row_key = jsonb_build_object('id', tr.id) AND l.op = 'UPDATE'::text AND 'deleted_at'::text = ANY (l.changed_columns) AND (l.new ->> 'deleted_at'::text) IS NOT NULL
                  ORDER BY l.seq DESC
                 LIMIT 1) AS actor_account,
            NULL::text AS text,
            NULL::uuid AS uuid,
            tr.training_name
           FROM training_records tr
          WHERE tr.deleted_at IS NOT NULL) a
  WHERE has_permission(permission);

COMMENT ON VIEW public.deleted_records IS
    'AUDEL-3:全站被软删的记录,一条一行 —— 编号、种类、时刻、谁、为什么,以及台账上那条注销/冲销流水。被回滚的加工单也在这里(它的"删除"就是它的冲销)。【每一行跟着它自己模块的读权限】(permission 列 + 外层 has_permission),无权的那一类整类缺席而不是显示成零 —— 不为跨模块页面合成新权限码(/margin 那一课)。属主权限:invoker 会让 RLS 静默丢行,而行消失在这里意味着"没有东西被删过"。【只读,永不提供恢复】—— 撤销删除是一个没有人做过的决定,一个按钮会替所有人默默做掉它。';

GRANT SELECT ON public.deleted_records TO authenticated;

-- ── 3 · 自证 ─────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.at1d1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE at1d1_pending_after ON COMMIT DROP AS
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
    v_bad  text;
    v_n    int;
    v_m    int;
    v_rows int;
    t      record;
    k      text;
    f      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM at1d1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1d1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1D1_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1D1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 一行没多(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1d1_pending_before b EXCEPT SELECT a.k, a.id FROM at1d1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1d1_pending_after a EXCEPT SELECT b.k, b.id FROM at1d1_pending_before b)) THEN
        RAISE EXCEPTION 'AT1D1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(n, mx)::text FROM at1d1_log_before) IS DISTINCT FROM (SELECT row(count(*), max(seq))::text FROM change_log) THEN
        RAISE EXCEPTION 'AT1D1_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1d1_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:六十八个主语;每一个 shown 成员表与根表都在 change_log 的覆盖里;执行权
    IF (SELECT count(*) FROM trail_subjects()) <> 68 THEN
        RAISE EXCEPTION 'AT1D1_PROOF|expected 68 subjects, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    SELECT string_agg(DISTINCT x.t, ', ') INTO v_bad FROM (
        SELECT m.table_name AS t FROM trail_subject_members() m WHERE m.shown
        UNION SELECT s.root_table FROM trail_subjects() s) x
     -- M9:只在变更记录里出现的表没有触发器(它的事件由 record_account_event 写)
     WHERE x.t NOT IN (SELECT l.table_name FROM trail_log_only_tables() l)
       AND
           NOT EXISTS (SELECT 1 FROM information_schema.triggers tr
                        WHERE tr.event_object_table = x.t AND tr.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1D1_PROOF|member or root tables without the change-log trigger: %', v_bad; END IF;
    FOREACH f IN ARRAY ARRAY['public.trail_subjects()', 'public.trail_subject_members()', 'public.trail_prelog_sources()',
                             'public.record_trail(text, text, integer)', 'public.save_employee(uuid, jsonb, jsonb)'] LOOP
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1D1_PROOF|authenticated cannot execute %', f;
        END IF;
        IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1D1_PROOF|anon can execute %', f;
        END IF;
    END LOOP;
    IF has_function_privilege('authenticated', 'public.trail_root_gate(text, text, jsonb)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'AT1D1_PROOF|authenticated can execute the M12 gate';
    END IF;
    -- 七个账号一个都没有被停(本刀不碰账号)
    IF (SELECT count(*) FROM auth.users WHERE banned_until IS NOT NULL AND banned_until > now()) <> 0 THEN
        RAISE EXCEPTION 'AT1D1_PROOF|an account is disabled';
    END IF;

    -- ⑤ 真的读:以 admin@ 把新主语在线上的每一条记录读一遍(被拒 = 坏了);1c-3 与 1a 的主语各读一条,证登记表换过之后照旧。
    PERFORM set_config('request.jwt.claims', '{"sub":"321f1819-8449-48f7-9ae0-78b2c4b50f35","role":"authenticated"}', true);
    v_n := 0;
    FOR t IN SELECT 'account' AS s, id::text AS id FROM auth.users
             UNION ALL SELECT 'approval_policy', 'true'
             UNION ALL SELECT 'employee', id::text FROM employees
             UNION ALL SELECT 'department', id::text FROM departments
             UNION ALL SELECT 'training_record', id::text FROM training_records
             UNION ALL SELECT 'import_batch', id::text FROM import_batches
             UNION ALL SELECT s.subject, 'all' FROM trail_subjects() s WHERE s.root_rule = 'collection'
             UNION ALL SELECT 'role', id::text FROM roles
             UNION ALL SELECT 'finance_lock', 'true'
             UNION ALL (SELECT 'purchase_order', id::text FROM purchase_orders ORDER BY created_at LIMIT 1) LOOP
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_rows FROM record_trail(t.s, t.id, 500);
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'AT1D1_PROOF|% % refused for admin@: %', t.s, t.id, SQLERRM;
        END;
        -- 每一条有它的建立(记录开始之前的那一行,或之后的 INSERT);字典与六本集合里每一本都至少有一行今天的值,但字典表没有
        --   任何时刻列(Step 0 C §C),所以它们在变更记录开始之前一条都没有 —— 那几本可以是空的
        IF v_rows = 0 AND t.s NOT LIKE 'dictionary_%' THEN
            RAISE EXCEPTION 'AT1D1_PROOF|% % has an empty trail for admin@', t.s, t.id;
        END IF;
        v_n := v_n + 1;
    END LOOP;
    RAISE NOTICE 'AT1D1 read % records as admin@, none refused', v_n;
    -- cto 那个角色的页上读得到它被授给的那一笔(Q22:user_roles 是角色的成员)
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_m FROM record_trail('role', (SELECT id::text FROM roles WHERE code = 'cto'), 500) r WHERE r.table_name = 'user_roles';
    EXECUTE 'RESET ROLE';
    IF v_m < (SELECT count(*) FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id WHERE ro.code = 'cto') THEN
        RAISE EXCEPTION 'AT1D1_PROOF|the cto role page reads % grant rows, user_roles holds %', v_m,
            (SELECT count(*) FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id WHERE ro.code = 'cto');
    END IF;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1d1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1D1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1d1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1D1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1d1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1d1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
