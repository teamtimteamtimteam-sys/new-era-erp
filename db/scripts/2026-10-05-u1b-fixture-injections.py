#!/usr/bin/env python3
"""U1-B:fixture 248 的故障注入 —— 每一格注入一处缺陷,fixture 247 必须在【它点名的那一臂】红。

做法照 U1-A 的 db/scripts/2026-10-05-u1a-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;
注入随 ROLLBACK 消失。函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】
(INJECTION_DID_NOT_APPLY)—— 一格悄悄没换上的注入,会被读成"这一臂没咬人"。

跑法:python3 db/scripts/2026-10-05-u1b-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 干净跑绿、每一格都红在它的那一臂;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import subprocess
import sys

DSN = sys.argv[1]
ROOT = pathlib.Path(".")
F248 = next(ROOT.glob("db/fixtures/248-*.sql")).read_text()
assert F248.count("\nBEGIN;\n") == 1 and F248.rstrip().endswith("ROLLBACK;"), "fixture shape changed"
BODY = F248.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]


def patch_fn(sig, old, new):
    o, n = old.replace("'", "''"), new.replace("'", "''")
    return f"""DO $inj$ DECLARE d text; d2 text; BEGIN
    d := pg_get_functiondef('{sig}'::regprocedure);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{sig}'; END IF;
    EXECUTE d2;
END $inj$;
"""


def patch_view(name, old, new):
    o, n = old.replace("'", "''"), new.replace("'", "''")
    return f"""DO $inj$ DECLARE d text; d2 text; BEGIN
    d := pg_get_viewdef('public.{name}'::regclass);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{name}'; END IF;
    EXECUTE format('CREATE OR REPLACE VIEW public.%I AS %s', '{name}', d2);
END $inj$;
"""


CASES = [
    # (臂, 名字, 注入 SQL)
    ("DT", "the statement-level delete guard dropped (a downtime period can be deleted again)",
     "DROP TRIGGER trg_equipment_downtime_no_delete ON public.equipment_downtime;"),
    ("DT", "direct writes may void a downtime period",
     patch_fn("public.guard_downtime_write()", "IF row_security_active(TG_RELID)", "IF false AND row_security_active(TG_RELID)")),
    ("DT", "a voided open period still counts as the open one",
     "DROP INDEX public.uq_equipment_downtime_open; CREATE UNIQUE INDEX uq_equipment_downtime_open ON public.equipment_downtime (equipment_id) WHERE ended_at IS NULL;"),
    ("DT", "a handover may reference a voided downtime period",
     patch_fn("public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[])", "WHERE e.voided_at IS NOT NULL", "WHERE false")),
    ("PO", "closing stops recording the reason in its own column",
     patch_fn("public.close_purchase_order(uuid, text)", "close_reason = NULLIF(btrim(COALESCE(p_notes, '')), ''),", "")),
    ("PO", "reopening goes back to rewriting the notes",
     patch_fn("public.reopen_purchase_order(uuid, text)", "reopen_reason = btrim(p_reason),", "reopen_reason = btrim(p_reason), notes = COALESCE(notes, '') || ' [reopened]',")),
    ("DD", "a cancelled order takes a deep-discharge judgement",
     patch_fn("public.set_po_line_deep_discharge(uuid, text)", "IF v_l.status = 'cancelled' THEN", "IF false THEN")),
    ("DD", "the judgement may go back to empty",
     patch_fn("public.set_po_line_deep_discharge(uuid, text)", "IF p_code IS NULL OR btrim(p_code) = '' THEN", "IF false THEN")),
    ("CL", "submit_expense_claim stops asking for another decider",
     patch_fn("public.submit_expense_claim(uuid, date, numeric, text, text, text)", "IF v_base IS NOT NULL THEN", "IF false THEN")),
    ("CL", "the subject leg is not passed (the claim's subject is ignored)",
     patch_fn("public.submit_expense_claim(uuid, date, numeric, text, text, text)", "approval_level_for(v_base), p_employee_id,", "approval_level_for(v_base), NULL,")),
    # 注入落在一支不再往下调另一支请假函数的叶子上:leave_balance 自己往下调 leave_balance_internal(那一支照样拒),
    #   在它上面注入不咬人(实测)—— 那说的是"这一格问错了地方",不是"这条断言瞎了"。
    ("LV", "consumed_from_accrual back to the NULL trap",
     patch_fn("public.consumed_from_accrual(uuid, integer)", "COALESCE(p_employee_id = current_user_employee(), false)", "(p_employee_id = current_user_employee())")),
    ("JR", "journal_requests.amount_base granted back on the base table",
     "GRANT SELECT (amount_base) ON public.journal_requests TO authenticated;"),
    ("JR", "journal_request_amount_visible answers visible",
     patch_fn("public.journal_request_amount_visible(uuid)", "SELECT has_permission('data.view_pay'::text)", "SELECT true OR has_permission('data.view_pay'::text)")),
    ("JR", "the approval row of a journal request carries its amount for everyone",
     patch_fn("public.approval_log_amount_visible(text, uuid)", "WHEN 'journal_request' THEN journal_request_amount_visible(p_subject_id)", "WHEN 'journal_request' THEN true")),
    ("MC", "medical_claims.decision_notes granted back on the base table",
     "GRANT SELECT (decision_notes) ON public.medical_claims TO authenticated;"),
    ("MC", "medical_claims_masked stops masking the decision notes",
     patch_view("medical_claims_masked",
                "WHEN (has_permission('data.view_health'::text) OR (employee_id = current_user_employee())) THEN decision_notes",
                "WHEN true THEN decision_notes")),
    ("MC", "the self-approval report shows the medical note again",
     patch_fn("public.self_approved_decisions()", "CASE WHEN approval_log_note_visible(a.subject_type, a.subject_id) THEN a.note END", "a.note")),
    ("ME", "the month-end reader counts allocated runs too",
     patch_fn("public.processing_runs_blocking_close(date)", "AND r.allocated_at IS NULL", "")),
    ("ME", "close_period stops asking the shared reader",
     patch_fn("public.close_period(date, text)", "FROM processing_runs_blocking_close(p_period_end) b", "FROM (SELECT 0 AS run_count, NULL::text AS run_codes) b")),
]


def run(injection):
    sql = "BEGIN;\n" + injection + "\n" + BODY + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
rc, out = run("")
if rc != 0 or "FIXTURE 248 全部通过" not in out:
    print("✗ the clean fixture is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 248 全部通过")
for arm, name, inj in CASES:
    rc, out = run(inj)
    err = [ln for ln in out.splitlines() if "ERROR" in ln]
    first = err[0] if err else "(no error)"
    if rc == 0:
        print(f"✗ {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif f"FIXTURE 248 {arm}" not in first:
        print(f"✗ {arm} · {name}: red in the wrong place — {first[:300]}")
        bad += 1
    else:
        print(f"✓ {arm} · {name}: {first[first.index('FIXTURE 248'):][:200]}")
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections, {bad} wrong)")
sys.exit(1 if bad else 0)
