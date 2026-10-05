#!/usr/bin/env python3
"""U1-A:fixture 247 的故障注入 —— 每一格注入一处缺陷,fixture 247 必须在【它点名的那一臂】红。

做法照 1d-3 的 db/scripts/2026-10-05-at1d3-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;
注入随 ROLLBACK 消失。函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】
(INJECTION_DID_NOT_APPLY)—— 一格悄悄没换上的注入,会被读成"这一臂没咬人"。

跑法:python3 db/scripts/2026-10-05-u1a-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 干净跑绿、每一格都红在它的那一臂;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import subprocess
import sys

DSN = sys.argv[1]
ROOT = pathlib.Path(".")
F247 = next(ROOT.glob("db/fixtures/247-*.sql")).read_text()
assert F247.count("\nBEGIN;\n") == 1 and F247.rstrip().endswith("ROLLBACK;"), "fixture shape changed"
BODY = F247.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]


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


PAYCASE = "(has_permission('data.view_pay'::text) OR (e.source_type IS DISTINCT FROM 'payroll'::text))"
CASES = [
    # (臂, 名字, 注入 SQL)
    ("JA", "the restrictive policy dropped (payroll lines back on the API)",
     'DROP POLICY "amounts: payroll journal lines need data.view_pay" ON public.journal_lines;'),
    ("JM", "the masked view stops masking the payroll amounts",
     patch_view("journal_lines_masked", "WHEN " + PAYCASE + " THEN l.debit", "WHEN true THEN l.debit")),
    ("JT", "trial_balance_totals back to invoker (cto's totals shrink)",
     "ALTER FUNCTION public.trial_balance_totals() SECURITY INVOKER;"),
    ("JT", "bank_book_balance_asof back to invoker (cto's bank book shrinks)",
     "ALTER FUNCTION public.bank_book_balance_asof(text, date) SECURITY INVOKER;"),
    ("JT", "journal_close_preview back to invoker",
     "ALTER FUNCTION public.journal_close_preview(date) SECURITY INVOKER;"),
    ("JR", "trail_row_visible applies the amounts: policy (lines hidden on the trail)",
     patch_fn("public.trail_row_visible(text, jsonb, jsonb)", "AND p.policyname NOT LIKE 'amounts:%'", "AND true")),
    ("JR", "the pay_journal mask rule answers visible",
     patch_fn("public.change_log_rule_visible(text, text, jsonb, jsonb, jsonb)",
              "RETURN has_permission(v_part[2])\n            OR COALESCE(change_log_field('journal_entries',",
              "RETURN true\n            OR COALESCE(change_log_field('journal_entries',")),
    ("PT", "gross_total granted back on the base table",
     "GRANT SELECT (gross_total) ON public.payroll_periods TO authenticated;"),
    ("PT", "the approval amount of a payroll request visible to everyone",
     patch_fn("public.approval_log_amount_visible(text, uuid)",
              "WHEN 'payroll_request' THEN has_permission('data.view_pay'::text)", "WHEN 'payroll_request' THEN true")),
    ("KP", "the kpi_entries self-read policy restored",
     'CREATE POLICY "kpi_entries select own" ON public.kpi_entries AS PERMISSIVE FOR SELECT TO authenticated USING (employee_id = current_user_employee());'),
    ("EN", "employees.notes granted back on the base table",
     "GRANT SELECT (notes) ON public.employees TO authenticated;"),
    ("EN", "employees_masked gives the employee their own notes",
     patch_view("employees_masked", "WHEN has_permission('module.hr.view'::text) THEN notes",
                "WHEN (has_permission('module.hr.view'::text) OR (id = current_user_employee())) THEN notes")),
    ("HL", "medical_claims_masked keyed on hr.view instead of view_health",
     patch_view("medical_claims_masked",
                "WHEN (has_permission('data.view_health'::text) OR (employee_id = current_user_employee())) THEN description",
                "WHEN (has_permission('module.hr.view'::text) OR (employee_id = current_user_employee())) THEN description")),
    ("HL", "leave reason granted back on the base table",
     "GRANT SELECT (reason) ON public.leave_requests TO authenticated;"),
    ("HL", "medical_claim_balance back to the NULL-trap gate (a reader with no employee passes)",
     patch_fn("public.medical_claim_balance(uuid, integer)",
              "COALESCE(p_employee_id = current_user_employee(), false)", "(p_employee_id = current_user_employee())")),
    ("CU", "my_period_labels stops carrying the payslip currency",
     patch_fn("public.my_period_labels()", "pp.period_month, pp.currency", "pp.period_month, NULL::text")),
    ("EQ", "the advice view unmasks the repair spend",
     patch_view("equipment_maintenance_advice", "WHEN has_permission('module.finance.view'::text) THEN e.amount_base",
                "WHEN true THEN e.amount_base")),
    ("AN", "anonymisation keeps the leave reason",
     patch_fn("public.anonymise_employee(uuid, text)", "    SET reason           = NULL,", "    SET reason           = reason,")),
    ("AN", "the change log redaction skips medical descriptions",
     patch_fn("public.change_log_redactable_columns(text)",
              "WHEN 'medical_claims' THEN ARRAY['description', 'receipt_ref', 'decision_notes']",
              "WHEN 'medical_claims' THEN ARRAY['receipt_ref', 'decision_notes']")),
]


def run(injection):
    sql = "BEGIN;\n" + injection + "\n" + BODY + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
rc, out = run("")
if rc != 0 or "FIXTURE 247 全部通过" not in out:
    print("✗ the clean fixture is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 247 全部通过")
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
    elif f"FIXTURE 247 {arm}" not in first:
        print(f"✗ {arm} · {name}: red in the wrong place — {first[:300]}")
        bad += 1
    else:
        print(f"✓ {arm} · {name}: {first[first.index('FIXTURE 247'):][:200]}")
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections, {bad} wrong)")
sys.exit(1 if bad else 0)
