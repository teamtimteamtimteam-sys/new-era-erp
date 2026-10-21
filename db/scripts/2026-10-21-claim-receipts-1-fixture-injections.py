#!/usr/bin/env python3
"""CLAIM-RECEIPTS-1 — fault-injection matrix for fixture 287 (receipts per claim item) and the pins this cut moved in 274 and 140 — against a
LOCAL rebuild (never live). The shape of db/scripts/2026-10-20-mes9c-fixture-injections.py: its own throwaway cluster (db/verify_rebuild.py
--skip-diff, then the storage stub + mirror the gate installs); each cell runs inside the fixture's own transaction (the injection is the first
statement after an outer BEGIN; the fixture's ROLLBACK undoes both). A function is injected by re-creating it from its MIRROR with one targeted
edit — the edit must change the text, or the script stops. Every cell names the line it must go red on BEFORE it runs; the baselines must pass.
Usage: python3 db/scripts/2026-10-21-claim-receipts-1-fixture-injections.py > <log> 2>&1 ; verdict: the log's INJ_OWN_EXIT= line (written by the caller).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = {n: next((ROOT / "db/fixtures").glob(f"{n}-*.sql")).read_text() for n in ("140", "274", "286", "287")}


def edit(name: str, old: str, new: str) -> str:
    src = (ROOT / f"db/functions/{name}.sql").read_text()
    if src.count(old) != 1:
        raise SystemExit(f"INJECTION NOT APPLIED: {name}: the text to replace occurs {src.count(old)} time(s): {old[:80]!r}")
    return src.replace(old, new)


UP = '"claim receipts upload own registered path"'
RD = '"claim receipts read by finance.view or own claim"'
CELLS = [
    ("287", "BEGIN: anyone with an item id may register an upload (Q4 dropped)",
     edit("claim_receipt_begin", "    IF NOT COALESCE(v_c.employee_id = current_user_employee() OR v_c.created_by = auth.uid(), false) THEN\n"
                                 "        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_YOURS|%', v_c.code;\n    END IF;\n", ""),
     "FIXTURE 287A 失败:另一名员工"),
    ("287", "BEGIN: the 900 MB storage guard dropped (Q10)",
     edit("claim_receipt_begin", "    IF v_used + p_file_size > v_ceiling THEN\n        RAISE EXCEPTION 'CLAIM_RECEIPT_STORAGE_FULL|%|%', v_used, v_ceiling;\n    END IF;\n", ""),
     "FIXTURE 287A 失败:存储满"),
    ("287", "BEGIN: a withdrawn claim still takes receipts",
     edit("claim_receipt_begin", "    IF v_c.status <> 'submitted' THEN\n        RAISE EXCEPTION 'CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;\n    END IF;\n    SELECT a.portal_upload_max_bytes",
          "    SELECT a.portal_upload_max_bytes"),
     "FIXTURE 287A 失败:撤回的单"),
    ("287", "UPLOAD: the upload policy admits any claim-receipts path",
     f"DROP POLICY {UP} ON storage.objects;\nCREATE POLICY {UP} ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated "
     "WITH CHECK (bucket_id = 'claim-receipts'::text);",
     "FIXTURE 287B 失败:一条没登记过的路径传得进"),
    ("287", "UPLOAD: the judge ignores who registered the path",
     edit("claim_receipt_can_upload", "r.status = 'uploading' AND r.created_by = auth.uid()", "r.status = 'uploading' AND auth.uid() IS NOT NULL"),
     "FIXTURE 287B 失败:员工本人传得进替他提单的人登记的路径"),
    ("287", "UPLOAD: the ten-minute window dropped",
     edit("claim_receipt_can_upload", "                      AND r.created_at > now() - interval '10 minutes' AND c.status = 'submitted'\n",
          "                      AND c.status = 'submitted'\n"),
     "FIXTURE 287B 失败:十分钟以前登记的路径还传得进"),
    ("287", "UPLOAD: a delete policy on claim-receipts (Q5: nobody deletes)",
     "CREATE POLICY \"inj delete claim receipts\" ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated USING (bucket_id = 'claim-receipts'::text);",
     "FIXTURE 287B 失败:有人改得动或删得掉"),
    ("287", "FINISH: the size / type check dropped",
     edit("claim_receipt_finish", "    IF (v_meta ? 'size' AND (v_meta ->> 'size')::bigint <> r.file_size)\n"
                                  "       OR (v_meta ? 'mimetype' AND v_meta ->> 'mimetype' <> r.file_type) THEN\n"
                                  "        RAISE EXCEPTION 'CLAIM_RECEIPT_MISMATCH';\n    END IF;\n", ""),
     "FIXTURE 287C 失败:大小对不上"),
    ("287", "READ: the read judge lets every signed-in person read",
     edit("claim_receipt_can_read", "       AND (has_permission('module.finance.view')", "       AND (auth.uid() IS NOT NULL OR has_permission('module.finance.view')"),
     "FIXTURE 287D 失败:另一名员工读到了别人的收据"),
    ("287", "READ: a removed receipt still readable by the claimant (Q5: hidden)",
     edit("claim_receipt_can_read", "(r.status = 'attached' OR (r.status = 'uploading' AND r.created_by = auth.uid()))",
          "(r.status IN ('attached', 'removed') OR (r.status = 'uploading' AND r.created_by = auth.uid()))"),
     "FIXTURE 287E 失败:拿掉的那份员工不该再读到"),
    ("287", "REMOVE: anyone may remove a receipt",
     edit("claim_receipt_remove", "    IF NOT COALESCE(v_c.employee_id = current_user_employee() OR v_c.created_by = auth.uid(), false) THEN\n"
                                  "        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_YOURS|%', v_c.code;\n    END IF;\n", ""),
     "FIXTURE 287E 失败:别人拿掉"),
    ("287", "DECIDE: an uploading (not arrived) receipt counts as evidence",
     edit("decide_expense_claim_items", "WHERE r.item_id = v_item.id AND r.status = 'attached')", "WHERE r.item_id = v_item.id AND r.status IN ('attached', 'uploading'))"),
     "FIXTURE 287F 失败:第 2 笔没有 attached 的收据"),
    ("287", "DECIDE: evidence judged per claim, not per item (the retired route's shape)",
     edit("decide_expense_claim_items", "WHERE r.item_id = v_item.id AND r.status = 'attached')", "WHERE r.claim_id = v_item.claim_id AND r.status = 'attached')"),
     "FIXTURE 287F 失败:第 2 笔没有 attached 的收据"),
    ("287", "AFTER: a receipt can be removed after approval (Q6)",
     edit("claim_receipt_remove", "    IF v_c.status <> 'submitted' THEN\n        RAISE EXCEPTION 'CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;\n    END IF;\n", ""),
     "FIXTURE 287G 失败:批准之后拿掉"),
    ("287", "GUARD: the status guard dropped",
     "DROP TRIGGER trg_expense_claim_receipts_immutable ON public.expense_claim_receipts;",
     "FIXTURE 287H 失败:attached → uploading"),
    ("287", "SHAPE: the claims trail still hangs finance_attachments",
     edit("trail_subject_members", "('expense_claim',    2, 'expense_claim_receipts', 'expense_claims', 'claim_id', '{}'::jsonb, 'down', true, true),",
          "('expense_claim',    2, 'finance_attachments', 'expense_claims', 'id', '{}'::jsonb, 'down', true, true),"),
     "FIXTURE 287I 失败:两条报销单审计记录"),
    # ── the pins this cut moved ──
    ("274", "274 SHAPE: a 59th storage policy",
     "CREATE POLICY \"inj extra\" ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));",
     "FIXTURE 274 SHAPE: 59 storage policies"),
    ("274", "274 SHAPE: the receipt upload policy loses its judge",
     f"DROP POLICY {UP} ON storage.objects;\nCREATE POLICY {UP} ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated "
     "WITH CHECK (bucket_id = 'claim-receipts'::text);",
     "FIXTURE 274 SHAPE: a storage policy without a judge"),
    ("140", "140 D: evidence ignores the receipt (only the reason counts)",
     edit("decide_expense_claim_items", "        IF NOT EXISTS (SELECT 1 FROM expense_claim_receipts r WHERE r.item_id = v_item.id AND r.status = 'attached')\n           AND ",
          "        IF "),
     "ERROR:  EXPENSE_CLAIM_NO_EVIDENCE"),   # 140 不接这个拒绝 —— 整支按名报错退出,那就是红
]


def run(dsn: str, sql: str) -> str:
    p = subprocess.run(["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True, text=True)
    return (p.stdout or "") + (p.stderr or "")


def first_fixture_line(out: str, n: str) -> str:
    m = re.search(rf"(FIXTURE {n}[^\n]*)", out)
    return m.group(1)[:240] if m else ""


def main() -> int:
    work = tempfile.mkdtemp(prefix="injcr1", dir="/tmp")
    data, sock = os.path.join(work, "pg"), os.path.join(work, "s")
    os.makedirs(sock)
    port = "55442"
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
        for n in ("140", "274", "286", "287"):
            out = run(dsn, FIX[n])
            ok = ("全部通过" in out) or (n in ("140", "286") and "ERROR" not in out)
            print(("✓" if ok else "✗") + f" baseline {n} (no injection) → {first_fixture_line(out, n) or ('clean' if ok else out[-300:])}")
            passed, failed = passed + ok, failed + (not ok)
        print(f"INJECTIONS pass={passed} fail={failed}")
        return 0 if failed == 0 else 1
    finally:
        subprocess.run(["pg_ctl", "-D", data, "stop", "-m", "immediate"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
