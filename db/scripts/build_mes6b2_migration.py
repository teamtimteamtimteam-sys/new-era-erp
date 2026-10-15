#!/usr/bin/env python3
"""MES-6b-2(v1.4.51):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数与换掉的函数、新视图与换掉的视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表上的改动(仓库申请多一种 coa_void 与它的主体列、三条约束、两条索引、列权限)、权限目录一行、
单据登记一行、两条授权、私有桶 coa-documents 与它的三条策略在这里逐句写出,并先断言镜像里那几行真的是这个样子。照抄 build_mes6b1_migration.py
的形状。跑法:python3 db/scripts/build_mes6b2_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql"

NEW_TABLES = ["certificates_of_analysis", "coa_issues"]
# 先于新表的:取号(读新表,但 plpgsql 的体建的时候不解析表名)与新表触发器要用的那一支
NEW_FUNCS_EARLY = ["next_coa_code", "guard_coa_mutation"]
# 新表与仓库申请的新列之后
NEW_FUNCS_LATE = ["coa_governing_assay", "coa_output_calibration_problem", "coa_issue_blockers", "coa_assemble",
                  "coa_certificate_data", "issue_coa", "record_coa_issue", "void_coa_internal", "submit_coa_void_request"]
# 同签名换掉;其中三支是 SQL 语言(体在建的时候就解析表名与列)—— 所以都放在新表与新列之后
REPLACED_FUNCS = ["warehouse_request_submit_internal", "warehouse_request_execute_internal", "warehouse_request_snapshot",
                  "warehouse_request_touches", "warehouse_request_conflict", "withdraw_warehouse_request",
                  "trail_subjects", "trail_subject_members"]
NEW_VIEWS = ["output_batch_chemistry_certainty_all", "output_batch_chemistry_certainty", "coa_rows"]
REPLACED_VIEWS = ["warehouse_requests_masked", "operations_now"]

PUBLIC_SIGS = ["public.issue_coa(uuid, uuid)",
               "public.record_coa_issue(uuid, text, text)",
               "public.submit_coa_void_request(uuid, text)",
               "public.coa_certificate_data(uuid, uuid)",
               "public.next_coa_code(date)"]
INTERNAL_SIGS = ["public.guard_coa_mutation()",
                 "public.coa_governing_assay(uuid, uuid)",
                 "public.coa_output_calibration_problem(uuid)",
                 "public.coa_issue_blockers(uuid, uuid)",
                 "public.coa_assemble(uuid, uuid)",
                 "public.void_coa_internal(uuid, text, uuid)"]

COA_ISSUERS = ["admin", "cco"]          # MES-0 Q90 · MES-6b Step 0 Q30

# 前后比对的表(既有的行逐字未变)。仓库申请减掉新列(减一个不存在的键是空操作)
DIGEST_TABLES = {
    "warehouse_requests": ["coa_id"], "output_batches": [], "inbound_batches": [], "assay_results": [], "assay_result_metals": [],
    "assay_result_indicators": [], "output_batch_metals": [], "assay_disputes": [], "nonconformance_reports": [],
    "quality_limit_judgements": [], "certificates_of_destruction": [], "cod_issues": [], "processing_runs": [], "processing_inputs": [],
    "processing_outputs": [], "sales_orders": [], "sales_order_lines": [], "sales_order_reservations": [], "shipment_lines": [],
    "contracts": [], "contract_settlement_terms": [], "contract_document_terms": [], "inventory_movements": [], "weighings": [],
    "instrument_calibrations": [], "company_profile": [], "employees": [], "positions": [], "customers": [], "approval_log": [],
    "journal_entries": [], "journal_lines": [], "payments": [], "expenses": [], "invoice_requests": [], "receipt_price_requests": [],
}


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


def between(path, start, end_marker):
    text = mirror(path)
    i = text.index(start)
    j = text.index(end_marker, i) + len(end_marker)
    return text[i:j]


def digest(t, minus):
    j = "to_jsonb(t)" + "".join(f" - '{c}'" for c in minus)
    return f"(SELECT md5(COALESCE(string_agg(({j})::text, '|' ORDER BY ({j})::text), '')) FROM {t} t)"


def comment_stmt(path, head):
    """一句 COMMENT ... IS '…'; —— 字面量里的 '' 是转义,不是结尾。"""
    m = re.search(re.escape(head) + r"\s*'(?:[^']|'')*';\n", mirror(path))
    assert m, (path, head)
    return m.group(0)


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
WR = "db/tables/warehouse_requests.sql"
WR_COL = must(WR, """    coa_id             uuid REFERENCES public.certificates_of_analysis (id) ON DELETE RESTRICT,
""")
WR_KIND = must(WR, """        CHECK (kind IN ('write_off_inbound', 'write_off_output', 'rollback', 'cod_void', 'coa_void')),""")
WR_SHAPE = between(WR, "    CONSTRAINT warehouse_requests_kind_shape CHECK (", "AND (kind = 'coa_void') = (coa_id IS NOT NULL)),")
WR_ONE = must(WR, "    CONSTRAINT warehouse_requests_one_subject CHECK (num_nonnulls(inbound_batch_id, output_batch_id, run_id, cod_id, coa_id) = 1),")
WR_IDX_OPEN = must(WR, """CREATE UNIQUE INDEX warehouse_requests_one_open_coa
    ON public.warehouse_requests (coa_id) WHERE status = 'submitted';
""")
WR_IDX_REL = must(WR, "CREATE INDEX warehouse_requests_coa_id_rel ON public.warehouse_requests (coa_id);\n")
must(WR, "              withdraw_reason, created_at, created_by, coa_id)\n    ON public.warehouse_requests TO authenticated;")
WR_COMMENT = comment_stmt(WR, "COMMENT ON TABLE public.warehouse_requests IS")
assert "作废分析证书(coa_void" in WR_COMMENT

PERM = "db/tables/permissions.sql"
PERM_ROW = between(PERM, "    ('action.issue_coa', 'action', 'Issue certificates of analysis'", "1250);")
must(PERM, "    ('action.issue_coa',                ARRAY['module.output.view','module.quality.view']),")
DOC_ROW = must("db/tables/document_types.sql",
               "    ('coa', 'COA', 'certificates_of_analysis', 'gapless', NULL, '/quality/coa', 'detail', 'void_reason', ARRAY['void_reason']::text[], ARRAY['module.output.view']::text[]);")
RP = mirror("db/tables/role_permissions.sql")
assert "action.issue_coa" not in RP   # 引导不授它:cco 不在引导里,admin 的引导按目录全给

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m, t
    bind_sql.append(m.group(0))
grants = mirror("db/views/zzz_function_grants.sql")
for sig in INTERNAL_SIGS:
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;" in grants, sig
for sig in PUBLIC_SIGS:
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;" not in grants, sig

HEADER = """-- db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql
-- MES-6b-2 —— 分析证书(CoA)、产出批的来料化学确定度(N38)、作废分析证书的 CFO 申请(MES 组的第十五刀,v1.4.51;
--   发布那一行在 docs/handbacks/MES-6b-2.md 的抬头)。由 db/scripts/build_mes6b2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-15:MES-6b Step 0 的 Q10–Q14 · Q17 · Q20 · Q29–Q32 · Q38–Q42 照推荐裁定;Q13:证书印「Issued by <名字>, <职位>」
--   与签发时刻,不放签名图片)
--   ① certificates_of_analysis(COA-YYYY-NNNN,按年无洞,签发那一刻铸):一批产出批,可选地点名一张预留过或发过它的销售单;一批 × 一张单同时
--      只有一张活证书;说话的那一份化验(结案争议点名的 → 点了单就合同约定那一方最新的 → 我们最新的,必须 is_final;成分读那一份化验自己的行,
--      从不读 output_batch_metals);快照由库组装一次(coa_assemble),签发之后只许作废、作废之后只许填一次替代品(guard_coa_mutation)。
--      coa_issues:字节的路径与 sha256(只追加);字节在私有桶 coa-documents。
--   ② issue_coa(action.issue_coa):拒绝清单 coa_issue_blockers 的第一句原样拒 —— 没有最终化验 · 质量暂扣 · 开着的争议 · 产出腿称重不在校准期内 ·
--      点名的单越限而报告没被接受 · 单不是这一批的 · 已有活证书 · 公司名没录;签发人不是员工 / 没有职位另拒。coa_certificate_data
--      (module.output.view)是同一份组装的预览外加拒绝清单。record_coa_issue 记字节。
--   ③ N38:output_batch_chemistry_certainty(属主权限,谓词 = 产出批的读策略)读无判据基视图 _all:进料叶子上最弱的那一个。
--   ④ 作废(Q20 · Q32):warehouse_requests 多一种 coa_void(主体列 coa_id,ALTER 加在末尾,列权限与遮蔽伴生视图同一支迁移里加上),
--      submit_coa_void_request(action.issue_coa)→ CFO 二级批准 → void_coa_internal;没有一步作废的门。重开一张时 issue_coa 链上 replaced_by_coa_id。
--   ⑤ 提醒 coa_facts_changed(action.issue_coa)· 审计主语 coa(两个批次主语下都挂着证书)· 单据登记 COA · 两张新表进变更记录(豁免仍是 8;
--      没有遮蔽的列)· action.issue_coa 进目录、声明 module.output.view 与 module.quality.view,授 cco · admin · 私有桶 coa-documents 与三条策略
--      (读:module.output.view;传:action.issue_coa;删:action.issue_coa 且那个对象还没被记进 coa_issues —— 签发时记哈希失败的孤儿;改:没有)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权只多 action.issue_coa 那两行;不写、不改任何一张既有单据、批次、化验、争议、报告、
--   证书、申请、合同、销售单、流水;不建任何分析证书或申请;不往桶里放任何对象;require_calibrated_since 保持空。线上由本迁移造出的只有:
--   两张空表、warehouse_requests 的 coa_id 那一列(全空)、一个权限码与它的两条授权、单据登记 COA 那一行、一个空的私有桶与它的三条策略。
--
-- 【破窗】新表、新视图、新函数旧应用一样都不读;warehouse_requests 的 kind 多一个取值、多一列(全空)—— 旧应用照旧读它认得的四种;
--   旧的提醒页按它自己的清单画牌子,coa_facts_changed 被跳过(线上零张证书,它也是空的)。窗口里什么都不坏;窗口 ≈ 部署时长。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了 action.issue_coa 的两行,admin 持目录里每一个码(79);在途单据一张不少、
--   一张不多,每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的申请、批次、化验、争议、报告、销毁证书、加工单、销售单、预留、
--   合同、流水、称重、校准、公司资料、员工、职位、客户、审批留痕、分录、付款、费用单、开票与定价申请逐字未变;两张新表零行;桶空;
--   变更记录只多了本刀种的那几行;五支对外的函数员工调得到、六支内层与触发器调不到;anon 能执行的【恰好】两支;那 44 条开着的读策略还是 44 条;
--   变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);单据登记 59 行、豁免 45 行;提醒 66 支、待定值 23 行;297 张表。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES6B2_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.certificates_of_analysis') IS NOT NULL OR to_regclass('public.coa_issues') IS NOT NULL
       OR to_regclass('public.coa_rows') IS NOT NULL OR to_regclass('public.output_batch_chemistry_certainty') IS NOT NULL
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'warehouse_requests'
                    AND column_name = 'coa_id')
       OR EXISTS (SELECT 1 FROM permissions WHERE code = 'action.issue_coa')
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'coa' OR prefix = 'COA')
       OR to_regprocedure('public.issue_coa(uuid, uuid)') IS NOT NULL
       OR EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'coa-documents') THEN
        RAISE EXCEPTION 'MES6B2_PRE|MES-6b-2 objects already exist';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'cco')) <> 2 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected the admin and cco roles';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 78
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected a catalogue of 78 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 58 OR (SELECT count(*) FROM document_type_exceptions) <> 45 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected 58 document types and 45 exceptions';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 65 THEN
        RAISE EXCEPTION 'MES6B2_PRE|operations_now should have 65 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES6B2_PRE|pending_values should have 23 arms';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 295 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected 295 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6B2_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, m)} AS {t}" for t, m in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes6b2_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes6b2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes6b2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes6b2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes6b2_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append("\n-- ── 1 · 新函数(镜像原样),先于新表的两支:取号 · 证书的变更守卫(新表的触发器要它)───\n")
for f in NEW_FUNCS_EARLY:
    parts.append(fn(f))

parts.append("\n-- ── 2 · 新表(镜像原样):分析证书 · 它的字节档案(外键次序)─────────────────────────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append(f"""
-- ── 3 · 仓库申请多一种 coa_void(与 db/tables/warehouse_requests.sql 逐字同一份的列、约束、索引、列权限与表注释)──────────────
--   列加在末尾(镜像照"后加的列在最后"排);三条约束先删后建(CHECK 不能就地改);列清单 SELECT 授权【不会】自己延伸到新列 ——
--   所以同一支迁移里给它加上,遮蔽伴生视图也在下面换(AGENTS.md「给遮蔽表加列」:三件事一支迁移)。
ALTER TABLE public.warehouse_requests ADD COLUMN
{WR_COL.rstrip().rstrip(',')};
ALTER TABLE public.warehouse_requests DROP CONSTRAINT warehouse_requests_kind_check;
ALTER TABLE public.warehouse_requests ADD CONSTRAINT warehouse_requests_kind_check
{WR_KIND.strip().rstrip(',')};
ALTER TABLE public.warehouse_requests DROP CONSTRAINT warehouse_requests_kind_shape;
ALTER TABLE public.warehouse_requests ADD
{WR_SHAPE.rstrip(',')};
ALTER TABLE public.warehouse_requests DROP CONSTRAINT warehouse_requests_one_subject;
ALTER TABLE public.warehouse_requests ADD
{WR_ONE.rstrip(',')};
{WR_IDX_OPEN}{WR_IDX_REL}GRANT SELECT (coa_id) ON public.warehouse_requests TO authenticated;
{WR_COMMENT}""")

parts.append("\n-- ── 4 · 新函数(镜像原样),新表与新列之后:说话的化验 · 称重校准 · 拒绝清单 · 组装 · 预览 · 签发 · 记字节 · 作废 · 作废的申请 ─────\n")
for f in NEW_FUNCS_LATE:
    parts.append(fn(f))

parts.append("\n-- ── 5 · 换掉的函数(镜像原样,同签名):仓库申请认 coa_void · 审计主语 coa 与它在两个批次主语下的成员 ──────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 6 · 视图:N38 的基视图与读面 · 证书的读面(新)· 仓库申请的遮蔽伴生多 coa_id · 提醒多一支(镜像原样,列只在末尾加)──────────\n")
for v in NEW_VIEWS:
    parts.append(view(v))
for v in REPLACED_VIEWS:
    parts.append(view(v, replace=True))

parts.append(f"""
-- ── 7 · 权限目录一行 + 它声明的查看码(与 db/tables/permissions.sql 逐字同一份)· 单据登记 COA(与 db/tables/document_types.sql 那一行同一份)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
{PERM_ROW}
UPDATE public.permissions SET requires_view_any = ARRAY['module.output.view','module.quality.view'] WHERE code = 'action.issue_coa';
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
{DOC_ROW}
""")

parts.append("\n-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──\n")
parts.append("".join(bind_sql))

parts.append(f"""
-- ── 9 · 授权(MES-0 Q90 · MES-6b Step 0 Q30):action.issue_coa → {' · '.join(COA_ISSUERS)} —— 本刀唯一的授权改动 ──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'action.issue_coa' FROM roles r WHERE r.code IN ({", ".join(f"'{c}'" for c in COA_ISSUERS)})
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

acl = ["""
-- ── 10 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in PUBLIC_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO service_role;\n")
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

parts.append("""
-- ── 11 · 私有桶 coa-documents 与它的三条策略(桶不在镜像里 —— AGENTS.md;它的证明是 db/scripts/2026-10-15-mes6b2-live-proof.mjs 的 BUCKET 一段)──
--   只收 PDF、≤ 10 MB。读:module.output.view(看证书跟着那一批的查看码,Q30)。传:action.issue_coa(签发的那一个码)。
--   删:action.issue_coa【并且】那个对象还没被记进 coa_issues —— 签发时记哈希失败留下的孤儿可以由签发的人清掉;记下了的字节谁都删不掉
--   (作废不动字节,Q32)。改:一条策略都不给(覆盖一份已存的字节,就是改一张已签发的证书)。
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('coa-documents', 'coa-documents', false, 10485760, ARRAY['application/pdf'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "coa-documents read by output view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'coa-documents'::text AND public.has_permission('module.output.view'::text));

CREATE POLICY "coa-documents upload by issue_coa"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'coa-documents'::text AND public.has_permission('action.issue_coa'::text));

CREATE POLICY "coa-documents remove unrecorded by issue_coa"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'coa-documents'::text AND public.has_permission('action.issue_coa'::text)
           AND NOT EXISTS (SELECT 1 FROM public.coa_issues i WHERE i.file_path = objects.name));
""")

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes6b2_pending_decider_check")
parts.append("\n-- ── 12 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

expected_grants = sorted(f"{r}:action.issue_coa" for r in COA_ISSUERS)
public_checks = "\n".join(
    f"""    IF NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|{sig} must be callable by staff and not by anon';
    END IF;""" for sig in PUBLIC_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(f"{digest(t, m)} IS DISTINCT FROM (SELECT {t} FROM mes6b2_rows_before)" for t, m in DIGEST_TABLES.items())
TRIGGERS = [("certificates_of_analysis", "trg_certificates_of_analysis_mutation"),
            ("certificates_of_analysis", "trg_certificates_of_analysis_truncate"),
            ("coa_issues", "trg_coa_issues_append_only")]
for t, g in TRIGGERS:
    assert g in mirror(f"db/tables/{t}.sql"), (t, g)
trigger_checks = "\n       OR ".join(
    f"NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '{g}' AND tgrelid = 'public.{t}'::regclass)" for t, g in TRIGGERS)

parts.append(f"""
CREATE TEMP TABLE mes6b2_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权:恰好多了 action.issue_coa 的两行,别的一行没动;admin 持目录里每一个码(79);每一个角色仍满足"动作码蕴含查看码"
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes6b2_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes6b2_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM '{", ".join(expected_grants)}' THEN
        RAISE EXCEPTION 'MES6B2_PROOF|grant change is not exactly the two issue_coa grants: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|admin does not hold every one of the 79 codes';
    END IF;
    IF (SELECT requires_view_any FROM permissions WHERE code = 'action.issue_coa') IS DISTINCT FROM ARRAY['module.output.view','module.quality.view'] THEN
        RAISE EXCEPTION 'MES6B2_PROOF|action.issue_coa must declare module.output.view and module.quality.view';
    END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6B2_PROOF|action-implies-view violated: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES6B2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes6b2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes6b2_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(仓库申请比对时减掉新列)
    IF EXISTS ((SELECT b.k, b.id FROM mes6b2_pending_before b EXCEPT SELECT a.k, a.id FROM mes6b2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes6b2_pending_after a EXCEPT SELECT b.k, b.id FROM mes6b2_pending_before b)) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES6B2_PROOF|a pre-existing request, batch, assay, dispute, report, certificate, run, order, reservation, contract, movement, weighing, calibration, company, employee, position, customer, approval, journal, payment, expense or request changed';
    END IF;
    IF EXISTS (SELECT 1 FROM warehouse_requests WHERE coa_id IS NOT NULL) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|coa_id must start empty on every existing request';
    END IF;

    -- ④ 两张新表零行;桶在、私有、空、三条策略
    IF EXISTS (SELECT 1 FROM certificates_of_analysis) OR EXISTS (SELECT 1 FROM coa_issues) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|a new table has rows';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'coa-documents' AND NOT public)
       OR EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'coa-documents')
       OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE 'coa-documents %') <> 3 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|bucket coa-documents must exist, be private, be empty and carry exactly three policies';
    END IF;

    -- ⑤ 变更记录只多了本刀种的那几行:permissions 1 插 1 改 · role_permissions 2 插 · document_types 1 插
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes6b2_log_before), 0)
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'document_types'))
                OR (c.op = 'UPDATE' AND c.table_name = 'permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6B2_PROOF|unexpected change_log rows: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes6b2_log_before), 0);
    IF v_n <> 5 THEN RAISE EXCEPTION 'MES6B2_PROOF|change_log moved by % (expected 1 + 1 + 2 + 1 = 5)', v_n; END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6B2_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:守卫都在;单据登记 59 行带 COA、豁免 45 行;提醒 66 支、待定值 23 行;297 张表;审计主语 coa 在册;仓库申请认 coa_void
    IF {trigger_checks} THEN
        RAISE EXCEPTION 'MES6B2_PROOF|a guard trigger is missing';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 59 OR document_type_prefix('coa') <> 'COA'
       OR (SELECT count(*) FROM document_type_exceptions) <> 45 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|document_types should be 59 with COA and exceptions stay 45';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|operations_now should have 66 arms and pending_values 23';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 297 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|expected 297 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'coa') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|trail subject coa is not registered';
    END IF;
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'warehouse_requests_kind_check')) NOT LIKE '%coa_void%'
       OR NOT has_column_privilege('authenticated', 'public.warehouse_requests', 'coa_id', 'SELECT') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|warehouse_requests must accept coa_void and grant coa_id';
    END IF;

    -- ⑦ 函数面:五支员工调得到;六支内层与触发器调不到;anon 能执行的【恰好】两支;新表与新视图 anon 读不到
{public_checks}
{internal_checks}
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES6B2_PROOF|anon executes: %', v_bad;
    END IF;
    IF has_table_privilege('anon', 'public.certificates_of_analysis'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.coa_issues'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.coa_rows'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.output_batch_chemistry_certainty'::regclass, 'SELECT')
       OR has_table_privilege('authenticated', 'public.output_batch_chemistry_certainty_all'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|anon reads a new relation, or staff read the ungated base view';
    END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条;两张新表上没有写策略(只经函数)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('certificates_of_analysis', 'coa_issues')
                 AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|a write policy exists on certificates_of_analysis or coa_issues';
    END IF;

    -- ⑨ 变更记录:覆盖零缺口(两张新表记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes6b2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES6B2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes6b2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes6b2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
