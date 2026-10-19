#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-9a(2026-10-19)· 对照:一个【员工】一次性账号第一次登录(must_change_password),地址栏是什么
// ════════════════════════════════════════════════════════════════════════════
// 线上验证 ② 量到:门户账号第一次登录,换密码的表单在屏幕上,而地址栏是 /portal(导航 /login → /login → /portal)。
// 这支只问一件事:员工走同一条机制时是不是也一样 —— 一样 = 那是登录动作 redirect() 的既有形状,不是门户这一刀带来的;
// 不一样 = 门户的路径有自己的毛病。一个一次性员工账号(gm 的同码克隆,前缀 mes9aprobe),打上 must_change_password,
// 经 /login 登录,记下导航序列、地址栏、表单在不在。不换密码;账号由计划删掉。
// 判决:最后一行 `MES9A_ADDR_EXIT=`(0 = 读到了,读数本身不是判词;2 = 驱动坏了)。
// 用法:PROOF_BASE=http://localhost:3196 PUPPETEER_CORE=<…/puppeteer-core.js> node db/scripts/2026-10-19-mes9a-first-signin-address.mjs
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const BASE = process.env.PROOF_BASE || 'http://localhost:3196'
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')
let locked = false, browser = null
installExitHooks({
    beforeFinish: async () => { try { if (browser) await browser.close() } catch { /* 浏览器已经没了 */ } },
    onFinish: (code) => { try { if (locked) release() } catch { /* 放锁失败不改判决 */ } console.log(`MES9A_ADDR_EXIT=${code}`) },
})

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-19-mes9a-first-signin-address.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-19-mes9a-first-signin-address.mjs')
    await reapStalePlans()
    const txt = readFileSync(join(ROOT, '.env.local'), 'utf8')
    const get = (k) => (txt.match(new RegExp('^' + k + '=(.*)$', 'm'))?.[1] ?? '').trim().replace(/^"|"$/g, '')
    const URL_ = get('NEXT_PUBLIC_SUPABASE_URL'), SERVICE = get('SUPABASE_SERVICE_ROLE_KEY')
    const puppeteer = (await import(process.env.PUPPETEER_CORE)).default
    browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox'] })

    const s = await mintThrowaway({ prefix: 'mes9aprobe', label: 'addr-gm', codes: { cloneOf: 'gm' }, signIn: false })
    const put = await fetch(`${URL_}/auth/v1/admin/users/${s.userId}`, { method: 'PUT',
        headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ user_metadata: { must_change_password: true } }) })
    if (!put.ok) throw new Error(`MES9A_DRIVER|could not mark the throwaway: HTTP ${put.status}`)

    const ctx = await browser.createBrowserContext()
    const page = await ctx.newPage()
    const seen = []
    page.on('framenavigated', (f) => { if (f === page.mainFrame()) seen.push(new URL(f.url()).pathname) })
    await page.setCookie({ name: 'NEXT_LOCALE', value: 'en', url: BASE })
    await page.goto(`${BASE}/login`, { waitUntil: 'networkidle0' })
    await page.type('input[name="email"]', s.email)
    await page.type('input[name="password"]', s.password)
    await Promise.all([page.waitForNavigation({ waitUntil: 'networkidle0' }).catch(() => null), page.click('form button[type="submit"]')])
    await page.waitForSelector('input[name="confirm"]', { timeout: 30000 }).catch(() => null)
    const form = await page.$('input[name="confirm"]') !== null
    const address = new URL(page.url()).pathname
    console.log(`ADDR|staff (gm clone), first sign-in|change-password form on screen=${form}|address ${address}|navigations ${seen.join(' → ')}`)
    // 地址栏那一页刷新一次:中间件这时会看见这个请求
    await page.reload({ waitUntil: 'networkidle0' })
    console.log(`ADDR|staff (gm clone), after a reload|address ${new URL(page.url()).pathname}|form=${await page.$('input[name="confirm"]') !== null}`)
    await ctx.close()
    return exitAfterCleanup(0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return exitAfterCleanup(2)
})
