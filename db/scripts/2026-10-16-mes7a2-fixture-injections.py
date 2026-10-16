#!/usr/bin/env python3
"""MES-7a-2:fixture 266 的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。
外加本刀给既有 fixture 加的一臂:263 的 HOLD(质量暂扣挡 maintenance_issue)。

做法照 db/scripts/2026-10-15-mes7a1-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 266 每进一臂先打一行 NOTICE "fixture 266 · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着
"FIXTURE 266 <臂>",或者它发生时最后打出的那一臂就是 <臂>。RECON 不是一行 NOTICE —— 它在每一步动钱之后跑,所以只认 ERROR 里的
"FIXTURE 266 RECON"。
措辞臂 ㉛ 的两格(wording-drift-mes7a2 · wording-part-mes7a2)是 scripts/check-trail-wording.mjs 的 TRAIL_WORDING_FAULT,不碰库,不在这里。
【257 的那一项没有注入格,照直说】257 的滚动恒等式多了 issued_to_maintenance 一项;257 自己的数据里没有一条保养流水,于是那一项恒为 0,
  把它从视图里拿掉 257 也照样绿 —— 那一项在 257 上是空转的,真正咬人的是 266 的 ROLL(下面两格)。
跑法:python3 db/scripts/2026-10-16-mes7a2-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"(绝不对着线上)
退出码:0 = 每一支 fixture 干净跑绿、每一格都红在它的那一臂、266 的每一臂都至少红过一次;1 = 否则。
"""
import pathlib
import re
import subprocess
import sys

DSN = sys.argv[1]
if "supabase" in DSN or "pooler" in DSN:
    sys.exit("refusing a live DSN — run against a throwaway rebuild")
ROOT = pathlib.Path(".")


def body_of(num, stem=None):
    src = next(ROOT.glob(f"db/fixtures/{num}-{stem or ''}*.sql")).read_text()
    assert src.count("\nBEGIN;\n") == 1 and src.rstrip().endswith("ROLLBACK;"), f"fixture {num} shape changed"
    return src.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]


ISSUE = "public.issue_spare_parts(uuid, date, jsonb)"
RET = "public.return_spare_parts(uuid, numeric, date, text)"
GPW = "public.guard_part_issue_write()"
GMM = "public.guard_maintenance_movement()"
GMC = "public.guard_maintenance_capitalise_parts()"
SPLIT = "public.reprice_split(numeric, numeric, numeric, numeric, numeric)"
RIB = "public.reprice_inbound_batch(uuid, numeric, text, numeric, text)"
PRV = "public.preview_reprice_inbound_batch(uuid, numeric, text)"
GQH = "public.guard_quality_hold()"
ICR = "public.inventory_control_reconciliation(date)"
JRR = "public.journal_entry_reversal_route(uuid)"
TSM = "public.trail_subject_members()"


def patch_fn(sig, old, new):
    o, n = old.replace("'", "''"), new.replace("'", "''")
    return f"""DO $inj$ DECLARE d text; d2 text; BEGIN
    d := pg_get_functiondef('{sig}'::regprocedure);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{sig}'; END IF;
    EXECUTE d2;
END $inj$;
"""


def patch_view(name, old, new):
    o, n = old.replace("'", "''"), new.replace("'", "''")
    return f"""DO $inj$ DECLARE d text; d2 text; BEGIN
    d := pg_get_viewdef('public.{name}'::regclass);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{name}'; END IF;
    EXECUTE format('CREATE OR REPLACE VIEW public.%I WITH (security_invoker = off) AS %s', '{name}', d2);
END $inj$;
"""


CASES_266 = [
    # ── REG ──
    ("REG", "6800 is renamed", "UPDATE public.accounts SET name_en = 'Repairs' WHERE code = '6800';\n"),
    ("REG", "the spare_part note still says no batch traceability",
     "UPDATE public.material_kinds SET notes = '机器的备件。【不按批次追溯】' WHERE code = 'spare_part';\n"),
    ("REG", "part issues are not under the equipment trail",
     patch_fn(TSM, "('equipment',          5, 'maintenance_part_issues'", "('equipmentx',         5, 'maintenance_part_issues'")),
    ("REG", "pending_values lost its V21 arm", patch_view("pending_values", "'V21'::text AS value_code", "'V2X'::text AS value_code")),
    # ── PERM ──
    ("PERM", "anyone may issue parts (the code check is gone)",
     patch_fn(ISSUE, "    PERFORM require_permission('module.inventory.edit');\n", "")),
    # ── REFUSE ──
    ("REFUSE", "a capitalised record takes parts", patch_fn(ISSUE, "IF v_maint.capitalised OR v_maint.capitalised_expense_id IS NOT NULL THEN", "IF false THEN")),
    ("REFUSE", "a battery batch is issued as a spare part", patch_fn(ISSUE, "IF v_b.kind_code IS DISTINCT FROM 'spare_part' THEN", "IF false THEN")),
    ("REFUSE", "an unpriced batch is issued at nothing", patch_fn(ISSUE, "IF v_b.unit_price IS NULL THEN", "IF false THEN")),
    ("REFUSE", "more than is available is asked for", patch_fn(ISSUE, "IF v_qty > v_avail THEN", "IF false THEN")),
    ("REFUSE", "two lines of one batch are judged one by one, not summed",
     patch_fn(ISSUE, "sum((l ->> 'quantity')::numeric)", "max((l ->> 'quantity')::numeric)")),
    ("REFUSE", "a future issue date is accepted", patch_fn(ISSUE, "IF p_issued_on > v_today THEN", "IF false THEN")),
    # ── VOID ──
    ("VOID", "maintenance records gain a void column", "ALTER TABLE public.equipment_maintenance ADD COLUMN voided_at timestamptz;\n"),
    # ── ISSUE ──
    ("ISSUE", "an issue is charged to miscellaneous, not to repairs",
     patch_fn(ISSUE, "jsonb_build_object('account_code', '6800', 'side', 'debit',", "jsonb_build_object('account_code', '6900', 'side', 'debit',")),
    ("ISSUE", "an issue is filed as a write-off", patch_fn(ISSUE, "'maintenance_part', v_id,", "'writeoff', v_id,")),
    ("ISSUE", "a part-issue entry can be reversed from the journal page",
     patch_fn(JRR, "'asset_disposal', 'maintenance_part') THEN", "'asset_disposal') THEN")),
    # ── RETURN ──
    ("RETURN", "a return needs no reason", patch_fn(RET, "IF p_reason IS NULL OR btrim(p_reason) = '' THEN", "IF false THEN")),
    ("RETURN", "more can come back than went out", patch_fn(RET, "IF p_quantity > v_left THEN", "IF false THEN")),
    ("RETURN", "a return may be dated before its issue", patch_fn(RET, "IF p_returned_on < v_iss.business_date THEN", "IF false THEN")),
    ("RETURN", "a return credits miscellaneous instead of repairs",
     patch_fn(RET, "jsonb_build_object('account_code', '6800', 'side', 'credit',", "jsonb_build_object('account_code', '6900', 'side', 'credit',")),
    ("RETURN", "a return may cite a return", patch_fn(RET, "WHERE i.id = p_issue_id AND i.kind = 'issue'", "WHERE i.id = p_issue_id")),
    # ── DIRECT ──
    ("DIRECT", "a direct insert is refused by RLS without a name", patch_fn(GPW, "IF row_security_active(TG_RELID) THEN", "IF false THEN")),
    ("DIRECT", "an issue row can be changed", patch_fn(GPW, "IF TG_OP IN ('UPDATE', 'DELETE') THEN", "IF false THEN")),
    ("DIRECT", "an owner path writes a maintenance movement", patch_fn(GMM, "IF COALESCE(current_setting('evoltrya.part_issue_ctx', true), '') = '' THEN", "IF false THEN")),
    # ── CAPITAL ──
    ("CAPITAL", "a record with parts is capitalised", patch_fn(GMC, "IF v_n > 0 THEN", "IF v_n > 999999 THEN")),
    # ── REPRICE ──
    ("REPRICE", "reprice_split ignores what went to maintenance", patch_fn(SPLIT, "COALESCE(p_maintenance_qty, 0)", "0")),
    ("REPRICE", "the maintenance share is posted to 5000",
     patch_fn(RIB, "                'account_code', '6800',", "                'account_code', '5000',")),
    ("REPRICE", "the preview forgets what went to maintenance", patch_fn(PRV, "inbound_batch_maintenance_net_qty(p_inbound_batch_id)", "0")),
    # ── HOLD ──
    ("HOLD", "the quality hold lets an issue through", patch_fn(GQH, "('processing_consume', 'sale', 'maintenance_issue')", "('processing_consume', 'sale')")),
    # ── ROLL ──
    ("ROLL", "the roll-forward drops issues to maintenance",
     patch_view("stock_rollforward_monthly_all", "ARRAY['maintenance_issue'::text, 'maintenance_return'::text]", "ARRAY['x'::text]")),
    ("ROLL", "the balance tree does not subtract maintenance from unexplained",
     patch_view("batch_balance_tree_all", ") - n.maintenance) - n.consumed)", ")) - n.consumed)")),
    # ── V21 ──
    ("V21", "V21 keeps a material whose minimum stock is set", patch_view("pending_values", "m.safety_stock_qty IS NULL", "true")),
    ("V21", "V21 lists materials that are not spare parts", patch_view("pending_values", "(m.kind_code = 'spare_part'::text) AND (m.safety_stock_qty IS NULL)", "true AND (m.safety_stock_qty IS NULL)")),
    # ── RECON ──
    # 只有勾稽看得见的那一种缺陷:一次出库在总账上把 1200 解除了两次(第二张分录不挂在那一行出库上,所以 ISSUE 臂读的那张分录照样对)。
    # ★ 不是"把勾稽里 maintenance_part 那一支归因拿掉"—— 那一支只决定差额【归到哪一类】,不决定【未解释】:未解释比的是 1200 的
    #   账户余额与明细(剩余 × 落地单价),归因拿掉之后两边仍然相等。第一版就注入了它,而它没有红 —— 那是信息:注入的不是这条断言看得见的性质。
    ("RECON", "an issue relieves stock twice in the ledger",
     patch_fn(ISSUE, "        v_out := v_out || jsonb_build_object('issue_id'",
              "        PERFORM post_journal_entry(p_issued_on, 'dup', 'manual', NULL, jsonb_build_array("
              "jsonb_build_object('account_code', '6800', 'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', v_amt), "
              "jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt)));\n"
              "        v_out := v_out || jsonb_build_object('issue_id'")),
    # ── TRAIL ──
    ("TRAIL", "part issues are not change-logged", "DROP TRIGGER zzz_change_log ON public.maintenance_part_issues;\n"),
]

OTHER = [
    ("263", "a-quality-hold", "FIXTURE 263 HOLD", "the quality hold lets an issue to maintenance through",
     patch_fn(GQH, "('processing_consume', 'sale', 'maintenance_issue')", "('processing_consume', 'sale')")),
]


def run(body, injection):
    sql = "BEGIN;\n" + injection + "\n" + body + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def where_red(out, num):
    last_arm, first_err = None, None
    for ln in out.splitlines():
        m = re.search(rf"fixture {num} · ([A-Z0-9-]+)", ln)
        if m:
            last_arm = m.group(1)
        if "ERROR" in ln:
            first_err = ln
            break
    return first_err or "(no error)", last_arm


bad = 0
rc, out = run(body_of("266"), "")
if rc != 0 or "FIXTURE 266 全部通过" not in out:
    print("✗ the clean fixture 266 is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 266 全部通过")
for num, stem in sorted({(o[0], o[1]) for o in OTHER}):
    rc, out = run(body_of(num, stem), "")
    if rc != 0:
        print(f"✗ the clean fixture {num} is not green:\n" + out[-1500:])
        sys.exit(1)
    print(f"✓ clean: fixture {num} (exit 0)")

B = body_of("266")
arms = set()
for arm, name, inj in CASES_266:
    rc, out = run(B, inj)
    first, last_arm = where_red(out, "266")
    if rc == 0:
        print(f"✗ 266 {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ 266 {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif f"FIXTURE 266 {arm}" in first or (arm != "RECON" and last_arm == arm):
        arms.add(arm)
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ 266 {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ 266 {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1
missing = {"REG", "PERM", "REFUSE", "VOID", "ISSUE", "RETURN", "DIRECT", "CAPITAL", "REPRICE", "HOLD", "ROLL", "V21", "RECON", "TRAIL"} - arms
if missing:
    print(f"✗ fixture 266: arms never made red: {sorted(missing)}")
    bad += 1

for num, stem, needle, name, inj in OTHER:
    rc, out = run(body_of(num, stem), inj)
    first, last_arm = where_red(out, num)
    if rc != 0 and "INJECTION_DID_NOT_APPLY" not in out and needle in first:
        print(f"✓ fixture {num} · {name}: {first[first.index('ERROR'):][:200]}")
    else:
        print(f"✗ fixture {num} · {name}: expected '{needle}', got [{last_arm}] {first[:300]}")
        bad += 1

print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES_266)} injections on 266 + {len(OTHER)} on 263, {bad} wrong)")
sys.exit(1 if bad else 0)
