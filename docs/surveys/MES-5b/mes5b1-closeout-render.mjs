// MES-5b-1 close-out item d — render probe (read-only GETs). Seven one-off clones of the seven real roles (cloneOf: exactly that
// role's codes at this moment), each fetching the four MES-5b-1 views on the DEPLOYED app. No real account signs in or acts.
// Verdict line: RENDER_PROBE_EXIT=<n> (0 = all fetched; the table says what each saw).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
onlyWhenRunDirectly(import.meta.url)

const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
const { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs')
const { acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs')
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
let locked = false
installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch {} ; console.log(`RENDER_PROBE_EXIT=${code}`) } })
const PAGES = [
  ['/operation/balance', ['Material balance', '物料平衡'], ['before balance closure', '结平之前']],
  ['/operation/yield', ['Yield', '得率'], ['recorded before balance closure', '记在结平之前']],
  ['/inbound/662bfff7-6121-454c-b37b-fd69a90c3b99/edit', ["Where this batch", '这一批'], ['before balance closure', '结平之前']],
  ['/output/4e77c5ad-26da-4a27-9711-076df43845bc/edit', ["Where this batch", '这一批'], ['before balance closure', '结平之前']],
]
const ROLES = ['admin', 'finance', 'warehouse', 'cto', 'cco', 'cfo', 'gm']
async function main() {
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('closeout-d-render.mjs', { ownExit: false }); locked = true
  openPlan('closeout-d-render.mjs'); await reapStalePlans()
  const stamp = Date.now()
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes5b1probe', label: `cod-${r}`, stamp, codes: { cloneOf: r } })
    const cells = []
    for (const [path, titles, pre] of PAGES) {
      const res = await fetch(BASE + path, { headers: { cookie: a.cookie }, redirect: 'manual' })
      const body = await res.text()
      const t = titles.some((x) => body.includes(x))
      const p = pre.some((x) => body.includes(x))
      const err = /Application error|Internal Server Error|PERMISSION_DENIED|权限不足|restrictedHint/.test(body)
      cells.push(`${path.split('/').slice(0, 3).join('/')} HTTP ${res.status} title=${t} preMes4aLabel=${p} errorText=${err}`)
    }
    console.log(`ROLE|${r}|${a.codes.length} codes|` + cells.join(' || '))
  }
  return exitAfterCleanup(0)
}
main().catch((e) => { console.error('✗', e?.stack || e); exitAfterCleanup(2) })
