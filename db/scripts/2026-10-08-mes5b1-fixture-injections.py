#!/usr/bin/env python3
"""MES-5b-1:fixture 257 的故障注入 —— 每一格注入一处缺陷,fixture 257 必须在【它点名的那一臂】红;
外加 fixture 255 SPLIT 新加的那几句(拆分那一炉自己结平、容差播成 0)各一格;
外加两处【重建】层的自检(引导的 role_permissions 自检、permissions 声明的自检)各一格 —— 那两格改的是镜像的一份拷贝,
对着一个全新的空库重建,断言重建按名失败。

做法照 db/scripts/2026-10-08-mes5a2-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
视图与函数的注入用 pg_get_viewdef / pg_get_functiondef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture 257 · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着
"FIXTURE 257 <臂>",或者它发生时最后打出的那一臂就是 <臂>。一格可以点名两臂(A|B)。
跑法:python3 db/scripts/2026-10-08-mes5b1-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>" "<同一个集群上可以 createdb 的维护库 DSN>"
退出码:0 = 干净跑绿、每一格都红在它的那一臂、每一臂都至少红过一次、两格重建注入都按名失败;1 = 否则。
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

DSN = sys.argv[1]
ADMIN = sys.argv[2] if len(sys.argv) > 2 else None
for d in (DSN, ADMIN or ""):
    if "supabase" in d or "pooler" in d:
        sys.exit("refusing a live DSN — run against a throwaway rebuild")
ROOT = pathlib.Path(".")


def body_of(num):
    src = next(ROOT.glob(f"db/fixtures/{num}-*.sql")).read_text()
    assert src.count("\nBEGIN;\n") == 1 and src.rstrip().endswith("ROLLBACK;"), f"fixture {num} shape changed"
    return src.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]


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
    EXECUTE format('CREATE OR REPLACE VIEW public.%I AS %s', '{name}', d2);
END $inj$;
"""


SRP = "public.set_role_permissions(uuid, text[])"
SPLIT = ("public.split_failed_modules_to_quarantine(uuid, text, uuid, text[], date, timestamp with time zone, timestamp with time zone, "
         "text, uuid, numeric, uuid, text)")
FLOW, TREE, MON, ROLLV, RY, YS = ("processing_run_flow_all", "batch_balance_tree_all", "processing_balance_monthly_all",
                                  "stock_rollforward_monthly_all", "processing_run_yield_all", "processing_yield_summary_all")

CASES = [
    # ── CONS ──
    ("CONS", "deep discharge counts as consumption",
     patch_view(FLOW, "WHEN (k.consumes_input IS FALSE) THEN 'pass_through'::text", "WHEN false THEN 'pass_through'::text")),
    ("CONS", "the quarantine split is a consuming run", patch_view(FLOW, "THEN 'transfer'::text", "THEN 'consumption'::text")),
    ("CONS", "a non-kg input leg is not noticed",
     patch_view(FLOW, "(COALESCE(ib.unit, ob.unit) IS DISTINCT FROM 'kg'::text)", "false")),
    ("NOTKG", "the non-kg run is not named on the batch", patch_view(TREE, "ELSE 'not_kg'::text", "ELSE 'pass_through'::text")),
    # ── ATTR ──
    ("ATTR", "an output's share is not the leg's mass over the run's input",
     patch_view(TREE, "(w.num * l.q),", "((w.num * l.q) * CASE WHEN (l.flow = 'transfer'::text) THEN (1)::numeric ELSE (2)::numeric END),")),
    ("ATTR", "a run's losses and remainder are split over the wrong total",
     patch_view(TREE, "(n.den * l.run_input),", "(n.den * (l.run_input + 1::numeric)),")),
    ("ATTR|GROUP", "every origin takes the whole run", patch_view("processing_run_origin_share_all", "(sum(t.qty) / f.input_qty) AS share", "1::numeric AS share")),
    # ── BAL ──
    ("ATTR|BAL", "on hand misses the stock that was sold or consumed",
     patch_view(TREE, "sum(m.qty_delta) AS on_hand,", "sum(m.qty_delta) FILTER (WHERE (m.movement_type <> 'processing_consume'::text)) AS on_hand,")),
    ("BAL", "a reversed run is not listed as reversed",
     patch_view(TREE, "WHEN (l.flow = 'reversed'::text) THEN 'reversed'::text", "WHEN (l.flow = 'reversed'::text) THEN 'not_kg'::text")),
    ("BAL", "the correcting run is not linked back", patch_view(TREE, "WHERE (c.corrects_run_id = t.run_id)", "WHERE false")),
    # ── PRE ──
    ("PRE", "every run reads as MES-4a era", patch_view(FLOW, "(r.started_at IS NOT NULL) AS era_mes4a", "true AS era_mes4a")),
    # ── INV ──
    ("INV", "pass-through mass is counted as input",
     patch_view(MON, "WHERE ((f.flow = 'consumption'::text) AND (NOT f.not_kg))\n        UNION ALL\n         SELECT f.month,\n            f.operation_type_code,\n            'output'::text AS line,",
                "WHERE ((f.flow = ANY (ARRAY['consumption'::text, 'pass_through'::text, 'transfer'::text])) AND (NOT f.not_kg))\n        UNION ALL\n         SELECT f.month,\n            f.operation_type_code,\n            'output'::text AS line,")),
    # ── MONTH ──
    ("MONTH", "the remainder line is dropped",
     patch_view(MON, "'remainder'::text AS line,", "'remainder_dropped'::text AS line,")),
    ("MONTH", "an operation's lines are not summed", patch_view(MON, "'operation'::text AS scope,\n    lines.operation_type_code,\n    lines.line,\n    lines.line_key,\n    lines.basis,\n    sum(lines.qty) AS qty,",
                                                                  "'operation'::text AS scope,\n    lines.operation_type_code,\n    lines.line,\n    lines.line_key,\n    lines.basis,\n    max(lines.qty) AS qty,")),
    ("MONTH", "a split reads as a discharge", patch_view(MON, "ELSE 'split'::text", "ELSE 'discharge'::text")),
    # ── ROLL ──
    ("ROLL", "the voided line is lost", patch_view(ROLLV, "(mv.movement_type = 'reversal_void'::text)", "(mv.movement_type = 'nothing'::text)")),
    ("ROLL", "closing forgets the consumption", patch_view(ROLLV, "((d.received + d.produced) + d.consumed)", "(d.received + d.produced)")),
    # ── YIELD ──
    ("YIELD", "a run's yield divides by the wrong input",
     patch_view(RY, "THEN ((l.qty * (100)::numeric) / r.input_qty)\n", "THEN ((l.qty * (100)::numeric) / (r.input_qty + 1::numeric))\n")),
    ("YIELD", "recoverable losses read as true losses", patch_view(RY, "(NOT lc.is_true_loss),", "lc.is_true_loss,")),
    ("YIELD", "pre-MES-4a runs are not counted", patch_view(YS, "FILTER (WHERE (NOT r.era_mes4a))", "FILTER (WHERE r.era_mes4a)")),
    # ── V37 ──
    ("V37", "the flag is inverted",
     patch_view(RY, "/ r.input_qty) < tf.expected_yield_pct)", "/ r.input_qty) > tf.expected_yield_pct)")),
    ("V37", "the pending row shows before any MES-4a-era run",
     patch_view("pending_values", "(f.flow = 'consumption'::text) AND f.era_mes4a)", "(f.flow = 'consumption'::text)) OR true")),
    ("V37", "the summary's flag is never set",
     patch_view(YS, "/ d.input_qty) < tf.expected_yield_pct)", "/ d.input_qty) < (0)::numeric)")),
    # ── GROUP ──
    ("GROUP", "a group's input ignores its share", patch_view(YS, "sum((g.share * r.input_qty)) AS input_qty,", "sum(r.input_qty) AS input_qty,")),
    ("GROUP", "the machine group loses the machine", patch_view(YS, "(r.equipment_id)::text AS equipment_id,", "NULL::text AS equipment_id,")),
    ("GROUP", "the supplier name shows without inbound view",
     patch_view("processing_yield_summary", "WHEN has_permission('module.inbound.view'::text) THEN sp.legal_name", "WHEN true THEN sp.legal_name")),
    # ── READ ──
    ("READ", "finance view cannot read the monthly balance",
     patch_view("processing_balance_monthly", "OR has_permission('module.finance.view'::text) ", "")),
    ("READ", "the batch tree ignores the batch's own view code",
     patch_view("batch_balance_tree", "OR ((root_kind = 'inbound'::text) AND has_permission('module.inbound.view'::text)) ", "")),
    ("READ", "the base tree view is readable", "GRANT SELECT ON public.batch_balance_tree_all TO authenticated;"),
    # ── FCHECK ──
    ("FCHECK", "the role-saving guard is gone", patch_fn(SRP, "IF v_action IS NOT NULL THEN", "IF false THEN")),
    ("FCHECK", "all of the views are required instead of any",
     patch_fn(SRP, "NOT (p.requires_view_any && v_codes)", "NOT (p.requires_view_any <@ v_codes)")),
    ("FCHECK", "a declaration points at the wrong view",
     "UPDATE public.permissions SET requires_view_any = ARRAY['module.hr.view'] WHERE code = 'action.wo_create';"),
    ("FCHECK", "the bootstrap admin is missing a code",
     "DELETE FROM public.role_permissions WHERE role_id = (SELECT id FROM roles WHERE code = 'admin') AND permission_code = 'data.view_health';"),
    ("FCHECK", "the bootstrap finance role loses processing view",
     "DELETE FROM public.role_permissions WHERE role_id = (SELECT id FROM roles WHERE code = 'finance') AND permission_code = 'module.processing.view';"),
    # ── LOG ──
    ("LOG", "a new table is not change-logged", "CREATE TABLE public.zz257_unlogged (id integer PRIMARY KEY);"),
    ("LOG", "the V37 change is not captured", "DROP TRIGGER zzz_change_log ON public.operation_type_output_forms;"),
]

CASES_255 = [
    ("SPLIT", "the split does not close its own balance", patch_fn(SPLIT, "v_closure := close_run_balance(v_split, NULL);", "v_closure := NULL;")),
    ("SPLIT", "the split operation's tolerance is not seeded",
     "UPDATE public.operation_types SET balance_tolerance_pct = NULL WHERE code = 'discharge_quarantine_split';"),
]


def run(dsn, body, inj):
    sql = "BEGIN;\n" + inj + "\n" + body + "\nROLLBACK;\n"
    p = subprocess.run(["psql", dsn, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def where_red(out, num):
    last_arm, first_err = None, None
    for ln in out.splitlines():
        m = re.search(rf"fixture {num} · ([A-Z0-9]+)", ln)
        if m:
            last_arm = m.group(1)
        if "ERROR" in ln:
            first_err = ln
            break
    return first_err or "(no error)", last_arm


bad = 0


def judge(num, body, cases, arms):
    global bad
    for arm, name, inj in cases:
        rc, out = run(DSN, body, inj)
        first, last_arm = where_red(out, num)
        named = arm.split("|")
        if rc == 0:
            print(f"✗ {num} {arm} · {name}: did NOT go red")
            bad += 1
        elif "INJECTION_DID_NOT_APPLY" in out:
            print(f"✗ {num} {arm} · {name}: the injection did not apply — {first}")
            bad += 1
        elif any(f"FIXTURE {num} {a}" in first for a in named) or last_arm in named:
            arms.update(a for a in named if f"FIXTURE {num} {a}" in first or last_arm == a)
            shown = first[first.index("ERROR"):][:180] if "ERROR" in first else first
            print(f"✓ {num} {arm} · {name}: [{last_arm}] {shown}")
        else:
            print(f"✗ {num} {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
            bad += 1


B257 = body_of("257")
rc, out = run(DSN, B257, "")
if rc != 0 or "FIXTURE 257 全部通过" not in out:
    print("✗ the clean fixture 257 is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 257 全部通过")
B255 = body_of("255")
rc, out = run(DSN, B255, "")
if rc != 0 or "FIXTURE 255 全部通过" not in out:
    print("✗ the clean fixture 255 is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 255 全部通过")

arms257 = set()
judge(257, B257, CASES, arms257)
arms255 = set()
judge(255, B255, CASES_255, arms255)

missing = {"CONS", "ATTR", "BAL", "PRE", "INV", "MONTH", "NOTKG", "ROLL", "YIELD", "V37", "GROUP", "READ", "FCHECK", "LOG"} - arms257
if missing:
    print(f"✗ arms of 257 never made red in their own name: {sorted(missing)}")
    bad += 1
if "SPLIT" not in arms255:
    print("✗ 255 SPLIT never made red")
    bad += 1

# ── 重建层的两格:改镜像的一份拷贝,对着一个全新的空库重建,断言按名失败 ──────────────────────
REBUILD = [
    ("bootstrap self-check", "db/tables/role_permissions.sql",
     "        'action.wo_release', 'module.processing.view',", "        'action.wo_release',", "BOOTSTRAP_ACTION_REQUIRES_VIEW|finance -> action.wo_release"),
    ("catalogue declaration self-check", "db/tables/permissions.sql",
     "    ('action.wo_create',                ARRAY['module.processing.view']),\n", "", "PERMISSIONS_REQUIRES_VIEW_UNDECLARED|action.wo_create"),
]
if ADMIN:
    for name, rel, old, new, want in REBUILD:
        tmp = pathlib.Path(tempfile.mkdtemp(prefix="mes5b1-inj-"))
        try:
            shutil.copytree(ROOT / "db", tmp / "db")
            for extra in ("lib", "scripts", "docs/surveys/AUDIT-TRAIL-0"):
                if (ROOT / extra).exists():
                    shutil.copytree(ROOT / extra, tmp / extra)
            f = tmp / rel
            s = f.read_text()
            assert s.count(old) == 1, f"{name}: injection anchor not unique"
            f.write_text(s.replace(old, new))
            db = "mes5b1inj"
            subprocess.run(["psql", ADMIN, "-X", "-q", "-c", f"DROP DATABASE IF EXISTS {db}"], check=True, capture_output=True)
            subprocess.run(["psql", ADMIN, "-X", "-q", "-c", f"CREATE DATABASE {db}"], check=True, capture_output=True)
            target = re.sub(r"dbname=\S+", f"dbname={db}", ADMIN)
            p = subprocess.run(["python3", "db/verify_rebuild.py", "--target", target, "--offline"], cwd=tmp, capture_output=True, text=True)
            outp = p.stdout + p.stderr
            if p.returncode != 0 and want in outp:
                print(f"✓ rebuild · {name}: exit {p.returncode}, names {want}")
            else:
                print(f"✗ rebuild · {name}: expected a failure naming {want}, got exit {p.returncode}\n{outp[-800:]}")
                bad += 1
        finally:
            subprocess.run(["psql", ADMIN, "-X", "-q", "-c", "DROP DATABASE IF EXISTS mes5b1inj"], capture_output=True)
            shutil.rmtree(tmp, ignore_errors=True)
else:
    print("✗ no maintenance DSN given — the two rebuild injections did not run")
    bad += 1

print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections on 257 + {len(CASES_255)} on 255 + {len(REBUILD)} rebuild, {bad} wrong)")
sys.exit(1 if bad else 0)
