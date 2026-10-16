#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-7b-2 · F16(2026-10-16)· 线上测量 —— 每一张 public 视图,以 anon 与以【一个不持任何码的一次性账号】(authenticated),
//   INSERT / UPDATE / DELETE 穿过它【被不被接受】。一笔【回滚】的事务;不碰任何桶。
// ════════════════════════════════════════════════════════════════════════════
// 【它量的是什么 —— 照直说】每一句写都是【零行】的:
//     INSERT INTO v (c) SELECT NULL WHERE false · UPDATE v SET c = c WHERE false · DELETE FROM v WHERE false
//   于是在册的行一行都不被碰(委托书:事务里也不许改、删在册的记录)。一句零行的写【被接受】= 它过了 ① 视图上的表级权限、
//   ② 视图可自动更新(或有 INSTEAD OF)、③ 基表上的语句级守卫(enforce_write_permission 一类,零行也照样触发)。
//   它【不】走到行级触发器与 RLS 的 WITH CHECK —— 那要一行真的数据,而真行只能是在册的行。所以"被接受"是"这条写路是开着的",
//   不是"某一行一定写得进去";反过来,"被拒"是确定的:连零行都过不去的写,任何一行都过不去。
//   c = 那张视图的第一列可更新的列(information_schema.columns.is_updatable);没有可更新的列就用第一列(拿到的是"不可更新"的那句错)。
// 【身份】anon:SET LOCAL ROLE anon,JWT 只有 role=anon。authenticated:mintThrowaway 造的一次性账号(前缀 mes7b2probe),
//   在【这笔事务里】先删掉它那个一次性角色的授权(那几行是本会话造的)—— 于是它在事务里一个码都不持,并当场读回 current_user_permissions() 为空。
// 【判决】只从日志里最后那一行 `VIEW_WRITES_EXIT=` 读。0 = 走完、回滚、一次性账号收干净(不论量出多少张可写)·
//   1 = 测量本身红了(覆盖断言不成立)· 2 = 驱动坏了 · 5 = live-lock 被占。读数在 `SUMMARY|` 与 `VW|` 行。
//   覆盖断言(AGENTS.md「覆盖率本身必须是一条断言」):逐张视图的结果行数 = 目录里的视图数 × 2 个身份 × 3 种写;任一不等 → 1。
// 用法:node db/scripts/2026-10-16-mes7b2-view-writes.mjs > <log> 2>&1
//       node db/scripts/2026-10-16-mes7b2-view-writes.mjs --local "<本地重建的 DSN>"   (排练:账号在事务里用 SQL 建,不经 mintThrowaway)
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { spawnSync } from 'node:child_process'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
let locked = false
installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`VIEW_WRITES_EXIT=${code}`)
    },
})
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`

function measureSql(uid, setup = '') {
    return `\\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL statement_timeout = '900s';
${setup}
-- 那个一次性账号在这笔事务里一个码都不持(删的是本会话造的那个一次性角色的授权)
DELETE FROM role_permissions WHERE role_id IN (SELECT role_id FROM user_roles WHERE user_id = ${lit(uid)});
CREATE FUNCTION pg_temp.vw_try(p_role text, p_sub uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    BEGIN
        PERFORM set_config('request.jwt.claims', CASE WHEN p_sub IS NULL THEN '{"role":"anon"}' ELSE format('{"sub":"%s","role":"authenticated"}', p_sub) END, true);
        EXECUTE format('SET LOCAL ROLE %I', p_role);
        EXECUTE p_sql;
        EXECUTE 'RESET ROLE';
        PERFORM set_config('request.jwt.claims', '', true);
        RETURN 'ACCEPTED';
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('request.jwt.claims', '', true);
        RETURN SQLSTATE || ' ' || left(replace(SQLERRM, E'\\n', ' '), 90);
    END;
END $f$;
DO $m$
DECLARE
    v record; c text; s text; r text; res text; op text;
    n_views int := 0; n_rows int := 0;
    who uuid := ${lit(uid)};
    perms text;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', who), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    perms := (SELECT COALESCE(string_agg(x, ','), '') FROM unnest(current_user_permissions()) x);
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF perms <> '' THEN RAISE EXCEPTION 'VIEW_WRITES: the throwaway still holds codes: %', perms; END IF;
    RAISE NOTICE 'WHO|throwaway %|codes in the transaction: none', who;
    FOR v IN SELECT c.relname, c.oid,
                    COALESCE(c.reloptions::text LIKE '%security_invoker=on%' OR c.reloptions::text LIKE '%security_invoker=true%', false) AS invoker
               FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relkind = 'v' ORDER BY c.relname LOOP
        n_views := n_views + 1;
        SELECT column_name INTO c FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = v.relname AND is_updatable = 'YES' ORDER BY ordinal_position LIMIT 1;
        IF c IS NULL THEN
            SELECT column_name INTO c FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = v.relname ORDER BY ordinal_position LIMIT 1;
        END IF;
        FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
            FOREACH op IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE'] LOOP
                s := CASE op
                       WHEN 'INSERT' THEN format('INSERT INTO public.%I (%I) SELECT NULL WHERE false', v.relname, c)
                       WHEN 'UPDATE' THEN format('UPDATE public.%I SET %I = %I WHERE false', v.relname, c, c)
                       ELSE format('DELETE FROM public.%I WHERE false', v.relname) END;
                res := pg_temp.vw_try(r, CASE WHEN r = 'anon' THEN NULL ELSE who END, s);
                n_rows := n_rows + 1;
                RAISE NOTICE 'VW|%|%|%|%|%', v.relname, CASE WHEN v.invoker THEN 'invoker' ELSE 'owner' END, r, op, res;
            END LOOP;
        END LOOP;
    END LOOP;
    IF n_views = 0 OR n_rows <> n_views * 6 THEN
        RAISE EXCEPTION 'VIEW_WRITES coverage: % views in the catalog, % result rows (want %)', n_views, n_rows, n_views * 6; END IF;
    RAISE NOTICE 'COVERAGE|views=%|results=%', n_views, n_rows;
END $m$;
ROLLBACK;
`
}

function report(out) {
    const rows = []
    for (const line of out.split('\n')) {
        const m = line.match(/VW\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|(.*)$/)
        if (m) rows.push({ view: m[1], kind: m[2], role: m[3], op: m[4], res: m[5] })
        const o = line.match(/(WHO\|.*|COVERAGE\|.*|ERROR:.*)$/)
        if (o) console.log(o[1])
    }
    for (const r of rows) console.log(`VW|${r.view}|${r.kind}|${r.role}|${r.op}|${r.res}`)
    const by = (role) => {
        const acc = rows.filter((r) => r.role === role && r.res === 'ACCEPTED')
        const views = new Set(acc.map((r) => r.view))
        const ops = (op) => acc.filter((r) => r.op === op).length
        const refusals = {}
        for (const r of rows.filter((x) => x.role === role && x.res !== 'ACCEPTED')) {
            const k = r.res.split(' ')[0]; refusals[k] = (refusals[k] || 0) + 1
        }
        console.log(`SUMMARY|${role}|views accepting a write=${views.size}|insert=${ops('INSERT')}|update=${ops('UPDATE')}|delete=${ops('DELETE')}`
            + `|owner-rights among them=${new Set(acc.filter((r) => r.kind === 'owner').map((r) => r.view)).size}|refusals by SQLSTATE=${JSON.stringify(refusals)}`)
        return views
    }
    const a = by('anon'), u = by('authenticated')
    console.log(`SUMMARY|views=${new Set(rows.map((r) => r.view)).size}|accepting a write from anon or authenticated=${new Set([...a, ...u]).size}`)
    return rows.length
}

async function local(dsn) {
    if (!dsn || /supabase|pooler/.test(dsn)) { console.error('--local needs a local DSN (refusing a live one)'); return exitAfterCleanup(2) }
    const { randomUUID } = await import('node:crypto')
    const uid = randomUUID()
    const setup = `DO $l$ DECLARE r uuid; BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (${lit(uid)}, 'mes7b2local-none@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-mes7b2local-none', 'p', 'p', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.tasks.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (${lit(uid)}, r);
END $l$;`
    const p = spawnSync('psql', ['-X', '-q', dsn], { input: measureSql(uid, setup), encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })
    const n = report(p.stderr + p.stdout)
    return exitAfterCleanup(p.status === 0 && !/ERROR:/.test(p.stderr) && n > 0 ? 0 : 1)
}

async function main() {
    if (process.argv[2] === '--local') return local(process.argv[3] ?? '')
    const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
    acquireOrExit('2026-10-16-mes7b2-view-writes.mjs', { ownExit: false }); locked = true
    openPlan('db/scripts/2026-10-16-mes7b2-view-writes.mjs'); await reapStalePlans()
    // 一次性账号:mintThrowaway 不收空码,所以给它一个码,再在那笔事务里把授权删掉(见上)
    const uid = (await mintThrowaway({ prefix: 'mes7b2probe', label: 'nocodes', signIn: false, codes: ['module.tasks.view'] })).userId
    const t0 = Date.now()
    const p = spawnSync('psql', ['-X', '-q', DSN], { input: measureSql(uid), encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })
    const n = report(p.stderr + p.stdout)
    console.log(`TXN|psql exit ${p.status}|${((Date.now() - t0) / 1000).toFixed(1)} s in the transaction`)
    return exitAfterCleanup(p.status === 0 && !/ERROR:/.test(p.stderr) && n > 0 ? 0 : 1)
}
main().catch((e) => { console.error('✗', e?.stack || e); exitAfterCleanup(2) })
