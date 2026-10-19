#!/usr/bin/env python3
"""MES-9b — fault-injection matrix for fixture 276 (and the pins MES-9b moved in 274 / 275) and verdict 8, against a LOCAL rebuild (never live).

The shape of db/scripts/2026-10-19-mes9a-fixture-injections.py: it builds its own throwaway cluster (db/verify_rebuild.py --skip-diff, then the
storage stub + mirror the gate installs), so it can be re-run on a fresh rebuild after the last database edit. Each cell runs inside the fixture's
own transaction (the injection is the first statement after an outer BEGIN; the fixture's ROLLBACK undoes both), so every cell starts from the
clean rebuild. A function is injected by re-creating it from its MIRROR with one targeted edit — the edit must change the text, or the script
stops (an injection that did not happen is not a pass). Every cell names the line it must go red on BEFORE it runs (AGENTS.md: a cell that does
not bite is information); the baseline cells must pass. Verdict 8 is then injected on its storage half.
Usage: python3 db/scripts/2026-10-19-mes9b-fixture-injections.py > <log> 2>&1 ; verdict: the log's INJ_OWN_EXIT= line (written by the caller).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = {n: next((ROOT / "db/fixtures").glob(f"{n}-*.sql")).read_text() for n in ("274", "275", "276")}


def edit(name: str, old: str, new: str) -> str:
    src = (ROOT / f"db/functions/{name}.sql").read_text()
    if src.count(old) != 1:
        raise SystemExit(f"INJECTION NOT APPLIED: {name}: the text to replace occurs {src.count(old)} time(s): {old[:80]!r}")
    return src.replace(old, new)


POLICY = '"portal reads its own logged issued documents"'
# (fixture, cell name, injection SQL, the line it must go red on)
CELLS = [
    # ── DOCS ──
    ("276", "DOCS: a draft / pending / rejected order is listed",
     edit("portal_documents", "\n               AND (EXISTS (SELECT 1 FROM po_issues i WHERE i.purchase_order_id = po.id)\n"
                              "                    OR (po.status <> 'draft' AND po.approval_status = 'approved'))", ""),
     "FIXTURE 276 DOCS: purchase orders listed"),
    ("276", "DOCS: the supplier filter dropped from the orders",
     edit("portal_documents", "             WHERE po.supplier_id = v_supplier AND po.deleted_at IS NULL", "             WHERE po.deleted_at IS NULL"),
     "FIXTURE 276 DOCS: purchase orders listed"),
    ("276", "DOCS: a void certificate offers its document",
     edit("portal_documents", "FROM cod_issues i WHERE i.cod_id = c.id AND c.status = 'issued'))", "FROM cod_issues i WHERE i.cod_id = c.id))"),
     "FIXTURE 276 DOCS: certificates"),
    ("276", "DOCS: a price (the order's estimated total) leaks",
     edit("portal_documents", "                       'order_date', po.order_date,\n",
          "                       'order_date', po.order_date, 'estimated_total_ccy', po.estimated_total_ccy,\n"),
     "FIXTURE 276 DOCS: A's documents carry B's data, a price"),
    # ── DELIV ──
    ("276", "DELIV: the unit price leaks",
     edit("portal_deliveries", "                       'unit', b.unit,\n", "                       'unit', b.unit, 'unit_price', b.unit_price,\n"),
     "FIXTURE 276 DELIV: A's deliveries carry"),
    ("276", "DELIV: a shared ticket shows the other supplier's share",
     edit("portal_deliveries", "                                   WHERE sh.ticket_id = t.id AND b.supplier_id = v_supplier AND b.deleted_at IS NULL))",
          "                                   WHERE sh.ticket_id = t.id AND b.deleted_at IS NULL))"),
     "FIXTURE 276 DELIV: tickets"),
    ("276", "DELIV: a soft-deleted receipt is shown",
     edit("portal_deliveries", "             WHERE b.supplier_id = v_supplier AND b.deleted_at IS NULL), '[]'::jsonb),",
          "             WHERE b.supplier_id = v_supplier), '[]'::jsonb),"),
     "FIXTURE 276 DELIV: receipts"),
    # ── OPEN ──
    ("276", "OPEN: the ownership check removed",
     edit("portal_document_open", "    IF v_path IS NULL OR v_owner IS DISTINCT FROM v_supplier THEN", "    IF v_path IS NULL THEN"),
     "FIXTURE 276 OPEN: A opened"),
    ("276", "OPEN: a deleted order's document is handed out",
     edit("portal_document_open", "         WHERE i.id = p_issue_id AND po.deleted_at IS NULL;", "         WHERE i.id = p_issue_id;"),
     "FIXTURE 276 OPEN: A opened"),
    ("276", "OPEN: a void certificate is handed out",
     edit("portal_document_open", "    IF p_kind = 'cod' AND v_status = 'void' THEN\n        RAISE EXCEPTION 'PORTAL_DOCUMENT_VOID|%', v_code;\n    END IF;\n"
                                  "    IF p_kind = 'cod' AND v_status IS DISTINCT FROM 'issued' THEN\n        RAISE EXCEPTION 'PORTAL_DOCUMENT_NOT_FOUND';\n    END IF;\n", ""),
     "FIXTURE 276 OPEN: a void certificate"),
    ("276", "OPEN: no download log row is written",
     edit("portal_document_open", "    INSERT INTO portal_document_downloads (portal_user_id, user_id, supplier_id, document_kind, issue_id, document_code, version,\n"
                                  "                                           bucket_id, file_path, sha256)\n"
                                  "    VALUES (v_link, v_user, v_supplier, p_kind, p_issue_id, v_code, v_version, v_bucket, v_path, v_sha)\n"
                                  "    RETURNING id INTO v_log;", "    v_log := gen_random_uuid();"),
     "FIXTURE 276 OPEN: the download log row is missing"),
    # ── STORE ──
    ("276", "STORE: the two-minute window removed (any old log row opens the object)",
     edit("portal_can_read_object", "\n                      AND d.downloaded_at > now() - interval '2 minutes'", ""),
     "FIXTURE 276 STORE: a log row three minutes old"),
    ("276", "STORE: the predicate ignores whose log row it is",
     edit("portal_can_read_object", "                    WHERE d.portal_user_id = v_link AND d.bucket_id = p_bucket", "                    WHERE d.bucket_id = p_bucket"),
     "FIXTURE 276 STORE: B, who logged nothing"),
    ("276", "STORE: the predicate raises instead of answering false",
     edit("portal_can_read_object", "    BEGIN\n        v_link := portal_require_link();\n    EXCEPTION WHEN OTHERS THEN\n        RETURN false;\n    END;\n",
          "    v_link := portal_require_link();\n"),
     "FIXTURE 276 STORE: an ended session"),
    ("276", "STORE: the portal policy reads every document object",
     f"DROP POLICY {POLICY} ON storage.objects;\nCREATE POLICY {POLICY} ON storage.objects AS PERMISSIVE FOR SELECT TO supplier_portal "
     "USING (bucket_id = ANY (ARRAY['po-documents'::text, 'cod-documents'::text, 'supplier-statement-documents'::text]));",
     "FIXTURE 276 STORE: A sees in storage"),
    # ── LOG ──
    ("276", "LOG: the delete guard dropped", "DROP TRIGGER trg_portal_document_downloads_no_delete ON public.portal_document_downloads;",
     "FIXTURE 276 LOG: DELETE FROM portal_document_downloads went through"),
    ("276", "LOG: the update guard dropped", "DROP TRIGGER trg_portal_document_downloads_append_only ON public.portal_document_downloads;",
     "FIXTURE 276 LOG: UPDATE portal_document_downloads"),
    ("276", "LOG: staff may insert directly",
     "GRANT INSERT ON public.portal_document_downloads TO authenticated;\n"
     "CREATE POLICY fx ON public.portal_document_downloads FOR INSERT TO authenticated WITH CHECK (true);",
     "FIXTURE 276 LOG: a direct insert by authenticated"),
    ("276", "LOG: the read predicate dropped",
     "DROP POLICY \"portal_document_downloads select by permission\" ON public.portal_document_downloads;\n"
     "CREATE POLICY fx ON public.portal_document_downloads FOR SELECT TO authenticated USING (true);",
     "FIXTURE 276 LOG: a reader without module.suppliers.view"),
    # ── EXCL ──
    ("276", "EXCL: the ninth exclusion removed (back to 8)",
     edit("change_log_exclusions", "        ('portal_document_downloads', 'Supplier portal download log (MES-9b, MES-9 Step 0 Q22): itself an append-only record of every issued document a portal user took; logging it again doubles the volume and adds no fact.'),\n", ""),
     "FIXTURE 276 EXCL: change-log coverage"),
    ("276", "EXCL: the download log bound to the change log",
     "CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.portal_document_downloads FOR EACH ROW EXECUTE FUNCTION public.change_log_capture();\n"
     "CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.portal_document_downloads FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();",
     "FIXTURE 276 EXCL: change-log coverage"),
    # ── EVERY ──
    ("276", "EVERY: one more function granted to supplier_portal",
     "GRANT EXECUTE ON FUNCTION public.portal_actor_labels(uuid[]) TO supplier_portal;", "has no two-supplier case here or in fixture 275"),
    ("276", "EVERY: portal_documents granted to authenticated", "GRANT EXECUTE ON FUNCTION public.portal_documents() TO authenticated;",
     "FIXTURE 276 EVERY: portal_documents() as authenticated"),
    ("276", "EVERY: portal_deliveries answers about the first link, not the caller's",
     edit("portal_deliveries", "    SELECT p.supplier_id INTO v_supplier FROM supplier_portal_users p WHERE p.id = v_link;",
          "    SELECT p.supplier_id INTO v_supplier FROM supplier_portal_users p WHERE p.id = (SELECT id FROM supplier_portal_users ORDER BY created_at, id LIMIT 1) AND v_link IS NOT NULL;"),
     "FIXTURE 276 EVERY: portal_deliveries() as B"),
    ("276", "EVERY: portal_document_open skips the session check (no portal_require_link)",
     edit("portal_document_open", "    v_link     uuid := portal_require_link();", "    v_link     uuid := (SELECT p.id FROM supplier_portal_users p WHERE p.user_id = auth.uid());"),
     "FIXTURE 276 EVERY: portal_document_open(text,uuid)"),
    # ── WRITES ──
    ("276", "WRITES: a portal function also writes a business row",
     edit("portal_document_open", "    RETURNING id INTO v_log;", "    RETURNING id INTO v_log;\n    UPDATE suppliers SET notes = COALESCE(notes, '') WHERE id = v_supplier;"),
     "FIXTURE 276 WRITES: a portal session wrote a change-logged row"),
    ("276", "WRITES: supplier_portal may insert into a public table", "GRANT INSERT ON public.suppliers TO supplier_portal;",
     "FIXTURE 276 WRITES: supplier_portal can write"),
    # ── GRANTS ──
    ("276", "GRANTS: CREATE on schema storage", "GRANT CREATE ON SCHEMA storage TO supplier_portal;", "FIXTURE 276 GRANTS: supplier_portal must hold USAGE"),
    ("276", "GRANTS: a second storage policy for the portal",
     "CREATE POLICY fx ON storage.objects FOR SELECT TO supplier_portal USING (false);", "FIXTURE 276 GRANTS: exactly one storage policy"),
    # ── the pins MES-9b moved ──
    ("275", "275 EVERY: a public function executable by supplier_portal with no case in 275 or 276",
     "GRANT EXECUTE ON FUNCTION public.portal_actor_labels(uuid[]) TO supplier_portal;", "no two-supplier case here or in fixture 276"),
    ("275", "275 LOG: the exclusions back at 8",
     edit("change_log_exclusions", "        ('portal_document_downloads', 'Supplier portal download log (MES-9b, MES-9 Step 0 Q22): itself an append-only record of every issued document a portal user took; logging it again doubles the volume and adds no fact.'),\n", ""),
     "FIXTURE 275 LOG"),
    ("274", "274 SHAPE: a 54th storage policy",
     "CREATE POLICY fx ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'avatars' AND has_permission('module.finance.view'));",
     "FIXTURE 274 SHAPE: 54 storage policies"),
    ("274", "274 SHAPE: the portal policy loses its judge",
     f"DROP POLICY {POLICY} ON storage.objects;\nCREATE POLICY {POLICY} ON storage.objects AS PERMISSIVE FOR SELECT TO supplier_portal "
     "USING (bucket_id = 'po-documents'::text);",
     "FIXTURE 274 SHAPE: a storage policy without a judge"),
]


def run(dsn: str, sql: str) -> str:
    p = subprocess.run(["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True, text=True)
    return (p.stdout or "") + (p.stderr or "")


def first_fixture_line(out: str, n: str) -> str:
    m = re.search(rf"(FIXTURE {n}[^\n]*)", out)
    return m.group(1)[:220] if m else ""


def main() -> int:
    work = tempfile.mkdtemp(prefix="inj9b", dir="/tmp")
    data, sock = os.path.join(work, "pg"), os.path.join(work, "s")
    os.makedirs(sock)
    port = "55440"
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
            if expect in line and "全部通过" not in line:
                print(f"✓ {name} → {line}")
                passed += 1
            else:
                err = next((l for l in out.splitlines() if "ERROR" in l), "")
                print(f"✗ {name} → {line or err or '<no fixture line>'} (expected: {expect})")
                failed += 1
        for n in ("274", "275", "276"):
            line = first_fixture_line(run(dsn, FIX[n]), n)
            ok = "全部通过" in line
            print(("✓" if ok else "✗") + f" baseline {n} (no injection) → {line}")
            passed, failed = passed + ok, failed + (not ok)
        # ── verdict 8 on the same rebuild: its MES-9b (storage) half, both ways ──
        cp = [sys.executable, str(ROOT / "db/check_portal.py"), "--rebuild", dsn, "--offline"]
        run(dsn, "GRANT SELECT ON storage.buckets TO supplier_portal;")
        v = subprocess.run(cp, capture_output=True, text=True).stdout
        run(dsn, "REVOKE SELECT ON storage.buckets FROM supplier_portal;")
        ok = "reaches what the baseline does not name: relation storage.buckets SELECT" in v
        print(("✓" if ok else "✗") + " verdict 8: an extra storage grant (storage.buckets → supplier_portal) is named" + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        run(dsn, "CREATE POLICY fx ON storage.objects FOR SELECT TO supplier_portal USING (false);")
        v = subprocess.run(cp, capture_output=True, text=True).stdout
        run(dsn, "DROP POLICY fx ON storage.objects;")
        ok = "reaches what the baseline does not name: policy storage.objects fx" in v
        print(("✓" if ok else "✗") + " verdict 8: an extra storage policy for the portal is named" + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        run(dsn, "REVOKE EXECUTE ON FUNCTION public.portal_document_open(text, uuid) FROM supplier_portal;")
        v = subprocess.run(cp, capture_output=True, text=True).stdout
        run(dsn, "GRANT EXECUTE ON FUNCTION public.portal_document_open(text, uuid) TO supplier_portal;")
        ok = "the baseline names what supplier_portal does not reach: function public.portal_document_open(p_kind text, p_issue_id uuid) EXECUTE" in v
        print(("✓" if ok else "✗") + " verdict 8: a missing grant (portal_document_open revoked) is named" + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        run(dsn, "REVOKE USAGE ON SCHEMA storage FROM supplier_portal;")
        v = subprocess.run(cp, capture_output=True, text=True).stdout
        run(dsn, "GRANT USAGE ON SCHEMA storage TO supplier_portal;")
        ok = ("the baseline names what supplier_portal does not reach: schema storage USAGE" in v
              and "the baseline names what supplier_portal does not reach: function storage.search_v2(" in v)
        print(("✓" if ok else "✗") + " verdict 8: storage USAGE revoked → the schema line and the storage functions are named missing" + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        bl = Path(work) / "bl.tsv"
        bl.write_text("".join(l for l in (ROOT / "db/portal-grants-baseline.tsv").read_text().splitlines(True)
                              if not l.startswith("policy\tstorage.objects\tportal reads its own logged issued documents")))
        v = subprocess.run(cp + ["--baseline", str(bl)], capture_output=True, text=True).stdout
        ok = "reaches what the baseline does not name: policy storage.objects portal reads its own logged issued documents" in v
        print(("✓" if ok else "✗") + " verdict 8: a deleted baseline line (the portal policy) is named" + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        v = subprocess.run(cp, capture_output=True, text=True).stdout
        ok = "all bit" in v and "判词【门户面】:✓" in v
        print(("✓" if ok else "✗") + " verdict 8 clean; always-on cells (unreadable baseline · blinded query · probe grant · removed line) bit"
              + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        print(f"INJECTIONS pass={passed} fail={failed}")
        return 0 if failed == 0 else 1
    finally:
        subprocess.run(["pg_ctl", "-D", data, "stop", "-m", "immediate"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
