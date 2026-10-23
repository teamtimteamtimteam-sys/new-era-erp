#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-3 Part 1.2 · TABLE-EXPORT-2b-2 收尾 —— 对着【生产】(Vercel)只读地看一眼
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.2:一个一次性账号打开 /operation/capture/inbox 第 2 页(200 行,与第 1 页不同);
//            一个看得见通知的一次性账号,顶栏徽标与 /notifications 上的未读数相同(并且 = 库里的数)。
//            然后收走账号,读回 0 残留。
// 只读:浏览器只发 GET;库里那一句以一次性账号的身份(request.jwt.claims,SET LOCAL ROLE authenticated)读,一笔事务,ROLLBACK。
//      线上提交的只有一次性账号与它们的授权(前缀 te2b2probe —— 这是 2b-2 的收尾,沿用 2b-2 的前缀,共用造号器),由清理计划收走。
// 判决只从最后一行 `TE2B2_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-23-table-export-2b2-closeout-prod-check.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-23-table-export-2b2-closeout-prod-check.mjs'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`TE2B2_CLOSEOUT_EXIT=${code}`)
    },
})

async function openAs(reader, path) {
    const page = await browser.newPage()
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
    return { page, status: res?.status() }
}

/** psql 一次,读回带 `PROOF|` 前缀的那几行;非零退出码就抛(驱动坏了,不是 FAIL)。 */
function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    const lines = `${r.stdout ?? ''}\n${r.stderr ?? ''}`.split('\n').filter((l) => l.includes('PROOF|'))
    if (r.status !== 0) throw new Error(`TE2B2C_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return lines.map((l) => l.slice(l.indexOf('PROOF|') + 6))
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE2B2C_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE2B2C_DRIVER|no chrome-headless-shell at ${exe}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    console.log(`STEP|base ${BASE}`)

    const stamp = Date.now()
    // 与 2b-2 证明同一组码
    const ops = await mintThrowaway({ prefix: 'te2b2probe', label: 'closeout-ops', stamp, codes: ['module.processing.view'] })
    const ntf = await mintThrowaway({ prefix: 'te2b2probe', label: 'closeout-ntf', stamp, codes: ['module.materials.view', 'module.inventory.view'] })

    // ① 收件箱第 1、2 页:各 200 行,第 2 页的编号全部小于第 1 页最旧的那一条(两页不相交)
    const readPage = async (p) => {
        const { page, status } = await openAs(ops, `/operation/capture/inbox${p > 1 ? `?page=${p}` : ''}`)
        try {
            const r = await page.evaluate(() => ({
                ids: [...document.querySelectorAll('tbody tr')].map((tr) => [...tr.querySelectorAll('td')].map((td) => td.textContent?.trim() ?? '').find((x) => /^#\d+$/.test(x)) ?? '').filter(Boolean).map((x) => Number(x.slice(1))),
                pager: document.querySelector('[data-inbox-pager]')?.textContent?.replace(/\s+/g, ' ').trim() ?? null,
            }))
            return { status, ...r }
        } finally { await page.close() }
    }
    const p1 = await readPage(1), p2 = await readPage(2)
    ok(p1.status === 200 && p1.ids.length === 200, `page 1 → HTTP ${p1.status}, ${p1.ids.length} rows; pager ${JSON.stringify(p1.pager)}`)
    const overlap = p2.ids.filter((id) => p1.ids.includes(id)).length
    ok(p2.status === 200 && p2.ids.length === 200 && overlap === 0 && Math.max(...p2.ids) < Math.min(...p1.ids),
       `page 2 → HTTP ${p2.status}, ${p2.ids.length} rows, ${overlap} shared with page 1; newest #${Math.max(...p2.ids)} < page 1's oldest #${Math.min(...p1.ids)}; pager ${JSON.stringify(p2.pager)}`)

    // ② 未读数:库里(以 ntf 的身份,回滚)= /notifications 上那一句 = 顶栏徽标
    const [dbLine] = psql(`BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"${ntf.userId}","role":"authenticated"}', true);
SELECT 'PROOF|' || (SELECT count(*) FROM notifications) || '|' ||
       (SELECT count(*) FROM notification_reads r JOIN notifications n ON n.id = r.notification_id WHERE r.user_id = '${ntf.userId}');
ROLLBACK;`)
    const [visible, readN] = dbLine.split('|').map(Number)
    const want = visible - readN
    console.log(`STEP|as the throwaway reader (rolled back): ${visible} visible notifications, ${readN} read → ${want} unread`)
    ok(want > 0, `the throwaway reader holds notifications: ${want} unread`)
    {
        const { page, status } = await openAs(ntf, '/notifications')
        try {
            const r = await page.evaluate(() => ({
                page: document.querySelector('[data-unread-count]')?.getAttribute('data-unread-count') ?? null,
                text: document.querySelector('[data-unread-count]')?.textContent?.trim() ?? null,
                bell: document.querySelector('[data-nav="unread-badge"]')?.textContent?.trim() ?? null,
            }))
            const bellWant = want === 0 ? null : want > 9 ? '9+' : String(want)
            ok(status === 200 && r.page === String(want), `/notifications → HTTP ${status}; the page says ${JSON.stringify(r.text)} = database ${want}`)
            ok(r.bell === bellWant, `the top-bar bell shows ${JSON.stringify(r.bell)} = the page's ${r.page} (${bellWant === null ? 'no badge at 0' : 'drawn as ' + bellWant})`)
        } finally { await page.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE2B2C_DRIVER') ? 2 : 1)
})
