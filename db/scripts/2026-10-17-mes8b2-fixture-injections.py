#!/usr/bin/env python3
"""MES-8b-2:fixture 271 的 KIND 臂(F18)与 fixture 273(车间大屏)的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。

做法照 db/scripts/2026-10-17-mes8b1-fixture-injections.py(本文件的 body_of / patch_fn / patch_view / run / where_red / sweep 逐字抄自它):
每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。函数与视图的注入先断言替换真的发生了(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture 27x · <臂>";一格算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 27x <臂>",
  或者它发生时最后打出的那一臂就是 <臂>。
【271 只扫本刀加的那两处】KIND 臂,与 EXPO 臂里本刀加的那一句("每一种物料都有种类 → 种类没说的一栏是空的")。271 的其余各臂由
  MES-8b-1 的注入脚本管,本刀没有改它们的判据。
【没有格的几处,照直说】
  · session_is_floor_display_only 的"没有会话 → 假":auth.uid() 为空时角色那一半本来就是空集,拿掉 "auth.uid() IS NOT NULL" 结果不变 ——
    纵深防御,今天单独咬不了人。
  · "角色停用 → 不豁免":current_user_permissions() 自己就滤掉停用的角色(码那一半先为空),拿掉角色那一半的 is_active 结果不变 —— 同上。
  · 中间件那一半(只在已判过期时问、问不到照旧登出)不在库里,由 db/scripts/2026-10-17-mes8b2-live-proof.mjs 的 HTTP 那几格证。
跑法:python3 db/scripts/2026-10-17-mes8b2-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"(绝不对着线上)
退出码:0 = 两支 fixture 干净跑绿、每一格都红在它的那一臂、每一臂都至少红过一次、跑完库与跑前逐字相同;1 = 否则。
"""
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, "db")
from injection_probe import Pristine  # noqa: E402

DSN = sys.argv[1]
if "supabase" in DSN or "pooler" in DSN:
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
    return f"""DO $inj$ DECLARE d text; d2 text; opts text; BEGIN
    d := pg_get_viewdef('public.{name}'::regclass);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{name}'; END IF;
    SELECT array_to_string(reloptions, ', ') INTO opts FROM pg_class WHERE oid = 'public.{name}'::regclass;
    EXECUTE format('CREATE OR REPLACE VIEW public.%I %s AS %s', '{name}',
                   CASE WHEN opts IS NULL THEN '' ELSE 'WITH (' || opts || ')' END, d2);
END $inj$;
"""



EXP = "public.inventory_metal_exposure()"
FB = "public.floor_board()"
FBA = "public.floor_board_arms()"
SIF = "public.session_is_floor_display_only()"
SFS = "public.set_floor_board_settings(integer, text[])"

CASES_271 = [
    ("KIND", "the kindless stock is never listed",
     patch_fn(EXP, "m.kind_code IS NULL GROUP BY b.id, b.code, b.unit", "false GROUP BY b.id, b.code, b.unit")),
    ("KIND", "the total reads complete although kindless stock exists",
     patch_fn(EXP, "\n                    AND jsonb_array_length(v_kind_not_stated) = 0", "")),
    ("KIND", "a kindless material is treated as processable and valued",
     patch_fn(EXP, "JOIN material_kinds k ON k.code = m.kind_code\n         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed",
              "LEFT JOIN material_kinds k ON k.code = m.kind_code\n         WHERE b.deleted_at IS NULL AND COALESCE(k.may_ever_be_processed, true)")),
    ("KIND", "a batch not in kg is given a kg figure",
     patch_fn(EXP, "'kg', CASE WHEN s.unit = 'kg' THEN round(s.qty, 3) END", "'kg', round(s.qty, 3)")),
    ("EXPO", "a recorded kind that may not be processed is listed as kind not stated",
     patch_fn(EXP, "m.kind_code IS NULL GROUP BY b.id, b.code, b.unit",
              "(m.kind_code IS NULL OR m.kind_code IN (SELECT code FROM material_kinds WHERE NOT may_ever_be_processed)) GROUP BY b.id, b.code, b.unit")),
]
ALL_271 = {a for a, _, _ in CASES_271}

CASES_273 = [
    ("REG", "floor_display holds a second code",
     "INSERT INTO public.role_permissions (role_id, permission_code) SELECT id, 'module.hr.view' FROM public.roles WHERE code = 'floor_display';"),
    ("REG", "floor_display is a system role", "UPDATE public.roles SET is_system = true WHERE code = 'floor_display';"),
    ("ARMS", "the floor board lists an arm that does not exist",
     patch_fn(FBA, "('safety_stock_below',", "('safety_stock_belowx',")),
    ("ARMS", "a processing arm is left off the board",
     patch_fn(FBA, "('allocation_stale',  ", "('stocktake_open',    ")),
    ("ARMS", "the arms view is readable by a session", "GRANT SELECT ON public.operations_arms_all TO authenticated;"),
    ("COUNTS", "a tile carries the arm's subject",
     patch_fn(FB, "jsonb_build_object('section', f.section, 'item_type', f.item_type, 'count', COALESCE(c.n, 0))",
              "jsonb_build_object('section', f.section, 'item_type', f.item_type, 'count', COALESCE(c.n, 0), 'subject', 'x')")),
    ("COUNTS", "a count is off by one", patch_fn(FB, "count(*) AS n", "count(*) + 1 AS n")),
    ("COUNTS", "an interval is guessed while V28 is not set",
     patch_fn(FB, "'refresh_seconds', v_refresh", "'refresh_seconds', COALESCE(v_refresh, 60)")),
    ("GATE", "the board does not ask for its code", patch_fn(FB, "PERFORM require_permission('data.view_floor_board');", "")),
    ("GATE", "a display session can read stocktakes",
     "CREATE POLICY f273_inj_st ON public.stocktakes FOR SELECT TO authenticated USING (true);"),
    ("IDLE", "a second role does not remove the exemption",
     patch_fn(SIF, "= ARRAY['floor_display']::text[]", "@> ARRAY['floor_display']::text[]")),
    ("IDLE", "a second code does not remove the exemption",
     patch_fn(SIF, "current_user_permissions() = ARRAY['data.view_floor_board']::text[]",
              "'data.view_floor_board' = ANY (current_user_permissions())")),
    ("V28", "the V28 row appears without any display account",
     patch_view("pending_values", "r.code = 'floor_display'::text", "true")),
    ("V28", "half a pair is accepted by the setter",
     patch_fn(SFS, "IF (p_refresh_seconds IS NULL) <> (p_tiles IS NULL) THEN", "IF false THEN")),
    ("V28", "an unknown tile is accepted",
     patch_fn(SFS, "NOT EXISTS (SELECT 1 FROM floor_board_arms() f WHERE f.item_type = t)", "false")),
    ("V28", "the board ignores the chosen tiles", patch_fn(FB, "WHERE v_tiles IS NULL OR f.item_type = ANY (v_tiles)", "WHERE true")),
    ("LOG", "floor_board_settings is not change-logged", "DROP TRIGGER zzz_change_log ON public.floor_board_settings;"),
]
ALL_273 = {a for a, _, _ in CASES_273}


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


def sweep(num, cases, all_arms):
    bad = 0
    B = body_of(num)
    rc, out = run(B, "")
    if rc != 0 or f"FIXTURE {num} 全部通过" not in out:
        print(f"✗ the clean fixture {num} is not green:\n" + out[-1500:])
        return 1
    print(f"✓ clean: FIXTURE {num} 全部通过")
    arms = set()
    for arm, name, inj in cases:
        rc, out = run(B, inj)
        first, last_arm = where_red(out, num)
        if rc == 0:
            print(f"✗ {num} {arm} · {name}: did NOT go red")
            bad += 1
        elif "INJECTION_DID_NOT_APPLY" in out:
            print(f"✗ {num} {arm} · {name}: the injection did not apply — {first}")
            bad += 1
        elif f"FIXTURE {num} {arm}" in first or last_arm == arm:
            arms.add(arm)
            shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
            print(f"✓ {num} {arm} · {name}: [{last_arm}] {shown}")
        else:
            print(f"✗ {num} {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
            bad += 1
    missing = all_arms - arms
    if missing:
        print(f"✗ fixture {num}: arms never made red: {sorted(missing)}")
        bad += 1
    return bad


TOUCHED = ["public.floor_board_settings", "public.operations_arms_all", "public.operations_now", "public.pending_values",
           "public.stocktakes", "public.roles", "public.role_permissions", "public.materials", EXP, FB, FBA, SIF, SFS]
P = Pristine(DSN, TOUCHED).capture()
bad = sweep("271", CASES_271, ALL_271)
bad += sweep("273", CASES_273, ALL_273)
P.assert_clean("after both sweeps")
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES_271)} injections on 271 + {len(CASES_273)} on 273, {bad} wrong)")
sys.exit(1 if bad else 0)
