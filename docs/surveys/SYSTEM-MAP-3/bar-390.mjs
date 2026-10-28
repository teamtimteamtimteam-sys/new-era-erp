#!/usr/bin/env node
// SYSTEM-MAP-3 Step 0 · the 390 px measurement for the upstream/downstream bar (brief: "the bar must work at 390 px on the
// longest chain (purchasing, eight steps); measure it"). Read-only against production: one throwaway cfo clone opens one
// purchase order detail page (GET only, nothing pressed), and a PROTOTYPE bar is injected into that page's DOM in the
// browser (never saved anywhere) in three layouts × two languages, to measure what fits in the real content column.
//   A · one row, no wrap (does it overflow the column?)
//   B · one row of chips that wraps (how many lines, how tall?)
//   C · a vertical list, one step per line (how tall?)
// Each step carries its label and one sample document code — the widest real shape is label + code.
// Verdict from the last line only: BAR390_EXIT= (0 measured · 2 driver broken · 5 live-lock held · 6 cleanup incomplete).
// Usage: PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<dir with puppeteer-core> PO_ID=<uuid> node docs/surveys/SYSTEM-MAP-3/bar-390.mjs
import { readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
const PUP_DIR = process.env.PUPPETEER_DIR
const PO_ID = process.env.PO_ID
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const SCRIPT = 'docs/surveys/SYSTEM-MAP-3/bar-390.mjs'
const STEPS = {
    en: [['Purchase order', 'PO-2026-0003'], ['Inbound batch', 'IN-2026-0322'], ['Assay', 'ASY-2026-0004'], ['Pricing', 'IN-2026-0322'],
        ['Payable', 'IN-2026-0322'], ['Payment request', 'PREQ-2026-0001'], ['Payment', 'PMT-2026-0011'], ['Bank reconciliation', 'BS-2026-0001']],
    zh: [['采购单', 'PO-2026-0003'], ['进料批', 'IN-2026-0322'], ['化验', 'ASY-2026-0004'], ['定价', 'IN-2026-0322'],
        ['应付', 'IN-2026-0322'], ['付款申请', 'PREQ-2026-0001'], ['付款', 'PMT-2026-0011'], ['银行对账', 'BS-2026-0001']],
}

let locked = false, browser = null
installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch { /* */ } console.log(`BAR390_EXIT=${code}`) } })

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* */ }
    browser = null
    return exitAfterCleanup(code)
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()
    if (!PO_ID) throw new Error('BAR_DRIVER|PO_ID not set')
    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('BAR_DRIVER|PUPPETEER_DIR has no puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    const reader = await mintThrowaway({ prefix: 'sm2probe', label: 'bar390-cfo', stamp: Date.now(), codes: { cloneOf: 'cfo' } })

    for (const lang of ['en', 'zh']) {
        for (const width of [390, 1440]) {
            const page = await browser.newPage()
            await page.setViewport({ width, height: 844, deviceScaleFactor: 1, isMobile: width < 768, hasTouch: width < 768 })
            const host = new URL(BASE).hostname
            const cdp = await page.createCDPSession()
            await cdp.send('Network.setCookies', { cookies: [
                { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
                { name: 'NEXT_LOCALE', value: lang, domain: host, path: '/' },
            ] })
            const res = await page.goto(`${BASE}/purchasing/orders/${PO_ID}`, { waitUntil: 'networkidle2', timeout: 120_000 })
            const m = await page.evaluate((steps) => {
                const h1 = document.querySelector('main h1') || document.querySelector('h1')
                const host = h1?.parentElement
                const before = document.documentElement.scrollWidth
                const col = host.getBoundingClientRect()
                const out = { status: null, column: Math.round(col.width), pageBefore: before, vw: innerWidth, layouts: {} }
                const chip = (lbl, code, i) => `<span style="display:inline-flex;align-items:baseline;gap:4px;white-space:nowrap;padding:2px 8px;border:1px solid #ccc;border-radius:9999px;font-size:13px;${i === 0 ? 'font-weight:600' : ''}"><span>${lbl}</span><span style="font-family:ui-monospace,monospace;font-size:12px">${code}</span></span>`
                const sep = '<span aria-hidden="true" style="padding:0 2px">→</span>'
                const mk = (style, inner) => { const d = document.createElement('nav'); d.setAttribute('style', style); d.innerHTML = inner; host.insertBefore(d, h1.nextSibling); return d }
                const A = mk('display:flex;flex-wrap:nowrap;gap:4px;align-items:center;font-size:13px', steps.map((s, i) => chip(s[0], s[1], i)).join(sep))
                out.layouts.A_one_row = { needed: Math.round(A.scrollWidth), fits: A.scrollWidth <= col.width, pageAfter: document.documentElement.scrollWidth }
                A.remove()
                const B = mk('display:flex;flex-wrap:wrap;gap:4px 4px;align-items:center;font-size:13px', steps.map((s, i) => chip(s[0], s[1], i)).join(sep))
                const tops = new Set([...B.children].filter((c) => c.textContent.trim() !== '→').map((c) => Math.round(c.getBoundingClientRect().top)))
                out.layouts.B_wrapping_chips = { lines: tops.size, height: Math.round(B.getBoundingClientRect().height), pageAfter: document.documentElement.scrollWidth }
                B.remove()
                const C = mk('display:grid;grid-template-columns:auto 1fr;gap:2px 8px;font-size:13px', steps.map((s, i) => `<span style="white-space:nowrap;${i === 0 ? 'font-weight:600' : ''}">${s[0]}</span><span style="font-family:ui-monospace,monospace;font-size:12px">${s[1]}</span>`).join(''))
                out.layouts.C_vertical = { height: Math.round(C.getBoundingClientRect().height), widest: Math.round(Math.max(...[...C.children].map((c) => c.getBoundingClientRect().width))), pageAfter: document.documentElement.scrollWidth }
                C.remove()
                return out
            }, STEPS[lang])
            m.status = res?.status()
            console.log(`READ|${lang} ${width}px ${JSON.stringify(m)}`)
            await page.close()
        }
    }
    return finish(0)
}

main().catch((e) => { console.error(String(e?.stack || e)); return finish(2) })
