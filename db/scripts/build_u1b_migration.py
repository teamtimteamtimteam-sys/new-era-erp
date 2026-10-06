#!/usr/bin/env python3
"""U1-B(UNBLOCK-1 的第二刀,v1.4.36):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影。
函数与视图原样从 db/functions、db/views 抽出;表上的改动(加列、约束、索引、触发器、列授权、种子行)在这里逐句写出,
并与 db/tables 里改过的那几处逐字同义(check_mirrors 在重建侧对照)。
跑法:python3 db/scripts/build_u1b_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-05-u1b-workflow-fixes.sql"

TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"       # tim@(cfo:持 data.view_pay / data.view_health)
PHUA = "e61d99f2-2b95-4059-86f8-5aef8b5cffb5"      # phua@(cto:finance.view + hr.view,不持 view_pay / view_health)
CHOOER = "476bf8c8-c248-4352-9a75-945bf52ca390"    # chooer@(finance:持 view_pay · view_health)

NEW_FUNCS_FIRST = ["journal_request_amount_visible", "approval_log_note_visible", "assert_other_decider_for_subject",
                   "processing_runs_blocking_close", "guard_downtime_write"]
FUNCS = ["approval_log_amount_visible", "change_log_rule_visible", "change_log_mask_rules", "assert_other_decider",
         "submit_expense_claim",
         "accrued_annual_leave_detail", "accrued_annual_leave", "annual_leave_available_from", "annual_leave_rate_per_year",
         "available_annual_accrual", "consumed_from_accrual", "compute_leave_encashment", "leave_balance_internal",
         "leave_balance",
         "guard_downtime_period", "void_equipment_downtime", "submit_shift_handover",
         "close_purchase_order", "reopen_purchase_order", "set_po_line_deep_discharge",
         "close_period", "self_approved_decisions", "journal_request_submit_internal", "decide_journal_request"]
NEW_VIEWS = ["journal_requests_masked"]
REPLACED_VIEWS = ["approval_log_masked", "medical_claims_masked", "purchase_orders_masked"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def view(name, replace):
    body = (ROOT / f"db/views/{name}.sql").read_text().rstrip("\n") + "\n"
    if replace:
        assert "CREATE VIEW public." in body or "CREATE OR REPLACE VIEW public." in body, name
        body = body.replace("CREATE VIEW public.", "CREATE OR REPLACE VIEW public.", 1)
    return "\n" + body


HEADER = """-- db/migrations/2026-10-05-u1b-workflow-fixes.sql
-- U1-B —— 工作流上的几扇门与剩下的几处泄漏(UNBLOCK-1 的第二刀,v1.4.36;发布那一行在 docs/handbacks/U1-B.md 的抬头)。
-- 由 db/scripts/build_u1b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-05:Step 0 的 Q14–Q25 全部照建议裁定;U1-A close-out 另加三件)
--   ① 停机(Q15):一段记错了的停机可以【更正】(起止与原因,表上的 UPDATE 策略,变更记录留着旧值)、可以【作废】(带理由,
--      void_equipment_downtime);【永远不硬删】(guard_downtime_write 对任何人都拒 DELETE)。作废的那一段不挡重叠、不算"开着的
--      那一段"、交接单不能再引用它。
--   ② 采购单关闭 / 重开的理由(Q25):进它们自己的五列(closed_by · close_reason · reopened_at · reopened_by · reopen_reason),
--      notes 不再被改写;历史各记一行 closed / reopened,理由在 amend_reason。线上两张单 notes 里的旧后缀原样留着。
--   ③ 深度放电判断(Q20):set_po_line_deep_discharge —— 持 module.purchasing.edit、单子没被取消就能写(那个控件从 APR-10 起
--      一次都没存进去过)。
--   ④ 报销单的另一位决定人(Step 0 §3 3.6):审批开着、提单人与主角之外没人批得动时,submit_expense_claim 按名拒
--      EXPENSE_CLAIM_NO_OTHER_DECIDER|单号(assert_other_decider_for_subject —— 带主角的那一版;assert_other_decider 改成调它)。
--   ⑤ 九支请假函数的 NULL 陷阱(U1A-SELF-GATE-NULL-TRAP):"持码或本人"的门对没有员工档案的账号关上(COALESCE)。
--   ⑥ 工资分录的冲销申请(U1A-PAYROLL-REVERSAL-REQUEST-SHOWS-AMOUNT):journal_requests.amount_base 从列授权里拿掉,只经
--      journal_requests_masked 读;审批留痕的金额、变更记录(jr_amount)与提交 / 决定两支函数的返回值都走同一支
--      journal_request_amount_visible(持 data.view_pay,或冲销的不是工资分录)。
--   ⑦ 医疗报销费用单(U1A-MEDICAL-EXPENSE-AMOUNT-ON-FINANCE-SIDE,Tim 的裁定:金额给财务;健康的字跟 data.view_health 走):
--      量下来费用单自己的列与分录里没有健康的字;从它那一页的审计记录出去的是报销单的【批准 / 驳回理由】—— decision_notes
--      与审批留痕上的 note。两样都收到 data.view_health(或本人);自批报表也问这两道判据;搜索不再按那段理由找。
--   ⑧ 月结(Step 0 §3 5.1):挡住关账的加工单抽成 processing_runs_blocking_close,close_period 与月结清单读同一支。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关、名册与授权;不写、不改任何一张单据。
--   唯一的数据写入:document_types 一行的搜索列(medical_claim 不再按 decision_notes 匹配)。
--
-- 【破窗】从这一支提交到部署之间,旧应用读新库:
--   · /finance/journal 选 journal_requests.amount_base → 42501(页面报错)直到部署(线上 0 张申请,但查询照样被拒)。
--   · /hr/claims/[id] 若直读 medical_claims.decision_notes → 42501;读 medical_claims_masked 的照常(那一列受限时是 NULL)。
--   · 旧的深度放电控件、旧的停机面板照旧(前者本来就存不进去;后者不认识作废,也不需要)。
--   · 旧的关单 / 重开按钮调的是同一支函数:理由从此进新列,旧页面只是看不见它(notes 里不再有后缀)。
--   · 窗口在部署那一刻闭合;部署是 Tim 在 Vercel 上看的。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行不多一行不少;在途单据一张不少、一张不多;change_log 只多
--   document_types 那一行;七个账号一个都没被停;遮蔽名单与目录对得上(零缺口,104 条);三列真的收回了;以真账号的身份把
--   新判据读一遍;每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

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
        RAISE EXCEPTION 'U1B_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 101 THEN
        RAISE EXCEPTION 'U1B_PRE|expected 101 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                  AND ((table_name = 'equipment_downtime' AND column_name = 'voided_at')
                    OR (table_name = 'purchase_orders' AND column_name = 'close_reason'))) THEN
        RAISE EXCEPTION 'U1B_PRE|the new columns already exist';
    END IF;
    IF to_regclass('public.journal_requests_masked') IS NOT NULL THEN
        RAISE EXCEPTION 'U1B_PRE|journal_requests_masked already exists';
    END IF;
    IF NOT has_column_privilege('authenticated', 'public.journal_requests', 'amount_base', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.approval_log', 'note', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.medical_claims', 'decision_notes', 'SELECT') THEN
        RAISE EXCEPTION 'U1B_PRE|one of the three columns is already revoked';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'purchase_order_history_change_type_check') THEN
        RAISE EXCEPTION 'U1B_PRE|purchase_order_history_change_type_check is not there to replace';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE u1b_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE u1b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE u1b_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE u1b_po_before ON COMMIT DROP AS
SELECT id, md5(to_jsonb(p)::text) AS digest FROM purchase_orders p;
CREATE TEMP TABLE u1b_dt_before ON COMMIT DROP AS
SELECT id, md5(to_jsonb(dt)::text) AS digest FROM equipment_downtime dt;
""")

parts.append("\n-- ── 1 · 新函数(镜像原样)── 视图、触发器与改过的函数要先有它们 ─────────────\n")
for name in NEW_FUNCS_FIRST:
    parts.append(fn(name))

parts.append("""
-- ── 2 · 表(与 db/tables 下改过的几处逐字同义)──────────────────────────────

-- equipment_downtime(Q15):作废三列 + 形状约束;开着的那一段不算作废的;写的闸
ALTER TABLE public.equipment_downtime
    ADD COLUMN voided_at   timestamptz,
    ADD COLUMN voided_by   uuid,
    ADD COLUMN void_reason text,
    ADD CONSTRAINT equipment_downtime_void_shape
        CHECK ((voided_at IS NULL AND voided_by IS NULL AND void_reason IS NULL)
            OR (voided_at IS NOT NULL AND void_reason IS NOT NULL AND btrim(void_reason) <> ''));
DROP INDEX public.uq_equipment_downtime_open;
CREATE UNIQUE INDEX uq_equipment_downtime_open
    ON public.equipment_downtime (equipment_id)
    WHERE ended_at IS NULL AND voided_at IS NULL;
CREATE TRIGGER trg_equipment_downtime_write
    BEFORE UPDATE ON public.equipment_downtime
    FOR EACH ROW EXECUTE FUNCTION public.guard_downtime_write();
CREATE TRIGGER trg_equipment_downtime_no_delete
    BEFORE DELETE ON public.equipment_downtime
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_downtime_write();

-- purchase_orders(Q25):关闭 / 重开的人与理由。遮蔽表 —— 加列 · 列授权 · _masked 视图在同一支迁移里(WO-1a 那一课)
ALTER TABLE public.purchase_orders
    ADD COLUMN closed_by     uuid,
    ADD COLUMN close_reason  text,
    ADD COLUMN reopened_at   timestamptz,
    ADD COLUMN reopened_by   uuid,
    ADD COLUMN reopen_reason text;
GRANT SELECT (closed_by, close_reason, reopened_at, reopened_by, reopen_reason) ON public.purchase_orders TO authenticated;

-- purchase_order_history(Q25):两种新的 change_type
ALTER TABLE public.purchase_order_history DROP CONSTRAINT purchase_order_history_change_type_check;
ALTER TABLE public.purchase_order_history ADD CONSTRAINT purchase_order_history_change_type_check
    CHECK (change_type IN ('header_update','line_update','line_add','line_remove','cancelled',
                           'payment_term_add','payment_term_update','payment_term_remove',
                           'closed','reopened'));

-- journal_requests(U1A-PAYROLL-REVERSAL-REQUEST-SHOWS-AMOUNT):amount_base 从列授权里拿掉
REVOKE SELECT ON public.journal_requests FROM authenticated;
GRANT SELECT (id, kind, status, label, entry_date, memo, lines, target_entry_id, credits_bank, decided_at, decided_by,
              decision_notes, result_journal_entry_id, withdrawn_at, withdrawn_by, withdraw_reason, created_at, created_by)
    ON public.journal_requests TO authenticated;

-- approval_log 与 medical_claims(Tim 对医疗报销费用单的裁定):说明 / 批准驳回理由从列授权里拿掉
REVOKE SELECT ON public.approval_log FROM authenticated, anon;
GRANT SELECT (id, seq, subject_type, subject_id, subject_code, decision, level,
              actor_user_id, decided_at, currency, fx_rate,
              is_reconstructed, reconstruction_note, created_at,
              self_decided)
    ON public.approval_log TO authenticated;
REVOKE SELECT ON public.medical_claims FROM authenticated, anon;
GRANT SELECT (id, code, employee_id, claim_date, claim_year, receipt_ref, status, decided_at, decided_by,
              expense_id, deleted_at, created_at, created_by, updated_at, updated_by, withdrawn_at)
    ON public.medical_claims TO authenticated;

-- document_types:搜索列不能是被遮的列(fixture 100/8 · 199F 的判据)—— 与 db/tables/document_types.sql 的种子行逐字相同
UPDATE public.document_types SET match_columns = ARRAY['receipt_ref']::text[] WHERE key = 'medical_claim';
""")

parts.append("\n-- ── 3 · 改过的函数(镜像原样)──────────────────────────────────────────────\n")
for name in FUNCS:
    parts.append(fn(name))

parts.append("\n-- ── 4 · 新的遮蔽伴生视图(镜像原样)────────────────────────────────────────\n")
for name in NEW_VIEWS:
    parts.append(view(name, False))
parts.append("\n-- ── 5 · 改过的视图(镜像原样,CREATE OR REPLACE)───────────────────────────\n")
for name in REPLACED_VIEWS:
    parts.append(view(name, True))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "u1b_pending_decider_check")
parts.append("\n-- ── 6 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")


def as_user(uid):
    return f"""PERFORM set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true);"""


parts.append(f"""
CREATE TEMP TABLE u1b_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_m     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权一行不多一行不少
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM u1b_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM u1b_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'U1B_PROOF|grants moved: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'U1B_PROOF|approvals switched off'; END IF;
    IF (SELECT count(*) FROM auth.users WHERE banned_until IS NOT NULL AND banned_until > now()) <> 0 THEN
        RAISE EXCEPTION 'U1B_PROOF|an account is disabled';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 只多 document_types 那一行;采购单与停机一行没动(加的列都是 NULL)
    IF EXISTS ((SELECT b.k, b.id FROM u1b_pending_before b EXCEPT SELECT a.k, a.id FROM u1b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM u1b_pending_after a EXCEPT SELECT b.k, b.id FROM u1b_pending_before b)) THEN
        RAISE EXCEPTION 'U1B_PROOF|a pending document changed state';
    END IF;
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM u1b_log_before) AND c.table_name NOT IN ('document_types');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'U1B_PROOF|change_log moved on %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM purchase_orders p JOIN u1b_po_before b ON b.id = p.id
     WHERE md5((to_jsonb(p) - ARRAY['closed_by', 'close_reason', 'reopened_at', 'reopened_by', 'reopen_reason'])::text) <> b.digest
        OR p.closed_by IS NOT NULL OR p.close_reason IS NOT NULL OR p.reopened_at IS NOT NULL
        OR p.reopened_by IS NOT NULL OR p.reopen_reason IS NOT NULL;
    IF v_n <> 0 OR (SELECT count(*) FROM purchase_orders) <> (SELECT count(*) FROM u1b_po_before) THEN
        RAISE EXCEPTION 'U1B_PROOF|% purchase order(s) changed', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM equipment_downtime dt JOIN u1b_dt_before b ON b.id = dt.id
     WHERE md5((to_jsonb(dt) - ARRAY['voided_at', 'voided_by', 'void_reason'])::text) <> b.digest OR dt.voided_at IS NOT NULL;
    IF v_n <> 0 OR (SELECT count(*) FROM equipment_downtime) <> (SELECT count(*) FROM u1b_dt_before) THEN
        RAISE EXCEPTION 'U1B_PROOF|% downtime row(s) changed', v_n;
    END IF;

    -- ④ 形状:遮蔽名单与目录对得上(104 条、零缺口);三列真的收回了
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN RAISE EXCEPTION 'U1B_PROOF|mask gaps: %', v_j -> 'gaps'; END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 104 THEN
        RAISE EXCEPTION 'U1B_PROOF|expected 104 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF has_column_privilege('authenticated', 'public.journal_requests', 'amount_base', 'SELECT')
       OR has_column_privilege('authenticated', 'public.approval_log', 'note', 'SELECT')
       OR has_column_privilege('authenticated', 'public.medical_claims', 'decision_notes', 'SELECT') THEN
        RAISE EXCEPTION 'U1B_PROOF|one of the three columns is still granted';
    END IF;
    IF NOT has_column_privilege('authenticated', 'public.purchase_orders', 'close_reason', 'SELECT') THEN
        RAISE EXCEPTION 'U1B_PROOF|purchase_orders.close_reason is not readable';
    END IF;

    -- ⑤ 以真账号的身份读:cto(phua@)读别人的医疗理由是 NULL;finance(chooer@)读得到;两人都读得到申请视图(线上 0 行)
    {as_user(PHUA)}
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM medical_claims_masked WHERE decision_notes IS NOT NULL AND employee_id <> current_user_employee();
    SELECT count(*) INTO v_m FROM approval_log_masked WHERE subject_type = 'medical_claim' AND note IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM medical_claims mc WHERE mc.id = subject_id AND mc.employee_id = current_user_employee());
    PERFORM count(*) FROM journal_requests_masked;
    EXECUTE 'RESET ROLE';
    IF v_n + v_m <> 0 THEN RAISE EXCEPTION 'U1B_PROOF|cto still reads medical decision text: claims % · approval rows %', v_n, v_m; END IF;
    {as_user(CHOOER)}
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM medical_claims_masked WHERE decision_notes IS NOT NULL;
    PERFORM count(*) FROM journal_requests_masked;
    EXECUTE 'RESET ROLE';
    IF v_n <> (SELECT count(*) FROM medical_claims WHERE decision_notes IS NOT NULL) THEN
        RAISE EXCEPTION 'U1B_PROOF|finance reads % of % medical decision notes', v_n,
            (SELECT count(*) FROM medical_claims WHERE decision_notes IS NOT NULL);
    END IF;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.u1b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'U1B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.u1b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'U1B_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.u1b_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
