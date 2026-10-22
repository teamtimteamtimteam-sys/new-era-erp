"""TABLE-EXPORT-1 — fault-injection matrix for fixture 291 (a special export does not stop at 1,000 rows) against a LOCAL rebuild (never live).
The shape of db/scripts/2026-10-22-payroll-pay-reversal-1-fixture-injections.py: its own throwaway cluster (db/verify_rebuild.py --skip-diff, then the
storage stub + mirror the gate installs); each cell runs inside the fixture's own transaction (the injection is the first statement after an outer BEGIN;
the fixture's ROLLBACK undoes both). Every cell names the line it must go red on BEFORE it runs; the baseline must pass.
Usage: python3 db/scripts/2026-10-22-table-export-1-fixture-injections.py > <log> 2>&1 ; verdict: the log's INJ_OWN_EXIT= line (written by the caller).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = next((ROOT / "db/fixtures").glob("291-*.sql")).read_text()


def edit(name: str, old: str, new: str) -> str:
    src = (ROOT / f"db/functions/{name}.sql").read_text()
    if src.count(old) != 1:
        raise SystemExit(f"INJECTION NOT APPLIED: {name}: the text to replace occurs {src.count(old)} time(s): {old[:80]!r}")
    # 镜像是 pg_get_functiondef 的原样字节,末尾没有分号 —— 注入时补上,否则下一句(fixture 的 BEGIN)会被读成它的一部分
    return src.replace(old, new) + ";"


CELLS = [
    ("A: the GL source itself stops at 1,000 rows (the cut PostgREST makes, moved into the database)",
     edit("journal_export_lines",
          "      FROM journal_activity_lines(p_from, p_to, p_include_year_close) a;",
          "      FROM journal_activity_lines(p_from, p_to, p_include_year_close) a ORDER BY a.line_id LIMIT 1000;"),
     "FIXTURE 291A 失败"),
    ("B: AR ageing becomes a row set (its export route would now be cut by max_rows)",
     "ALTER FUNCTION public.ar_aging_asof(date) RENAME TO ar_aging_asof_x;\n"
     "CREATE FUNCTION public.ar_aging_asof(p_as_of date DEFAULT CURRENT_DATE) RETURNS SETOF jsonb LANGUAGE sql AS $$ SELECT '{}'::jsonb $$;",
     "FIXTURE 291B 失败"),
    ("B: the GL source becomes a single value (red at arm A: the read itself fails before B is reached)",
     "ALTER FUNCTION public.journal_export_lines(date, date, boolean) RENAME TO journal_export_lines_x;\n"
     "CREATE FUNCTION public.journal_export_lines(p_from date, p_to date, p_include_year_close boolean) RETURNS jsonb LANGUAGE sql AS $$ SELECT '{}'::jsonb $$;",
     "ERROR:"),
    ("B: (period_id, box) on gst_return_boxes is no longer unique (paging by box could repeat or skip)",
     "ALTER TABLE public.gst_return_boxes DROP CONSTRAINT gst_return_boxes_one_per_period;",
     "FIXTURE 291B 失败"),
]


def run(dsn: str, sql: str) -> str:
    p = subprocess.run(["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True, text=True)
    return (p.stdout or "") + (p.stderr or "")


def first_fixture_line(out: str) -> str:
    m = re.search(r"(FIXTURE 291[^\n]*)", out)
    return m.group(1)[:240] if m else ""


def main() -> int:
    work = tempfile.mkdtemp(prefix="injte1", dir="/tmp")
    data, sock = os.path.join(work, "pg"), os.path.join(work, "s")
    os.makedirs(sock)
    port = "55447"
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
        for name, inj, expect in CELLS:
            out = run(dsn, "BEGIN;\n" + inj + "\n" + FIX)
            line = first_fixture_line(out)
            if expect.startswith("ERROR:"):
                # 返回 jsonb 的假 journal_export_lines 让 A 臂的 `FROM journal_export_lines(...) x` 当场报错 —— 那就是红
                line = next((l for l in out.splitlines() if expect in l), line)
            if expect in line and "全部通过" not in line:
                print(f"✓ {name} → {line}")
                passed += 1
            else:
                err = next((l for l in out.splitlines() if "ERROR" in l), "")
                print(f"✗ {name} → {line or err or '<no fixture line>'} (expected: {expect})")
                failed += 1
        out = run(dsn, FIX)
        ok = "全部通过" in out
        print(("✓" if ok else "✗") + f" baseline 291 (no injection) → {first_fixture_line(out) or out[-300:]}")
        passed, failed = passed + ok, failed + (not ok)
        print(f"INJECTIONS pass={passed} fail={failed}")
        return 0 if failed == 0 else 1
    finally:
        subprocess.run(["pg_ctl", "-D", data, "stop", "-m", "immediate"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
