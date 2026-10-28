#!/usr/bin/env python3
"""LOCAL ONLY. Other per-page reads on the 21 chain detail pages that live's pg_stat_statements shows as slow (mean > 100 ms or max > 300 ms),
re-timed on a local DB as each of the seven real role holders (rolled back). Each read is called the way the page calls it (file:line in Q)."""
import json, subprocess, sys, os, re
from walk import USERS

Q = [  # (name, page, sql template with {id}, id source sql)
    ('inbound_batch_margin', '/inbound/[id]/edit', "SELECT count(*) FROM inbound_batch_margin('{id}')", "SELECT id FROM inbound_batches"),
    ('coa_certificate_data', '/output/[id]/edit', "SELECT length(coa_certificate_data('{id}')::text)", "SELECT id FROM output_batches"),
    ('traceability_report_data', '/output/[id]/edit', "SELECT length(traceability_report_data('{id}')::text)", "SELECT id FROM output_batches"),
    ('shipment_document', '/sales/shipments/[id]', "SELECT length(shipment_document('{id}')::text)", "SELECT id FROM shipments"),
    ('payroll_payment_entries', '/hr/payroll/[id]', "SELECT count(*) FROM payroll_payment_entries(ARRAY['{id}']::uuid[])", "SELECT id FROM payroll_periods"),
    ('po_document_data', '/purchasing/orders/[id]', "SELECT length(po_document_data('{id}')::text)", "SELECT id FROM purchase_orders"),
    ('journal_lines_masked', '/finance/journal/[id]', "SELECT count(*) FROM journal_lines_masked WHERE entry_id = '{id}'", "SELECT id FROM journal_entries"),
    ('discharge_module_rows', '/operation/processing/[id]', "SELECT count(*) FROM discharge_module_rows WHERE run_id = '{id}'", "SELECT id FROM processing_runs"),
    ('bank_reconciliation_record', '/finance/bank/statements/[id]', "SELECT count(*) FROM bank_reconciliation_record WHERE statement_id = '{id}'", "SELECT id FROM bank_statements"),
    ('customer_credit_status', '/output/[id]/edit', "SELECT count(*) FROM customer_credit_status", "SELECT NULL::uuid"),
    ('employees_masked', '/hr/attendance/[id]', "SELECT count(*) FROM employees_masked", "SELECT NULL::uuid"),
]


def psql(db, sql, ok_fail=False):
    r = subprocess.run(['psql', f'host=/tmp/cwc port=55440 user=postgres dbname={db}', '-XAt', '-v', 'ON_ERROR_STOP=1'],
                       input=sql, capture_output=True, text=True)
    if r.returncode and not ok_fail:
        raise SystemExit(r.stderr[-2000:])
    return r.stdout


def main():
    db = sys.argv[1]
    limit = int(os.environ.get('PER', '25'))
    out = {}
    for name, page, tmpl, src in Q:
        ids = [l for l in psql(db, src + (" WHERE code !~ 'S[0-9]+$'" if 'FROM' in src and os.environ.get('ORIG_ONLY') else '') + f" LIMIT {limit}").splitlines()] or ['']
        worst = {}
        for role, uid in USERS.items():
            lines = ["SET statement_timeout = 0;",
                     """CREATE FUNCTION pg_temp.tq(q text, OUT ms numeric, OUT err text) LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz := clock_timestamp(); BEGIN EXECUTE q; ms := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
EXCEPTION WHEN OTHERS THEN ms := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1); err := left(SQLERRM, 60); END $$;""",
                     "BEGIN;", "SET LOCAL ROLE authenticated;",
                     f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null"""]
            for i in ids:
                q = tmpl.format(id=i).replace("'", "''")
                lines.append(f"SELECT 'R|' || ms || '|' || coalesce(err,'') FROM pg_temp.tq('{q}');")
            lines.append("ROLLBACK;")
            rs = [l.split('|', 2) for l in psql(db, "\n".join(lines)).splitlines() if l.startswith('R|')]
            ok = [float(r[1]) for r in rs if not r[2]]
            worst[role] = (max(ok) if ok else None, sum(1 for r in rs if r[2]), next((r[2] for r in rs if r[2]), ''))
        out[name] = {'page': page, 'docs': len(ids), 'worst': worst}
        cells = ''.join((f"{w[0]:.0f}" if w[0] is not None else 'refused').rjust(9) for w in worst.values())
        errs = sorted({w[2] for w in worst.values() if w[2]})
        print(f"{name:28}{page:32}{len(ids):>4}{cells}   {'; '.join(errs)[:80]}")
    if len(sys.argv) > 2:
        json.dump(out, open(sys.argv[2], 'w'))


if __name__ == '__main__':
    print(f"{'read':28}{'page':32}{'docs':>4}" + ''.join(r.rjust(9) for r in USERS))
    main()
