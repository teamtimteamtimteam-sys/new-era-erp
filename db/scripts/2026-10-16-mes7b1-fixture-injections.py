#!/usr/bin/env python3
"""MES-7b-1:fixture 267 的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。

做法照 db/scripts/2026-10-16-mes7a2-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
视图重建时带回它自己的 reloptions(不假设 security_invoker = off)。
【红在哪一臂】fixture 267 每进一臂先打一行 NOTICE "fixture 267 · <臂>"(NUM 与 MASK 共用一行 "NUM · MASK",正则取到的是 NUM);
一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 267 <臂>",或者它发生时最后打出的那一臂就是 <臂>。
措辞臂 ㉜ 的两格(TRAIL_WORDING_FAULT drift / part)是 scripts/check-trail-wording.mjs 的,不碰库,不在这里。
【一条"不发生"的断言怎么注入】LINK 臂的"链接从不设安全状态、从不动货"断言的是一件【不发生】的事:link_incident_batch 里本来就没有一句写
  inbound_batch_safety_states / inventory_movements,所以那一格是往函数里【加】一句写(LINK · a link writes a safety state)。
【六格红在表自己的 CHECK / 外键上,不是红在函数的具名错误上】(REFUSE 受伤无人 · DIRECT 直插 ×2 · UPDATE 更正无理由 · KIND 改代号 ·
  LINK 解链无理由 · NCR 来源无事故 · HANDOVER 未知事故):fixture 断言的是【那个具名错误】,所以拿掉函数里那一句就红 ——
  表上的约束是第二道墙,它让数据不坏,但不替那一句说出名字。
【TRAIL 两格为什么不是"摘掉 zzz_change_log"】摘掉或停用触发器会先在 REG 的覆盖断言上红(实测两格都红在 REG)——
  那是 REG 的事;TRAIL 这两格注入的是只有真的走一次 record_trail 才看得见的那一种(成员表连错列)。
跑法:python3 db/scripts/2026-10-16-mes7b1-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"(绝不对着线上)
退出码:0 = fixture 267 干净跑绿、每一格都红在它的那一臂、267 的每一臂都至少红过一次;1 = 否则。
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


RI = "public.record_incident(text, timestamp with time zone, text, text, boolean, uuid, text, uuid, uuid, numeric, uuid, bigint, uuid, text, text, text, numeric, text)"
RIU = "public.record_incident_update(uuid, text, timestamp with time zone, text, text, text, text, text)"
SUG = "public.suggest_incident_batches(uuid)"
LNK = "public.link_incident_batch(uuid, text, uuid, uuid)"
ULK = "public.unlink_incident_batch(bigint, text)"
SSS = "public.set_safety_settings(integer, boolean, text)"
BDA = "public.business_days_after(date, integer)"
NIC = "public.next_incident_code(date)"
GIW = "public.guard_incident_write()"
GIK = "public.guard_incident_kind_code()"
GIB = "public.guard_incident_batch_write()"
GIU = "public.guard_incident_update_write()"
NCR = "public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid)"
TSM = "public.trail_subject_members()"
SSH = "public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[], uuid[])"


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


CASES = [
    # ── REG ──
    ("REG", "a catch-all kind called other is allowed", "ALTER TABLE public.incident_kinds DROP CONSTRAINT incident_kinds_code_check;\n"),
    ("REG", "the spare_part note (F12) is back to the old text",
     "UPDATE public.material_kinds SET notes = '机器的备件。【不按批次追溯】' WHERE code = 'spare_part';\n"),
    ("REG", "V19 ships as 3 days", "UPDATE public.safety_settings SET nea_report_working_days = 3;\n"),
    ("REG", "an injury column is in the column grant", "GRANT SELECT (injury_nature) ON public.incidents TO authenticated;\n"),
    ("REG", "the incident list view is writable through", "GRANT UPDATE ON public.incident_rows TO authenticated;\n"),
    # ── GRANT ──
    ("GRANT", "auditor (holds processing.view) misses safety.view",
     "DELETE FROM public.role_permissions WHERE permission_code = 'module.safety.view' AND role_id = (SELECT id FROM public.roles WHERE code = 'auditor');\n"),
    ("GRANT", "warehouse is given data.view_health",
     "INSERT INTO public.role_permissions (role_id, permission_code) SELECT id, 'data.view_health' FROM public.roles WHERE code = 'warehouse';\n"),
    # ── REFUSE ──
    ("REFUSE", "anyone may record an incident (the code check is gone)",
     patch_fn(RI, "    PERFORM require_permission('module.safety.edit');\n", "")),
    ("REFUSE", "a future incident time is accepted", patch_fn(GIW, "IF NEW.occurred_at > now() THEN", "IF false THEN")),
    ("REFUSE", "the device source is accepted (function and guard)",
     patch_fn(RI, "IF p_source IS DISTINCT FROM 'manual' THEN", "IF false THEN") + patch_fn(GIW, "IF NEW.source IS DISTINCT FROM 'manual' THEN", "IF false THEN")),
    ("REFUSE", "an injury detail with no injured person is accepted",
     patch_fn(RI, "RAISE EXCEPTION 'INCIDENT_INJURY_NEEDS_PERSON';", "NULL;")),
    ("REFUSE", "an inactive kind is accepted", patch_fn(GIW, "AND k.is_active) THEN", "OR true) THEN")),
    # ── NUM ──
    ("NUM", "the number is three digits wide", patch_fn(NIC, "GREATEST(4, length(v_seq::text))", "3")),
    ("NUM", "the numbering skips one", patch_fn(NIC, "COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1", "COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 2")),
    # ── MASK ──
    ("MASK", "everyone counts as the injured person",
     patch_view("incidents_masked", "COALESCE((injured_employee_id = current_user_employee()), false)", "true")),
    ("MASK", "the injured person does not see their own injury",
     patch_view("incidents_masked", "COALESCE((injured_employee_id = current_user_employee()), false)", "false")),
    # ── DIRECT ──
    ("DIRECT", "a direct insert is not refused by name", patch_fn(GIW, "IF row_security_active(TG_RELID) THEN", "IF false THEN")),
    ("DIRECT", "the owner may rewrite an incident", "DROP TRIGGER trg_incidents_immutable ON public.incidents;\n"),
    ("DIRECT", "a direct update-row insert is not refused by name", patch_fn(GIU, "IF row_security_active(TG_RELID) THEN", "IF false THEN")),
    # ── UPDATE ──
    ("UPDATE", "the first correction wins", patch_view("incident_current_all", "ORDER BY u.id DESC", "ORDER BY u.id")),
    ("UPDATE", "a correction needs no reason", patch_fn(RIU, "RAISE EXCEPTION 'INCIDENT_CORRECTION_REASON_REQUIRED';", "NULL;")),
    ("UPDATE", "a closed incident still takes corrections", patch_fn(RIU, "RAISE EXCEPTION 'INCIDENT_CLOSED|%', v_cur.code;", "NULL;")),
    ("UPDATE", "a notification may be dated before the incident", patch_fn(RIU, "IF p_occurred_at < v_cur.occurred_at THEN", "IF false THEN")),
    # ── KIND ──
    ("KIND", "a used kind code may change", patch_fn(GIK, "IF v_n > 0 THEN", "IF v_n > 999 THEN")),
    ("KIND", "a kind used only by a correction is not locked",
     patch_fn(GIK, "WHERE u.kind = 'correction' AND u.field = 'kind_code' AND u.new_value = OLD.code", "WHERE false")),
    # ── LINK ──
    ("LINK", "stock that arrived after the incident is suggested", patch_fn(SUG, "m.occurred_at <= v_cur.occurred_at", "true")),
    ("LINK", "an earlier run on the machine is suggested",
     patch_fn(SUG, "r.started_at <= v_cur.occurred_at AND r.ended_at > v_cur.occurred_at", "r.started_at <= v_cur.occurred_at")),
    ("LINK", "a batch not in the suggestions is linked as a suggestion", patch_fn(LNK, "IF p_basis <> 'picked' AND NOT EXISTS (", "IF false AND NOT EXISTS (")),
    ("LINK", "an unlink needs no reason", patch_fn(ULK, "IF p_reason IS NULL OR btrim(p_reason) = '' THEN", "IF false THEN")),
    ("LINK", "an unlinked link may change again", patch_fn(GIB, "IF OLD.unlinked_at IS NOT NULL OR NEW.unlinked_at IS NULL", "IF false")),
    ("LINK", "a link writes a safety state",
     patch_fn(LNK, "IF p_basis <> 'picked' AND NOT EXISTS (",
              "IF p_inbound_batch_id IS NOT NULL THEN INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) "
              "SELECT p_inbound_batch_id, code FROM inbound_safety_states LIMIT 1; END IF;\n    IF p_basis <> 'picked' AND NOT EXISTS (")),
    # ── NCR ──
    ("NCR", "an NCR may cite an incident the batch is not linked to",
     patch_fn(NCR, "IF NOT EXISTS (SELECT 1 FROM incident_batches b", "IF false AND NOT EXISTS (SELECT 1 FROM incident_batches b")),
    ("NCR", "an incident-source NCR needs no incident", patch_fn(NCR, "IF p_source = 'incident' AND p_incident_id IS NULL THEN", "IF false THEN")),
    ("NCR", "ncr_rows does not name the incident", patch_view("ncr_rows", "inc.code AS incident_code", "NULL::text AS incident_code")),
    # ── CITE ──
    ("CITE", "a downtime of another machine is cited", patch_fn(GIW, "IF v_dt.equipment_id IS DISTINCT FROM NEW.equipment_id THEN", "IF false THEN")),
    ("CITE", "a downtime is cited with no machine", patch_fn(RI, "IF p_downtime_id IS NOT NULL AND p_equipment_id IS NULL THEN", "IF false THEN")),
    ("CITE", "a withdrawn run event is cited",
     patch_fn(GIW, "IF v_ev.withdrawn OR v_ev.withdrawn_by THEN", "IF false THEN") + patch_fn(GIW, "IF v_ev.superseded_by IS NOT NULL THEN", "IF false THEN")),
    # ── NEA ──
    ("NEA", "working days ignore public holidays", patch_fn(BDA, "IF is_business_day(v_day) THEN", "IF extract(isodow FROM v_day) < 6 THEN")),
    ("NEA", "a missing calendar year is guessed through", patch_fn(BDA, "IF NOT EXISTS (SELECT 1 FROM public_holidays h", "IF false AND NOT EXISTS (SELECT 1 FROM public_holidays h")),
    ("NEA", "the notify reminder stays after the notification",
     patch_view("operations_now", "WHERE (c.nea_reportable AND (c.notified_at IS NULL))", "WHERE c.nea_reportable")),
    ("NEA", "the reminders are open to everyone",
     patch_view("operations_now", "'incident_nea_notify_due'::text AS item_type,\n            'module.safety.view'::text AS permission",
                "'incident_nea_notify_due'::text AS item_type,\n            'module.processing.view'::text AS permission")),
    ("NEA", "the deadline reads confirmed", patch_view("incident_current_all", "(s.nea_report_days_confirmed_at IS NOT NULL) AS deadline_confirmed", "true AS deadline_confirmed")),
    # ── V19 ──
    ("V19", "a confirmed V19 stays on the pending list", patch_view("pending_values", "(ss.nea_report_days_confirmed_at IS NULL)", "true")),
    ("V19", "a changed number keeps the old confirmation", patch_fn(SSS, "CASE WHEN COALESCE(p_confirmed, false) THEN now() END", "CASE WHEN true THEN now() END")),
    ("V19", "the V19 row is open to everyone", patch_view("pending_values", "'V19'::text AS value_code,\n            'module.safety.view'::text AS permission",
                                                         "'V19'::text AS value_code,\n            'module.processing.view'::text AS permission")),
    # ── HANDOVER ──
    ("HANDOVER", "an unknown incident is not refused by name",
     patch_fn(SSH, "WHERE NOT EXISTS (SELECT 1 FROM incidents i WHERE i.id = x)) THEN", "WHERE false) THEN")),
    ("HANDOVER", "the handover does not store its incident references",
     patch_fn(SSH, "SELECT v_id, x, v_user FROM unnest(p_incident_ids) x", "SELECT v_id, x, v_user FROM unnest(p_incident_ids) x WHERE false")),
    ("HANDOVER", "staff may write a reference directly", "GRANT INSERT ON public.shift_handover_incident_refs TO authenticated;\n"
     "CREATE POLICY f267_inj ON public.shift_handover_incident_refs FOR INSERT TO authenticated WITH CHECK (true);\n"),
    # ── TRAIL ──
    # (把 zzz_change_log 摘掉或停用会先在 REG 的覆盖断言上红 —— 那是 REG 的事;这里注入的是只有走一次 record_trail 才看得见的那一种)
    ("TRAIL", "the incident trail joins the handover reference on the wrong column",
     patch_fn(TSM, "('incident',           3, 'shift_handover_incident_refs',     'incidents',                    'incident_id'",
                   "('incident',           3, 'shift_handover_incident_refs',     'incidents',                    'handover_id'")),
    ("TRAIL", "the output batch trail joins its incident links on the wrong column",
     patch_fn(TSM, "('output_batch',      52, 'incident_batches',                 'output_batches',               'output_batch_id'",
                   "('output_batch',      52, 'incident_batches',                 'output_batches',               'inbound_batch_id'")),
]

ALL_ARMS = {"REG", "GRANT", "REFUSE", "NUM", "MASK", "DIRECT", "UPDATE", "KIND", "LINK", "NCR", "CITE", "NEA", "V19", "HANDOVER", "TRAIL"}


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
B = body_of("267")
rc, out = run(B, "")
if rc != 0 or "FIXTURE 267 全部通过" not in out:
    print("✗ the clean fixture 267 is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 267 全部通过")

arms = set()
for arm, name, inj in CASES:
    rc, out = run(B, inj)
    first, last_arm = where_red(out, "267")
    # NUM 与 MASK 共用一行 NOTICE(正则取到 NUM);MASK 一格只认 ERROR 里的 "FIXTURE 267 MASK"
    if rc == 0:
        print(f"✗ 267 {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ 267 {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif f"FIXTURE 267 {arm}" in first or (arm != "MASK" and last_arm == arm):
        arms.add(arm)
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ 267 {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ 267 {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1
missing = ALL_ARMS - arms
if missing:
    print(f"✗ fixture 267: arms never made red: {sorted(missing)}")
    bad += 1

print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections on 267, {bad} wrong)")
sys.exit(1 if bad else 0)
