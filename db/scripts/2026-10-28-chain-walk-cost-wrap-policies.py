#!/usr/bin/env python3
"""CHAIN-WALK-COST (Tim 2026-10-28 Q1): rewrite every table mirror's CREATE POLICY so each permission check is evaluated
ONCE per statement instead of once per row:  has_permission('x')  ->  (SELECT has_permission('x'))  (same for has_any_permission),
and the reader's identity the same way:  current_user_employee() -> (SELECT current_user_employee()),  auth.uid() -> (SELECT auth.uid()).
(The identity calls take no argument and depend only on the session; on the seeded rebuild the leave policy's per-row
current_user_employee() was 2,617 calls and 111 ms of one people-chain walk.)

Why it is the same answer: has_permission() reads only the session (auth.uid() -> the reader's grants); its argument in every policy
is a literal (measured: 734 + 20 calls, 0 with a row-dependent argument). Wrapped in a scalar sub-select, PostgreSQL plans it as an
InitPlan - evaluated once, the value reused for every row. Without the wrap it is called per row (SECURITY DEFINER + SET search_path,
never inlined), and each call re-aggregates the reader's roles: ~177 buffer hits a row (docs/surveys/CHAIN-WALK-COST/README.md).

Only text inside a CREATE POLICY statement is touched (table mirrors also carry CREATE FUNCTION bodies - those are left alone).
The live side is the migration (db/migrations/2026-10-28-chain-walk-cost.sql), which applies the same transformation to pg_policies;
db/gate.py's mirror verdict compares the two catalogs, so a difference between this rewrite and the migration fails the gate.
Usage: python3 db/scripts/2026-10-28-chain-walk-cost-wrap-policies.py [--check]   (--check: exit 1 if anything would change)"""
import glob
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
CALL = re.compile(r'\b(has_permission|has_any_permission)\(|\bcurrent_user_employee\(\)|\bauth\.uid\(\)')
POLICY = re.compile(r'CREATE POLICY\b.*?;', re.S)


def close_paren(s, i):
    """index of the ')' matching the '(' at s[i], skipping quoted strings"""
    depth, q = 0, False
    while i < len(s):
        c = s[i]
        if q:
            if c == "'":
                if i + 1 < len(s) and s[i + 1] == "'":
                    i += 1
                else:
                    q = False
        elif c == "'":
            q = True
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError('unbalanced parentheses')


def already_wrapped(s, start):
    return re.search(r'\(\s*SELECT\s+$', s[:start], re.I) is not None


def wrap_policy(stmt):
    out, i, n = [], 0, 0
    for m in CALL.finditer(stmt):
        if m.start() < i:
            continue
        if already_wrapped(stmt, m.start()):
            continue
        end = m.end() - 1 if m.group(0).endswith('()') else close_paren(stmt, m.end() - 1)
        out.append(stmt[i:m.start()])
        out.append('(SELECT ' + stmt[m.start():end + 1] + ')')
        i = end + 1
        n += 1
    out.append(stmt[i:])
    return ''.join(out), n


def main():
    check = '--check' in sys.argv
    files = changed = calls = policies = 0
    for f in sorted(glob.glob(os.path.join(ROOT, 'db', 'tables', '*.sql'))):
        src = open(f, encoding='utf8').read()
        total = 0

        def repl(m):
            nonlocal total
            new, k = wrap_policy(m.group(0))
            total += k
            return new
        new = POLICY.sub(repl, src)
        files += 1
        if new != src:
            changed += 1
            calls += total
            policies += sum(1 for p in POLICY.findall(src) if wrap_policy(p)[1])
            if not check:
                open(f, 'w', encoding='utf8').write(new)
    print(f'WRAP|files {files} · changed {changed} · policies rewritten {policies} · calls wrapped {calls}{" (check only)" if check else ""}')
    if check and changed:
        sys.exit(1)


if __name__ == '__main__':
    main()
