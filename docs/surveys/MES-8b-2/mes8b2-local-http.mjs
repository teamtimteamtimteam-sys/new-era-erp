// LOCAL harness (never live): HTTP probe of /display, the refusals and the idle exemption, through the real middleware.
import { execFileSync } from 'node:child_process'
const H = new URL('.', import.meta.url).pathname
const BASE = process.env.BASE || 'http://localhost:3196'
const who = { floor: ['a0000000-0000-4000-8000-000000000008', 'floor@test.local'], floor2: ['a0000000-0000-4000-8000-000000000009', 'floor2@test.local'],
  admin: ['a0000000-0000-4000-8000-000000000001', 'clone-admin@test.local'], warehouse: ['a0000000-0000-4000-8000-000000000004', 'clone-warehouse@test.local'],
  cfo: ['a0000000-0000-4000-8000-000000000006', 'clone-cfo@test.local'] }
const cookieOf = (k) => execFileSync('node', ['proxy.mjs', 'cookie', ...who[k]], { cwd: H, env: { ...process.env, H_SECRET: 'harness-local-secret-0123456789-abcdefghij' } }).toString().trim()
let bad = 0
async function get(k, path, idleMin) {
  const ck = [`sb-localhost-auth-token=${cookieOf(k)}`]
  if (idleMin !== undefined) ck.push(`evoltrya-last-activity=${Date.now() - idleMin * 60000}`)
  const r = await fetch(BASE + path, { headers: { cookie: ck.join('; ') }, redirect: 'manual' })
  const body = r.status === 200 ? await r.text() : ''
  return { status: r.status, loc: r.headers.get('location') || '', body }
}
function check(label, ok, detail) { console.log(`${ok ? '✓' : '✗'} ${label} ${detail}`); if (!ok) bad++ }
const r1 = await get('floor', '/display')
check('floor /display 200 with tiles, no chrome, no settings', r1.status === 200 && r1.body.includes('data-page="display"') && (r1.body.match(/data-tile="/g) || []).length === 23
  && !r1.body.includes('data-app-chrome') && !r1.body.includes('data-section="floor-board-settings"') && !r1.body.includes('data-idle-warning'),
  `status=${r1.status} tiles=${(r1.body.match(/data-tile="/g) || []).length}`)
for (const p of ['/', '/me', '/my-reviews', '/notifications', '/welcome', '/tools/reminders', '/finance/month-end', '/finance/price-exposure', '/inventory', '/settings/accounts', '/settings/pending-values', '/compliance/packs', '/suppliers']) {
  const r = await get('floor', p)
  check(`floor ${p} refused`, r.status === 200 && r.body.includes('data-access-denied') && (r.body.includes('This account is a wall display') || r.body.includes('这个账号是一块车间大屏')) && r.body.includes('href="/display"'),
    `status=${r.status}`)
}
const r2 = await get('admin', '/display')
check('admin /display 200 with settings panel (pressable)', r2.status === 200 && r2.body.includes('data-section="floor-board-settings"') && !r2.body.includes('data-access-denied'), `status=${r2.status}`)
const r3 = await get('warehouse', '/display')
check('warehouse /display refused (no code)', r3.status === 200 && r3.body.includes('data-access-denied'), `status=${r3.status}`)
const r4 = await get('admin', '/finance/month-end')
check('admin other route not refused', r4.status === 200 && !r4.body.includes('This account is a wall display'), `status=${r4.status}`)
// idle: 31 minutes since the last activity
for (const [k, path, expectExempt] of [['floor', '/display', true], ['floor2', '/display', false], ['admin', '/display', false], ['admin', '/finance/month-end', false], ['warehouse', '/inventory', false], ['cfo', '/finance/month-end', false]]) {
  const r = await get(k, path, 31)
  if (expectExempt) check(`idle 31 min · ${k} ${path} not logged out`, r.status === 200, `status=${r.status} loc=${r.loc}`)
  else check(`idle 31 min · ${k} ${path} logged out as today`, r.status === 307 && r.loc.includes('/login') && r.loc.includes('reason=ended'), `status=${r.status} loc=${r.loc}`)
}
for (const [k, path] of [['floor2', '/display'], ['admin', '/finance/month-end'], ['warehouse', '/inventory']]) {
  const r = await get(k, path, 29)
  check(`idle 29 min · ${k} ${path} still in`, r.status === 200, `status=${r.status}`)
}
console.log(`HTTP8B2_EXIT=${bad ? 1 : 0}`)
process.exit(bad ? 1 : 0)
