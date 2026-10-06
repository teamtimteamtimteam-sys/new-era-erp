#!/usr/bin/env python3
"""MES-1:fixture 249 的故障注入 —— 每一格注入一处缺陷,fixture 249 必须在【它点名的那一臂】红。

做法照 U1-B 的 db/scripts/2026-10-05-u1b-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;
注入随 ROLLBACK 消失。函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】
(INJECTION_DID_NOT_APPLY)—— 一格悄悄没换上的注入,会被读成"这一臂没咬人"。

跑法:python3 db/scripts/2026-10-06-mes1-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 干净跑绿、每一格都红在它的那一臂;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import subprocess
import sys

DSN = sys.argv[1]
ROOT = pathlib.Path(".")
F249 = next(ROOT.glob("db/fixtures/249-*.sql")).read_text()
assert F249.count("\nBEGIN;\n") == 1 and F249.rstrip().endswith("ROLLBACK;"), "fixture shape changed"
BODY = F249.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]

SUBMIT = "public.ingest_submit(text, text, jsonb)"


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


CASES = [
    # (臂, 名字, 注入 SQL)
    ("DEV", "save_device stops asking for action.manage_devices",
     patch_fn("public.save_device(jsonb, uuid)", "PERFORM require_permission('action.manage_devices');", "")),
    ("GRANT", "ingest_submit granted back to authenticated",
     "GRANT EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) TO authenticated;"),
    ("GRANT", "ingest_submit granted to service_role",
     "GRANT EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) TO service_role;"),
    ("GRANT", "a third function becomes anonymous (the inbox processor)",
     "GRANT EXECUTE ON FUNCTION public.ingest_process_pending(integer) TO anon;"),
    ("GRANT", "the dispatcher becomes callable by authenticated",
     "GRANT EXECUTE ON FUNCTION public.ingest_transform_row(bigint) TO authenticated;"),
    ("GRANT", "anon may read the inbox",
     "GRANT SELECT ON public.ingest_inbox TO anon;"),
    ("POL", "an open read policy lands on the inbox",
     "CREATE POLICY fx249_open ON public.ingest_inbox AS PERMISSIVE FOR SELECT TO authenticated USING (true);"),
    ("HASH", "key_hash granted to authenticated",
     "GRANT SELECT (key_hash) ON public.gateway_keys TO authenticated;"),
    ("HASH", "gateway_keys_masked shows the hash",
     patch_view("gateway_keys_masked", "WHEN false THEN key_hash", "WHEN true THEN key_hash")),
    ("HASH", "the never rule answers visible",
     patch_fn("public.change_log_rule_visible(text, text, jsonb, jsonb, jsonb)",
              "IF p_rule = 'never' THEN\n        RETURN false;", "IF p_rule = 'never' THEN\n        RETURN true;")),
    ("APPEND", "the gateway call touches the device row it came from",
     patch_fn(SUBMIT, "    PERFORM pg_advisory_xact_lock(hashtext('ingest:' || v_gw.id::text)::bigint);",
              "    PERFORM pg_advisory_xact_lock(hashtext('ingest:' || v_gw.id::text)::bigint);\n    UPDATE devices SET notes = notes WHERE id = v_gw.id;")),
    ("RESP", "the answer carries the gateway's name",
     patch_fn(SUBMIT, "RETURN jsonb_build_object('ok', true, 'accepted', v_acc, 'duplicates', v_dup, 'rejected', v_rej);",
              "RETURN jsonb_build_object('ok', true, 'accepted', v_acc, 'duplicates', v_dup, 'rejected', v_rej, 'gateway', v_gw.name);")),
    ("AUTH", "a refusal names its reason",
     patch_fn(SUBMIT, "RETURN jsonb_build_object('ok', false, 'code', 'refused');",
              "RETURN jsonb_build_object('ok', false, 'code', v_result);")),
    ("AUTH", "a revoked key is accepted",
     patch_fn(SUBMIT, "ELSIF v_revoked THEN\n            v_result := 'revoked_key';", "ELSIF false THEN\n            v_result := 'revoked_key';")),
    ("AUTH", "a retired gateway is judged by its keys only",
     patch_fn(SUBMIT, "IF v_gw.retired_at IS NOT NULL THEN\n            v_result := 'retired_gateway';",
              "IF false THEN\n            v_result := 'retired_gateway';")),
    ("SIZE", "the payload cap is a hundred times too large",
     patch_fn(SUBMIT, "ELSIF v_bytes > s.max_payload_bytes THEN", "ELSIF v_bytes > s.max_payload_bytes * 100 THEN")),
    ("SIZE", "the message cap is not checked",
     patch_fn(SUBMIT, "ELSIF jsonb_array_length(v_msgs) > s.max_messages THEN", "ELSIF false THEN")),
    ("OWN", "a gateway may write for any device",
     patch_fn(SUBMIT, "WHERE d.code = v_m ->> 'device' AND d.gateway_id = v_gw.id AND d.retired_at IS NULL;",
              "WHERE d.code = v_m ->> 'device' AND d.retired_at IS NULL;")),
    ("SEQ", "a reused sequence number counts as a duplicate",
     patch_fn(SUBMIT, "IF v_prior = v_sha THEN", "IF true THEN")),
    ("SEQ", "clock-ahead is never flagged",
     patch_fn(SUBMIT, "COALESCE((o ->> 'to')::timestamptz > v_now + make_interval(secs => s.clock_ahead_s), false)", "false")),
    ("SEQ", "the gap view forgets the gap before the first number",
     patch_view("ingest_sequence_gaps", "COALESCE(prev_seq, (0)::bigint)", "COALESCE(prev_seq, seq - 1)")),
    ("HB", "a bucket grows without the function's flag",
     patch_fn("public.guard_ingest_transmissions_write()",
              "IF COALESCE(current_setting('evoltrya.ingest_ctx', true), '') <> 'ingest_submit' THEN", "IF false THEN")),
    ("HB", "a bucket may shrink",
     patch_fn("public.guard_ingest_transmissions_write()", "OR NEW.bucket_count < OLD.bucket_count", "")),
    ("STAT", "no outage is recorded on reconnect",
     patch_fn(SUBMIT, "AND v_now - v_last > make_interval(secs => v_gw.heartbeat_interval_s) THEN", "AND false THEN")),
    ("STAT", "an unset interval reads as ok",
     patch_view("gateway_health", "WHEN (d.heartbeat_interval_s IS NULL) THEN 'interval_not_set'::text", "WHEN false THEN 'interval_not_set'::text")),
    ("PV", "pending values stop asking for each arm's code",
     patch_view("pending_values", "WHERE has_permission(permission);", "WHERE true;")),
    ("XF", "a failed transformation is marked transformed",
     patch_fn("public.ingest_transform_row(bigint)",
              "                v_err := 'TRANSFORM_UNEXPECTED|' || SQLSTATE;\n            END IF;\n            v_state := 'failed';",
              "                v_err := 'TRANSFORM_UNEXPECTED|' || SQLSTATE;\n            END IF;\n            v_state := 'transformed';")),
    ("XF", "an inbox row can be deleted",
     "DROP TRIGGER trg_ingest_inbox_no_delete ON public.ingest_inbox;"),
    ("XF", "anyone may process the inbox",
     patch_fn("public.ingest_process_pending(integer)", "PERFORM require_permission('module.processing.view');", "")),
    ("ROT", "a third active key is allowed",
     patch_fn("public.guard_gateway_keys_write()", "IF v_n >= 2 THEN", "IF v_n >= 3 THEN")),
    ("LIM", "the global ceiling is gone",
     patch_fn(SUBMIT, "IF v_n_all >= s.global_reject_budget OR v_n_code >= s.fail_budget THEN", "IF v_n_code >= s.fail_budget THEN")),
    ("LIM", "the per-code budget is gone",
     patch_fn(SUBMIT, "IF v_n_all >= s.global_reject_budget OR v_n_code >= s.fail_budget THEN", "IF v_n_all >= s.global_reject_budget THEN")),
    ("LIM", "a valid key is throttled once the failure budget is spent",
     patch_fn(SUBMIT, "    -- ── ② 认证过的调用:形状与上限",
              "    IF v_result IS NULL AND (SELECT count(*) FROM ingest_transmissions t WHERE t.kind = 'call' AND t.result <> 'accepted') >= 300 THEN\n        v_result := 'bad_key';\n    END IF;\n    -- ── ② 认证过的调用:形状与上限")),
]


def run(injection):
    sql = "BEGIN;\n" + injection + "\n" + BODY + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
rc, out = run("")
if rc != 0 or "FIXTURE 249 全部通过" not in out:
    print("✗ the clean fixture is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 249 全部通过")
for arm, name, inj in CASES:
    rc, out = run(inj)
    err = [ln for ln in out.splitlines() if "ERROR" in ln]
    first = err[0] if err else "(no error)"
    if rc == 0:
        print(f"✗ {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif f"FIXTURE 249 {arm}" not in first:
        print(f"✗ {arm} · {name}: red in the wrong place — {first[:300]}")
        bad += 1
    else:
        print(f"✓ {arm} · {name}: {first[first.index('FIXTURE 249'):][:200]}")
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections, {bad} wrong)")
sys.exit(1 if bad else 0)
