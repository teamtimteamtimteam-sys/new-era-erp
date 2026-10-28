#!/usr/bin/env node
// SYSTEM-MAP-3 Step 1 · which element makes the purchase order page wider than 390 px (Tim's added item 9). Copied from bar-390.mjs;
// the measurement below walks every element whose right edge passes the viewport, skipping those inside a sideways scroller.
// (Original header follows.)
// SYSTEM-MAP-3 Step 0 · the 390 px measurement for the upstream/downstream bar (brief: "the bar must work at 390 px on the
// longest chain (purchasing, eight steps); measure it"). Read-only against production: one throwaway cfo clone opens one
// purchase order detail page (GET only, nothing pressed), and a PROTOTYPE bar is injected into that page's DOM in the
// browser (never saved anywhere) in three layouts × two languages, to measure what fits in the real content column.
//   A · one row, no wrap (does it overflow the column?)
//   B · one row of chips that wraps (how many lines, how tall?)
//   C · a vertical list, one step per line (how tall?)
// Each step carries its label and one sample document code — the widest real shape is label + code.
// Verdict from the last line only: POOVF_EXIT= (0 measured · 2 driver broken · 5 live-lock held · 6 cleanup incomplete).
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
const SCRIPT = 'docs/surveys/SYSTEM-MAP-3/po-overflow-390.mjs'

let locked = false, browser = null
installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch { /* */ } console.log(`POOVF_EXIT=${code}`) } })

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
    const reader = await mintThrowaway({ prefix: 'sm2probe', label: 'poovf-cfo', stamp: Date.now(), codes: { cloneOf: 'cfo' } })

    for (const lang of ['en', 'zh']) {
        const page = await browser.newPage()
        await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 1, isMobile: true, hasTouch: true })
        const host = new URL(BASE).hostname
        const cdp = await page.createCDPSession()
        await cdp.send('Network.setCookies', { cookies: [
            { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
            { name: 'NEXT_LOCALE', value: lang, domain: host, path: '/' },
        ] })
        await page.goto(`${BASE}/purchasing/orders/${PO_ID}`, { waitUntil: 'networkidle2', timeout: 120_000 })
        const m = await page.evaluate(() => {
            const vw = document.documentElement.clientWidth
            const scroller = (el) => { for (let p = el.parentElement; p; p = p.parentElement) { const o = getComputedStyle(p).overflowX; if (o === 'auto' || o === 'scroll' || o === 'hidden') return true } return false }
            const out = []
            for (const el of document.querySelectorAll('body *')) {
                const r = el.getBoundingClientRect()
                if (r.width > 0 && r.right > vw + 0.5 && !scroller(el)) {
                    out.push({ tag: el.tagName.toLowerCase(), cls: (el.getAttribute('class') || '').slice(0, 90), right: Math.round(r.right), w: Math.round(r.width), text: (el.textContent || '').trim().slice(0, 50) })
                }
            }
            return { vw, docW: document.documentElement.scrollWidth, culprits: out.slice(0, 25) }
        })
        console.log(`READ|${lang} ${JSON.stringify(m)}`)
        await page.close()
    }
    return finish(0)
}

main().catch((e) => { console.error(String(e?.stack || e)); return finish(2) })
