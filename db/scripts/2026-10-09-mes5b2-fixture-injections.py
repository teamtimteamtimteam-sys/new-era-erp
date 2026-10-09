#!/usr/bin/env python3
"""MES-5b-2:fixture 258 的故障注入 —— 每一格注入一处缺陷,fixture 258 必须在【它点名的那一臂】红。
外加 fixture 256 的 ALLOC-PAID(已付的电费单贷了应付而不是银行 —— Step 0 Q29 点名的那一格)与 fixture 213 的冲抵冲销那一臂(F2)。

做法照 db/scripts/2026-10-08-mes5a2-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture 258 · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 258 <臂>",
或者它发生时最后打出的那一臂就是 <臂>。一格可以点名两臂(A|B)。
跑法:python3 db/scripts/2026-10-09-mes5b2-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 三支 fixture 干净跑绿、每一格都红在它的那一臂、258 的每一臂都至少红过一次;1 = 否则。
"""
import pathlib
import re
import subprocess
import sys

DSN = sys.argv[1]
if "supabase" in DSN or "pooler" in DSN:
    sys.exit("refusing a live DSN — run against a throwaway rebuild")
ROOT = pathlib.Path(".")


def body_of(num):
    src = next(ROOT.glob(f"db/fixtures/{num}-*.sql")).read_text()
    assert src.count("\nBEGIN;\n") == 1 and src.rstrip().endswith("ROLLBACK;"), f"fixture {num} shape changed"
    return src.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]


EAC = "public.electricity_allocation_compute(date, date, numeric, numeric, text, text, text)"
POST = "public.post_electricity_allocation(date, date, date, text, numeric, numeric, text, text, text, uuid, text, text)"
REA = "public.reverse_electricity_allocation(uuid, text)"
REI = "public.reverse_expense_internal(uuid, text)"
REVX = "public.reverse_expense(uuid, text)"
RPA = "public.relieve_processing_accruals(uuid[], numeric, date, text, text, uuid, text, text)"
RPC = "public.remit_processing_costs(uuid[], date, text)"
GUARD = "public.guard_cost_entry_settled()"
GLINE = "public.guard_electricity_line_one_live_allocation()"
TSM = "public.trail_subject_members()"
APA = "public.assert_posting_allowed(date, text)"


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


CASES_258 = [
    # ── PERM ──
    ("PERM", "posting no longer asks module.finance.view (Q28)",
     patch_fn(POST, "    PERFORM require_permission('module.finance.view');\n", "")),
    ("PERM", "reversing asks a view code instead of module.finance.edit",
     patch_fn(REA, "PERFORM require_permission('module.finance.edit');", "PERFORM require_permission('module.finance.view');")),
    ("PERM", "the reason is not required",
     patch_fn(REA, "IF v_reason IS NULL THEN", "IF false THEN")),
    ("PERM", "reverse_expense's refusal no longer names the allocation (the page route)",
     patch_fn(REVX, "v_orig.code, v_alloc", "v_orig.code, NULL")),
    # ── UNPAID ──
    ("UNPAID", "the actual lines are unsettled but not soft-deleted",
     patch_fn(REA, "UPDATE processing_cost_entries SET deleted_at = now(), updated_by = v_user", "UPDATE processing_cost_entries SET updated_by = v_user")),
    ("UNPAID", "the restored estimates stay soft-deleted",
     patch_fn(REA, "SET deleted_at = NULL, updated_by = v_user", "SET updated_by = v_user")),
    ("UNPAID", "no explicit re-accrual for a restored estimate",
     patch_fn(REA, "IF v_e.amount_base <> 0 THEN", "IF false THEN")),
    ("UNPAID", "the re-accrual is posted on the wrong side",
     patch_fn(REA, "fin_cost_lines(v_e.cost_type, v_e.amount_base, false)", "fin_cost_lines(v_e.cost_type, v_e.amount_base, true)")),
    ("UNPAID", "the reversal record carries a wrong line amount",
     patch_fn(REA, "v_line_n, v_line_amt, v_est_n, v_est_amt, v_user", "v_line_n, 0, v_est_n, v_est_amt, v_user")),
    ("UNPAID|AGREE", "the expense is marked reversed but its journal is not",
     patch_fn(REI, "v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, reversal_date_for(v_orig.journal_entry_id), 'Expense reversal ' || v_orig.code);",
              "v_je := jsonb_build_object('reversal_id', v_orig.journal_entry_id, 'code', 'X');")),
    ("UNPAID|REPOST", "a run's energy still reads a reversed allocation",
     patch_view("processing_run_energy", "WHERE ((ll.run_id = r.id) AND (NOT (EXISTS ( SELECT 1\n                   FROM electricity_allocation_reversals v\n                  WHERE (v.allocation_id = ll.allocation_id)))))",
                "WHERE (ll.run_id = r.id)")),
    ("UNPAID", "a reversed allocation can be reversed again",
     patch_fn(REA, "IF EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = p_allocation_id) THEN", "IF false THEN")),
    # ── REPOST ──
    ("REPOST", "'already allocated' counts a reversed allocation",
     patch_fn(EAC, """'allocated', EXISTS (SELECT 1 FROM electricity_allocation_lines l WHERE l.run_id = r.id
                                              AND NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v
                                                               WHERE v.allocation_id = l.allocation_id)))""",
              """'allocated', EXISTS (SELECT 1 FROM electricity_allocation_lines l WHERE l.run_id = r.id))""")),
    ("REPOST", "'period overlaps' counts a reversed allocation",
     patch_fn(EAC, "       AND NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = a.id)\n", "")),
    ("REPOST", "the one-live guard is gone (and run_id is no longer unique)",
     "DROP TRIGGER trg_electricity_allocation_lines_one_live ON public.electricity_allocation_lines;"),
    ("REPOST", "the guard behaves like the old unique constraint (ignores reversals)",
     patch_fn(GLINE, "\n                  AND NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = l.allocation_id)", "")),
    # ── PAID ──
    ("PAID", "a paid bill credits payables instead of the bank (Q29's fault)",
     patch_fn(EAC, "v_credit := p_bank_account;", "v_credit := '2000';")),
    ("PAID", "a foreign-currency bank is accepted for a paid bill",
     patch_fn(EAC, "IF p_bank_account IS NULL OR bank_native_currency(p_bank_account) IS DISTINCT FROM v_base THEN", "IF p_bank_account IS NULL THEN")),
    # ── F2 ──
    ("F2", "reversing a relief whose run was allocated since is not refused",
     patch_fn(REVX, "    IF FOUND THEN\n        RAISE EXCEPTION 'RELIEF_ESTIMATE_NOW_ALLOCATED", "    IF false THEN\n        RAISE EXCEPTION 'RELIEF_ESTIMATE_NOW_ALLOCATED")),
    ("F2", "the now-allocated refusal counts a reversed allocation",
     patch_fn(REVX, "\n       AND NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = a.id)", "")),
    ("F2", "reversing a relief does not clear its estimates' stamps",
     patch_fn(REVX, "SET relieved_at = NULL, relief_expense_id = NULL, updated_by = auth.uid()", "SET updated_by = auth.uid()")),
    ("F2", "reverse_expense clears the stamps without the finance context (guard refuses)",
     patch_fn(REVX, "    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);\n", "")),
    # ── VAR ──
    ("VAR", "the variance view counts reversed reliefs",
     patch_view("processing_cost_variance", " AND (ex.status = 'posted'::text)", "")),
    # ── CCY ──
    ("CCY", "the relief expense's currency is a literal again (MES5A2-RELIEVE-SGD-LITERAL)",
     patch_fn(RPA, "base_currency_code(), 1,", "'SGD', 1,")),
    # ── LOCK ──
    ("LOCK", "period locks are not enforced",
     patch_fn(APA, "IF v_locked IS NOT NULL AND p_entry_date < v_locked", "IF false AND p_entry_date < v_locked")),
    # ── KINDS ──
    ("KINDS", "an expense settled through a payment can be reversed (Q24)",
     patch_fn(REI, "IF v_settled > 0 THEN", "IF false THEN")),
    ("AGREE", "only a fully paid expense is refused — a part-paid one reverses and the AP list leaves the ledger",
     patch_fn(REI, "IF v_settled > 0 THEN", "IF v_settled >= v_orig.amount_ccy THEN")),
    ("KINDS", "an expense with a prepayment applied can be reversed",
     patch_fn(REI, "IF v_prepaid > 0 THEN", "IF false THEN")),
    ("KINDS", "a reversed payment still counts as settlement",
     patch_fn(REI, "JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'", "JOIN payments p ON p.id = pa.payment_id")),
    # ── GUARD ──
    ("GUARD", "the guard ignores changes to the settlement stamps (Q26)",
     patch_fn(GUARD, "IF NOT v_ctx AND (NEW.remitted_at IS DISTINCT FROM OLD.remitted_at", "IF false AND (NEW.remitted_at IS DISTINCT FROM OLD.remitted_at")),
    ("GUARD", "a born-settled line can be inserted",
     "DROP TRIGGER trg_processing_cost_entries_settlement_insert_guard ON public.processing_cost_entries;"),
    ("GUARD", "remit leaves the finance context set",
     patch_fn(RPC, "    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);\n", "")),
    ("GUARD", "remit stamps without the finance context (guard refuses the finance function)",
     patch_fn(RPC, "    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);\n", "")),
    ("REPOST", "relieve stamps without the finance context (guard refuses the finance function)",
     patch_fn(RPA, "    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);\n", "")),
    ("UNPAID", "post writes settled lines without the finance context",
     patch_fn(POST, "    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);\n", "")),
    ("UNPAID", "reverse_electricity_allocation clears stamps without the finance context",
     patch_fn(REA, "    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);\n", "")),
    # ── MASK ──
    ("MASK", "a reversal amount leaks through the masked view",
     patch_view("electricity_allocation_reversals_masked", "WHEN has_permission('data.view_prices'::text) THEN bill_amount", "WHEN true THEN bill_amount")),
    ("MASK", "a reversal amount is in the column grant",
     "GRANT SELECT (actual_line_amount) ON public.electricity_allocation_reversals TO authenticated;"),
    # ── LOG ──
    ("LOG", "the reversals table is not change-logged",
     "DROP TRIGGER zzz_change_log ON public.electricity_allocation_reversals;"),
    ("LOG", "the allocation's trail does not carry its reversal",
     patch_fn(TSM, "('electricity_allocation', 2, 'electricity_allocation_reversals'", "('electricity_allocation_x', 2, 'electricity_allocation_reversals'")),
    ("LOG", "the run's trail does not carry the reversal",
     patch_fn(TSM, "('processing_run',    19, 'electricity_allocation_reversals'", "('processing_run_x',  19, 'electricity_allocation_reversals'")),
    ("LOG", "a V37 change is not on the operation's trail (MES5B1-V37-NOT-ON-OPERATION-TRAIL)",
     patch_fn(TSM, "('operation_type',     5, 'operation_type_output_forms'", "('operation_type_x',   5, 'operation_type_output_forms'")),
]

# fixture 256 ALLOC-PAID 与 fixture 213 的冲抵冲销那一臂:各自的注入、各自要红的那一句
OTHER = [
    ("256", "FIXTURE 256 ALLOC-PAID", "a paid bill credits payables instead of the bank (Q29's own fault)",
     patch_fn(EAC, "v_credit := p_bank_account;", "v_credit := '2000';")),
    ("213", "FIXTURE 213-A20a", "reversing a relief leaves its estimates stamped (F2)",
     patch_fn(REVX, "SET relieved_at = NULL, relief_expense_id = NULL, updated_by = auth.uid()", "SET updated_by = auth.uid()")),
]


def run(body, injection):
    sql = "BEGIN;\n" + injection + "\n" + body + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def where_red(out, num):
    """(第一条 ERROR, 它之前最后一次进到的那一臂)。"""
    last_arm, first_err = None, None
    for ln in out.splitlines():
        m = re.search(rf"fixture {num} · ([A-Z0-9-]+)", ln)
        if m:
            last_arm = m.group(1)
        if "ERROR" in ln:
            first_err = ln
            break
    return first_err or "(no error)", last_arm


bad = 0
for num in ("258", "256", "213"):
    rc, out = run(body_of(num), "")
    if rc != 0 or f"FIXTURE {num} 全部通过" not in out:
        print(f"✗ the clean fixture {num} is not green:\n" + out[-1500:])
        sys.exit(1)
    print(f"✓ clean: FIXTURE {num} 全部通过")

B258 = body_of("258")
arms = set()
for arm, name, inj in CASES_258:
    rc, out = run(B258, inj)
    first, last_arm = where_red(out, 258)
    named = arm.split("|")
    if rc == 0:
        print(f"✗ {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif any(f"FIXTURE 258 {a}" in first for a in named) or last_arm in named:
        arms.update(a for a in named if f"FIXTURE 258 {a}" in first or a == last_arm)
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1

for num, needle, name, inj in OTHER:
    rc, out = run(body_of(num), inj)
    first, last_arm = where_red(out, num)
    if rc != 0 and "INJECTION_DID_NOT_APPLY" not in out and needle in first:
        print(f"✓ fixture {num} · {name}: [{last_arm}] {first[first.index('ERROR'):][:200]}")
    else:
        print(f"✗ fixture {num} · {name}: expected '{needle}', got [{last_arm}] {first[:300]}")
        bad += 1

missing = {"PERM", "UNPAID", "REPOST", "PAID", "F2", "VAR", "CCY", "LOCK", "KINDS", "GUARD", "MASK", "LOG", "AGREE"} - arms
if missing:
    print(f"✗ arms never made red: {sorted(missing)}")
    bad += 1
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES_258)} injections on 258 + {len(OTHER)} on 256 / 213, {bad} wrong)")
sys.exit(1 if bad else 0)
