#!/usr/bin/env python3
"""MES-6a-1(v1.4.48):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新视图、新函数与换掉的函数原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表上的改动(四张表各加列、两支触发器、权限目录两行与一行声明、单据登记一行、
九行授权)在这里逐句写出,并先断言镜像里那几行真的是这个样子。照抄 build_mes5b3_migration.py 的形状。
跑法:python3 db/scripts/build_mes6a1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql"

NEW_TABLES = ["quality_settings", "samples", "sample_events", "assay_disputes"]
NEW_FUNCS = ["next_sample_code", "record_sample", "record_sample_event", "set_quality_settings", "open_assay_dispute",
             "record_dispute_umpire", "withdraw_assay_dispute", "resolve_assay_dispute", "link_dispute_fee", "guard_assay_sample_batch"]
REPLACED_FUNCS = ["apply_assay_result", "apply_output_assay", "preview_assay_price", "receipt_price_post_internal",
                  "sale_settlement_compute", "reverse_expense", "reverse_expense_internal", "reverse_electricity_allocation",
                  "trail_subjects", "trail_subject_members"]
NEW_VIEWS = ["sample_rows", "assay_dispute_metals", "assay_dispute_rows", "assay_disagreements_all"]
REPLACED_VIEWS = ["pending_values", "operations_now"]

OLD_RECORD_ASSAY = ("public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text)")
NEW_RECORD_ASSAY = ("public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid)")
STAFF_SIGS = ["public.record_sample(text, date, uuid, uuid, numeric, uuid, bigint, uuid, text)",
              "public.record_sample_event(uuid, text, timestamp with time zone, text, text, uuid, text, text)",
              "public.set_quality_settings(integer)",
              "public.open_assay_dispute(uuid, uuid, text, uuid)",
              "public.record_dispute_umpire(uuid, uuid, uuid)",
              "public.withdraw_assay_dispute(uuid, text)",
              "public.resolve_assay_dispute(uuid, uuid, text)",
              "public.link_dispute_fee(uuid, uuid)",
              NEW_RECORD_ASSAY]
PLAIN_SIGS = ["public.next_sample_code(date)"]
INTERNAL_SIGS = ["public.guard_assay_sample_batch()"]

# 前后比对的表:新加的列在比对时从两边都减掉(减一个不存在的键是空操作),于是"既有的行逐字未变"仍然是一句真话
DIGEST_TABLES = {
    "assay_results": ["sample_id"], "assay_result_metals": [], "inbound_batches": [], "output_batches": [],
    "inbound_batch_metals": [], "output_batch_metals": [], "receipt_price_requests": [], "price_history": [],
    "journal_entries": [], "journal_lines": [], "expenses": ["reversal_reason", "reversed_at", "reversed_by"],
    "payments": [], "payment_allocations": [], "payment_requests": [], "contracts": [],
    "contract_settlement_terms": ["arbitration_fee_rule"], "contract_document_terms": [], "laboratories": ["supplier_id"],
    "sales_orders": [], "sales_settlements": [], "electricity_allocations": [], "electricity_allocation_reversals": [],
    "expense_claims": [], "medical_claims": [], "suppliers": [], "storage_locations": [], "contamination_checks": [],
}

Q_VIEW_ROLES = ["admin", "cco", "cfo", "cto", "finance", "warehouse"]     # MES-0 Q90 + 常设裁定(admin 每一个码、cfo 每一个查看码)
Q_EDIT_ROLES = ["admin", "cco", "cto"]                                    # MES-0 Q90;Q12:warehouse 不加


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def view(name, replace=False):
    body = (ROOT / f"db/views/{name}.sql").read_text().rstrip("\n") + "\n"
    assert "CREATE VIEW public." in body, name
    if replace:
        body = body.replace("CREATE VIEW public.", "CREATE OR REPLACE VIEW public.", 1)
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def must(path, text):
    assert text in mirror(path), (path, text[:80])
    return text


def digest(t, drop):
    j = "to_jsonb(t)" + "".join(f" - '{k}'" for k in drop)
    return f"(SELECT md5(COALESCE(string_agg(({j})::text, '|' ORDER BY ({j})::text), '')) FROM {t} t)"


def comment_stmt(path, head):
    """一句 COMMENT ... IS '…'; —— 字面量里的 '' 是转义,不是结尾(按"下一个 ';"切会切在 ''counterparty''; 上)。"""
    m = re.search(re.escape(head) + r"\s*'(?:[^']|'')*';\n", mirror(path))
    assert m, (path, head)
    return m.group(0)


def between(path, start, end_marker):
    text = mirror(path)
    i = text.index(start)
    j = text.index(end_marker, i) + len(end_marker)
    return text[i:j]


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
AR = "db/tables/assay_results.sql"
must(AR, "    sample_id        uuid REFERENCES public.samples (id),\n")
must(AR, "CREATE INDEX assay_results_sample_id_rel ON public.assay_results (sample_id);\n")
AR_TRIGGER = must(AR, """CREATE TRIGGER trg_assay_results_sample_batch
    BEFORE INSERT OR UPDATE OF sample_id ON public.assay_results
    FOR EACH ROW EXECUTE FUNCTION public.guard_assay_sample_batch();
""")
AR_COMMENT_SAMPLE = comment_stmt(AR, "COMMENT ON COLUMN public.assay_results.sample_id IS")
AR_COMMENT_SUPERSEDED = comment_stmt(AR, "COMMENT ON COLUMN public.assay_results.superseded_by IS")

LAB = "db/tables/laboratories.sql"
must(LAB, "    supplier_id uuid REFERENCES public.suppliers (id)\n);")
LAB_COMMENT = comment_stmt(LAB, "COMMENT ON COLUMN public.laboratories.supplier_id IS")

CST = "db/tables/contract_settlement_terms.sql"
CST_COL = must(CST, """    arbitration_fee_rule text
        CHECK (arbitration_fee_rule IS NULL OR arbitration_fee_rule IN
               ('loser_pays', 'equal', 'further_from_umpire_pays', 'buyer', 'seller')),
""")
CST_COMMENT = comment_stmt(CST, "COMMENT ON COLUMN public.contract_settlement_terms.arbitration_fee_rule IS")

EXP = "db/tables/expenses.sql"
EXP_ALTER = between(EXP, "ALTER TABLE public.expenses\n    ADD COLUMN reversal_reason text,", "reversed_at IS NOT NULL));\n")
EXP_COMMENTS = between(EXP, "COMMENT ON COLUMN public.expenses.reversal_reason IS", "COMMENT ON COLUMN public.expenses.reversed_by IS 'MES-6a-1(F3):谁冲销的(auth.uid(),与 reversal_reason 同一步写)。';\n")
EXP_GUARD = between(EXP, "CREATE OR REPLACE FUNCTION public.guard_expense_mutation()", "$function$;\n")
assert "EXPENSE_REVERSAL_REASON_REQUIRED" in EXP_GUARD

PERM = "db/tables/permissions.sql"
PERM_ROWS = between(PERM, "    ('module.quality.view', 'module', 'Quality (view)'", "151);")
must(PERM, "    ('action.apply_assay',              ARRAY['module.inbound.view','module.output.view','module.quality.view']),")

DOC_ROW = must("db/tables/document_types.sql",
               "    ('sample', 'SMP', 'samples', 'gapless', NULL, '/quality/samples', 'detail', 'notes', ARRAY['notes']::text[], ARRAY['module.quality.view']::text[]);")
RP = mirror("db/tables/role_permissions.sql")
assert "        'module.quality.view'\n) WHERE r.code = 'finance';" in RP and "        'module.quality.view'\n) WHERE r.code = 'warehouse';" in RP

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m, t
    bind_sql.append(m.group(0))

HEADER = """-- db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql
-- MES-6a-1 —— 样品与化验争议:一个新的「质量」区记样品(SMP-…)与它在谁手上直到处置;一份与对方对不上的化验可以立成一件争议,
--   挡住定价与结算直到结案;实验室可以指到它的供应商,于是仲裁费记成一张费用单;每一次费用冲销从此要一句理由
--   (MES 组的第十二刀,v1.4.48;发布那一行在 docs/handbacks/MES-6a-1.md 的抬头)。
-- 由 db/scripts/build_mes6a1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-09:MES-6a Step 0 —— Q1 拆两刀,本刀是 6a-1;Q2、Q5–Q45 中属于本刀的全部照推荐;Q12:仓库【不】加质量编辑码)
--   ① 四张新表:samples(SMP- 按年无洞 · 恰好一批 · 种类 · 留样日在建时抄下)· sample_events(保管记录,只追加)·
--      assay_disputes(open → resolved | withdrawn,只经函数)· quality_settings(单行:V16)。
--   ② 既有表加列:assay_results.sample_id(可空,样品必须同一批 —— 函数一道、表上守卫一道)· laboratories.supplier_id(可空)·
--      contract_settlement_terms.arbitration_fee_rule(可空 = V14)· expenses.reversal_reason / reversed_at / reversed_by(F3)+ 一条 CHECK。
--   ③ 挡:进料 apply_assay_result / preview_assay_price 与化验来源的定价过账(receipt_price_post_internal)、卖方 sale_settlement_compute,
--      在一件开着的争议上一律按名拒 ASSAY_DISPUTE_OPEN(Q18 · Q21);手工与按已承诺条款的改价照常。结案点名哪一份说了算,什么都不应用(Q19)。
--   ④ D4(Q20):应用一份结果只取代【同一出具方】的上一份 —— 进料与产出两支都改。
--   ⑤ F3(Q33–Q37):reverse_expense 与 reverse_electricity_allocation 都要理由(码之后第一件事),reverse_expense_internal 自己再拒空白;
--      理由写在被冲掉的那一张上,行守卫只在 posted → reversed 那一步放行这三列;镜像单的 notes 回到 'REVERSAL: <单号>'。签名不变。
--   ⑥ 码(Q11 · Q13 · Q90):module.quality.view(cco · cto · finance · cfo · admin · warehouse)/ module.quality.edit(cco · cto · admin);
--      action.apply_assay 声明的查看码多了 module.quality.view(结案在争议页上)。
--   ⑦ 提醒三支(sample_retention_due · assay_dispute_open · assay_results_disagree)· 待补的值两支(V16 · V14)· 审计主语三个(sample ·
--      assay_dispute · quality_settings)与两个批次主语的新成员 · 单据登记 SMP · 四张新表进变更记录(豁免仍是 8)· 没有新审批、没有新遮蔽列。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;除了上面九行质量码的授权,不加任何码、不改任何授权;不写、不改、不冲任何一张
--   既有单据、批次、化验、合同、费用单、付款、分录;不建任何样品、争议、实验室 → 供应商的指向,不填 V14、V16;require_calibrated_since 保持空。
--
-- 【破窗】见 docs/surveys/MES-6a/STEP0-HANDBACK.md §8:旧的费用页不送理由 → 每一次费用冲销都按名拒(EXPENSE_REVERSAL_REASON_REQUIRED,
--   旧应用印它的兜底句),直到部署;线上从没冲过一张费用单。旧的化验表单按具名参数调 record_assay_result,不带 p_sample_id → 默认值,照常。
--   争议的拒绝只在有争议时才咬,旧应用没有争议页。旧页面不读新表。窗口 ≈ 部署时长。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了那九行、别的一行没动,admin 持目录里每一个码;每一个角色仍满足
--   "动作码蕴含查看码";在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的化验、批次、含量、
--   定价申请、价格历史、分录、费用单、付款、合同与副本、实验室、销售单与结算、电费分摊与撤回、报销与医疗申报、供应商、库位、抽检逐字未变
--   (新加的列在比对时从两边减掉);变更记录只多了本刀种的那几行;四张新表空(设定表一行、天数为空);两支触发器在;record_assay_result
--   只剩新签名、reverse_expense 签名不变;anon 能执行的【恰好】两支;九支员工函数是 DEFINER、调得到,守卫函数调不到;那 44 条开着的读策略
--   还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);提醒臂 62、待补的值 22;单据登记 57 行。断言失败 = 整笔回滚。

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
        RAISE EXCEPTION 'MES6A1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.samples') IS NOT NULL OR to_regclass('public.assay_disputes') IS NOT NULL
       OR to_regclass('public.sample_events') IS NOT NULL OR to_regclass('public.quality_settings') IS NOT NULL
       OR EXISTS (SELECT 1 FROM permissions WHERE code LIKE 'module.quality.%')
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'sample' OR prefix = 'SMP') THEN
        RAISE EXCEPTION 'MES6A1_PRE|MES-6a-1 objects already exist';
    END IF;
    IF to_regprocedure('{OLD_RECORD_ASSAY}') IS NULL THEN
        RAISE EXCEPTION 'MES6A1_PRE|record_assay_result does not have the signature this migration replaces';
    END IF;
    IF to_regprocedure('public.reverse_expense(uuid, text)') IS NULL THEN
        RAISE EXCEPTION 'MES6A1_PRE|reverse_expense(uuid, text) expected';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES6A1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 75
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6A1_PRE|expected a catalogue of 75 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 56 THEN
        RAISE EXCEPTION 'MES6A1_PRE|expected 56 document types';
    END IF;
    IF EXISTS (SELECT 1 FROM expenses WHERE status = 'reversed') THEN
        RAISE EXCEPTION 'MES6A1_PRE|a reversed expense exists — the reversal-shape CHECK was written for none';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6A1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6A1_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES6A1_PRE|operations_now should have 59 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES6A1_PRE|pending_values should have 20 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6A1_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, d)} AS {t}" for t, d in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes6a1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes6a1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes6a1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes6a1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes6a1_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append(f"""
-- ── 1 · 权限目录:两个质量码;action.apply_assay 的声明多一个 module.quality.view(与 db/tables/permissions.sql 逐字同一份)──────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
{PERM_ROWS}
UPDATE public.permissions SET requires_view_any = ARRAY['module.inbound.view','module.output.view','module.quality.view']
 WHERE code = 'action.apply_assay';
""")

parts.append("\n-- ── 2 · 新表(镜像原样):质量的设定 · 样品 · 保管记录 · 化验争议 ─────────────────────────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append(f"""
-- ── 3 · 既有表加列(与各自的表镜像逐字同一份:列定义、索引、注释)──────────────────────────────────────────
ALTER TABLE public.assay_results ADD COLUMN sample_id uuid REFERENCES public.samples (id);
CREATE INDEX assay_results_sample_id_rel ON public.assay_results (sample_id);
{AR_COMMENT_SAMPLE}
{AR_COMMENT_SUPERSEDED}
ALTER TABLE public.laboratories ADD COLUMN supplier_id uuid REFERENCES public.suppliers (id);
{LAB_COMMENT}
ALTER TABLE public.contract_settlement_terms ADD COLUMN
{CST_COL.rstrip().rstrip(',')};
{CST_COMMENT}
{EXP_ALTER}
{EXP_COMMENTS}""")

parts.append("\n-- ── 4 · 新函数(镜像原样):取号 · 取样 · 保管 · V16 · 立 / 记仲裁 / 撤回 / 结案 / 挂仲裁费 · 样品守卫(表先在,%ROWTYPE 才解析得了)────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))

parts.append(f"""
-- ── 5 · 换掉的函数 ──────────────────────────────────────────────────────────────
-- 5a · 费用单的行守卫(与 db/tables/expenses.sql 里那一份逐字同一份):posted → reversed 那一步要理由
{EXP_GUARD}
-- 5b · record_assay_result 尾部多一个 p_sample_id(带默认)—— 签名变了,先 DROP 旧的再建(PROC-6 的先例);旧的具名调用照旧走得通
DROP FUNCTION {OLD_RECORD_ASSAY};
""")
parts.append(fn("record_assay_result"))
parts.append("\n-- 5c · 同签名替换(镜像原样):争议的挡 · D4 · 结算的拒 · F3 的两条路与内层 · 审计主语登记\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append(f"""
-- ── 6 · 化验的样品守卫上表(与 db/tables/assay_results.sql 逐字同一份)──────────────────────
{AR_TRIGGER}
-- ── 7 · 单据登记:SMP(与 db/tables/document_types.sql 那一行逐字同一份)──────────────────────────────
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
{DOC_ROW}
""")

parts.append("\n-- ── 8 · 新视图(镜像原样):样品此刻的状态 · 争议逐元素的差 · 争议一行 · 卖方的分歧底表 ───────────────────────\n")
for v in NEW_VIEWS:
    parts.append(view(v))
parts.append("\n-- ── 9 · 换掉的视图(镜像原样,同列):待补的值 +V16 +V14 · 提醒 +3 支 ─────────────────────────────────────\n")
for v in REPLACED_VIEWS:
    parts.append(view(v, replace=True))

parts.append("\n-- ── 10 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──\n")
parts.append("".join(bind_sql))

parts.append(f"""
-- ── 11 · 授权(MES-0 Q90 · MES-6a Step 0 Q11 · Q12):查看 → {' · '.join(Q_VIEW_ROLES)};编辑 → {' · '.join(Q_EDIT_ROLES)} —— 本刀唯一的授权改动 ──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'module.quality.view' FROM roles r WHERE r.code IN ({", ".join(f"'{c}'" for c in Q_VIEW_ROLES)})
ON CONFLICT (role_id, permission_code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'module.quality.edit' FROM roles r WHERE r.code IN ({", ".join(f"'{c}'" for c in Q_EDIT_ROLES)})
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

acl = ["""
-- ── 12 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + PLAIN_SIGS + INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes6a1_pending_decider_check")
parts.append("\n-- ── 13 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

expected_grants = sorted([f"{r}:module.quality.view" for r in Q_VIEW_ROLES] + [f"{r}:module.quality.edit" for r in Q_EDIT_ROLES])
staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(
    f"{digest(t, d)} IS DISTINCT FROM (SELECT {t} FROM mes6a1_rows_before)" for t, d in DIGEST_TABLES.items())
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES + NEW_VIEWS)

parts.append(f"""
CREATE TEMP TABLE mes6a1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权:恰好多了那九行质量码,别的一行没动;admin 持目录里每一个码;每一个角色仍满足"动作码蕴含查看码"
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes6a1_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes6a1_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM '{", ".join(expected_grants)}' THEN
        RAISE EXCEPTION 'MES6A1_PROOF|grant change is not exactly the nine quality grants: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 77
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6A1_PROOF|admin does not hold every one of the 77 codes';
    END IF;
    IF NOT (SELECT 'module.quality.view' = ANY (requires_view_any) FROM permissions WHERE code = 'action.apply_assay') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|action.apply_assay must declare module.quality.view';
    END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6A1_PROOF|action-implies-view violated: %', v_bad; END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code LIKE '%.edit'
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = replace(rp.permission_code, '.edit', '.view'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6A1_PROOF|edit-implies-view violated: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES6A1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes6a1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes6a1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES6A1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(新加的列在比对时从两边减掉)
    IF EXISTS ((SELECT b.k, b.id FROM mes6a1_pending_before b EXCEPT SELECT a.k, a.id FROM mes6a1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes6a1_pending_after a EXCEPT SELECT b.k, b.id FROM mes6a1_pending_before b)) THEN
        RAISE EXCEPTION 'MES6A1_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES6A1_PROOF|a pre-existing assay, batch, content, request, price, journal, expense, payment, contract, laboratory, sales order, settlement, allocation, claim, supplier, location or check changed';
    END IF;
    IF EXISTS (SELECT 1 FROM laboratories WHERE supplier_id IS NOT NULL) OR EXISTS (SELECT 1 FROM contract_settlement_terms WHERE arbitration_fee_rule IS NOT NULL)
       OR EXISTS (SELECT 1 FROM assay_results WHERE sample_id IS NOT NULL)
       OR EXISTS (SELECT 1 FROM expenses WHERE reversal_reason IS NOT NULL OR reversed_at IS NOT NULL OR reversed_by IS NOT NULL) THEN
        RAISE EXCEPTION 'MES6A1_PROOF|a new column was filled on an existing row (no lab link, fee rule, sample link or reversal reason is set by this cut)';
    END IF;

    -- ④ 变更记录只多了本刀种的那几行(权限目录 2 插 + 1 改 · 授权 9 插 · 单据登记 ≤ 1 插);四张新表空(设定表恰好一行、天数为空)
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes6a1_log_before), 0)
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'document_types'))
                OR (c.op = 'UPDATE' AND c.table_name = 'permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6A1_PROOF|unexpected change_log rows: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes6a1_log_before), 0);
    IF v_n NOT IN (12, 13) THEN RAISE EXCEPTION 'MES6A1_PROOF|change_log moved by % (expected 12, or 13 if document_types is logged)', v_n; END IF;
    IF EXISTS (SELECT 1 FROM samples) OR EXISTS (SELECT 1 FROM sample_events) OR EXISTS (SELECT 1 FROM assay_disputes)
       OR (SELECT count(*) FROM quality_settings) <> 1 OR (SELECT internal_retention_days FROM quality_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6A1_PROOF|the new tables must be empty (quality_settings: one row, V16 empty)';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6A1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑤ 结构:两支守卫在、CHECK 在;record_assay_result 只剩新签名、最后一个参数带默认;reverse_expense 签名不变;单据登记 57 行,SMP 一行
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_assay_results_sample_batch')
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_sample_events_append_only')
       OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'expenses_reversal_shape')
       OR position('EXPENSE_REVERSAL_REASON_REQUIRED' IN pg_get_functiondef('public.guard_expense_mutation()'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|the sample guard, the append-only guard, the reversal CHECK or the extended row guard is missing';
    END IF;
    IF to_regprocedure('{OLD_RECORD_ASSAY}') IS NOT NULL OR to_regprocedure('{NEW_RECORD_ASSAY}') IS NULL
       OR (SELECT count(*) FROM pg_proc WHERE proname = 'record_assay_result' AND pronamespace = 'public'::regnamespace) <> 1
       OR pg_get_function_arguments('{NEW_RECORD_ASSAY}'::regprocedure) NOT LIKE '%p_sample_id uuid DEFAULT NULL::uuid' THEN
        RAISE EXCEPTION 'MES6A1_PROOF|record_assay_result must exist once, with p_sample_id last and defaulted';
    END IF;
    IF pg_get_function_arguments('public.reverse_expense(uuid, text)'::regprocedure) <> 'p_expense_id uuid, p_memo text DEFAULT NULL::text' THEN
        RAISE EXCEPTION 'MES6A1_PROOF|reverse_expense must keep its signature';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 57 OR document_type_prefix('sample') <> 'SMP' THEN
        RAISE EXCEPTION 'MES6A1_PROOF|document_types should be 57 with SMP';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工函数 DEFINER、调得到;守卫调不到;新表与视图 anon 读不到;底视图 authenticated 也读不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES6A1_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6A1_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.assay_disagreements_all'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|the base view must not be readable by authenticated';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;新表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ({", ".join(f"'{t}'" for t in NEW_TABLES)}) AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|a write policy exists on a new quality table';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(四张新表记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑨ 提醒臂 62、待补的值 22
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 62
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 22 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|reminder arms 62 / pending-value arms 22 expected';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes6a1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES6A1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes6a1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes6a1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
