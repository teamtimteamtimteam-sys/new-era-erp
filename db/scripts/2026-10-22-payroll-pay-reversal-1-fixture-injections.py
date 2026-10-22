#!/usr/bin/env python3
"""PAYROLL-PAY-REVERSAL-1 — fault-injection matrix for fixtures 288 (payroll payment reversal), 289 (the bank-match check on the payment,
bank-transfer and WHT reversal paths) and 290 (leave by service, /me in one call) — against a LOCAL rebuild (never live). The shape of
db/scripts/2026-10-21-claim-receipts-1-fixture-injections.py: its own throwaway cluster (db/verify_rebuild.py --skip-diff, then the storage stub +
mirror the gate installs); each cell runs inside the fixture's own transaction (the injection is the first statement after an outer BEGIN; the
fixture's ROLLBACK undoes both). A function is injected by re-creating it from its MIRROR with one targeted edit — the edit must change the text,
or the script stops. Every cell names the line it must go red on BEFORE it runs; the baselines must pass.
Usage: python3 db/scripts/2026-10-22-payroll-pay-reversal-1-fixture-injections.py > <log> 2>&1 ; verdict: the log's INJ_OWN_EXIT= line (written by the caller).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = {n: next((ROOT / "db/fixtures").glob(f"{n}-*.sql")).read_text() for n in ("288", "289", "290")}


def edit(name: str, old: str, new: str) -> str:
    src = (ROOT / f"db/functions/{name}.sql").read_text()
    if src.count(old) != 1:
        raise SystemExit(f"INJECTION NOT APPLIED: {name}: the text to replace occurs {src.count(old)} time(s): {old[:80]!r}")
    return src.replace(old, new)


BM = "    PERFORM assert_entry_not_bank_matched("
CELLS = [
    ("288", "ROUTE: payroll payments fall back to 'request' (Q8 undone)",
     edit("journal_entry_reversal_route", "            RETURN 'payroll_payment';", "            RETURN 'request';"),
     "FIXTURE 288C1 失败"),
    ("288", "GENERIC: reverse_journal_entry no longer refuses the new route",
     edit("reverse_journal_entry", "        RAISE EXCEPTION 'JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL|%', v_code;", "        NULL;"),
     "FIXTURE 288C2 失败"),
    ("288", "GENERIC: the journal reversal request no longer refuses the new route",
     # 两层:提交那一句,与提交时试跑的过账那一句(journal_request_post_internal)—— 只拿掉一层,另一层照样按同一个码拒(第一版就是这么没咬)
     edit("journal_request_submit_internal", "            RAISE EXCEPTION 'JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL|%', v_je.code;", "            NULL;")
     + "\n" + edit("journal_request_post_internal", "            RAISE EXCEPTION 'JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL|%', v_code;", "            NULL;"),
     "FIXTURE 288C3 失败"),
    ("288", "SUBMIT: the reason is no longer required",
     edit("submit_payroll_payment_reversal_request", "    IF p_notes IS NULL OR btrim(p_notes) = '' THEN\n        RAISE EXCEPTION 'PAYROLL_REVERSAL_REASON_REQUIRED|%', v_p.code;\n    END IF;\n", ""),
     "FIXTURE 288D1 失败"),
    ("288", "SUBMIT: a posting entry is accepted as a payment",
     # 两层:提交那一句,与试跑的引擎那一句 —— 第一版只拿掉提交那一句,引擎照样按同一个码拒
     edit("submit_payroll_payment_reversal_request", "    IF v_je.source_type IS DISTINCT FROM 'payroll' OR payroll_payment_entry_kind(v_je.id) IS NULL THEN",
          "    IF v_je.source_type IS DISTINCT FROM 'payroll' THEN")
     + "\n" + edit("reverse_payroll_payment_internal", "    IF v_je.source_type IS DISTINCT FROM 'payroll' OR v_kind IS NULL THEN",
          "    IF v_je.source_type IS DISTINCT FROM 'payroll' THEN"),
     "FIXTURE 288D2 失败"),
    ("288", "BANK: the payroll engine ignores bank matches (Q6)",
     edit("reverse_payroll_payment_internal", BM + "v_je.id);\n", ""),
     "FIXTURE 288F1 失败"),
    ("288", "BANK: the refusal never says reconciled",
     edit("assert_entry_not_bank_matched", "v_code, v_stmt, v_status;", "v_code, v_stmt, 'open';"),
     "FIXTURE 288F2 失败"),
    ("288", "DOOR: execution takes no date and uses today (Q3 undone)",
     edit("reverse_payroll_payment", "    IF p_reversal_date IS NULL THEN\n        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';\n    END IF;\n    SELECT * INTO v_r",
          "    p_reversal_date := COALESCE(p_reversal_date, CURRENT_DATE);\n    SELECT * INTO v_r"),
     "FIXTURE 288H2 失败"),
    ("288", "ENGINE: a reversal dated tomorrow is accepted (Q4)",
     edit("reverse_payroll_payment_internal", "    IF p_reversal_date > CURRENT_DATE THEN", "    IF p_reversal_date > CURRENT_DATE + 30 THEN"),
     "FIXTURE 288H3 失败"),
    ("288", "ENGINE: only the first line's stamp is cleared (Q5: net-zero line stays stamped)",
     edit("reverse_payroll_payment_internal", "         WHERE paid_journal_entry_id = v_je.id;",
          "         WHERE paid_journal_entry_id = v_je.id AND net_pay > 0;"),
     "FIXTURE 288I2 失败"),
    ("288", "ENGINE: the stamps are not cleared at all",
     edit("reverse_payroll_payment_internal", "        UPDATE payroll_lines\n           SET paid_at = NULL, paid_journal_entry_id = NULL", "        UPDATE payroll_lines\n           SET paid_at = paid_at"),
     "FIXTURE 288I2 失败"),
    ("288", "ENGINE: CPF's date stays stamped (Q5 / Q7)",
     edit("reverse_payroll_payment_internal", "           SET cpf_paid_at = NULL, cpf_journal_entry_id = NULL", "           SET cpf_journal_entry_id = NULL"),
     "FIXTURE 288K"),
    ("288", "DRY RUN: payment_reversal is not dry-run at submit / approve",
     edit("payroll_request_dry_run", "            v_res := reverse_payroll_payment_internal(v_r.target_entry_id, reversal_date_for(v_r.target_entry_id), v_r.notes);",
          "            NULL;"),
     "FIXTURE 288F1 失败"),
    ("289", "BANK: the payment reversal ignores bank matches",
     edit("reverse_payment_internal", BM + "v_orig.journal_entry_id);\n", ""),
     "FIXTURE 289-payment"),
    ("289", "BANK: the bank-transfer reversal ignores bank matches",
     edit("reverse_bank_transfer_internal", BM + "v_t.journal_entry_id);\n", ""),
     "FIXTURE 289-transfer"),
    ("289", "BANK: the WHT remittance reversal ignores bank matches",
     edit("reverse_wht_remittance_internal", BM + "v_w.journal_entry_id);\n", ""),
     "FIXTURE 289-wht"),
    ("290", "SERVICE: no qualifying period (the full year from day one, the LEAVE-BAL-1 shape)",
     edit("leave_service_entitlement", "    IF v_months < v_t.qualifying_service_months THEN", "    IF false THEN"),
     "FIXTURE 290B 失败"),
    ("290", "SERVICE: a part-month counts as a month",
     edit("leave_service_entitlement", "EXTRACT(MONTH FROM age(p_as_of, p_hire_date)))::integer", "EXTRACT(MONTH FROM age(p_as_of + 30, p_hire_date)))::integer"),
     "FIXTURE 290"),
    ("290", "SERVICE: proration rounds down instead of half-up",
     edit("leave_service_entitlement", "v_t.default_days_per_year * v_months / 12.0 + 0.5", "v_t.default_days_per_year * v_months / 12.0"),
     "FIXTURE 290B 失败"),
    ("290", "SERVICE: the childcare minimum is ignored",
     edit("leave_service_entitlement", "COALESCE(v_t.prorate_minimum_days, 0)", "0"),
     "FIXTURE 290B2 失败"),
    ("290", "BALANCE: leave_balance_internal goes back to the whole year",
     edit("leave_balance_internal", "        v_yearly := (v_svc ->> 'days')::numeric;", "        v_yearly := v_type.default_days_per_year;"),
     "FIXTURE 290D1 失败"),
    ("290", "ME: leave_balances drops annual leave",
     edit("leave_balances", "WHERE lt.is_active AND (lt.is_accrued OR lt.default_days_per_year IS NOT NULL)",
          "WHERE lt.is_active AND lt.default_days_per_year IS NOT NULL"),
     "FIXTURE 290E1 失败"),
    ("290", "ME: leave_balances lets anyone read",
     # 两层:leave_balances 的门,与它逐种调用的 leave_balance_internal 的同一道门
     edit("leave_balances", "    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN",
          "    IF false THEN")
     + "\n" + edit("leave_balance_internal", "    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN",
          "    IF false THEN")
     # ★ 第三层(第二版仍没咬时量出来的):年假那一项还经过三支累积读者,它们各有同一道门(EMPSELF1 那十支里的三支)
     + "".join("\n" + edit(f, "    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN",
                           "    IF false THEN") for f in ("accrued_annual_leave", "consumed_from_accrual", "accrued_annual_leave_detail")),
     "FIXTURE 290E3 失败"),
    ("290", "SEED: hospitalisation loses its steps",
     "UPDATE leave_types SET service_rule = 'full', service_steps = NULL WHERE code = 'hospitalisation';",
     "FIXTURE 290A 失败"),
]


def run(dsn: str, sql: str) -> str:
    p = subprocess.run(["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True, text=True)
    return (p.stdout or "") + (p.stderr or "")


def first_fixture_line(out: str, n: str) -> str:
    m = re.search(rf"(FIXTURE {n}[^\n]*)", out)
    return m.group(1)[:240] if m else ""


def main() -> int:
    work = tempfile.mkdtemp(prefix="injppr1", dir="/tmp")
    data, sock = os.path.join(work, "pg"), os.path.join(work, "s")
    os.makedirs(sock)
    port = "55443"
    passed = failed = 0
    try:
        subprocess.run(["initdb", "-D", data, "-U", "postgres", "--no-locale", "--encoding=UTF8"], capture_output=True, check=True)
        subprocess.run(["pg_ctl", "-D", data, "-o", f"-p {port} -k {sock} -c listen_addresses=''", "-l", os.path.join(work, "pg.log"), "start"],
                       capture_output=True, check=True)
        subprocess.run(["createdb", "-h", sock, "-p", port, "-U", "postgres", "inj"], capture_output=True, check=True)
        dsn = f"host={sock} port={port} user=postgres dbname=inj"
        vr = subprocess.run([sys.executable, str(ROOT / "db/verify_rebuild.py"), "--target", dsn, "--skip-diff"], capture_output=True, text=True)
        if vr.returncode != 0:
            print(vr.stdout[-2000:], vr.stderr[-2000:])
            print(f"✗ the rebuild did not build (exit {vr.returncode})")
            return 2
        si = subprocess.run(["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(ROOT / "db/storage/platform-storage-stub.sql"),
                             "-f", str(ROOT / "db/storage/buckets-and-policies.sql")], capture_output=True, text=True)
        if si.returncode != 0:
            print("✗ storage stub did not install:", si.stderr[-500:])
            return 2
        print("== a fresh local rebuild (db/verify_rebuild.py --skip-diff) + storage stub")
        for n, name, inj, expect in CELLS:
            out = run(dsn, "BEGIN;\n" + inj + "\n" + FIX[n])
            line = first_fixture_line(out, n)
            if expect.startswith("ERROR:"):
                line = next((l for l in out.splitlines() if expect in l), line)
            if expect in line and "全部通过" not in line:
                print(f"✓ {name} → {line}")
                passed += 1
            else:
                err = next((l for l in out.splitlines() if "ERROR" in l), "")
                print(f"✗ {name} → {line or err or '<no fixture line>'} (expected: {expect})")
                failed += 1
        for n in ("288", "289", "290"):
            out = run(dsn, FIX[n])
            ok = "全部通过" in out
            print(("✓" if ok else "✗") + f" baseline {n} (no injection) → {first_fixture_line(out, n) or ('clean' if ok else out[-300:])}")
            passed, failed = passed + ok, failed + (not ok)
        print(f"INJECTIONS pass={passed} fail={failed}")
        return 0 if failed == 0 else 1
    finally:
        subprocess.run(["pg_ctl", "-D", data, "stop", "-m", "immediate"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
