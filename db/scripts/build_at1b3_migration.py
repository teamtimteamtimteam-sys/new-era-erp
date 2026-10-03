#!/usr/bin/env python3
"""AUDIT-TRAIL-1b-3:从镜像拼出迁移文件(形状照 build_at1b2_migration.py)。镜像是真源,迁移是它的一次投影 ——
三支登记表、一支新函数、一张视图从 db/ 原样抽出,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_at1b3_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-03-at1b3-trails-master-data-and-tools.sql"

# 同一签名,原地替换(不换任何一支的形状 —— 不需要 DROP)
REPLACED = ["trail_subjects", "trail_subject_members", "trail_prelog_sources"]
NEW_FUNCTIONS = ["save_storage_location"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


HEADER = """-- db/migrations/2026-10-03-at1b3-trails-master-data-and-tools.sql
-- AUDIT-TRAIL-1b-3 —— 主数据与工具的审计记录:物料 · 库位 · 金属价格 · 定价公式与条款申请 · 任务 · 三个阈值面板;
--   删掉的主数据进被删记录(v1.4.33 的一部分,未发布)。
-- 由 db/scripts/build_at1b3_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AT-1b Step 0 §a 的登记表与 Q2 · Q3 · Q9 · Q13 · M2 · M5 · M6,Tim 2026-09-29 照建议裁定;
--   1b-1 已经建好了 M1–M6,这一刀只加主语)
--   ① trail_subjects:加八个主语 —— material · storage_location · metal_price · pricing_formula · task ·
--      processing_settings · pricing_settings · receiving_settings(后三个:M5 的布尔主键,M6 只看面板自己的几列)。
--   ② trail_subject_members:物料的附件与化验要求;库位的允许分类;公式的应付金属、修改史、条款申请与它的审批;
--      任务的步骤、参与者、修改史。
--   ③ trail_prelog_sources:"记录开始之前"的来源 —— 建行时刻与删除戳;公式与任务的修改史;任务那一族的人是员工 id(M2)。
--   ④ save_storage_location(新):库位与它的允许分类【一次调用、一笔事务、只写变了的】(Q13)—— 取代应用里的三次写。
--   ⑤ deleted_records:加四类 —— 客户 · 供应商 · 物料 · 定价公式;"谁删的"取自变更记录(这四张表从来没有记过),
--      读不到就是 NULL(横幅只说日期,Q8)。同一组列,CREATE OR REPLACE。
--
-- 【不做什么】不改任何表、策略、授权、触发器;不写任何业务行;不加新权限码;不碰审批开关与名册。
--
-- 【破窗】什么都不坏:
--   · 旧应用只用 1b-2 之前的二十一个主语调 record_trail,参数不变;新主语对旧应用不存在(它不叫它们)。
--   · 旧应用的库位保存仍是三次直连写 —— 两张表的写策略与触发器一个没动,它照旧能写;新函数只是多出来的一扇门。
--   · deleted_records 多了四类行:旧的 /settings/deleted 会把它们列出来,种类名一栏是 deleted.kind.<键>,而旧应用的
--     消息文件里没有那四个键 —— 窗口里那四类的"种类"一格会印出键本身(deleted.kind.customer),没有链接(旧的
--     KIND_HREF 不认它们,不给链接)。这一页只给 data.view_deleted(auditor · cfo 等)。这是唯一一处看得见的不同。
--   · 三支登记表都是 IMMUTABLE 的函数,替换不锁表;视图的 CREATE OR REPLACE 只在提交那一刻拿一下它自己的锁。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;change_log 的行数
--   没变;每一张在途单据都还有一个【不是它自己当事人】的决定人;二十九个主语;新函数 authenticated 能执行、anon 不能;
--   被删记录列得出线上那几类;并以 tim@(cfo)真的读几次(每一张任务的修改史一行不少;阈值面板读得到、不报错)。
--   断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"   # tim@evoltrya.test(cfo)

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子(1b-2 的形状,二十一个主语;新函数还不存在)──────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1B3_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM trail_subjects()) <> 21 THEN
        RAISE EXCEPTION 'AT1B3_PRE|expected the 21 subjects of 1b-2, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    IF to_regproc('public.save_storage_location') IS NOT NULL THEN
        RAISE EXCEPTION 'AT1B3_PRE|save_storage_location already exists';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1b3_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE at1b3_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1b3_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
-- deleted_records 按【调用者】的模块码过滤(has_permission 读 JWT);迁移的属主身份没有 JWT,读到的会是 0 行 ——
--   一次权限拒绝长得和一次测量一模一样(AGENTS.md「一个 0 行的读数,先问它是谁读的」)。所以以 tim@(cfo,持每一个 view 码)读
SELECT set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
CREATE TEMP TABLE at1b3_deleted_before ON COMMIT DROP AS
SELECT record_kind, record_id FROM deleted_records;
SELECT set_config('request.jwt.claims', '', true);
""")
parts.append("\n-- ── 1 · 三支登记表:原地替换(同一签名,镜像原样)──────────────────────────────\n")
for name in REPLACED:
    parts.append(fn(name))
parts.append("\n-- ── 2 · 库位的保存:一次调用、只写变了的(Q13)────────────────────────────────\n")
for name in NEW_FUNCTIONS:
    parts.append(fn(name))
# apply_migration.sh 在本事务【末尾】(COMMIT 之前、自证之后)才回放 zzz_function_grants —— 那时新函数才收回 PUBLIC / anon。
# 自证 ④ 要断言的正是那个终态,所以在这里先做一遍同样的两句(回放到时再做一遍,幂等;镜像那一侧由重建跑的同一个文件给出)
parts.append("""
REVOKE EXECUTE ON FUNCTION public.save_storage_location(text, text, text[], uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_storage_location(text, text, text[], uuid, text, text) TO authenticated, service_role;
""")
parts.append("\n-- ── 3 · 被删记录:加四类(镜像原样;同一组列)──────────────────────────────────\n")
parts.append("\n" + (ROOT / "db/views/deleted_records.sql").read_text().rstrip("\n") + "\n")

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "at1b3_pending_decider_check")
parts.append("\n-- ── 4 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE at1b3_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    v_m    int;
    v_j    jsonb;
    t      record;
    k      text;
    f      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM at1b3_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1b3_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1B3_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1B3_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 一行没多(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1b3_pending_before b EXCEPT SELECT a.k, a.id FROM at1b3_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1b3_pending_after a EXCEPT SELECT b.k, b.id FROM at1b3_pending_before b)) THEN
        RAISE EXCEPTION 'AT1B3_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(n, mx)::text FROM at1b3_log_before) IS DISTINCT FROM (SELECT row(count(*), max(seq))::text FROM change_log) THEN
        RAISE EXCEPTION 'AT1B3_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1b3_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:二十九个主语;每一个 shown 成员表都在 change_log 的覆盖里;登记表与读法对 authenticated 的执行权照旧;
    --    新函数 authenticated 能执行、anon 不能(apply_migration.sh 在本事务里回放 zzz_function_grants)
    IF (SELECT count(*) FROM trail_subjects()) <> 29 THEN
        RAISE EXCEPTION 'AT1B3_PROOF|expected 29 subjects, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    SELECT string_agg(DISTINCT m.table_name, ', ') INTO v_bad FROM trail_subject_members() m
     WHERE m.shown AND NOT EXISTS (SELECT 1 FROM information_schema.triggers tr
                                    WHERE tr.event_object_table = m.table_name AND tr.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1B3_PROOF|member tables without the change-log trigger: %', v_bad; END IF;
    SELECT string_agg(s.root_table, ', ') INTO v_bad FROM trail_subjects() s
     WHERE NOT EXISTS (SELECT 1 FROM information_schema.triggers tr WHERE tr.event_object_table = s.root_table AND tr.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1B3_PROOF|root tables without the change-log trigger: %', v_bad; END IF;
    FOREACH f IN ARRAY ARRAY['public.trail_subjects()', 'public.trail_subject_members()', 'public.trail_prelog_sources()',
                             'public.record_trail(text, text, integer)', 'public.save_storage_location(text, text, text[], uuid, text, text)'] LOOP
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1B3_PROOF|authenticated cannot execute %', f;
        END IF;
        IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1B3_PROOF|anon can execute %', f;
        END IF;
    END LOOP;

    -- ⑤ 被删记录(以 tim@ 读 —— 见文首那一句):原来那几类一行不少;新的四类与基表里删掉的行数逐类相等
    PERFORM set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
    IF (SELECT count(*) FROM at1b3_deleted_before) = 0 THEN
        RAISE EXCEPTION 'AT1B3_PROOF|the before-reading of deleted_records is empty — a refused read, not a measurement';
    END IF;
    IF EXISTS (SELECT record_kind, record_id FROM at1b3_deleted_before EXCEPT SELECT record_kind, record_id FROM deleted_records) THEN
        RAISE EXCEPTION 'AT1B3_PROOF|a deleted record that was listed before is no longer listed';
    END IF;
    FOR t IN SELECT * FROM (VALUES ('customer', 'customers'), ('supplier', 'suppliers'), ('material', 'materials'),
                                   ('pricing_formula', 'pricing_formulas')) v(kind, tbl) LOOP
        EXECUTE format('SELECT count(*) FROM %I WHERE deleted_at IS NOT NULL', t.tbl) INTO v_n;
        SELECT count(*) INTO v_m FROM deleted_records WHERE record_kind = t.kind;
        RAISE NOTICE 'AT1B3 deleted %: % in the table, % listed for tim@ (% with a person)', t.kind, v_n, v_m,
            (SELECT count(*) FROM deleted_records WHERE record_kind = t.kind AND deleted_by IS NOT NULL);
        IF v_n <> v_m THEN RAISE EXCEPTION 'AT1B3_PROOF|deleted %: % in the table but % listed', t.kind, v_n, v_m; END IF;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑥ 真的读几次:每一张任务(删掉的也读 —— 读规则不过滤 deleted_at)以它【归属人】的账号读 —— 归属人永远打得开自己的任务
    --    (Q3;私人任务对别人是私的:tim@ 不持 module.tasks.view_all,读别人的私人任务被按名拒,那是对的);修改史一行不少。
    --    归属人没有账号的,退回 tim@;一张团队任务被拒 = 坏了。三个阈值面板以 tim@ 读得到(M5:主键 'true')
    FOR t IN SELECT tk.id, tk.code, tk.task_type, COALESCE(e.user_id, '{TIM}'::uuid) AS reader,
                    CASE WHEN e.id IS NULL THEN 'no owner' WHEN e.user_id IS NULL THEN 'owner ' || e.code || ' has no login'
                         ELSE 'owner ' || e.code || COALESCE(' (' || e.employment_status || CASE WHEN e.deleted_at IS NOT NULL THEN ', deleted' ELSE '' END || ')', '') END AS why
               FROM tasks tk LEFT JOIN employees e ON e.id = tk.owner_id ORDER BY tk.code LOOP
        PERFORM set_config('request.jwt.claims', json_build_object('sub', t.reader, 'role', 'authenticated')::text, true);
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT jsonb_agg(to_jsonb(r)) INTO v_j FROM record_trail('task', t.id::text, 500) r;
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            IF t.task_type = 'team' OR SQLERRM NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
                RAISE EXCEPTION 'AT1B3_PROOF|task % (%) refused for its reader: %', t.code, t.task_type, SQLERRM;
            END IF;
            RAISE NOTICE 'AT1B3 task % (personal) refused by name for its reader (%) — % history rows', t.code, t.why,
                (SELECT count(*) FROM task_history WHERE task_id = t.id);
            CONTINUE;
        END;
        SELECT count(*) INTO v_n FROM task_history h WHERE h.task_id = t.id
           AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_j, '[]'::jsonb)) e
                            WHERE e ->> 'table_name' = 'task_history' AND e -> 'row_key' ->> 'id' = h.id::text);
        IF v_n > 0 THEN RAISE EXCEPTION 'AT1B3_PROOF|% task history row(s) of % missing from its trail', v_n, t.code; END IF;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
    FOREACH k IN ARRAY ARRAY['processing_settings', 'pricing_settings', 'receiving_settings'] LOOP
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT count(*) INTO v_n FROM record_trail(k, 'true', 20);
        EXECUTE 'RESET ROLE';
        RAISE NOTICE 'AT1B3 % trail rows for tim@: %', k, v_n;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑦ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1b3_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1B3 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1b3_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1B3_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1b3_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1b3_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
