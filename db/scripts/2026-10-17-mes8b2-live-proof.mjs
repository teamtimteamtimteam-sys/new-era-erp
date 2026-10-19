#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-8b-2(2026-10-17)· 线上验证 —— 车间大屏、空闲豁免、F18:一笔【回滚】的事务 + 一台本地 next 对着线上的 HTTP 读
// ════════════════════════════════════════════════════════════════════════════
// 两半,因为要证的东西住在两个地方:
//   【库里那一半】(一个常开的 psql,一笔事务从头开到尾,最后 ROLLBACK)——
//     · floor_board() 以大屏会话读:返回的键恰好四个、每块牌子恰好三个键(只有数),每一块的数 = operations_arms_all 里那一支的行数;
//     · session_is_floor_display_only():大屏 → 真;七个真角色的克隆 → 假;floor_display 多【任何一个】码(事务里加、子事务撤)→ 假,而大屏照样开;
//       大屏账号多一个角色 → 假;
//     · 大屏会话读别的东西:operations_now · 进料批 · 事故 · 盘点 → 0 行;
//     · F18:以只持 finance.view + data.view_prices 的一次性账号读 inventory_metal_exposure() —— 种类没说的批逐批列出、合计不完整;
//     · 七个真角色的克隆在三页上能做什么(大屏的门、价格敞口页与库存一节的门、账号页的门)—— 角色表;
//     · 收尾:在册的行逐字未变、在途单据与开场相同、审批开着、require_calibrated_since 为空、两条勾稽未解释 0.00。
//   【HTTP 那一半】(PROOF_BASE 上一台【跑本刀代码、连线上】的 next —— 中间件、根布局与页面是应用代码,只有 HTTP 看得见它们)——
//     · 大屏会话:/display 200、画出牌子、没有外壳;一组别的页一律是那一句拒绝、出路指回 /display;
//     · 空闲:把活动 cookie 设成 31 分钟以前(lib/session.ts 的那个 cookie —— 会话模块自己的测试路径,不是真等三十分钟):
//       大屏会话照样进得了 /display;七个真角色的克隆一律被登出(307 → /login?reason=ended),与今天一样;29 分钟时都还在。
//   ☞ "floor_display 多一个码之后空闲登出回来"在 HTTP 一侧量不到 —— 那个码只能加在【回滚的事务】里(委托书),另一个连接看不见它;
//     库里那一半证判据为假,HTTP 那一半证中间件只认判据(判据为真的进得去、为假的被登出)。两半合起来是那一句。
// 【身份】都是一次性账号(前缀 mes8b2probe),七个真账号一个都不用:
//   floor = 真的 floor_display 角色本身(realRole)—— 一个大屏账号;收尾时连同授权一起删掉,线上不留一个大屏账号
//   fin   = module.finance.view · data.view_prices(读 F18)
//   c_<角色> = 七个真账号此刻持有的七个角色的码的克隆(cloneOf)
// 【布景】只在事务里插、随回滚消失;在册的东西一行都不改、不决定、不删;floor_display 那个角色加的码也在这笔事务里,回滚。
// 【判决】只从日志里最后那一行 `MES8B2_PROOF_EXIT=` 读(exitAfterCleanup 的 onFinish 打的)。
//   0 = 两半都走完 · 1 = 证明红了 · 2 = 驱动自己坏了 · 5 = live-lock 被占。
// 用法:PROOF_BASE=http://localhost:3197 node db/scripts/2026-10-17-mes8b2-live-proof.mjs > <log> 2>&1
//   (那台 next 要先起来:在仓库根目录 `npx next dev -p 3197`,它读 .env.local 连线上)
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { spawn } from 'node:child_process'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const BASE = process.env.PROOF_BASE || 'http://localhost:3197'
const ROLE_CLONES = ['admin', 'cfo', 'finance', 'cco', 'cto', 'warehouse', 'gm']
const ACTIVITY_COOKIE = 'evoltrya-last-activity'   // lib/session.ts —— 同一个名字
const REFUSED_ROUTES = ['/', '/me', '/my-reviews', '/notifications', '/tools/reminders', '/finance/month-end', '/finance/price-exposure',
    '/inventory', '/settings/accounts', '/settings/pending-values', '/compliance/packs', '/suppliers', '/operation']

let locked = false
let psql = null
installExitHooks({
    beforeFinish: async () => {
        try { if (psql && psql.exitCode === null) psql.kill('SIGTERM') } catch { /* 子进程已经没了 */ }
    },
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`MES8B2_PROOF_EXIT=${code}`)
    },
})

let out = ''
let err = ''
function startPsql() {
    psql = spawn('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', DSN], { stdio: ['pipe', 'pipe', 'pipe'] })
    psql.stdout.on('data', (d) => { out += d })
    psql.stderr.on('data', (d) => {
        err += d
        for (const line of String(d).split('\n')) {
            const m = line.match(/(STEP\|.*|ROLE\|.*|IDLE\|.*)$/)
            if (m) console.log(m[1])
        }
    })
}
let seq = 0
async function run(sqlText, label) {
    const mark = `@@MES8B2_DONE_${++seq}@@`
    const from = out.length
    psql.stdin.write(`${sqlText}\n\\echo ${mark}\n`)
    const t0 = Date.now()
    while (!out.includes(mark, from)) {
        if (psql.exitCode !== null) {
            throw new Error(`MES8B2_SQL|${label}|psql exited ${psql.exitCode}:\n${err.split('\n').slice(-20).join('\n')}`)
        }
        if (Date.now() - t0 > 360_000) throw new Error(`MES8B2_SQL|${label}|no answer within 360s`)
        await new Promise((r) => setTimeout(r, 50))
    }
    const chunk = out.slice(from, out.indexOf(mark, from))
    const vals = {}
    for (const line of chunk.split('\n')) {
        const m = line.match(/^OUT\|([^|]+)\|(.*)$/)
        if (m) vals[m[1]] = m[2]
    }
    return vals
}
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`
function must(cond, msg) { if (!cond) throw new Error(`MES8B2_LIVE|${msg}`) }

// ── HTTP:一次硬导航,带着那个账号的会话 cookie(与可选的活动 cookie)──────────
async function get(acct, path, idleMinutes) {
    const ck = [`${acct.cookieName}=${acct.cookieValue}`]
    if (idleMinutes !== undefined) ck.push(`${ACTIVITY_COOKIE}=${Date.now() - idleMinutes * 60_000}`)
    const r = await fetch(BASE + path, { headers: { cookie: ck.join('; ') }, redirect: 'manual' })
    const body = r.status === 200 ? await r.text() : ''
    return { status: r.status, loc: r.headers.get('location') || '', body }
}
const isFloorRefusal = (b) => b.includes('data-access-denied') && b.includes('href="/display"')
    && (b.includes('This account is a wall display') || b.includes('这个账号是一块车间大屏'))

async function main() {
    const other = heldBy()
    if (other) {
        console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着 —— 等它跑完再来。`)
        return exitAfterCleanup(5)
    }
    acquireOrExit('db/scripts/2026-10-17-mes8b2-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-17-mes8b2-live-proof.mjs')
    await reapStalePlans()
    // 那台 next 起着吗(起不来就是驱动坏了,不是证明红了)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); must(r.status === 200, `${BASE}/login answered ${r.status}`) }
    catch (e) { throw new Error(`MES8B2_DRIVER|no next server at ${BASE}: ${e.message}`) }

    const stamp = Date.now()
    const who = {}
    const mint = async (key, label, codes) => {
        const a = await mintThrowaway({ prefix: 'mes8b2probe', label, stamp, codes })
        who[key] = a
        console.log(`· ${key}: ${a.email} ← ${a.roleCode} (${a.codes.length} codes${Array.isArray(codes) ? ': ' + a.codes.join(', ') : ''})`)
    }
    await mint('floor', 'floor', { realRole: 'floor_display' })
    await mint('fin', 'fin', ['module.finance.view', 'data.view_prices'])
    for (const r of ROLE_CLONES) await mint(`c_${r}`, `c-${r}`, { cloneOf: r })
    must(who.floor.codes.length === 1 && who.floor.codes[0] === 'data.view_floor_board', `the floor account holds ${who.floor.codes.join(',')}`)

    // ══ HTTP 那一半(先跑:它读的是【已提交】的状态 —— 下面那笔事务里加的码它本来就看不见)══
    const d = await get(who.floor, '/display')
    const tiles = (d.body.match(/data-tile="/g) || []).length
    must(d.status === 200 && d.body.includes('data-page="display"') && tiles === 23 && !d.body.includes('data-app-chrome')
        && !d.body.includes('data-section="floor-board-settings"'), `/display as the display: ${d.status}, ${tiles} tiles`)
    const shown = [...d.body.matchAll(/data-value="count-([a-z_0-9]+)">(\d+)</g)].map((m) => `${m[1]}=${m[2]}`)
    console.log(`STEP|http display|/display 200 · 23 tiles · no chrome · no settings panel · counts ${shown.join(' ')}`)
    must(!/[Ss]\$|USD|SGD|@test\.local|@evoltrya/.test(d.body.replace(/<script[\s\S]*?<\/script>/g, '')), 'the board shows money or a name')
    const refused = []
    for (const p of REFUSED_ROUTES) {
        const r = await get(who.floor, p)
        must(r.status === 200 && isFloorRefusal(r.body), `${p} as the display: ${r.status} — not the display refusal`)
        refused.push(p)
    }
    console.log(`STEP|http refusals|${refused.length} other routes refused with the display refusal, way back to /display: ${refused.join(' ')}`)
    const i31 = await get(who.floor, '/display', 31)
    must(i31.status === 200 && i31.body.includes('data-page="display"'), `idle 31 min, the display: ${i31.status} ${i31.loc}`)
    console.log('IDLE|display (floor_display only)|31 min idle → /display 200, not logged out (exempt)')
    for (const r of ROLE_CLONES) {
        const a = who[`c_${r}`]
        const target = r === 'warehouse' ? '/inventory' : '/finance/month-end'
        const s29 = await get(a, target, 29)
        const s31 = await get(a, target, 31)
        must(s29.status === 200, `${r} clone at 29 min: ${s29.status} ${s29.loc}`)
        must(s31.status === 307 && s31.loc.includes('/login') && s31.loc.includes('reason=ended'), `${r} clone at 31 min: ${s31.status} ${s31.loc}`)
        console.log(`IDLE|${r} clone (${a.codes.length} codes)|29 min → ${target} 200 · 31 min → 307 ${s31.loc.split('?')[0]}?reason=ended (logged out as today)`)
    }
    // 角色表的 HTTP 那一列:三页
    const pageRows = {}
    for (const r of ROLE_CLONES) {
        const a = who[`c_${r}`]
        const pd = await get(a, '/display'), pe = await get(a, '/finance/price-exposure'), pa = await get(a, '/settings/accounts')
        const kns = pe.body.includes('data-section="exposure-kind-not-stated"')
        pageRows[r] = {
            display: pd.status === 200 && pd.body.includes('data-page="display"') ? (pd.body.includes('data-form="floor-board-settings"') ? 'board + V28 panel' : 'board') : (pd.body.includes('data-access-denied') ? 'refused' : `HTTP ${pd.status}`),
            exposure: pe.status !== 200 ? `HTTP ${pe.status}` : pe.body.includes('data-access-denied') ? 'page refused'
                : pe.body.includes('data-access-restricted="inventory-exposure"') ? 'page · stock section Restricted' : kns ? 'page · stock section with "kind not stated"' : 'page · stock section',
            accounts: pa.status !== 200 ? `HTTP ${pa.status}` : pa.body.includes('data-access-denied') ? 'refused' : 'open',
            panelPressable: pd.body.includes('data-form="floor-board-settings"') && !/<fieldset[^>]*disabled[^>]*>\s*<div[^>]*data-form="floor-board-settings"/.test(pd.body),
        }
    }

    // ══ 库里那一半(一笔回滚的事务)══
    startPsql()
    const emails = Object.entries(who).map(([k, a]) => `(${lit('email.' + k)}, ${lit(a.email)})`).join(', ')
    let v = await run(String.raw`
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '300s';
SET LOCAL lock_timeout = '10s';
CREATE TEMP TABLE p8 (k text PRIMARY KEY, v text) ON COMMIT DROP;
INSERT INTO p8 VALUES ${emails};
CREATE FUNCTION pg_temp.put_(p_k text, p_v text) RETURNS void LANGUAGE sql AS $f$
    INSERT INTO p8 VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v $f$;
CREATE FUNCTION pg_temp.val_(p_k text) RETURNS text LANGUAGE sql AS $f$ SELECT v FROM p8 WHERE k = p_k $f$;
CREATE FUNCTION pg_temp.uid_(p_who text) RETURNS uuid LANGUAGE sql AS $f$
    SELECT u.id FROM auth.users u WHERE u.email = (SELECT v FROM p8 WHERE k = 'email.' || p_who) $f$;
CREATE FUNCTION pg_temp.as_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_uid uuid; e text := (SELECT x.v FROM p8 x WHERE x.k = 'email.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v_uid FROM auth.users WHERE email = e;
    IF v_uid IS NULL OR e NOT LIKE 'mes8b2probe-%@test.local' THEN RAISE EXCEPTION 'MES8B2_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
CREATE FUNCTION pg_temp.me_() RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
END $f$;
CREATE FUNCTION pg_temp.try_(p_who text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.as_(p_who);
    EXECUTE p_sql;
    PERFORM pg_temp.me_();
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.me_();
    RETURN SQLERRM;
END $f$;
CREATE FUNCTION pg_temp.get_(p_who text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.as_(p_who);
    EXECUTE p_sql INTO v;
    PERFORM pg_temp.me_();
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.me_();
    RAISE;
END $f$;
CREATE FUNCTION pg_temp.exempt_(p_who text) RETURNS boolean LANGUAGE plpgsql AS $f$
DECLARE v boolean;
BEGIN
    PERFORM pg_temp.as_(p_who);
    v := session_is_floor_display_only();
    PERFORM pg_temp.me_();
    RETURN v;
END $f$;
-- 在册的行:开场的指纹(本证明自己的行按创建时刻排除)
CREATE FUNCTION pg_temp.fp_() RETURNS text LANGUAGE sql AS $f$
    SELECT string_agg(t || ':' || h, '#' ORDER BY t) FROM (VALUES
      ('inbound_batches', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM inbound_batches x)),
      ('output_batches', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM output_batches x)),
      ('inventory_movements', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM inventory_movements x)),
      ('materials', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM materials x)),
      ('material_kinds', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM material_kinds x)),
      ('metal_prices', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM metal_prices x)),
      ('inbound_batch_metals', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM inbound_batch_metals x)),
      ('output_batch_metals', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM output_batch_metals x)),
      ('stocktakes', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM stocktakes x)),
      ('journal_lines', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM journal_lines x)),
      ('floor_board_settings', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM floor_board_settings x)),
      ('roles_real', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM roles x WHERE x.code NOT LIKE 'probe-%')),
      ('role_permissions_real', (SELECT md5(COALESCE(string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code), ''))
                                   FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code NOT LIKE 'probe-%')),
      ('user_roles_real', (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM user_roles x
                            JOIN auth.users u ON u.id = x.user_id WHERE u.email NOT LIKE '%@test.local'))
    ) v(t, h) $f$;
SELECT pg_temp.put_('fp', pg_temp.fp_());
SELECT pg_temp.put_('pending', (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()));
SELECT 'OUT|ok|1';
`, 'open')

    // ① 大屏:只有数,每一支的数 = 基视图的行数;读别的东西是 0 行
    v = await run(String.raw`
DO $s$
DECLARE b jsonb; x jsonb; bad text;
BEGIN
    b := pg_temp.get_('floor', 'SELECT floor_board()');
    IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(b) k) IS DISTINCT FROM ARRAY['as_of', 'refresh_seconds', 'settings_set', 'tiles']
       OR jsonb_array_length(b -> 'tiles') <> 23
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(b -> 'tiles') t WHERE (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(t) k) IS DISTINCT FROM ARRAY['count', 'item_type', 'section']) THEN
        RAISE EXCEPTION 'MES8B2_LIVE|the board returns more than counts: %', b;
    END IF;
    SELECT string_agg(t ->> 'item_type', ', ') INTO bad FROM jsonb_array_elements(b -> 'tiles') t
     WHERE (t ->> 'count')::bigint <> (SELECT count(*) FROM operations_arms_all a WHERE a.item_type = t ->> 'item_type');
    IF bad IS NOT NULL THEN RAISE EXCEPTION 'MES8B2_LIVE|tile counts differ from the arms: %', bad; END IF;
    IF jsonb_typeof(b -> 'refresh_seconds') <> 'null' OR (b ->> 'settings_set')::boolean THEN RAISE EXCEPTION 'MES8B2_LIVE|V28 should be unset on live: %', b - 'tiles'; END IF;
    x := pg_temp.get_('floor', $q$SELECT jsonb_build_object('ops', (SELECT count(*) FROM operations_now), 'ib', (SELECT count(*) FROM inbound_batches),
                                                         'inc', (SELECT count(*) FROM incidents), 'st', (SELECT count(*) FROM stocktakes),
                                                         'emp', (SELECT count(*) FROM employees), 'pv', (SELECT count(*) FROM pending_values))$q$);
    IF (x ->> 'ops')::int + (x ->> 'ib')::int + (x ->> 'inc')::int + (x ->> 'st')::int + (x ->> 'emp')::int + (x ->> 'pv')::int <> 0 THEN
        RAISE EXCEPTION 'MES8B2_LIVE|the display session reads rows: %', x;
    END IF;
    IF pg_temp.try_('c_warehouse', 'SELECT floor_board()') NOT LIKE 'PERMISSION_DENIED|data.view_floor_board%' THEN
        RAISE EXCEPTION 'MES8B2_LIVE|a session without the code reads the board';
    END IF;
    RAISE NOTICE 'STEP|board|floor_board() as the display: keys {as_of, refresh_seconds, settings_set, tiles}, 23 tiles of {section, item_type, count}, every count = its arm''s rows, V28 unset (no interval); the display reads 0 rows of operations_now · inbound_batches · incidents · stocktakes · employees · pending_values; warehouse clone → PERMISSION_DENIED|data.view_floor_board · counts %',
        (SELECT string_agg((t ->> 'item_type') || '=' || (t ->> 'count'), ' ') FROM jsonb_array_elements(b -> 'tiles') t WHERE (t ->> 'count')::int > 0);
END $s$;
SELECT 'OUT|ok|1';
`, 'board')

    // ② 豁免:只有大屏;七个克隆;floor_display 多一个码 / 大屏账号多一个角色
    v = await run(String.raw`
DO $s$
DECLARE r text; c text; n int := 0; v_role uuid; v_x uuid;
BEGIN
    IF pg_temp.exempt_('floor') IS NOT TRUE THEN RAISE EXCEPTION 'MES8B2_LIVE|the display account is not exempt'; END IF;
    RAISE NOTICE 'IDLE|db · display (only floor_display, only data.view_floor_board)|session_is_floor_display_only() = true';
    FOREACH r IN ARRAY ARRAY['admin', 'cfo', 'finance', 'cco', 'cto', 'warehouse', 'gm'] LOOP
        IF pg_temp.exempt_('c_' || r) IS NOT FALSE THEN RAISE EXCEPTION 'MES8B2_LIVE|the % clone would be exempt', r; END IF;
        RAISE NOTICE 'IDLE|db · % clone|session_is_floor_display_only() = false (idle logout unchanged)', r;
    END LOOP;
    SELECT id INTO v_role FROM roles WHERE code = 'floor_display';
    FOR c IN SELECT code FROM permissions WHERE code <> 'data.view_floor_board' ORDER BY code LOOP
        BEGIN
            INSERT INTO role_permissions (role_id, permission_code) VALUES (v_role, c);
            IF pg_temp.exempt_('floor') IS NOT FALSE THEN RAISE EXCEPTION 'MES8B2_LIVE|floor_display + % is still exempt', c; END IF;
            IF pg_temp.try_('floor', 'SELECT floor_board()') <> 'OK' THEN RAISE EXCEPTION 'MES8B2_LIVE|floor_display + % no longer opens the board', c; END IF;
            n := n + 1;
            RAISE EXCEPTION 'MES8B2_UNDO';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM <> 'MES8B2_UNDO' THEN RAISE; END IF;
        END;
    END LOOP;
    IF pg_temp.exempt_('floor') IS NOT TRUE THEN RAISE EXCEPTION 'MES8B2_LIVE|the display is not exempt again after the codes were undone'; END IF;
    RAISE NOTICE 'IDLE|db · floor_display + any other code|% codes tried one at a time (each in a sub-transaction, undone): exempt = false every time, /display still opens', n;
    -- 大屏账号多一个角色(一个零码的一次性角色,子事务里)
    BEGIN
        INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-mes8b2-extra', 'probe', 'probe', true) RETURNING id INTO v_x;
        INSERT INTO user_roles (user_id, role_id) VALUES (pg_temp.uid_('floor'), v_x);
        IF pg_temp.exempt_('floor') IS NOT FALSE THEN RAISE EXCEPTION 'MES8B2_LIVE|a second role on the display account leaves it exempt'; END IF;
        RAISE EXCEPTION 'MES8B2_UNDO';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'MES8B2_UNDO' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'IDLE|db · display account + a second role (no codes)|exempt = false';
END $s$;
SELECT 'OUT|ok|1';
`, 'exemption')

    // ③ F18:种类没说的库存逐批列出来
    v = await run(String.raw`
DO $s$
DECLARE e jsonb;
BEGIN
    e := pg_temp.get_('fin', 'SELECT inventory_metal_exposure()');
    RAISE NOTICE 'STEP|F18|as a finance.view + view_prices throwaway: kind_not_stated % batch(es), % kg (inbound %, output %); complete %; value of what is measured and priced USD %; not measured %',
        jsonb_array_length(e -> 'kind_not_stated'), e ->> 'kind_not_stated_kg',
        (SELECT count(*) FROM jsonb_array_elements(e -> 'kind_not_stated') x WHERE x ->> 'kind' = 'inbound'),
        (SELECT count(*) FROM jsonb_array_elements(e -> 'kind_not_stated') x WHERE x ->> 'kind' = 'output'),
        e ->> 'complete', e ->> 'value_usd_priced', jsonb_array_length(e -> 'not_measured');
    RAISE NOTICE 'STEP|F18 list|%', (SELECT string_agg((x ->> 'code') || ' ' || COALESCE(x ->> 'kg', (x ->> 'qty') || ' ' || (x ->> 'unit')), ' · ' ORDER BY x ->> 'code')
                                      FROM jsonb_array_elements(e -> 'kind_not_stated') x);
    PERFORM pg_temp.put_('f18', e::text);
END $s$;
SELECT 'OUT|f18|' || pg_temp.val_('f18');
`, 'f18')
    const f18 = JSON.parse(v.f18)
    must(f18.kind_not_stated.length === 23 && Number(f18.kind_not_stated_kg) === 119104 && f18.complete === false,
        `F18 on live: ${f18.kind_not_stated.length} batches, ${f18.kind_not_stated_kg} kg, complete ${f18.complete} (expected 23 · 119,104 · false)`)

    // ④ 角色表:七个克隆在三页上
    for (const r of ROLE_CLONES) {
        v = await run(String.raw`
SELECT 'OUT|row|' || jsonb_build_object(
    'codes', (SELECT count(*) FROM role_permissions rp JOIN roles x ON x.id = rp.role_id JOIN user_roles ur ON ur.role_id = x.id WHERE ur.user_id = pg_temp.uid_(${lit('c_' + r)})),
    'board', pg_temp.try_(${lit('c_' + r)}, 'SELECT floor_board()'),
    'exposure', pg_temp.try_(${lit('c_' + r)}, 'SELECT inventory_metal_exposure()'),
    'manage', pg_temp.try_(${lit('c_' + r)}, 'SELECT require_permission(''action.manage_permissions'')'),
    'exempt', pg_temp.exempt_(${lit('c_' + r)}))::text;
`, `role ${r}`)
        const row = JSON.parse(v.row)
        const short = (s) => (s === 'OK' ? 'yes' : `no (${s.split('|')[0]}${s.includes('|') ? '|' + s.split('|')[1] : ''})`)
        const h = pageRows[r]
        console.log(`ROLE|${r}|codes ${row.codes}|/display ${h.display} (floor_board ${short(row.board)})|V28 panel ${h.display.includes('panel') ? (row.manage === 'OK' ? 'pressable' : 'drawn disabled, names action.manage_permissions') : '—'}|/finance/price-exposure ${h.exposure} (inventory_metal_exposure ${short(row.exposure)})|/settings/accounts ${h.accounts} (manage accounts ${short(row.manage)})|idle exempt ${row.exempt}`)
    }

    // ⑤ 在册的东西一个字都没动;收尾
    v = await run(String.raw`
DO $s$
BEGIN
    IF pg_temp.fp_() IS DISTINCT FROM pg_temp.val_('fp') THEN RAISE EXCEPTION 'MES8B2_LIVE|pre-existing rows changed'; END IF;
    IF (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()) <> pg_temp.val_('pending') THEN
        RAISE EXCEPTION 'MES8B2_LIVE|the pending documents changed';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'MES8B2_LIVE|require_calibrated_since set'; END IF;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES8B2_LIVE|approvals switched off'; END IF;
    RAISE NOTICE 'STEP|untouched|pre-existing rows identical (inbound, output, movements, materials, kinds, prices, content, stocktakes, journal lines, V28 row, real roles, their codes, real accounts'' roles); pending «%»; approvals on; require_calibrated_since NULL', pg_temp.val_('pending');
END $s$;
-- 两条勾稽(以 cfo 的克隆读)
DO $s$
DECLARE s jsonb;
BEGIN
    PERFORM pg_temp.as_('c_cfo');
    FOR s IN SELECT x FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') x LOOP
        RAISE NOTICE 'STEP|reconciliation|% list % · ledger % · unexplained %', s ->> 'side', s ->> 'list_base', s ->> 'ledger_base', s ->> 'unexplained_base';
        IF (s ->> 'unexplained_base')::numeric <> 0 THEN RAISE EXCEPTION 'MES8B2_LIVE|% unexplained %', s ->> 'side', s ->> 'unexplained_base'; END IF;
    END LOOP;
    PERFORM pg_temp.me_();
END $s$;
ROLLBACK;
SELECT 'OUT|afterDb|' || 'floor_display holders=' || (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id JOIN auth.users u ON u.id = ur.user_id
                                                      WHERE r.code = 'floor_display' AND u.email NOT LIKE 'mes8b2probe-%')
    || ' · floor_display codes=' || (SELECT string_agg(rp.permission_code, ',') FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'floor_display')
    || ' · V28 set=' || (SELECT count(*) FROM floor_board_settings WHERE refresh_seconds IS NOT NULL OR tiles IS NOT NULL)
    || ' · require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL')
    || ' · approvals=' || approvals_enabled()::text;
`, 'close')
    console.log(`AFTER|database (after ROLLBACK): ${v.afterDb}`)
    psql.stdin.end()
    console.log('STEP|done|both halves')
    return exitAfterCleanup(0)
}

async function endTransaction() {
    if (!psql || psql.exitCode !== null) return
    const gone = new Promise((r) => psql.once('exit', r))
    psql.kill('SIGTERM')
    await Promise.race([gone, new Promise((r) => setTimeout(r, 10_000))])
}
main().catch(async (e) => {
    console.error('✗ ' + (e?.stack || e))
    await endTransaction()
    return exitAfterCleanup(String(e?.message || '').startsWith('MES8B2_LIVE') || String(e?.message || '').startsWith('MES8B2_SQL') ? 1 : 2)
})
