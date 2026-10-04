#!/usr/bin/env python3
"""AUDIT-TRAIL-1d-1:从镜像拼出迁移文件(形状照 build_at1d1_migration.py)。镜像是真源,迁移是它的一次投影 ——
登记 / 读法函数原样从 db/functions 抽出(同一签名,原地替换;三支新的、save_employee 新建),deleted_records 视图原样从 db/views 抽出。
跑法:python3 db/scripts/build_at1d1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-04-at1d1-trails-accounts-settings-and-employees.sql"

REPLACED = ["trail_log_only_tables", "trail_member_columns", "trail_root_gate", "trail_current_image", "trail_row_visible",
            "trail_subjects", "trail_subject_members", "trail_prelog_sources", "trail_ref_label", "record_trail", "change_log_rows",
            "save_employee"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


HEADER = """-- db/migrations/2026-10-04-at1d1-trails-accounts-settings-and-employees.sql
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
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

ADMIN = "321f1819-8449-48f7-9ae0-78b2c4b50f35"   # admin@swm-os.test(admin —— 唯一持 action.manage_permissions)

parts = [HEADER]
parts.append("""
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
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1d1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE at1d1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1d1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
""")
parts.append("\n-- ── 1 · 登记表与读法的内层:原地替换(同一签名,镜像原样)──────────────────────────────\n")
for name in REPLACED:
    parts.append(fn(name))
parts.append("""
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
""")
parts.append("\n-- ── 2 · 删掉的记录:多四类(Q25 · Q26)—— 视图原样从镜像来 ──────────────────────────────\n")
view = (ROOT / "db/views/deleted_records.sql").read_text()
parts.append("\n" + view.rstrip("\n") + "\n")
a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "at1d1_pending_decider_check")
parts.append("\n-- ── 3 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE at1d1_pending_after ON COMMIT DROP AS
{PENDING};

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
    PERFORM set_config('request.jwt.claims', '{{"sub":"{ADMIN}","role":"authenticated"}}', true);
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
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
