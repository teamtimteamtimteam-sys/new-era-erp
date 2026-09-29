#!/usr/bin/env python3
"""AUDIT-TRAIL-1b-2:从镜像拼出迁移文件(形状照 build_at1b1_migration.py)。镜像是真源,迁移是它的一次投影 ——
四支登记表 / 解析函数从 db/functions/ 原样抽出,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_at1b2_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-30-at1b2-trails-commercial.sql"

# 同一签名,原地替换(本刀不换任何一支的形状 —— 不需要 DROP)
REPLACED = {"trail_subjects": "()", "trail_subject_members": "()", "trail_prelog_sources": "()",
            "trail_ref_label": "(text, text, text)"}


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


HEADER = """-- db/migrations/2026-09-30-at1b2-trails-commercial.sql
-- AUDIT-TRAIL-1b-2 —— 商务那一半的审计记录:报价 · 销售订单 · 发货单 · 客户 · 佣金协议 · 供应商 · 货代 · 集装箱 ·
--   航段与港口 · 公司执照(v1.4.33 的一部分,未发布)。
-- 由 db/scripts/build_at1b2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AT-1b Step 0 §a 的登记表,Tim 2026-09-29 照建议裁定;1b-1 已经建好了 M1–M6,这一刀只加主语)
--   ① trail_subjects:加十一个主语 —— quote · sales_order · shipment(M1:销售或发货任一码)· customer · commission_agreement ·
--      supplier · container · forwarder(M3:页面的码是门)· lane · port · company_licence。
--   ② trail_subject_members:它们的子行与相关行(Step 0 §a 逐行);预留、发货单明细、订单事件史的"家"从此是订单 / 发货单。
--   ③ trail_prelog_sources:"记录开始之前"的来源 —— 建单戳与事件史同一刻,归成一条;签发档不登记(事件史的 issued 已说)。
--   ④ trail_ref_label:订单 / 报价明细行、港口、航段、执照与证书、附件、集装箱单据有了人认得的名字;物料带回单位。
--   四支都是同一签名原地替换(CREATE OR REPLACE),不 DROP、不改形状。
--
-- 【不做什么】不改任何表、策略、授权、触发器;不写任何业务行;不加新权限码;不碰审批开关与名册。
--
-- 【破窗】什么都不坏:旧应用只用 1b-1 之前的十个主语调 record_trail,参数不变;新主语对旧应用不存在(它不叫它们)。
--   四支都是 IMMUTABLE / STABLE 的函数,替换不锁任何表。旧应用的两段"历史"照旧读 quote_history / sales_order_history。
--   唯一【提前】到的变化:/settings/change-history 的 Record 一栏,预留、发货单明细、订单事件史的行从此指向它们的订单 /
--   发货单(trail_row_record 沿"家"走)—— 那是终态,只是早到。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;change_log 的行数
--   没变;每一张在途单据都还有一个【不是它自己当事人】的决定人;二十一个主语;并以 tim@(cfo)与仓库的账号真的读几次
--   (仓库的账号持 action.ship_goods、不持 module.sales.view —— M1 在线上真正的那一位读者)。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"   # tim@evoltrya.test(cfo)

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子(1b-1 的形状,十个主语)───────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1B2_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM trail_subjects()) <> 10 THEN
        RAISE EXCEPTION 'AT1B2_PRE|expected the 10 subjects of 1b-1, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1b2_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE at1b2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1b2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
""")
parts.append("\n-- ── 1 · 四支登记表 / 解析函数:原地替换(同一签名,镜像原样)──────────────────────────────\n")
for name in REPLACED:
    parts.append(fn(name))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "at1b2_pending_decider_check")
parts.append("\n-- ── 2 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE at1b2_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    v_id   uuid;
    v_wh   uuid;
    v_j    jsonb;
    k      text;
    f      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM at1b2_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1b2_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1B2_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1B2_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 一行没多(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1b2_pending_before b EXCEPT SELECT a.k, a.id FROM at1b2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1b2_pending_after a EXCEPT SELECT b.k, b.id FROM at1b2_pending_before b)) THEN
        RAISE EXCEPTION 'AT1B2_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(n, mx)::text FROM at1b2_log_before) IS DISTINCT FROM (SELECT row(count(*), max(seq))::text FROM change_log) THEN
        RAISE EXCEPTION 'AT1B2_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1b2_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:二十一个主语;每一个 shown 成员表都在 change_log 的覆盖里;四支对 authenticated 的执行权与原来一样
    IF (SELECT count(*) FROM trail_subjects()) <> 21 THEN
        RAISE EXCEPTION 'AT1B2_PROOF|expected 21 subjects, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    SELECT string_agg(DISTINCT m.table_name, ', ') INTO v_bad FROM trail_subject_members() m
     WHERE m.shown AND NOT EXISTS (SELECT 1 FROM information_schema.triggers t
                                    WHERE t.event_object_table = m.table_name AND t.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1B2_PROOF|member tables without the change-log trigger: %', v_bad; END IF;
    FOREACH f IN ARRAY ARRAY['public.trail_subjects()', 'public.trail_subject_members()', 'public.trail_prelog_sources()',
                             'public.record_trail(text, text, integer)'] LOOP
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1B2_PROOF|authenticated cannot execute %', f;
        END IF;
        IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1B2_PROOF|anon can execute %', f;
        END IF;
    END LOOP;
    IF has_function_privilege('authenticated', 'public.trail_ref_label(text, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'AT1B2_PROOF|authenticated can execute the inner function trail_ref_label';
    END IF;

    -- ⑤ 真的读几次:tim@(cfo)读 SO-2026-0001 —— 读得到、带着"记录开始之前"的那一段,事件史一行不少;
    --    仓库的账号(持 action.ship_goods、不持 module.sales.view)读 SHP-2026-0001 —— 不被拒(M1)
    SELECT id INTO v_id FROM sales_orders WHERE code = 'SO-2026-0001';
    PERFORM set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT jsonb_agg(to_jsonb(r)) INTO v_j FROM record_trail('sales_order', v_id::text, 200) r;
    EXECUTE 'RESET ROLE';
    IF v_j IS NULL OR (SELECT count(*) FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'sales_order_history')
                      <> (SELECT count(*) FROM sales_order_history WHERE sales_order_id = v_id) THEN
        RAISE EXCEPTION 'AT1B2_PROOF|tim@ should read every sales-order history row of SO-2026-0001, got %', v_j;
    END IF;
    RAISE NOTICE 'AT1B2 SO-2026-0001 trail rows for tim@: % (pre-log: %)', jsonb_array_length(v_j),
        (SELECT count(*) FROM jsonb_array_elements(v_j) e WHERE (e ->> 'prelog')::boolean);

    SELECT ur.user_id INTO v_wh FROM user_roles ur JOIN roles r ON r.id = ur.role_id
     WHERE r.code = 'warehouse' AND ur.revoked_at IS NULL ORDER BY ur.user_id LIMIT 1;
    SELECT id INTO v_id FROM shipments WHERE code = 'SHP-2026-0001';
    IF v_wh IS NOT NULL AND v_id IS NOT NULL THEN
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_wh, 'role', 'authenticated')::text, true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT count(*) INTO v_n FROM record_trail('shipment', v_id::text, 20);
        EXECUTE 'RESET ROLE';
        RAISE NOTICE 'AT1B2 the warehouse account (ship_goods, no sales.view) reads SHP-2026-0001: % rows', v_n;
        IF v_n = 0 THEN RAISE EXCEPTION 'AT1B2_PROOF|the warehouse account read an empty shipment trail'; END IF;
    END IF;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1b2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1B2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1b2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1B2_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1b2_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1b2_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
