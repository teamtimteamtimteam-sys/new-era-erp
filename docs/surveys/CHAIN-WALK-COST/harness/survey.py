#!/usr/bin/env python3
"""LOCAL ONLY. Every chain detail page × every document × seven roles: document_chain_walk time inside the database.
usage: survey.py <db> [out.json] [--rounds N]
One psql session per role (warm, like a pooled PostgREST connection); each walk timed with clock_timestamp() around it,
as the role's real account (SET ROLE authenticated + JWT claims); everything rolled back."""
import json, subprocess, sys, os, re
SP = os.path.dirname(os.path.abspath(__file__))
from walk import USERS, CH

PAGES = [  # (route, table, [(chain, step)])  — app/**/page.tsx <DocumentChains …>
    ('/purchasing/orders/[id]', 'purchase_orders', [('purchasing', 'purchase_order')]),
    ('/inbound/[id]/edit', 'inbound_batches', [('purchasing', 'inbound_batch'), ('processing', 'input_batches')]),
    ('/inbound/[id]/assays/[assayId]', 'assay_results', [('purchasing', 'assay')]),
    ('/finance/payables/[batchId]', 'inbound_batches', [('purchasing', 'payable')]),
    ('/finance/payment-requests/[id]', 'payment_requests', [('purchasing', 'payment_request')]),
    ('/finance/payments/[id]', 'payments', [('purchasing', 'payment'), ('sales', 'receipt')]),
    ('/finance/bank/statements/[id]', 'bank_statements', [('purchasing', 'bank_reconciliation')]),
    ('/operation/orders/[id]', 'work_orders', [('processing', 'work_order')]),
    ('/operation/processing/[id]', 'processing_runs', [('processing', 'processing_run')]),
    ('/output/[id]/edit', 'output_batches', [('processing', 'output_batches')]),
    ('/sales/quotes/[id]', 'quotes', [('sales', 'quote')]),
    ('/sales/orders/[id]', 'sales_orders', [('sales', 'sales_order')]),
    ('/sales/shipments/[id]', 'shipments', [('sales', 'shipment')]),
    ('/logistics/containers/[id]', 'containers', [('sales', 'container')]),
    ('/finance/invoices/[id]', 'invoices', [('sales', 'invoice')]),
    ('/finance/credit-notes/[id]', 'credit_notes', [('sales', 'credit_note')]),
    ('/hr/attendance/[id]', 'attendance_periods', [('people', 'attendance')]),
    ('/hr/overtime/[id]', 'overtime_batches', [('people', 'overtime')]),
    ('/hr/leave/[id]', 'leave_requests', [('people', 'leave')]),
    ('/hr/payroll/[id]', 'payroll_periods', [('people', 'payroll_period')]),
    ('/finance/journal/[id]', 'journal_entries', [('people', 'payroll_payment')]),
]


def psql(db, sql):
    r = subprocess.run(['psql', f'host=/tmp/cwc port=55440 user=postgres dbname={db}', '-XAt', '-v', 'ON_ERROR_STOP=1'],
                       input=sql, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr[-2000:])
    return r.stdout


def main():
    db = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith('--') else None
    rounds = int(sys.argv[sys.argv.index('--rounds') + 1]) if '--rounds' in sys.argv else 1
    types = json.loads(psql(db, "select json_agg(json_build_object('key',key,'table',table_name,'prefix',prefix)) from document_types"))
    calls = []  # (route, chain, step, key, id, code)
    for route, table, specs in PAGES:
        flt = " where source_type = 'payroll'" if table == 'journal_entries' else ''   # the journal page draws the chain only for payroll payments
        docs = json.loads(psql(db, f"select coalesce(json_agg(json_build_object('id',id,'code',code) order by code),'[]') from public.{table}{flt}"))
        mine = [t for t in types if t['table'] == table]
        if os.environ.get('SAMPLE'):
            k = max(1, len(docs) // int(os.environ['SAMPLE']))
            docs = docs[::k]
        for d in docs:
            if os.environ.get('ORIG_ONLY') and re.search(r'S[0-9]+$', d['code'] or ''):
                continue
            me = mine[0] if len(mine) == 1 else next((t for t in mine if (d['code'] or '').startswith(t['prefix'] + '-')), None)
            if not me:
                continue
            for chain, step in specs:
                c = CH[chain]
                at = c['steps'].index(step)
                if me['key'] not in c['def']['steps'][at]['keys']:
                    continue
                calls.append((route, chain, step, me['key'], d['id'], d['code']))
    if os.environ.get('REPS'):
        calls = [(x['route'], x['chain'], x['step'], x['key'], x['id'], x['code']) for x in json.load(open(os.environ['REPS']))]
    print(f'{len(calls)} walks per role', file=sys.stderr)
    results = []
    for role, uid in USERS.items():
        lines = ["SET statement_timeout = 0;",
                 """CREATE FUNCTION pg_temp.tw(p_chain jsonb, p_step int, p_key text, p_id uuid, OUT ms numeric, OUT n int, OUT err text)
LANGUAGE plpgsql AS $$ DECLARE t0 timestamptz := clock_timestamp(); BEGIN
  SELECT count(*) INTO n FROM public.""" + os.environ.get('WALKFN', 'document_chain_walk') + """(p_chain, p_step, p_key, p_id);
  ms := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
EXCEPTION WHEN OTHERS THEN ms := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1); err := SQLERRM; END $$;""",
                 "BEGIN;", f"SELECT set_config('app.chain_walk_budget_ms', '{os.environ.get('BUDGET_MS','')}', true) \\g /dev/null", "SET LOCAL ROLE authenticated;",
                 f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null"""]
        for rnd in range(rounds):
            for i, (route, chain, step, key, did, code) in enumerate(calls):
                d = json.dumps(CH[chain]['def']).replace("'", "''")
                at = CH[chain]['steps'].index(step)
                lines.append(f"SELECT 'R|{rnd}|{i}|' || ms || '|' || coalesce(n::text,'') || '|' || coalesce(err,'') FROM pg_temp.tw('{d}'::jsonb, {at}, '{key}', '{did}');")
        lines.append("ROLLBACK;")
        o = psql(db, "\n".join(lines))
        for l in o.splitlines():
            if l.startswith('R|'):
                _, rnd, i, ms, n, err = l.split('|', 5)
                route, chain, step, key, did, code = calls[int(i)]
                results.append({'role': role, 'round': int(rnd), 'route': route, 'chain': chain, 'step': step, 'key': key,
                                'id': did, 'code': code, 'ms': float(ms), 'rows': int(n) if n else None, 'err': err or None})
        print(f'{role} done', file=sys.stderr)
    if out:
        json.dump(results, open(out, 'w'), ensure_ascii=False)
    # summary: worst per (route, role)
    worst = {}
    for r in results:
        k = (r['route'], r['role'])
        if k not in worst or r['ms'] > worst[k]['ms']:
            worst[k] = r
    roles = list(USERS)
    print('route'.ljust(34) + ''.join(x.rjust(10) for x in roles) + '   worst doc')
    for route, _, _ in PAGES:
        cells = [worst.get((route, ro)) for ro in roles]
        if not any(cells):
            print(route.ljust(34) + '   (no rows)')
            continue
        w = max((c for c in cells if c), key=lambda c: c['ms'])
        print(route.ljust(34) + ''.join((f"{c['ms']:.0f}" if c else '-').rjust(10) for c in cells) + f"   {w['code']} ({w['chain']})")
    errs = [r for r in results if r['err']]
    print(f'errors: {len(errs)}', *[f"  {e['role']} {e['code']} {e['chain']}: {e['err'][:120]}" for e in errs[:10]], sep='\n')


if __name__ == '__main__':
    main()
