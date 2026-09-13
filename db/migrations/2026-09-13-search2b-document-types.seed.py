#!/usr/bin/env python3
"""SEARCH-2 · document_types 的 40 行种子 —— 逐条声明,由闸核对,不由人记得。

★ 每一行的 route / link_mode 都是【声明】的:round 6 实测证明它【推导不出来】
  (一支按"谁查这张表"推导的脚本在 31 张里错了至少 8 张 —— 它找到的是 JOIN 到这张表
  的页面,不是【关于】这张表的页面。SEARCH-0 早就量过:今天没有机读的"本页主语")。
  ☞ 所以它们由闸核对:route 要存在、link_mode='detail' 要有 [id]/page.tsx、
    'list_q' 要有一个读 q 的 page.tsx。那道闸会抓住我亲手犯过的两次错。

★ match_columns:只放【页面真的显示、而且 authenticated 真的 SELECT 得到】的列。
  闸断言每一列都 SELECT-granted —— 于是 employees 的 identity_no / work_pass_no /
  work_email / work_phone **按构造**进不来(它们对 authenticated 是 REVOKE 掉的)。
  那不是一条例外,那是 Tim 的裁定"搜索不比页面松"被正确地应用。
"""

# key, prefix, table, numbering, sequence, route, link_mode, label_col, match_cols
ROWS = [
    # ── A · 20 支专职 next_*_code(gapless:MAX(split_part)+1 + advisory lock)──
    ("assay_result",       "ASY",   "assay_results",              "gapless", None, "/inbound",                  "list_q", "notes",       ["lab_name","certificate_ref","sample_ref","notes"]),
    ("collection_chase",   "CHASE", "collection_chases",          "gapless", None, "/sales/customers",          "list_q", None,          []),
    ("cod",                "COD",   "certificates_of_destruction","gapless", None, "/output",                   "list_q", "void_reason", ["void_reason"]),
    ("container",          "CTR",   "containers",                 "gapless", None, "/logistics/containers",     "detail", "notes",       ["container_number","vessel","voyage","bl_number","notes"]),
    ("credit_note",        "CN",    "credit_notes",               "gapless", None, "/finance/credit-notes",     "list",   "reason",      ["reason"]),
    ("employee",           "EMP",   "employees",                  "gapless", None, "/hr/employees",             "detail", "legal_name",  ["legal_name","preferred_name","notes"]),
    ("expense_claim",      "CLM",   "expense_claims",             "gapless", None, "/hr/claims",                "list",   "description", ["description","no_receipt_reason","decision_notes"]),
    ("fixed_asset",        "FA",    "fixed_assets",               "gapless", None, "/finance/assets",           "detail", "description", ["description","category","notes"]),
    ("cash_forecast",      "FCST",  "cash_forecasts",             "gapless", None, "/finance/cash-forecast",    "list",   None,          []),
    ("leave_request",      "LV",    "leave_requests",             "gapless", None, "/hr/leave",                 "detail", "reason",      ["reason","certificate_ref","decision_notes"]),
    ("medical_claim",      "MC",    "medical_claims",             "gapless", None, "/hr/claims",                "list",   "description", ["description","receipt_ref","decision_notes"]),
    ("payroll_period",     "PAY",   "payroll_periods",            "gapless", None, "/hr/payroll",               "detail", "notes",       ["source_note","notes"]),
    ("pricing_formula",    "PF",    "pricing_formulas",           "gapless", None, "/tools/pricing/formulas",   "list",   "name",        ["name","notes"]),
    ("purchase_order",     "PO",    "purchase_orders",            "gapless", None, "/purchasing/orders",        "detail", "notes",       ["terms_text","notes","delivery_location"]),
    ("quote",              "QT",    "quotes",                     "gapless", None, "/sales/quotes",             "detail", "notes",       ["terms_text","notes","decline_reason"]),
    ("sales_order",        "SO",    "sales_orders",               "gapless", None, "/sales/orders",             "detail", "notes",       ["terms_text","notes","cancel_reason"]),
    ("shipment",           "SHP",   "shipments",                  "gapless", None, "/sales/shipments",          "detail", "notes",       ["notes"]),
    ("customer_statement", "STMT",  "customer_statements",        "gapless", None, "/sales/customers",          "list_q", None,          []),
    ("traceability_report","TRC",   "traceability_report_issues", "gapless", None, "/output",                   "list_q", None,          []),
    ("work_order",         "WO",    "work_orders",                "gapless", None, "/operation/orders",         "detail", "notes",       ["notes","close_reason"]),

    # ── B · 9 支触发器(gapped:nextval,★ 号码有洞,而且序列已跑在数据前面)──
    ("contract",           "CON",   "contracts",                  "gapped", "contract_code_seq",   "/contracts",              "list",   None,        []),
    ("customer",           "CUS",   "customers",                  "gapped", "customer_code_seq",   "/sales/customers",        "detail", "legal_name",["legal_name","short_name","address","country","tax_id","notes"]),
    ("inbound_batch",      "IN",    "inbound_batches",            "gapped", "inbound_code_seq",    "/inbound",                "list_q", "notes",     ["notes","import_permit_ref","source_reason_note"]),
    ("material",           "MAT",   "materials",                  "gapped", "material_code_seq",   "/materials",              "list_q", "name",      ["name","chemistry","spec","notes"]),
    ("output_batch",       "OUT",   "output_batches",             "gapped", "output_code_seq",     "/output",                 "list_q", "notes",     ["purity","notes"]),
    ("processing_run",     "PROC",  "processing_runs",            "gapped", "processing_code_seq", "/operation/processing",   "detail", "notes",     ["notes"]),
    ("stocktake",          "ST",    "stocktakes",                 "gapped", "stocktake_code_seq",  "/stocktakes",             "detail", "notes",     ["notes"]),
    ("supplier",           "SUP",   "suppliers",                  "gapped", "supplier_code_seq",   "/suppliers",              "list_q", "legal_name",["legal_name","short_name","address","country","tax_id","notes"]),
    ("task",               "TASK",  "tasks",                      "gapped", "task_code_seq",       "/tools/tasks",            "detail", "title",     ["title","description"]),

    # ── C · 13 处内联铸码(住在业务函数体里)──────────────────────────────
    ("invoice",            "INV",   "invoices",                   "gapless", None, "/finance/invoices",       "detail", "notes",  ["notes","terms_text","void_reason"]),
    ("management_pack",    "PACK",  "management_packs",           "gapless", None, "/finance/packs",          "detail", None,     []),
    ("bank_statement",     "BS",    "bank_statements",            "gapless", None, "/finance/bank/statements","detail", "notes",  ["file_name","notes"]),
    ("attendance_period",  "ATT",   "attendance_periods",         "gapless", None, "/hr/attendance",          "list",   None,     []),
    ("gst_period",         "GST",   "gst_periods",                "gapless", None, "/finance/gst",            "list",   None,     []),
    ("journal_entry",      "JE",    "journal_entries",            "gapless", None, "/finance/journal",        "detail", "memo",   ["memo"]),
    ("expense",            "EXP",   "expenses",                   "gapless", None, "/finance/expenses",       "detail", "notes",  ["payee_name","notes"]),
    ("freight_document",   "FRT",   "freight_documents",          "gapless", None, "/finance/freight",        "detail", "notes",  ["notes","reversal_reason"]),
    ("wht_remittance",     "WHT",   "wht_remittances",            "gapless", None, "/finance/wht",            "list",   None,     []),

    # ── D · 1 支参数化(fin_next_payment_code)—— ★ 一张表铸两个前缀 ────────
    #   它【已经】是 prefix-as-data 的先例:前缀由调用方传进来
    #   (record_payment:635 的 CASE WHEN p_direction='in' THEN 'RCPT' ELSE 'PMT' END)。
    ("payment_receipt",    "RCPT",  "payments",                   "gapless", None, "/finance/payments",       "detail", "notes",  ["notes"]),
    ("payment_out",        "PMT",   "payments",                   "gapless", None, "/finance/payments",       "detail", "notes",  ["notes"]),
]

def lit(v):
    if v is None: return "NULL"
    return "'" + str(v).replace("'", "''") + "'"

def arr(xs):
    if not xs: return "'{}'::text[]"
    return "ARRAY[" + ", ".join(lit(x) for x in xs) + "]::text[]"

assert len(ROWS) == 40, f"expected 40 rows, got {len(ROWS)}"
assert len({r[1] for r in ROWS}) == 40, "prefixes must be unique"
assert len({r[0] for r in ROWS}) == 40, "keys must be unique"
gapped = [r for r in ROWS if r[3] == "gapped"]
assert len(gapped) == 9, f"expected 9 gapped, got {len(gapped)}"
assert all(r[4] for r in gapped), "every gapped row needs a sequence_name"
assert all(r[4] is None for r in ROWS if r[3] == "gapless"), "gapless rows must have no sequence"

print("INSERT INTO public.document_types")
print("    (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns)")
print("VALUES")
out = []
for k, p, t, n, s, r, lm, lc, mc in ROWS:
    out.append(f"    ({lit(k)}, {lit(p)}, {lit(t)}, {lit(n)}, {lit(s)}, {lit(r)}, {lit(lm)}, {lit(lc)}, {arr(mc)})")
print(",\n".join(out) + ";")
