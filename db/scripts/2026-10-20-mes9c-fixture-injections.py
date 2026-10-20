#!/usr/bin/env python3
"""MES-9c — fault-injection matrix for fixtures 277 (certificate uploads and review) and 278 (F19, the change-history pages), the pins MES-9c moved
in 274 / 275 / 276, and verdict 8's MES-9c half — against a LOCAL rebuild (never live).

The shape of db/scripts/2026-10-19-mes9b-fixture-injections.py: it builds its own throwaway cluster (db/verify_rebuild.py --skip-diff, then the
storage stub + mirror the gate installs), so it can be re-run on a fresh rebuild after the last database edit. Each cell runs inside the fixture's
own transaction (the injection is the first statement after an outer BEGIN; the fixture's ROLLBACK undoes both), so every cell starts from the
clean rebuild. A function or view is injected by re-creating it from its MIRROR with one targeted edit — the edit must change the text, or the
script stops (an injection that did not happen is not a pass). Every cell names the line it must go red on BEFORE it runs; the baselines must pass.
Usage: python3 db/scripts/2026-10-20-mes9c-fixture-injections.py > <log> 2>&1 ; verdict: the log's INJ_OWN_EXIT= line (written by the caller).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = {n: next((ROOT / "db/fixtures").glob(f"{n}-*.sql")).read_text() for n in ("274", "275", "276", "277", "278")}


def edit(name: str, old: str, new: str) -> str:
    src = (ROOT / f"db/functions/{name}.sql").read_text()
    if src.count(old) != 1:
        raise SystemExit(f"INJECTION NOT APPLIED: {name}: the text to replace occurs {src.count(old)} time(s): {old[:80]!r}")
    return src.replace(old, new)


def edit_view(name: str, old: str, new: str) -> str:
    src = (ROOT / f"db/views/{name}.sql").read_text()
    if src.count(old) != 1:
        raise SystemExit(f"INJECTION NOT APPLIED: view {name}: the text to replace occurs {src.count(old)} time(s): {old[:80]!r}")
    src = src.replace(old, new)
    return src.replace(f"CREATE VIEW public.{name}", f"CREATE OR REPLACE VIEW public.{name}", 1)


UP = '"portal uploads its own pending submission file"'
RD = '"portal reads its own pending submission file"'
STAFF_RD = '"portal-uploads read by suppliers.view"'
BEGIN_SIG = "public.portal_submission_begin(text, text, text, bigint, text, date, date)"
# (fixture, cell name, injection SQL, the line it must go red on)
CELLS = [
    # ── 277 V39 ──
    ("277", "V39: the size limit not enforced",
     edit("portal_submission_begin", "    IF p_file_size > v_max THEN\n        RAISE EXCEPTION 'PORTAL_UPLOAD_TOO_LARGE|%', v_max;\n    END IF;\n", ""),
     "FIXTURE 277 V39: 10 MB + 1 byte"),
    ("277", "V39: the type limit not enforced",
     edit("portal_submission_begin", "    IF p_file_type IS NULL OR NOT (p_file_type = ANY (v_types)) THEN\n"
                                     "        RAISE EXCEPTION 'PORTAL_UPLOAD_TYPE_NOT_ACCEPTED|%', COALESCE(p_file_type, '');\n    END IF;\n", ""),
     "FIXTURE 277 V39: a GIF"),
    ("277", "V39: an unset limit treated as no limit",
     edit("portal_submission_begin", "    IF v_max IS NULL OR v_types IS NULL THEN\n        RAISE EXCEPTION 'PORTAL_UPLOAD_LIMITS_NOT_SET';\n    END IF;\n", ""),
     "FIXTURE 277 V39: V39 cleared"),
    ("277", "V39: the upload policy admits any portal-uploads path (bytes before the check)",
     f"DROP POLICY {UP} ON storage.objects;\nCREATE POLICY {UP} ON storage.objects AS PERMISSIVE FOR INSERT TO supplier_portal "
     "WITH CHECK (bucket_id = 'portal-uploads'::text);\n"
     f"DROP POLICY {RD} ON storage.objects;\nCREATE POLICY {RD} ON storage.objects AS PERMISSIVE FOR SELECT TO supplier_portal "
     "USING (bucket_id = 'portal-uploads'::text);",
     "FIXTURE 277 V39: bytes stored without a submission"),
    # ── 277 ONLY ──
    ("277", "ONLY: an upload also touches the supplier row",
     edit("portal_submission_finish", "    UPDATE portal_certificate_submissions SET status = 'submitted', submitted_at = now() WHERE id = s.id;",
          "    UPDATE portal_certificate_submissions SET status = 'submitted', submitted_at = now() WHERE id = s.id;\n"
          "    UPDATE suppliers SET notes = COALESCE(notes, '') || ' ' WHERE id = s.supplier_id;"),
     "FIXTURE 277 ONLY: an upload changed suppliers"),
    ("277", "ONLY: an upload creates a compliance row by itself",
     edit("portal_submission_finish", "    UPDATE portal_certificate_submissions SET status = 'submitted', submitted_at = now() WHERE id = s.id;",
          "    UPDATE portal_certificate_submissions SET status = 'submitted', submitted_at = now() WHERE id = s.id;\n"
          "    INSERT INTO supplier_compliance (supplier_id, cert_type_code) VALUES (s.supplier_id, s.cert_type_code);"),
     "FIXTURE 277 ONLY: an upload changed supplier_compliance"),
    ("277", "ONLY: the submissions table not change-logged",
     "DROP TRIGGER zzz_change_log ON public.portal_certificate_submissions;",
     "FIXTURE 277 ONLY: expected two change-log rows"),
    # ── 277 UPLOAD ──
    ("277", "UPLOAD: the upload judge ignores whose submission it is",
     edit("portal_can_upload_object", "                    WHERE s.portal_user_id = v_link AND s.storage_path = p_name",
          "                    WHERE v_link IS NOT NULL AND s.storage_path = p_name"),
     "FIXTURE 277 UPLOAD: B stored at A's path"),
    ("277", "UPLOAD: the upload judge ignores the status (a finished path still admits bytes)",
     edit("portal_can_upload_object", " AND s.status = 'uploading'\n", "\n"),
     "FIXTURE 277 UPLOAD: a finished submission's path still admits bytes"),
    ("277", "UPLOAD: the ten-minute window removed",
     edit("portal_can_upload_object", "\n                      AND s.created_at > now() - interval '10 minutes'", ""),
     "FIXTURE 277 UPLOAD: a submission registered eleven minutes ago"),
    ("277", "UPLOAD: finish does not look for the bytes",
     edit("portal_submission_finish", "    IF NOT FOUND THEN\n        RAISE EXCEPTION 'PORTAL_UPLOAD_NOT_STORED';\n    END IF;\n", ""),
     "FIXTURE 277 UPLOAD: finish without bytes"),
    ("277", "UPLOAD: finish does not compare the stored size",
     edit("portal_submission_finish", "    IF (v_meta ? 'size' AND (v_meta ->> 'size')::bigint <> s.file_size)\n       OR (v_meta ? 'mimetype' AND v_meta ->> 'mimetype' <> s.file_type) THEN",
          "    IF false THEN"),
     "FIXTURE 277 UPLOAD: a size mismatch"),
    ("277", "UPLOAD: finish does not check whose submission it is",
     edit("portal_submission_finish", "WHERE x.id = p_submission_id AND x.portal_user_id = v_link FOR UPDATE;", "WHERE x.id = p_submission_id AND v_link IS NOT NULL FOR UPDATE;"),
     "FIXTURE 277 UPLOAD: B finished A's submission"),
    # ── 277 REVIEW ──
    ("277", "REVIEW: accept asks for the view code only",
     edit("portal_submission_accept", "    PERFORM require_permission('module.suppliers.edit');", "    PERFORM require_permission('module.suppliers.view');"),
     "FIXTURE 277 REVIEW: a view reader reviewed"),
    ("277", "REVIEW: reject executable by the portal",
     "GRANT EXECUTE ON FUNCTION public.portal_submission_reject(uuid, text) TO supplier_portal;",
     "FIXTURE 277 REVIEW: the portal account reviewed its own submission"),
    ("277", "REVIEW: the submissions read predicate dropped",
     "DROP POLICY \"portal_certificate_submissions select by permission\" ON public.portal_certificate_submissions;\n"
     "CREATE POLICY fx ON public.portal_certificate_submissions FOR SELECT TO authenticated USING (true);",
     "FIXTURE 277 REVIEW: a reader without module.suppliers.view reads"),
    ("277", "REVIEW: staff cannot see the submitted file", f"DROP POLICY {STAFF_RD} ON storage.objects;",
     "FIXTURE 277 REVIEW: a suppliers viewer cannot see the submitted file"),
    # ── 277 ACCEPT ──
    ("277", "ACCEPT: accept does not check the copy",
     edit("portal_submission_accept", "    IF NOT FOUND OR (v_size IS NOT NULL AND v_size::bigint <> s.file_size) THEN\n        RAISE EXCEPTION 'PORTAL_SUBMISSION_FILE_NOT_COPIED';\n    END IF;\n", ""),
     "FIXTURE 277 ACCEPT: accepted without the copy"),
    ("277", "ACCEPT: accept files the certificate under another type",
     edit("portal_submission_accept", "    VALUES (s.supplier_id, s.cert_type_code, COALESCE(", "    VALUES (s.supplier_id, 'basel', COALESCE("),
     "FIXTURE 277 ACCEPT: the supplier_compliance row is missing or wrong"),
    ("277", "ACCEPT: accept also changes the supplier",
     edit("portal_submission_accept", "    RETURN jsonb_build_object('submission', s.id, 'compliance_id', v_comp, 'attachment_id', v_att);",
          "    UPDATE suppliers SET notes = COALESCE(notes, '') || ' ' WHERE id = s.supplier_id;\n"
          "    RETURN jsonb_build_object('submission', s.id, 'compliance_id', v_comp, 'attachment_id', v_att);"),
     "FIXTURE 277 ACCEPT: accepting changed"),
    ("277", "ACCEPT: an accepted certificate can be accepted again",
     edit("portal_submission_accept", "    IF s.status <> 'submitted' THEN\n        RAISE EXCEPTION 'PORTAL_SUBMISSION_NOT_WAITING|%', s.status;\n    END IF;\n", ""),
     "FIXTURE 277 ACCEPT: a second accept"),
    # ── 277 REJECT ──
    ("277", "REJECT: a blank reason accepted by the function (the table's check is all that is left)",
     edit("portal_submission_reject", "    IF v_reason = '' THEN\n        RAISE EXCEPTION 'PORTAL_SUBMISSION_REASON_REQUIRED';\n    END IF;\n", ""),
     "FIXTURE 277 REJECT: a blank reason"),
    ("277", "REJECT: the portal hides the reason",
     edit("portal_certificates", "                       'reject_reason', CASE WHEN s.status = 'rejected' THEN s.reject_reason END,",
          "                       'reject_reason', NULL::text,"),
     "FIXTURE 277 REJECT: the supplier does not see the reason"),
    # ── 277 EVERY ──
    ("277", "EVERY: one more function granted to supplier_portal",
     "GRANT EXECUTE ON FUNCTION public.portal_actor_labels(uuid[]) TO supplier_portal;", "has no two-supplier case here, in 275 or in 276"),
    ("277", "EVERY: portal_certificates answers about the first link, not the caller's",
     edit("portal_certificates", "    SELECT p.supplier_id INTO v_supplier FROM supplier_portal_users p WHERE p.id = v_link;",
          "    SELECT p.supplier_id INTO v_supplier FROM supplier_portal_users p WHERE p.id = (SELECT id FROM supplier_portal_users ORDER BY created_at, id LIMIT 1) AND v_link IS NOT NULL;"),
     "FIXTURE 277 EVERY: portal_certificates() as B"),
    ("277", "EVERY: portal_submission_begin skips the session check (no portal_require_link)",
     edit("portal_submission_begin", "    v_link     uuid := portal_require_link();", "    v_link     uuid := (SELECT p.id FROM supplier_portal_users p WHERE p.user_id = auth.uid());"),
     "FIXTURE 277 EVERY: portal_submission_begin("),
    ("277", "EVERY: abandon does not check whose submission it is",
     edit("portal_submission_abandon", "WHERE x.id = p_submission_id AND x.portal_user_id = v_link FOR UPDATE;", "WHERE x.id = p_submission_id AND v_link IS NOT NULL FOR UPDATE;"),
     "on the other supplier's submission"),
    ("277", "EVERY: the upload judge raises instead of answering false",
     edit("portal_can_upload_object", "    BEGIN\n        v_link := portal_require_link();\n    EXCEPTION WHEN OTHERS THEN\n        RETURN false;\n    END;\n",
          "    v_link := portal_require_link();\n"),
     "must answer false, never raise"),
    # ── 277 GRANTS ──
    ("277", "GRANTS: the portal may update storage objects", "GRANT UPDATE ON storage.objects TO supplier_portal;",
     "FIXTURE 277 UPLOAD: a portal session changed storage"),
    ("277", "GRANTS: a fourth storage policy for the portal", "CREATE POLICY fx ON storage.objects FOR SELECT TO supplier_portal USING (false);",
     "FIXTURE 277 GRANTS: the portal-uploads policies"),
    # ── 277 TRAIL · EXCL ──
    ("277", "TRAIL: the submissions dropped from the supplier's trail",
     edit("trail_subject_members", "        ('supplier',            8, 'portal_certificate_submissions',   'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, true),\n", ""),
     "FIXTURE 277 TRAIL: the submissions are not members"),
    ("277", "EXCL: the submissions table excluded from the change log (a tenth exclusion)",
     edit("change_log_exclusions", "        ('portal_document_downloads',",
          "        ('portal_certificate_submissions', 'fx'),\n        ('portal_document_downloads',"),
     "FIXTURE 277 EXCL: change-log coverage"),
    ("277", "EXCL: the V39 pending arm never lists a row",
     edit_view("pending_values", "          WHERE acs.id AND (acs.portal_upload_max_bytes IS NULL OR acs.portal_upload_types IS NULL)) p",
               "          WHERE acs.id AND false) p"),
     "FIXTURE 277 EXCL: V39 cleared — pending_values lists 0"),
    # ── 278 F19 ──
    ("278", "F19: the row limit ignored (one call answers the whole operation)",
     edit("change_log_rows", "THEN (CASE WHEN p_row_limit IS NOT NULL THEN LEAST(GREATEST(p_row_limit, 1), 200) END) ELSE v_limit END",
          "THEN NULL ELSE v_limit END"),
     "FIXTURE 278 BOUND: one paged call returned"),
    ("278", "F19: the cursor repeats its boundary row (<=)",
     edit("change_log_rows", "AND (p_row_before IS NULL OR c.seq < p_row_before)", "AND (p_row_before IS NULL OR c.seq <= p_row_before)"),
     "FIXTURE 278 SAME"),
    ("278", "F19: the cursor ignored (every call answers the first page)",
     edit("change_log_rows", "AND (p_row_before IS NULL OR c.seq < p_row_before)", "AND (p_row_before IS NULL OR p_row_before IS NOT NULL)"),
     "FIXTURE 278 BOUND: more than 100 calls"),
    # ── the pins MES-9c moved ──
    ("276", "276 EVERY: a MES-9c function no longer executable by supplier_portal (the hand-off list is stale)",
     "REVOKE EXECUTE ON FUNCTION public.portal_certificates() FROM supplier_portal;", "MES-9c functions are executable by supplier_portal — the name list here is stale"),
    ("276", "276 STORE: the portal may update storage objects", "GRANT UPDATE ON storage.objects TO supplier_portal;",
     "FIXTURE 276 STORE: a portal session wrote storage"),
    ("276", "276 GRANTS: a fourth storage policy for the portal", "CREATE POLICY fx ON storage.objects FOR SELECT TO supplier_portal USING (false);",
     "FIXTURE 276 GRANTS: exactly three storage policies"),
    ("275", "275 EVERY: a MES-9c function no longer executable by supplier_portal (the hand-off list is stale)",
     "REVOKE EXECUTE ON FUNCTION public.portal_certificates() FROM supplier_portal;", "MES-9b / MES-9c functions are executable by supplier_portal — the name list here is stale"),
    ("274", "274 SHAPE: a 57th storage policy",
     "CREATE POLICY fx ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'avatars' AND has_permission('module.finance.view'));",
     "FIXTURE 274 SHAPE: 57 storage policies"),
    ("274", "274 SHAPE: the portal upload policy loses its judge",
     f"DROP POLICY {UP} ON storage.objects;\nCREATE POLICY {UP} ON storage.objects AS PERMISSIVE FOR INSERT TO supplier_portal "
     "WITH CHECK (bucket_id = 'portal-uploads'::text);",
     "FIXTURE 274 SHAPE: a storage policy without a judge"),
    ("274", "274 BUCKET: the read code uploads into portal-uploads",
     "CREATE POLICY fx ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'portal-uploads' AND has_permission('module.suppliers.view'));",
     "FIXTURE 274 BUCKET: the read code module.suppliers.view alone uploads into portal-uploads"),
]


def run(dsn: str, sql: str) -> str:
    p = subprocess.run(["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True, text=True)
    return (p.stdout or "") + (p.stderr or "")


def first_fixture_line(out: str, n: str) -> str:
    m = re.search(rf"(FIXTURE {n}[^\n]*)", out)
    return m.group(1)[:240] if m else ""


def main() -> int:
    work = tempfile.mkdtemp(prefix="inj9c", dir="/tmp")
    data, sock = os.path.join(work, "pg"), os.path.join(work, "s")
    os.makedirs(sock)
    port = "55441"
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
        for n in ("274", "275", "276", "277", "278"):
            out = run(dsn, FIX[n])
            line = first_fixture_line(out, n)
            ok = "全部通过" in line
            print(("✓" if ok else "✗") + f" baseline {n} (no injection) → {line}")
            passed, failed = passed + ok, failed + (not ok)
        # ── verdict 8 on the same rebuild: its MES-9c (storage INSERT · two policies) half, both ways ──
        cp = [sys.executable, str(ROOT / "db/check_portal.py"), "--rebuild", dsn, "--offline"]
        run(dsn, "GRANT UPDATE ON storage.objects TO supplier_portal;")
        v = subprocess.run(cp, capture_output=True, text=True).stdout
        run(dsn, "REVOKE UPDATE ON storage.objects FROM supplier_portal;")
        ok = "reaches what the baseline does not name: relation storage.objects UPDATE" in v
        print(("✓" if ok else "✗") + " verdict 8: an extra storage grant (UPDATE on storage.objects) is named" + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        run(dsn, "REVOKE INSERT ON storage.objects FROM supplier_portal;")
        v = subprocess.run(cp, capture_output=True, text=True).stdout
        run(dsn, "GRANT INSERT ON storage.objects TO supplier_portal;")
        ok = "the baseline names what supplier_portal does not reach: relation storage.objects INSERT" in v
        print(("✓" if ok else "✗") + " verdict 8: the storage INSERT grant revoked is named missing" + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        run(dsn, f"REVOKE EXECUTE ON FUNCTION {BEGIN_SIG} FROM supplier_portal;")
        v = subprocess.run(cp, capture_output=True, text=True).stdout
        run(dsn, f"GRANT EXECUTE ON FUNCTION {BEGIN_SIG} TO supplier_portal;")
        ok = "the baseline names what supplier_portal does not reach: function public.portal_submission_begin(" in v
        print(("✓" if ok else "✗") + " verdict 8: portal_submission_begin revoked is named missing" + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        bl = Path(work) / "bl.tsv"
        bl.write_text("".join(l for l in (ROOT / "db/portal-grants-baseline.tsv").read_text().splitlines(True)
                              if not l.startswith("policy\tstorage.objects\tportal uploads its own pending submission file")))
        v = subprocess.run(cp + ["--baseline", str(bl)], capture_output=True, text=True).stdout
        ok = "reaches what the baseline does not name: policy storage.objects portal uploads its own pending submission file" in v
        print(("✓" if ok else "✗") + " verdict 8: a deleted baseline line (the portal upload policy) is named" + ("" if ok else f": {v[-400:]}"))
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
