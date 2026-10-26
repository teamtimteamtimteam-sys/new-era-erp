#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-3 · 线上证明(回滚)—— 保存的视图 · 批量批准的四眼(Q4)· 驳回要理由(Q11)
// ════════════════════════════════════════════════════════════════════════════
// 【一笔事务,结尾 ROLLBACK】(LIVE SAFETY:每一个线上证明都在回滚的事务里;一次性账号经共享的 mintThrowaway 造)
//   V  保存的视图:一次性账号 sv 以本人身份(SET LOCAL ROLE authenticated + 它的 JWT)存一个视图 ——
//      查询串由 lib/savedViews.ts encodeViewQuery 从「本月 + 未付 + 第 2 页」的地址算出来(页码去掉、本月存成 date_preset=thisMonth);
//      设为默认(与 saved-view-actions.ts setDefaultView 同样的两句 UPDATE);重新读出(与 loadSavedViews 同一句 SELECT)→
//      默认的那个就是它;viewHref 把它解成【今天的】新加坡本月起止(与本脚本独立算的那一对逐字相同)。另一个一次性账号读到 0 行。
//   B  ★ Q4(Tim 2026-10-26 明确的一次性例外):审批人 apr 在【本事务里】得到真的 cfo 角色 —— 一条【新的】user_roles 行,
//      回滚带走它;没有任何既有行被改。三张人工凭证申请:两张由 req 提、一张由 apr 自己提;然后逐张调用单击那一个函数
//      decide_journal_request(每张一个子事务,与界面上一次一项、各自一笔事务同形)→ 期望 两张批准、一张 SELF_APPROVAL_FORBIDDEN。
//   (结果行用 | 分格,而库的拒绝本身形如 CODE|<编号> —— 所以消息里的 | 在 SQL 那头换成 #,不让分格把编号切掉;第二轮就是被它切掉的,见 readings)
//   L  Q11:一张待批的请假、一张待决的医疗报销(本事务里新建、属于一次性员工)→ hr 以空理由驳回,各被按名拒
//      LEAVE_REJECT_REASON_REQUIRED|<编号> · MEDICAL_CLAIM_REJECT_REASON_REQUIRED|<编号>,单据不动;带理由驳回落下。
// 【浏览器(只看,不按)】next start 跑这棵树、对着线上:/finance/claims 上批量条与「全选本屏」摆着;/finance/expenses 上视图条摆着。
//   什么都不按 —— Q4:线上只摆出批量条与全选。
// 【事后读回】0 个一次性账号;除真的 cfo 持有人之外 0 条授 cfo 的 user_roles。
// 判决只认最后一行 `TF3_PROOF_EXIT=`:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3196 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-26-table-features-3-live-proof.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'
import { encodeViewQuery, viewHref } from '../../lib/savedViews.ts'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3196'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-26-table-features-3-live-proof.mjs'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|committed on live: only the throwaway accounts and their grants (removed by the plan); everything else ran in one transaction that ended in ROLLBACK')
        console.log(`TF3_PROOF_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 180_000 })
    if (r.status !== 0) throw new Error(`TF3_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-6).join(' / ')}`)
    return { rows: (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6)), out: r.stdout ?? '' }
}
const kv = (line) => Object.fromEntries(line.split('|').map((p) => { const i = p.indexOf('='); return [p.slice(0, i), p.slice(i + 1)] }))
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`

function sgToday() { return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore' }).format(new Date()) }
// 独立于 lib/datePresets.ts 的第二份算术(与 TF-2 证明同一支):证明要的是两条路对上
function expectedPresets(today, fyM, fyD) {
    const [y, m] = today.split('-').map(Number)
    const dim = (yy, mm) => new Date(Date.UTC(yy, mm, 0)).getUTCDate()
    const f = (yy, mm, dd) => `${yy}-${String(mm).padStart(2, '0')}-${String(dd).padStart(2, '0')}`
    const lm = m === 1 ? 12 : m - 1, ly = m === 1 ? y - 1 : y
    const qs = [1, 4, 7, 10].filter((q) => q <= m).pop()
    const fyEnd = (yy) => f(yy, fyM, Math.min(fyD, dim(yy, fyM)))
    const endY = fyEnd(y) >= today ? y : y + 1
    const prev = new Date(Date.UTC(endY - 1, fyM - 1, Math.min(fyD, dim(endY - 1, fyM)) + 1))
    return [
        { key: 'thisMonth', from: f(y, m, 1), to: f(y, m, dim(y, m)) },
        { key: 'lastMonth', from: f(ly, lm, 1), to: f(ly, lm, dim(ly, lm)) },
        { key: 'thisQuarter', from: f(y, qs, 1), to: f(y, qs + 2, dim(y, qs + 2)) },
        { key: 'thisYear', from: prev.toISOString().slice(0, 10), to: fyEnd(endY) },
    ]
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

async function openAs(reader, path) {
    const page = await browser.newPage()
    await page.setViewport({ width: 1280, height: 900 })
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
    return { page, status: res?.status() }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TF3_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TF3_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`TF3_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    // ── 布景:库里的数(以 postgres 只读)──────────────────────────────────
    const pre = kv(psql(`
        SELECT 'PROOF|fym=' || fy_end_month || '|fyd=' || fy_end_day FROM fiscal_year_end_setting();
        SELECT 'PROOF|approvals=' || approvals_enabled || '|l2=' || approval_level2_role_code || '|locked=' || COALESCE(locked_before::text, 'none') FROM finance_settings;
        SELECT 'PROOF|base=' || code FROM currencies WHERE is_base;
        SELECT 'PROOF|lvtype=' || code FROM leave_types WHERE is_active ORDER BY code LIMIT 1;`).rows.join('|'))
    const today = sgToday()
    const presets = expectedPresets(today, Number(pre.fym), Number(pre.fyd))
    const tm = presets[0]
    console.log(`STEP|database as postgres: ${JSON.stringify(pre)} · SG today ${today} · this month ${tm.from}…${tm.to}`)

    // ── 一次性账号(共享的 mintThrowaway;线上提交的只有它们与它们的一次性角色,收尾计划收走)──
    const stamp = Date.now()
    const sv  = await mintThrowaway({ prefix: 'tf3probe', label: 'views',    stamp, codes: ['module.finance.view'] })
    const sv2 = await mintThrowaway({ prefix: 'tf3probe', label: 'views2',   stamp, codes: ['module.finance.view'] })
    const req = await mintThrowaway({ prefix: 'tf3probe', label: 'raiser',   stamp, codes: ['module.finance.view', 'module.finance.edit', 'data.view_prices'] })
    const apr = await mintThrowaway({ prefix: 'tf3probe', label: 'approver', stamp, codes: ['module.finance.view', 'module.finance.edit', 'data.view_prices'] })
    const hr  = await mintThrowaway({ prefix: 'tf3probe', label: 'hr',       stamp, codes: ['module.hr.view', 'action.decide_hr_requests'] })
    const fin = await mintThrowaway({ prefix: 'tf3probe', label: 'browse',   stamp, codes: ['module.finance.view', 'module.finance.edit', 'data.view_prices'] })

    // V 的查询串:由 lib/savedViews.ts 从一条真实形状的地址算出来
    const dates = { fromKey: 'date_from', toKey: 'date_to', presets }
    const storedQuery = encodeViewQuery(`?status=unpaid&date_from=${tm.from}&date_to=${tm.to}&page=2`, dates)
    ok(storedQuery === 'status=unpaid&date_preset=thisMonth',
       `V encode: "?status=unpaid&date_from=${tm.from}&date_to=${tm.to}&page=2" is stored as "${storedQuery}" (page dropped, this month stored as its name — Q2)`)

    const as = (u) => `PERFORM set_config('request.jwt.claims', ${lit(JSON.stringify({ sub: u.userId, role: 'authenticated' }))}, true); EXECUTE 'SET LOCAL ROLE authenticated';`
    const lines = (memo) => `jsonb_build_array(
        jsonb_build_object('account_code', '6400', 'side', 'debit',  'currency', ${lit(pre.base)}, 'amount_ccy', 10, 'line_memo', ${lit(memo + ' dr')}),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', ${lit(pre.base)}, 'amount_ccy', 10, 'line_memo', ${lit(memo + ' cr')}))`

    const sql = `
BEGIN;
SET LOCAL statement_timeout = '120s';
CREATE TEMP TABLE tf3_proof (seq serial, line text) ON COMMIT DROP;
GRANT ALL ON tf3_proof TO authenticated;
GRANT ALL ON SEQUENCE tf3_proof_seq_seq TO authenticated;

-- ══ V · 保存的视图:存 → 设默认 → 重新读出(以本人身份,RLS 生效)══
DO $v$
DECLARE v_id uuid; v_n int;
BEGIN
    ${as(sv)}
    INSERT INTO saved_views (list_key, name, query) VALUES ('/finance/expenses', 'TF3 proof - unpaid this month', ${lit(storedQuery)}) RETURNING id INTO v_id;
    -- saved-view-actions.ts setDefaultView 的两句
    UPDATE saved_views SET is_default = false WHERE list_key = '/finance/expenses' AND is_default;
    UPDATE saved_views SET is_default = true WHERE id = v_id AND list_key = '/finance/expenses';
    -- lib/savedViewsServer.ts loadSavedViews 的那一句
    INSERT INTO tf3_proof (line) SELECT 'PROOF|arm=V|name=' || name || '|query=' || query || '|default=' || is_default || '|user_ok=' || (user_id = auth.uid())
      FROM saved_views WHERE list_key = '/finance/expenses' ORDER BY name;
    EXECUTE 'RESET ROLE';
    ${as(sv2)}
    SELECT count(*) INTO v_n FROM saved_views;
    INSERT INTO tf3_proof (line) VALUES ('PROOF|arm=V2|other_reader_rows=' || v_n);
    EXECUTE 'RESET ROLE';
END $v$;

-- ══ B · Q4:真的 cfo 角色作为一条【新的】授权行给审批人(回滚带走);三张申请;逐张单击那一个函数 ══
DO $b$
DECLARE r_l2 uuid; jr uuid[] := '{}'; v_label text[] := '{}'; v_res jsonb; v_msg text; i int;
BEGIN
    SELECT id INTO r_l2 FROM roles WHERE code = (SELECT approval_level2_role_code FROM finance_settings LIMIT 1);
    INSERT INTO user_roles (user_id, role_id) VALUES (${lit(apr.userId)}, r_l2);
    INSERT INTO tf3_proof (line) SELECT 'PROOF|arm=B0|approver_real_holders_of_l2=' || count(*) FROM real_role_holders((SELECT approval_level2_role_code FROM finance_settings LIMIT 1)) h WHERE h.user_id = ${lit(apr.userId)};
    -- 两张由 req 提
    ${as(req)}
    v_res := submit_journal_request(${lit(today)}::date, 'TF3 proof A', ${lines('tf3 A')}); jr := jr || (v_res->>'request_id')::uuid;
    v_res := submit_journal_request(${lit(today)}::date, 'TF3 proof B', ${lines('tf3 B')}); jr := jr || (v_res->>'request_id')::uuid;
    EXECUTE 'RESET ROLE';
    -- 一张由审批人自己提
    ${as(apr)}
    v_res := submit_journal_request(${lit(today)}::date, 'TF3 proof C (raised by the approver)', ${lines('tf3 C')}); jr := jr || (v_res->>'request_id')::uuid;
    EXECUTE 'RESET ROLE';
    SELECT array_agg(label ORDER BY array_position(jr, id)) INTO v_label FROM journal_requests WHERE id = ANY(jr);
    -- 一次一项:每一张一个子事务(界面上是每一张一次请求、一笔事务)
    FOR i IN 1 .. array_length(jr, 1) LOOP
        BEGIN
            ${as(apr)}
            PERFORM decide_journal_request(jr[i], true, NULL);
            EXECUTE 'RESET ROLE';
            v_msg := 'done';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            v_msg := 'refused:' || SQLERRM;
        END;
        INSERT INTO tf3_proof (line) SELECT 'PROOF|arm=B|i=' || i || '|label=' || v_label[i] || '|raised_by_approver=' || (created_by = ${lit(apr.userId)})
               || '|outcome=' || replace(v_msg, '|', '#') || '|status=' || status || '|entry=' || COALESCE(result_journal_entry_id::text, 'none')
          FROM journal_requests WHERE id = jr[i];
    END LOOP;
END $b$;

-- ══ L · Q11:驳回要理由(本事务里新建的、属于一次性员工的一张请假与一张医疗报销)══
DO $l$
DECLARE e uuid := gen_random_uuid(); lv uuid := gen_random_uuid(); mc uuid := gen_random_uuid(); v_msg text; b text;
BEGIN
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (e, 'TF3PROOF-EMP', 'TF3 proof employee', 'full_time', 'office', DATE '2020-01-01', ${lit(sv.userId)});
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status, created_by)
    VALUES (lv, 'TF3PROOF-LV', e, ${lit(pre.lvtype)}, DATE '2030-03-04', DATE '2030-03-04', 1, 'pending', ${lit(sv.userId)});
    INSERT INTO medical_claims (id, code, employee_id, claim_date, claim_year, amount_sgd, status, created_by)
    VALUES (mc, 'TF3PROOF-MC', e, DATE '2030-03-04', 2030, 10, 'submitted', ${lit(sv.userId)});
    FOREACH b IN ARRAY ARRAY['NULL', '''''', '''   '''] LOOP
        BEGIN
            ${as(hr)}
            EXECUTE format('SELECT decide_leave_request(%L, false, %s)', lv, b);
            EXECUTE 'RESET ROLE'; v_msg := 'done';
        EXCEPTION WHEN OTHERS THEN EXECUTE 'RESET ROLE'; v_msg := SQLERRM; END;
        INSERT INTO tf3_proof (line) SELECT 'PROOF|arm=L|blank=' || b || '|msg=' || replace(v_msg, '|', '#') || '|status=' || status FROM leave_requests WHERE id = lv;
        BEGIN
            ${as(hr)}
            EXECUTE format('SELECT decide_medical_claim(%L, false, %s)', mc, b);
            EXECUTE 'RESET ROLE'; v_msg := 'done';
        EXCEPTION WHEN OTHERS THEN EXECUTE 'RESET ROLE'; v_msg := SQLERRM; END;
        INSERT INTO tf3_proof (line) SELECT 'PROOF|arm=M|blank=' || b || '|msg=' || replace(v_msg, '|', '#') || '|status=' || status FROM medical_claims WHERE id = mc;
    END LOOP;
    ${as(hr)}
    PERFORM decide_leave_request(lv, false, 'TF3 proof: no cover that week');
    PERFORM decide_medical_claim(mc, false, 'TF3 proof: receipt unreadable');
    EXECUTE 'RESET ROLE';
    INSERT INTO tf3_proof (line) SELECT 'PROOF|arm=LR|leave=' || (SELECT status FROM leave_requests WHERE id = lv) || '|medical=' || (SELECT status FROM medical_claims WHERE id = mc);
END $l$;

SELECT line FROM tf3_proof ORDER BY seq;
ROLLBACK;
`
    const { rows, out } = psql(sql)
    ok(/\nROLLBACK\s*$/.test(out.trimEnd() + '\n') || out.trimEnd().endsWith('ROLLBACK'), `the proof transaction ended in ROLLBACK (psql printed ${JSON.stringify(out.trimEnd().split('\n').pop())})`)
    const arms = rows.map(kv)
    const byArm = (a) => arms.filter((r) => r.arm === a)

    // V
    const v = byArm('V')
    const mine = v.find((r) => r.name === 'TF3 proof - unpaid this month')
    ok(v.length === 1 && mine && mine.default === 'true' && mine.query === storedQuery && mine.user_ok === 'true',
       `V saved, set as default and read back as its owner: ${JSON.stringify(v)}`)
    const href = mine ? viewHref('/finance/expenses', mine.query, dates) : null
    ok(href === `/finance/expenses?status=unpaid&date_from=${tm.from}&date_to=${tm.to}`,
       `V reopened: the default view resolves to ${href} — "This month" computed for SG today ${today} = ${tm.from}…${tm.to} (independent arithmetic)`)
    ok(byArm('V2')[0]?.other_reader_rows === '0', `V another throwaway reads ${byArm('V2')[0]?.other_reader_rows} saved views (own rows only)`)

    // B
    const b0 = byArm('B0')[0]
    ok(b0?.approver_real_holders_of_l2 === '1', `B0 inside the transaction the approver is a real holder of the level-2 role (${pre.l2}): ${b0?.approver_real_holders_of_l2}`)
    const b = byArm('B')
    const done = b.filter((r) => r.outcome === 'done' && r.status === 'approved' && r.entry !== 'none')
    const self = b.filter((r) => r.outcome.startsWith('refused:SELF_APPROVAL_FORBIDDEN') && r.status === 'submitted' && r.raised_by_approver === 'true')
    ok(b.length === 3 && done.length === 2 && self.length === 1 && done.every((r) => r.raised_by_approver === 'false'),
       `B one at a time through decide_journal_request: ${JSON.stringify(b.map((r) => [r.label, r.raised_by_approver === 'true' ? 'raised by approver' : 'raised by another', r.outcome, r.status]))}`)

    // L / M
    const l = byArm('L'), m = byArm('M')
    ok(l.length === 3 && l.every((r) => /^LEAVE_REJECT_REASON_REQUIRED#TF3PROOF-LV$/.test(r.msg) && r.status === 'pending'),
       `L leave reject without a reason refused by name (NULL / '' / '   '): ${JSON.stringify(l.map((r) => [r.blank, r.msg, r.status]))}`)
    ok(m.length === 3 && m.every((r) => /^MEDICAL_CLAIM_REJECT_REASON_REQUIRED#TF3PROOF-MC$/.test(r.msg) && r.status === 'submitted'),
       `M medical-claim reject without a reason refused by name: ${JSON.stringify(m.map((r) => [r.blank, r.msg, r.status]))}`)
    ok(byArm('LR')[0]?.leave === 'rejected' && byArm('LR')[0]?.medical === 'rejected', `L/M with a reason both reject: ${JSON.stringify(byArm('LR')[0])}`)

    // ── 浏览器:只看,不按 ─────────────────────────────────────────────
    {
        const { page, status } = await openAs(fin, '/finance/claims')
        try {
            const r = await page.evaluate(() => {
                const bar = document.querySelector('[data-slot="bulk-bar"]')
                return {
                    bar: !!bar,
                    selectAll: !!bar?.querySelector('input[type="checkbox"]'),
                    cardChecks: document.querySelectorAll('[data-bulk-check]').length,
                    reject: [...(bar?.querySelectorAll('button') ?? [])].map((x) => x.textContent?.trim()),
                    results: !!document.querySelector('[data-slot="bulk-results"]'),
                }
            })
            ok(status === 200 && r.bar && r.selectAll && r.cardChecks >= 1 && r.reject.some((x) => /^Reject selected/.test(x ?? '')) && !r.results,
               `browser /finance/claims → HTTP ${status}: bulk bar ${r.bar}, select-all ${r.selectAll}, card checkboxes ${r.cardChecks}, buttons ${JSON.stringify(r.reject)}; nothing pressed (no result list)`)
        } finally { await page.close() }
    }
    {
        const { page, status } = await openAs(fin, '/finance/expenses')
        try {
            const r = await page.evaluate(() => {
                const bar = document.querySelector('[data-slot="saved-views"]')
                return { bar: !!bar, plain: !!bar?.querySelector('[data-view-plain]'), save: !!bar?.querySelector('[data-view-save="open"]'), url: location.pathname + location.search }
            })
            ok(status === 200 && r.bar && r.plain && r.save && r.url === '/finance/expenses',
               `browser /finance/expenses → HTTP ${status}: views bar ${r.bar}, "Plain list" ${r.plain}, "Save view" ${r.save}; no default for this reader → stays at ${r.url}; nothing pressed`)
        } finally { await page.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TF3_DRIVER') ? 2 : 1)
})
