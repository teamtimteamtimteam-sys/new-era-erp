#!/usr/bin/env python3
"""LOCAL ONLY. record_trail(subject, id, 20) on every chain detail page × every document × seven roles; time inside the database.
usage: trail_survey.py <db> [out.json]   (env ORIG_ONLY=1 skips the scale copies, codes ending S<n>)"""
import json, subprocess, sys, os, re
from walk import USERS

SUBJ = [  # (route, subject, table)
    ('/purchasing/orders/[id]', 'purchase_order', 'purchase_orders'), ('/inbound/[id]/edit', 'inbound_batch', 'inbound_batches'),
    ('/finance/payables/[batchId]', 'payable', 'inbound_batches'), ('/finance/payment-requests/[id]', 'payment_request', 'payment_requests'),
    ('/finance/payments/[id]', 'payment', 'payments'), ('/finance/bank/statements/[id]', 'bank_statement', 'bank_statements'),
    ('/operation/orders/[id]', 'work_order', 'work_orders'), ('/operation/processing/[id]', 'processing_run', 'processing_runs'),
    ('/output/[id]/edit', 'output_batch', 'output_batches'), ('/sales/quotes/[id]', 'quote', 'quotes'),
    ('/sales/orders/[id]', 'sales_order', 'sales_orders'), ('/sales/shipments/[id]', 'shipment', 'shipments'),
    ('/logistics/containers/[id]', 'container', 'containers'), ('/finance/invoices/[id]', 'invoice', 'invoices'),
    ('/finance/credit-notes/[id]', 'credit_note', 'credit_notes'), ('/hr/attendance/[id]', 'attendance_period', 'attendance_periods'),
    ('/hr/overtime/[id]', 'overtime_batch', 'overtime_batches'), ('/hr/leave/[id]', 'leave_request', 'leave_requests'),
    ('/hr/payroll/[id]', 'payroll_period', 'payroll_periods'), ('/finance/journal/[id]', 'journal_entry', 'journal_entries'),
]


def psql(db, sql):
    r = subprocess.run(['psql', f'host=/tmp/cwc port=55440 user=postgres dbname={db}', '-XAt', '-v', 'ON_ERROR_STOP=1'],
                       input=sql, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr[-2000:])
    return r.stdout


def main():
    db = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    calls = []
    for route, subj, table in SUBJ:
        docs = json.loads(psql(db, f"select coalesce(json_agg(json_build_object('id',id,'code',code)),'[]') from public.{table}"))
        if os.environ.get('SAMPLE'):
            k = max(1, len(docs) // int(os.environ['SAMPLE']))
            docs = docs[::k]
        for d in docs:
            if os.environ.get('ORIG_ONLY') and re.search(r'S[0-9]+$', d['code'] or ''):
                continue
            calls.append((route, subj, d['id'], d['code']))
    print(f'{len(calls)} trails per role', file=sys.stderr)
    results = []
    for role, uid in USERS.items():
        lines = ["SET statement_timeout = 0;",
                 """CREATE FUNCTION pg_temp.tt(p_subject text, p_id text, OUT ms numeric, OUT n int, OUT err text)
LANGUAGE plpgsql AS $$ DECLARE t0 timestamptz := clock_timestamp(); BEGIN
  SELECT count(*) INTO n FROM public.record_trail(p_subject, p_id, 20);
  ms := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
EXCEPTION WHEN OTHERS THEN ms := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1); err := split_part(SQLERRM, '|', 1); END $$;""",
                 "BEGIN;", "SET LOCAL ROLE authenticated;",
                 f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null"""]
        for i, (route, subj, did, code) in enumerate(calls):
            lines.append(f"SELECT 'R|{i}|' || ms || '|' || coalesce(n::text,'') || '|' || coalesce(err,'') FROM pg_temp.tt('{subj}', '{did}');")
        lines.append("ROLLBACK;")
        for l in psql(db, "\n".join(lines)).splitlines():
            if l.startswith('R|'):
                _, i, ms, n, err = l.split('|', 4)
                route, subj, did, code = calls[int(i)]
                results.append({'role': role, 'route': route, 'subject': subj, 'id': did, 'code': code, 'ms': float(ms),
                                'rows': int(n) if n else None, 'err': err or None})
        print(f'{role} done', file=sys.stderr)
    if out:
        json.dump(results, open(out, 'w'), ensure_ascii=False)
    roles = list(USERS)
    print('route'.ljust(32) + ''.join(x.rjust(10) for x in roles) + '   worst doc')
    for route, subj, _ in SUBJ:
        cells = []
        for ro in roles:
            rs = [r for r in results if r['route'] == route and r['role'] == ro and not r['err']]
            cells.append(max(rs, key=lambda r: r['ms']) if rs else None)
        if not any(cells):
            refused = sum(1 for r in results if r['route'] == route and r['err'])
            print(route.ljust(32) + (f'   (only refusals: {refused})' if refused else '   (no rows)'))
            continue
        w = max((c for c in cells if c), key=lambda c: c['ms'])
        print(route.ljust(32) + ''.join((f"{c['ms']:.0f}" if c else 'refused').rjust(10) for c in cells) + f"   {w['code']}")
    errs = {}
    for r in results:
        if r['err']:
            errs[r['err']] = errs.get(r['err'], 0) + 1
    print('named refusals/errors:', errs)


if __name__ == '__main__':
    main()
