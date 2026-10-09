#!/usr/bin/env python3
"""MES-5b-3(v1.4.47):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新视图、新函数与换掉的函数原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有对象上的改动(两支新触发器、工序与形态的种子行、单据登记、admin 的一行授权)
在这里逐句写出,并先断言镜像里那几行真的是这个样子。照抄 build_mes5b2_migration.py 的形状。
跑法:python3 db/scripts/build_mes5b3_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-09-mes5b3-blending.sql"

NEW_TABLES = ["blending_plans", "blending_plan_targets", "blending_plan_lines"]
NEW_FUNCS = ["next_blending_plan_code", "blending_plan_write_children", "create_blending_plan", "amend_blending_plan",
             "release_blending_plan", "cancel_blending_plan", "execute_blending_plan",
             "guard_blending_run_from_plan", "guard_blended_batch_metals_from_assay"]
REPLACED_FUNCS = ["trail_subjects", "trail_subject_members"]
NEW_VIEWS = ["blending_plan_line_metals_all", "blending_plan_line_metals", "blending_plan_prediction",
             "blending_plan_execution", "blending_plan_outcome"]

STAFF_SIGS = ["public.create_blending_plan(uuid, jsonb, jsonb, uuid, text)",
              "public.amend_blending_plan(uuid, uuid, jsonb, jsonb, uuid, text)",
              "public.release_blending_plan(uuid)",
              "public.cancel_blending_plan(uuid, text)",
              "public.execute_blending_plan(uuid, date, timestamp with time zone, timestamp with time zone, text, jsonb, numeric, uuid, text)"]
PLAIN_SIGS = ["public.next_blending_plan_code(date)"]
INTERNAL_SIGS = ["public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb)",
                 "public.guard_blending_run_from_plan()", "public.guard_blended_batch_metals_from_assay()"]

ENGINE_SIG = ("p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, "
              "p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text, "
              "p_started_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ended_at timestamp with time zone DEFAULT NULL::timestamp with time zone, "
              "p_shift_code text DEFAULT NULL::text, p_recipe_version_id uuid DEFAULT NULL::uuid, p_values jsonb DEFAULT NULL::jsonb, "
              "p_corrects_run_id uuid DEFAULT NULL::uuid")

DIGEST_TABLES = ["processing_runs", "processing_inputs", "processing_outputs", "inbound_batches", "output_batches", "inbound_batch_metals",
                 "output_batch_metals", "assay_results", "assay_result_metals", "inventory_movements", "journal_entries", "journal_lines",
                 "expenses", "payments", "payment_allocations", "work_orders", "devices", "materials", "contracts", "contract_grade_specs",
                 "material_forms", "processing_run_closures", "processing_run_losses"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def view(name):
    body = (ROOT / f"db/views/{name}.sql").read_text().rstrip("\n") + "\n"
    assert "CREATE VIEW public." in body, name
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def must(path, text):
    assert text in mirror(path), (path, text[:80])
    return text


def digest(t):
    return f"(SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM {t} t) AS {t}"


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
RUN_TRIGGER = must("db/tables/processing_runs.sql", """CREATE TRIGGER trg_processing_runs_blending_from_plan
    BEFORE INSERT ON public.processing_runs
    FOR EACH ROW EXECUTE FUNCTION public.guard_blending_run_from_plan();
""")
METALS_TRIGGER = must("db/tables/output_batch_metals.sql", """CREATE TRIGGER trg_output_batch_metals_blended_from_assay
    BEFORE INSERT OR UPDATE ON public.output_batch_metals
    FOR EACH ROW EXECUTE FUNCTION public.guard_blended_batch_metals_from_assay();
""")
OPS = mirror("db/tables/operation_types.sql")
OP_ROW = re.search(r"    \('blending', 'Blending', '配料', 'transforming', NULL, 9,\n     '(.*?)'\);\n", OPS, re.S)
assert OP_ROW, "blending row not in the operation_types mirror"
OP_NOTE = OP_ROW.group(1)
must("db/tables/operation_types.sql", "UPDATE public.operation_types SET started_from_run_page = true WHERE code = 'blending';\n")
for f in ("db/tables/operation_type_input_forms.sql", "db/tables/operation_type_output_forms.sql"):
    for form in ("black_mass", "cathode_powder", "anode_powder"):
        must(f, f"    ('blending', '{form}', '【MES-5b-3】')")
must("db/tables/operation_type_safety_states.sql", "    ('blending', 'discharged_verified', false,\n")
SAFETY_NOTE = re.search(r"\('blending', 'discharged_verified', false,\n     '(.*?)'\);", mirror("db/tables/operation_type_safety_states.sql"), re.S).group(1)
DOC_ROW = must("db/tables/document_types.sql",
               "    ('blending_plan', 'BLD', 'blending_plans', 'gapless', NULL, '/operation/blending', 'detail', 'notes', ARRAY['notes']::text[], ARRAY['module.processing.view']::text[]);")
must("db/tables/role_permissions.sql", " WHERE r.code = 'admin';\n")
assert "p.code <> 'module.tasks.view_all'" not in mirror("db/tables/role_permissions.sql")

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m, t
    bind_sql.append(m.group(0))

HEADER = """-- db/migrations/2026-10-09-mes5b3-blending.sql
-- MES-5b-3 —— 配料(将来那条线):一份配料计划从可售的粉料批次里排出来,对着每种金属的上下界,混之前先看预测的成分,
--   建单人之外的人放行,从计划页上执行成一炉,混出来那一批化验之后对着目标比一遍;admin 也持 module.tasks.view_all
--   (MES 组的第十一刀,v1.4.47;发布那一行在 docs/handbacks/MES-5b-3.md 的抬头)。
-- 由 db/scripts/build_mes5b3_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-09:MES-5b Step 0 的配料那一部分 —— Q16–Q20 与 Q1 · Q32 · Q34–Q36 的配料部分 —— 全部照推荐裁定;
--   Q16:今天这条线不配料,将来那条线会;并入:admin 持 module.tasks.view_all,关掉 MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED)
--   ① 三张表(Q17):blending_plans(BLD- 按年 · 产出物料 · 合同可空 · draft / released / executed / cancelled)·
--      blending_plan_targets(每种金属的下界 / 上界,从合同的品位规格抄来或人敲的)· blending_plan_lines(候选批次与计划的公斤数)。
--   ② 预测(Q17):按计划公斤数加权的平均,出处照直给,任何一行没量过就是"没量过";不落盘(blending_plan_prediction)。出界只标,不拒(Q20)。
--   ③ 一道新工序 blending(Q18):只从计划页上起(started_from_run_page,新建加工单的选单不列它;直接记按名拒 BLEND_RUN_FROM_PLAN_ONLY),
--      execute_blending_plan 是 commit_processing_run 的外壳(拆去隔离的先例 —— 引擎签名不动);实际公斤数可以与计划不同,差多少照直印出来;
--      混出来那一批的含量只来自化验(BLEND_CONTENT_FROM_ASSAY_ONLY)。
--   ④ 码(Q19):没有新码 —— 建与改 action.wo_create,放行 action.wo_release(建单人永远不能放行),执行 action.processing_commit,
--      读 module.processing.view;批次的含量只给看得见那一批的人(其余「受限」)。
--   ⑤ 可售(Q20):产出物料必须是可售的形态,否则按名拒(BLEND_OUTPUT_NOT_SALEABLE)。计划页把之后的化验对着目标比(blending_plan_outcome)。
--   ⑥ Q32 · Q34–Q36:没有新审批;三张新表都进变更记录(豁免仍是 8);新的审计主语 blending_plan;没有遮蔽的列;没有新的 Not yet set;一支迁移;
--      单据登记多一行 BLD(document_types)。
--   ⑦ 并入:线上的 admin 角色补一行 module.tasks.view_all(本刀唯一的一处授权改动);引导的 admin 同步(镜像)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;除了 admin 那一行,不加任何码、不改任何授权;不写、不改、不冲任何一张既有单据、
--   批次、加工单、化验、费用单、付款、分录;不建任何计划、目标、批次行、化验或品位规格;不给配料这道工序任何容差、字段、机器或配方
--   (它的平衡容差为空 —— V1 那一支从此也列它,那是 V1 本来的意思,不是一个新的待补值);require_calibrated_since 保持空。
--
-- 【破窗】见 docs/surveys/MES-5b/STEP0-HANDBACK.md §11:配料是 started_from_run_page,旧应用的新建加工单表单本来就不列它;旧应用没有配料的页;
--   新的两支触发器只拒两条旧应用不发的路(记一炉 blending、给一批混出来的料敲含量 —— 线上一批都没有)。窗口 ≈ 部署时长。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了 admin:module.tasks.view_all 一行、别的一行没动,admin 持目录里每一个码;
--   在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的加工单与腿、批次与含量、化验、流水、分录、
--   费用单、付款、工单、设备、物料、合同与品位规格逐字未变;变更记录只多了本刀种的那几行(插入,七张配置表与那一行授权);三张新表是空的;
--   两支触发器在;配料是 started_from_run_page;引擎的签名逐字未变;anon 能执行的【恰好】两支;五支员工函数是 DEFINER、调得到,内层调不到;
--   那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);提醒臂 59、待补的值 20 不变;每一个角色仍满足"动作码蕴含查看码"。
--   断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

parts = [HEADER]
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES5B3_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.blending_plans') IS NOT NULL OR to_regprocedure('public.execute_blending_plan(uuid, date, timestamp with time zone, timestamp with time zone, text, jsonb, numeric, uuid, text)') IS NOT NULL
       OR EXISTS (SELECT 1 FROM operation_types WHERE code = 'blending') OR EXISTS (SELECT 1 FROM document_types WHERE key = 'blending_plan' OR prefix = 'BLD') THEN
        RAISE EXCEPTION 'MES5B3_PRE|MES-5b-3 objects already exist';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES5B3_PRE|expected 7 accounts';
    END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin' AND rp.permission_code = 'module.tasks.view_all')
       OR (SELECT count(*) FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                               WHERE r.code = 'admin' AND rp.permission_code = p.code)) <> 1 THEN
        RAISE EXCEPTION 'MES5B3_PRE|expected admin to hold every code but module.tasks.view_all';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 55 THEN
        RAISE EXCEPTION 'MES5B3_PRE|expected 55 document types';
    END IF;
    IF pg_get_function_arguments('public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid)'::regprocedure)
         <> '{ENGINE_SIG}' THEN
        RAISE EXCEPTION 'MES5B3_PRE|the run engine signature is not the one this migration was written against';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B3_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES5B3_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5B3_PRE|operations_now should have 59 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES5B3_PRE|pending_values should have 20 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B3_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes5b3_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes5b3_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes5b3_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes5b3_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes5b3_rows_before ON COMMIT DROP AS
SELECT {(',' + chr(10) + '       ').join(digest(t) for t in DIGEST_TABLES)};
""")

parts.append("\n-- ── 1 · 新表(镜像原样):配料计划 · 目标品位 · 候选批次 ─────────────────────────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))
parts.append("\n-- ── 2 · 新函数(镜像原样):取号 · 判据 · 建 / 改 / 放行 / 取消 / 执行 · 两支守卫(表先在,%ROWTYPE 才解析得了)────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))

parts.append(f"""
-- ── 3 · 两支守卫上表(与 db/tables/processing_runs.sql · output_batch_metals.sql 逐字同一份)──────────────
{RUN_TRIGGER}
{METALS_TRIGGER}""")

parts.append(f"""
-- ── 4 · 一道新工序 blending 与它的形态、安全状态(与 db/tables/operation_type*.sql 的种子逐字同一份)──────────
INSERT INTO public.operation_types (code, name_en, name_zh, kind_code, resulting_safety_state_code, sort_order, notes, started_from_run_page) VALUES
    ('blending', 'Blending', '配料', 'transforming', NULL, 9,
     '{OP_NOTE}', true);
INSERT INTO public.operation_type_input_forms (operation_type_code, form_code, notes) VALUES
    ('blending', 'black_mass', '【MES-5b-3】'),
    ('blending', 'cathode_powder', '【MES-5b-3】'),
    ('blending', 'anode_powder', '【MES-5b-3】');
INSERT INTO public.operation_type_output_forms (operation_type_code, form_code, notes) VALUES
    ('blending', 'black_mass', '【MES-5b-3】'),
    ('blending', 'cathode_powder', '【MES-5b-3】'),
    ('blending', 'anode_powder', '【MES-5b-3】');
INSERT INTO public.operation_type_safety_states (operation_type_code, safety_state_code, resolves, notes) VALUES
    ('blending', 'discharged_verified', false,
     '{SAFETY_NOTE}');

-- ── 5 · 单据登记:BLD(与 db/tables/document_types.sql 那一行逐字同一份)──────────────────────────────
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
{DOC_ROW}
""")

parts.append("\n-- ── 6 · 换掉的函数(镜像原样,同签名):审计主语登记 —— blending_plan 与它的两张子表 ─────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 7 · 新视图(镜像原样):含量底表 · 逐行含量 · 预测 · 计划与实际 · 之后的化验 ───────────────────────\n")
for v in NEW_VIEWS:
    parts.append(view(v))

parts.append("\n-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──\n")
parts.append("".join(bind_sql))

parts.append("""
-- ── 9 · 并入:admin 持 module.tasks.view_all(Tim 2026-10-09;关掉 MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED)—— 本刀唯一的一处授权改动 ──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'module.tasks.view_all' FROM roles r WHERE r.code = 'admin'
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

acl = ["""
-- ── 10 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + PLAIN_SIGS + INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes5b3_pending_decider_check")
parts.append("\n-- ── 11 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(
    f"(SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM {t} t) IS DISTINCT FROM (SELECT {t} FROM mes5b3_rows_before)"
    for t in DIGEST_TABLES)
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES + NEW_VIEWS)

parts.append(f"""
CREATE TEMP TABLE mes5b3_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权:恰好多了 admin:module.tasks.view_all 一行,别的一行没动;admin 持目录里每一个码
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes5b3_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes5b3_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM 'admin:module.tasks.view_all' THEN RAISE EXCEPTION 'MES5B3_PROOF|grant change is not exactly admin:module.tasks.view_all: %', v_bad; END IF;
    IF EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                             WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES5B3_PROOF|admin does not hold every code';
    END IF;
    -- 每一个角色仍满足"动作码蕴含查看码"(MES-5b-1 的规矩)
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B3_PROOF|action-implies-view violated: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES5B3_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes5b3_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes5b3_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES5B3_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变
    IF EXISTS ((SELECT b.k, b.id FROM mes5b3_pending_before b EXCEPT SELECT a.k, a.id FROM mes5b3_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes5b3_pending_after a EXCEPT SELECT b.k, b.id FROM mes5b3_pending_before b)) THEN
        RAISE EXCEPTION 'MES5B3_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES5B3_PROOF|a pre-existing run, leg, batch, metal content, assay, movement, journal, expense, payment, work order, device, material or contract changed';
    END IF;

    -- ④ 变更记录只多了本刀种的那几行(插入:工序 1 · 投料形态 3 · 产出形态 3 · 安全状态 1 · 单据登记 ≤ 1 · 授权 1);三张新表是空的
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes5b3_log_before), 0)
       AND NOT (c.op = 'INSERT' AND c.table_name IN ('operation_types', 'operation_type_input_forms', 'operation_type_output_forms',
                                                     'operation_type_safety_states', 'document_types', 'role_permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B3_PROOF|unexpected change_log rows: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5b3_log_before), 0);
    IF v_n NOT IN (9, 10) THEN RAISE EXCEPTION 'MES5B3_PROOF|change_log moved by % (expected 9, or 10 if document_types is logged)', v_n; END IF;
    IF EXISTS (SELECT 1 FROM blending_plans) OR EXISTS (SELECT 1 FROM blending_plan_targets) OR EXISTS (SELECT 1 FROM blending_plan_lines) THEN
        RAISE EXCEPTION 'MES5B3_PROOF|the new tables must be empty';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B3_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑤ 结构:两支守卫在;配料从计划页上起;引擎的签名逐字未变;单据登记 56 行,BLD 一行
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_processing_runs_blending_from_plan')
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_output_batch_metals_blended_from_assay') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|the two guards are missing';
    END IF;
    IF NOT (SELECT started_from_run_page AND is_active AND kind_code = 'transforming' AND balance_tolerance_pct IS NULL FROM operation_types WHERE code = 'blending') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|blending must be an active transforming operation started from the plan page, with no tolerance set';
    END IF;
    IF pg_get_function_arguments('public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid)'::regprocedure)
         <> '{ENGINE_SIG}' THEN
        RAISE EXCEPTION 'MES5B3_PROOF|the run engine signature changed';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 56 OR document_type_prefix('blending_plan') <> 'BLD' THEN
        RAISE EXCEPTION 'MES5B3_PROOF|document_types should be 56 with BLD';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工函数 DEFINER、调得到;内层调不到;新表与视图 anon 读不到;底表 authenticated 也读不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES5B3_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B3_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.blending_plan_line_metals_all'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|the base view must not be readable by authenticated';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;新表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B3_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ({", ".join(f"'{t}'" for t in NEW_TABLES)}) AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|a write policy exists on a blending table';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(三张新表记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有金额)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES5B3_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES5B3_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑨ 提醒臂 59、待补的值 20 不变
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES5B3_PROOF|reminder arms 59 / pending-value arms 20 changed';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes5b3_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES5B3 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes5b3_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES5B3_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes5b3_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
