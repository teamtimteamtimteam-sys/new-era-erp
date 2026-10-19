#!/usr/bin/env python3
"""NOROLE-SURFACE — compare a pre-migration per-role reading with a post-migration one (dry run or live).

For every identity (7 role copies · norole · display) and every object / bucket, the EXPECTED post value is derived from the pre value
and the rulings (Step 0 §12, accepted by Tim 2026-10-19): an object or bucket whose predicate the identity's codes pass keeps exactly its
pre reading (same row count, same digest); one it does not pass reads 0 (user_roles: its own grant row stays). Storage: read / upload by
the record's code; UPDATE gone on the 4 attachment buckets; DELETE only for an orphan by the upload code on the 4 attachment buckets and
cod / po / traceability; the other 5 buckets unchanged. Any difference between EXPECTED and ACTUAL is printed and the exit code is 1.
Usage: compare-readings.py <pre.log> <post.log> <role-codes.txt> <orphans.txt>
  role-codes: lines ROLECODES|<role>|<code,code,…>; orphans: lines ORPHAN|<bucket>|<name> — existing files no record points at
  (those, and only those, become deletable by the delete code).
"""
import re, sys

def parse(path):
    rel, stor, own = {}, {}, {}
    for line in open(path, encoding="utf-8", errors="replace"):
        line = re.sub(r"^.*NOTICE:\s+", "", line.strip())
        p = line.split("|")
        if p[0] == "REL":
            rel[(p[2], p[3])] = (p[4], p[5])
        elif p[0] == "STOR":
            stor[(p[2], p[3])] = dict(kv.split("=") for kv in p[4:])
        elif p[0] == "OWN":
            own[p[2]] = dict(kv.split("=") for kv in p[3:])
    return rel, stor, own

def codes(path):
    out = {"norole": set(), "display": {"data.view_floor_board"}}
    for line in open(path):
        p = line.strip().split("|")
        if p[0] == "ROLECODES":
            out[p[1]] = set(p[2].split(","))
    return out

ANY = lambda *cs: (lambda C: bool(C & set(cs)))
REL_PRED = {
    # Tim 2026-10-19 (build Q21): the audit trails read these rows too — module.hr.view (employee page) · data.view_change_log
    "user_roles": ANY("action.manage_permissions", "module.hr.view", "data.view_change_log"),
    "roles": ANY("action.manage_permissions", "data.view_change_log"),
    "role_permissions": ANY("action.manage_permissions", "data.view_change_log"),
    "permissions": ANY("action.manage_permissions", "data.view_change_log"),
    "metal_prices": ANY("module.pricing.view", "module.suppliers.view", "module.inventory.view", "module.materials.view"),
    "metal_price_indices": ANY("module.pricing.view", "module.suppliers.view", "action.metal_prices"),
    "pricing_settings": ANY("module.pricing.view", "module.inventory.view"),
    "accounts": ANY("module.finance.view"), "collection_promise_status": ANY("module.finance.view"),
}
# bucket: (read, upload, delete-orphan or None)
B = {
    "cn-documents": (ANY("module.finance.view"), ANY("module.finance.edit"), None),
    "cod-documents": (ANY("action.issue_cod"), ANY("action.issue_cod"), ANY("action.issue_cod")),
    "company-assets": (ANY("module.finance.view", "module.purchasing.view", "module.sales.view", "action.ship_goods", "action.issue_cod",
                           "module.processing.view", "module.output.view", "module.compliance.view"), None, None),
    "customer-attachments": (ANY("module.customers.view"), ANY("module.customers.edit"), ANY("module.customers.edit")),
    "finance-attachments": (ANY("module.finance.view"), ANY("module.finance.edit"), ANY("module.finance.edit")),
    "invoice-documents": (ANY("module.finance.view"), ANY("module.finance.edit"), None),
    "material-attachments": (ANY("module.materials.view"), ANY("module.materials.edit"), ANY("module.materials.edit")),
    "po-documents": (ANY("module.purchasing.view"), ANY("module.purchasing.edit"), ANY("module.purchasing.edit")),
    "qt-documents": (ANY("module.sales.view"), ANY("module.sales.edit"), None),
    "shipment-documents": (ANY("module.sales.view", "action.ship_goods"), ANY("action.ship_goods"), None),
    "so-documents": (ANY("module.sales.view"), ANY("module.sales.edit"), None),
    "statement-documents": (ANY("module.finance.view"), ANY("module.finance.edit"), None),
    "supplier-attachments": (ANY("module.suppliers.view"), ANY("module.suppliers.edit"), ANY("module.suppliers.edit")),
    "traceability-documents": (ANY("module.sales.view", "module.processing.view"), ANY("module.sales.edit", "module.processing.edit"),
                               ANY("module.sales.edit", "module.processing.edit")),
}
ATTACH = {"customer-attachments", "finance-attachments", "material-attachments", "supplier-attachments"}

def tf(b): return "t" if b else "f"

def main():
    pre_rel, pre_st, pre_own = parse(sys.argv[1])
    post_rel, post_st, post_own = parse(sys.argv[2])
    C = codes(sys.argv[3])
    orphans = {}
    for line in open(sys.argv[4]):
        q = line.strip().split("|")
        if q[0] == "ORPHAN": orphans[q[1]] = orphans.get(q[1], 0) + 1
    diffs, rows = [], []
    ids = sorted({i for i, _ in pre_rel})
    if len(ids) != 9 or len(pre_st) < 9 * 19 or len(post_st) < 9 * 19:
        print("✗ a reading is short (identities %d, pre stor %d, post stor %d) — blindness, not a comparison" % (len(ids), len(pre_st), len(post_st)))
        return 1
    for (i, o), pre in sorted(pre_rel.items()):
        passes = REL_PRED[o](C[i])
        exp = pre if passes else ("rows=0", "digest=d41d8cd98f00b204e9800998ecf8427e")
        act = post_rel.get((i, o))
        rows.append((i, o, pre[0], act[0] if act else "?", "keeps" if passes else "closed"))
        if act != exp:
            diffs.append(f"REL {i} {o}: pre={pre} expected={exp} actual={act}")
    for i in ids:
        if post_own.get(i) != pre_own.get(i):
            diffs.append(f"OWN {i}: pre={pre_own.get(i)} post={post_own.get(i)}")
    for (i, b), pre in sorted(pre_st.items()):
        exp = dict(pre)
        if b in B:
            rd, up, de = B[b]
            exp["visible"] = pre["visible"] if rd(C[i]) else "0"
            if up: exp["upload"] = tf(up(C[i]))
            if b in ATTACH: exp["update"] = "f"
            if de: exp["delete_orphan"] = tf(de(C[i]))
            if de: exp["deletable_existing"] = str(orphans.get(b, 0)) if de(C[i]) else "0"
            if b == "company-assets": pass  # upload / update / delete unchanged (action.finance_settings)
        act = post_st.get((i, b))
        if act != exp:
            diffs.append(f"STOR {i} {b}: pre={pre} expected={exp} actual={act}")
    print("== per-role comparison: %d identities · %d relation readings · %d bucket readings" % (len(ids), len(pre_rel), len(pre_st)))
    for d in diffs:
        print("✗ " + d)
    print("COMPARE_RESULT=" + ("clean" if not diffs else "%d differences" % len(diffs)))
    return 1 if diffs else 0

if __name__ == "__main__":
    sys.exit(main())
