#!/usr/bin/env python3
"""APR-8:从镜像拼出迁移文件(形状照 build_apr7_migration.py)。镜像是真源,迁移是它的一次投影 ——
函数、表、策略、触发器、视图都从镜像里【原样抽出】,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_apr8_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql"


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.lstrip().startswith("--"):
        body = f"-- ─── {name}\n" + body
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def stmt(path, head):
    """从镜像里抽出以 head 开头、到【语句真正的结尾】为止的那一句(跳过 -- 注释与单引号字符串)。"""
    s = mirror(path)
    assert s.count(head) == 1, (path, head)
    i = s.index(head)
    k = i
    while True:
        c = s[k]
        if s.startswith("--", k):
            k = s.index("\n", k)
        elif c == "'":
            k = s.index("'", k + 1)
            while s.startswith("''", k):
                k = s.index("'", k + 2)
        elif c == ";":
            return s[i:k + 1] + "\n"
        k += 1


HEADER = """-- db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql
-- APR-8 —— 合同条款与定价公式:cco 提,CFO 批每一张,批准之前什么都不生效
-- (docs/role-matrix.md「合同条款 · 定价公式 | cco | CFO」)。
-- 由 db/scripts/build_apr8_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-8 grilling Q1–Q11,Tim 2026-09-26 全部接受)
--   ① 公式(Q1):新公式生下来停用、挂一张 formula_create;改在用的公式 = 一张带完整拟议条款的 formula_change,
--      批准时就地替换(pricing_formula_history 照记);等待期间旧条款照旧生效;重新启用 = formula_reactivate;
--      停用、删除仍是 cco 一步(deactivate_pricing_formula · delete_pricing_formula)。不加状态列。
--   ② 合同(Q2):只有 active 有效力,进入 active 的每一条路都经 CFO(contract_activate);生效中的合同表头与七张
--      条款表冻结;改 = 暂停、编辑、再申请,CFO 看见与上一次批准时那一份的差别;暂停 / 到期 / 终止仍是一步。
--   ③ 一张表 terms_requests,四种(Q4);submitted → approved(当场生效)· rejected(要理由)· withdrawn。
--      提交按同一条路试跑(PQ006);审批关着时生下来就批准并生效(auto_approved)。
--   ④ 冻结(Q5):一个主体只挂一张在等的(TERMS_REQUEST_OPEN);合同等待中表头 TERMS_REQUEST_FREEZES_CONTRACT、
--      条款 CONTRACT_TERMS_FROZEN;批准时 fingerprint 再比(TERMS_CHANGED_SINCE_REQUEST)。
--   ⑤ 关门(Q6):公式两张表的六条写策略拿掉,直连写按名拒 PRICING_FORMULA_THROUGH_REQUEST_ONLY(语句级,零行也拒);
--      合同直连只许建草稿(CONTRACT_ACTIVATES_THROUGH_REQUEST)、生效中表头 CONTRACT_ACTIVE_IS_FROZEN。
--   ⑥ 引擎登记(Q9):approval_chain_gates 一行(二级,五个门码);approval_pending_documents 一支(blocks_disable、
--      fixed_level = 2、金额 NULL);approval_log 的主体类型与读策略;record_approval_decision 一支;
--      operations_now 一支 terms_request_pending。
--
-- 【不做什么】不新增任何权限码(Q6),所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行 —— 线上那张 PF-2026-0001 照旧在用(Q7)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一条没变;在途单据一张不少、一张不多;
-- approval_log、分录、公式、比例、公式历史、合同、条款、承诺一行没变;申请表是空的;公式两张表与申请表没有写策略;
-- 十支守卫挂上;内层算子 authenticated 调不到;新链有人批得了;每一张在途单据(连同每一条申请链)都还有一个
-- 【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = """SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
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
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'"""

COUNTS = """SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM pricing_formulas) AS formulas,
       (SELECT count(*) FROM pricing_formulas WHERE is_active AND deleted_at IS NULL) AS formulas_live,
       (SELECT count(*) FROM pricing_formula_metals) AS formula_metals,
       (SELECT count(*) FROM pricing_formula_history) AS formula_history,
       (SELECT count(*) FROM pricing_term_commitments) AS commitments,
       (SELECT count(*) FROM contracts) AS contracts,
       (SELECT (SELECT count(*) FROM contract_grade_specs) + (SELECT count(*) FROM contract_insurance_obligations)
             + (SELECT count(*) FROM contract_volume_commitments) + (SELECT count(*) FROM contract_pricing_terms)
             + (SELECT count(*) FROM contract_settlement_terms) + (SELECT count(*) FROM contract_refining_charges)
             + (SELECT count(*) FROM contract_penalty_elements)) AS contract_terms,
       (SELECT count(*) FROM contract_document_terms) AS contract_links"""

INTERNALS = ["terms_request_submit_internal(text, uuid, jsonb, text)",
             "terms_request_execute_internal(uuid)",
             "terms_request_dry_run(uuid)",
             "terms_request_snapshot(text, uuid, jsonb)",
             "terms_request_fingerprint(text, uuid)",
             "formula_terms_state(uuid)",
             "contract_terms_state(uuid)"]

DOORS = ["submit_formula_create_request(jsonb, text)",
         "submit_formula_change_request(uuid, jsonb, text)",
         "submit_formula_reactivate_request(uuid, jsonb, text)",
         "submit_contract_activation_request(uuid, text)",
         "decide_terms_request(uuid, boolean, text)", "withdraw_terms_request(uuid, text)",
         "terms_requests_visible(integer, uuid, uuid)",
         "deactivate_pricing_formula(uuid)", "delete_pricing_formula(uuid)",
         "formula_terms_normalize(jsonb)", "contract_terms_lock_reason(uuid)",
         "guard_pricing_formula_direct_write()", "guard_contract_write()", "guard_contract_terms_frozen()"]

TERM_TABLES = ["contract_grade_specs", "contract_insurance_obligations", "contract_volume_commitments",
               "contract_pricing_terms", "contract_settlement_terms", "contract_refining_charges",
               "contract_penalty_elements"]
GUARDS = (["trg_pricing_formulas_direct_write", "trg_pricing_formula_metals_direct_write", "trg_contracts_guard_write"]
          + [f"trg_{t}_frozen" for t in TERM_TABLES])

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR8_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.terms_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR8_PRE|terms_requests already exists';
    END IF;
    -- 批的人要持五个门码:cfo 今天五个都持(APR-8 Step 0 以 postgres 读 role_permissions 量过)
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.pricing.view', 'data.view_prices',
               'data.view_purchase_prices', 'module.suppliers.view', 'module.customers.view')) <> 5 THEN
        RAISE EXCEPTION 'APR8_PRE|cfo does not hold all five gate codes';
    END IF;
    -- 六条要拿掉的写策略此刻都在
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
         AND tablename IN ('pricing_formulas', 'pricing_formula_metals') AND cmd <> 'SELECT') <> 6 THEN
        RAISE EXCEPTION 'APR8_PRE|expected exactly six formula write policies';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a8_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE a8_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE a8_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
""")

# ── 1 · 表 ───────────────────────────────────────────────────────────────────
t = mirror("db/tables/terms_requests.sql")
parts.append("\n-- ── 1 · terms_requests(镜像原样)────────────────────────────────────────────\n")
parts.append(t[t.index("CREATE TABLE public.terms_requests"):])

# ── 2 · approval_log:主体类型 + 读策略 ─────────────────────────────────────────
al = mirror("db/tables/approval_log.sql")
i = al.index("subject_type        text NOT NULL CHECK (subject_type IN (")
j = al.index("'terms_request')),", i) + len("'terms_request'))")
check_body = al[i + len("subject_type        text NOT NULL "):j]
parts.append("\n-- ── 2 · approval_log:主体类型加 terms_request;读策略加同名一支 ────────────────\n")
parts.append("ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;\n")
parts.append("ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check\n    "
             + check_body + ";\n")
parts.append('DROP POLICY "approval_log select by permission" ON public.approval_log;\n')
parts.append(stmt("db/tables/approval_log.sql", 'CREATE POLICY "approval_log select by permission"'))

# ── 3 · 函数 ─────────────────────────────────────────────────────────────────
parts.append("\n-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in ["formula_terms_state", "contract_terms_state", "formula_terms_normalize",
             "terms_request_fingerprint", "terms_request_snapshot", "contract_terms_lock_reason",
             "terms_request_execute_internal", "terms_request_dry_run", "terms_request_submit_internal",
             "submit_formula_create_request", "submit_formula_change_request", "submit_formula_reactivate_request",
             "submit_contract_activation_request", "decide_terms_request", "withdraw_terms_request",
             "terms_requests_visible", "deactivate_pricing_formula", "delete_pricing_formula",
             "guard_pricing_formula_direct_write", "guard_contract_write", "guard_contract_terms_frozen",
             "record_approval_decision", "approval_pending_documents", "approval_chain_gates"]:
    parts.append(fn(name))

# ── 4 · 关门:公式的写策略拿掉;十支守卫 ─────────────────────────────────────────
parts.append("\n-- ── 4 · 关门(Q6):公式两张表的写策略拿掉;十支守卫挂上 ─────────────────────────\n")
for tbl in ["pricing_formulas", "pricing_formula_metals"]:
    for verb in ["insert", "update", "delete"]:
        parts.append(f'DROP POLICY "{tbl} {verb} by permission" ON public.{tbl};\n')
parts.append(stmt("db/tables/pricing_formulas.sql", "CREATE TRIGGER trg_pricing_formulas_direct_write\n"))
parts.append(stmt("db/tables/pricing_formula_metals.sql", "CREATE TRIGGER trg_pricing_formula_metals_direct_write\n"))
parts.append(stmt("db/tables/contracts.sql", "CREATE TRIGGER trg_contracts_guard_write\n"))
for tt in TERM_TABLES:
    parts.append(stmt(f"db/tables/{tt}.sql", f"CREATE TRIGGER trg_{tt}_frozen\n"))

# ── 5 · EXECUTE ──────────────────────────────────────────────────────────────
parts.append("\n-- ── 5 · EXECUTE:内层算子从 authenticated 收回(与 zzz_function_grants.sql 同句)────────\n")
for sig in INTERNALS:
    parts.append(f"REVOKE EXECUTE ON FUNCTION public.{sig} FROM PUBLIC, anon, authenticated;\n")
for sig in DOORS:
    parts.append(f"REVOKE EXECUTE ON FUNCTION public.{sig} FROM PUBLIC, anon;\n")

# ── 6 · operations_now ───────────────────────────────────────────────────────
v = mirror("db/views/operations_now.sql")
i = v.index("CREATE VIEW public.operations_now AS")
j = v.index("\n\nGRANT SELECT ON public.operations_now", i)
view = v[i:j].rstrip().rstrip(";") + ";\n"
parts.append("\n-- ── 6 · operations_now:加一支 terms_request_pending(镜像原样)──────────────────\n")
parts.append(view.replace("CREATE VIEW public.operations_now AS", "CREATE OR REPLACE VIEW public.operations_now AS", 1))

# ── 7 · 自证 ─────────────────────────────────────────────────────────────────
a7 = mirror("db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql")
start = a7.index("CREATE FUNCTION pg_temp.a7_pending_decider_check")
dec = a7[start:a7.index("$f$;", start) + 4].replace("a7_pending_decider_check", "a8_pending_decider_check")
parts.append("\n-- ── 7 · 自证 ──────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
internal_list = ", ".join(f"'public.{s}'" for s in INTERNALS)
guard_list = ", ".join(f"'{g}'" for g in GUARDS)
parts.append(f"""
CREATE TEMP TABLE a8_pending_after ON COMMIT DROP AS
{PENDING}
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码,Q6)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM a8_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a8_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR8_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR8_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、公式、比例、历史、承诺、合同、条款、挂接一行没变;申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM a8_pending_before b EXCEPT SELECT a.k, a.id FROM a8_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a8_pending_after a EXCEPT SELECT b.k, b.id FROM a8_pending_before b)) THEN
        RAISE EXCEPTION 'APR8_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a8_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'APR8_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM a8_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;
    IF EXISTS (SELECT 1 FROM terms_requests) THEN
        RAISE EXCEPTION 'APR8_PROOF|terms_requests is not empty';
    END IF;

    -- ④ 结构:公式两张表与申请表上没有写策略;十支守卫挂上;内层算子 authenticated 调不到;名册一行、只有二级
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('pricing_formulas', 'pricing_formula_metals', 'terms_requests') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'APR8_PROOF|a formula / terms_requests write policy exists';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ({guard_list});
    IF v_n <> {len(GUARDS)} THEN RAISE EXCEPTION 'APR8_PROOF|expected {len(GUARDS)} guard triggers, got %', v_n; END IF;
    SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY[{internal_list}]) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR8_PROOF|authenticated can still execute: %', v_bad; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'terms_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR8_PROOF|terms_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了
    SELECT count(*) INTO v_n FROM approval_deciders('terms_request', 'decide_terms_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR8_PROOF|nobody can decide a terms request'; END IF;
    RAISE NOTICE 'APR8 deciders for terms_request: %', v_n;

    -- ⑥ 每一张在途单据 —— 连同每一条申请链 —— 都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a8_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR8 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a8_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR8_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a8_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a8_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
