// MES-8b-2 close-out (2026-10-19) — items 1.3 and 1.4 b, on the DEPLOYED app (https://new-era-erp.vercel.app), throwaway accounts only.
//
// 1.3 · the SESSION-1 manual repro (docs/known-issues.md, "任何动到 lib/supabase/middleware.ts … 之后,按这个走一遍"), walked in a real browser
//       (chrome-headless-shell, driven through puppeteer-core installed in the job scratch directory — not a repo dependency):
//   1  sign in through the /login form;
//   2  /inventory/locations/new, submit an EXISTING location code → the named duplicate refusal (LOC_CODE_EXISTS). The duplicate is refused inside the
//      database before any row is written; the existing location is only compared against, never changed. ★ A NEW location cannot be used here:
//      storage_locations has no hard-delete path (guard_storage_location_no_hard_delete), so a location of mine could never be removed.
//   3  assert together: the localized duplicate sentence is shown AND the session survives (no auth cookie cleared with Max-Age=0 in any response of
//      the submission; a reload does not land on /login; the auth cookie is still in the jar);
//   4  a SUCCESSFUL submission and a submission in another module: the avatar form on /me (upload → success; then "Remove" → success). The only
//      record is a storage object named after my throwaway account's own uid; it is removed by the form itself, then once more by name at exit and read back;
//   5  the cookie's stored expires_at moved into the past (the tokens untouched) — a tab left open for an hour — then 2–4 again.
// 1.4 b · page usability as clones (cloneOf) of admin, cfo, finance, warehouse and a floor_display-only account (realRole floor_display; floor_display is
//       not a system role): /display, the display session on other routes, /finance/price-exposure (kind not stated + incomplete total), and
//       /finance/month-end at 390 px (horizontal overflow of the page, measured in the browser).
//
// Every throwaway (prefix mes8b2probe, already in scripts/ephemeral.mjs) is removed by the ephemeral plan; the verdict line is CLOSEOUT_PROBE_EXIT=<n>
// (0 = every step ran and every assertion held · 1 = an assertion failed · 2 = the driver broke · 5 = live-lock held).
// Usage: PUPPETEER_CORE=<dir>/node_modules/puppeteer-core/lib/esm/puppeteer/puppeteer-core.js AVATAR_PNG=<png> node docs/surveys/MES-9/mes8b2-closeout-probe.mjs
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
// ★ It acts on live, so it runs only when executed directly — importing this file starts nothing.
onlyWhenRunDirectly(import.meta.url)

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const env = readFileSync(join(REPO, '.env.local'), 'utf8')
const SB_URL = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const REF = SB_URL.split('//')[1].split('.')[0]
const AUTH = `sb-${REF}-auth-token`
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, acquireOrExit, release, heldBy
let locked = false, browser = null, bad = 0
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++ }
const svcGet = async (path) => { const r = await fetch(SB_URL + path, { headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } }); return { status: r.status, body: await r.json().catch(() => null) } }
const svcHdr = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' }
// does avatars/<uid>.webp exist? (storage list, read-only)
const avatarExists = async (uid) => { const r = await fetch(SB_URL + '/storage/v1/object/list/avatars', { method: 'POST', headers: svcHdr, body: JSON.stringify({ prefix: '', search: `${uid}.webp`, limit: 10 }) })
  const j = await r.json(); if (!r.ok || !Array.isArray(j)) throw new Error(`storage list HTTP ${r.status} ${JSON.stringify(j).slice(0, 200)}`); return j.some((o) => o.name === `${uid}.webp`) }
// remove it by name if it is still there (bulk delete answers 200 for a missing name)
const avatarRemove = async (uid) => { const r = await fetch(SB_URL + '/storage/v1/object/avatars', { method: 'DELETE', headers: svcHdr, body: JSON.stringify({ prefixes: [`${uid}.webp`] }) }); return r.status }
let s1User = null

// ── the auth cookie: @supabase/ssr stores "base64-" + base64url(session JSON), chunked as <name>.0, <name>.1 … when long ──
async function readSession(page) {
  const jar = (await page.cookies(BASE)).filter((c) => c.name === AUTH || c.name.startsWith(AUTH + '.'))
  const parts = jar.some((c) => c.name === AUTH) ? jar.filter((c) => c.name === AUTH)
    : jar.sort((a, b) => Number(a.name.split('.').pop()) - Number(b.name.split('.').pop()))
  const raw = parts.map((c) => c.value).join('')
  if (!raw) return { jar, session: null }
  return { jar, session: JSON.parse(Buffer.from(raw.replace(/^base64-/, ''), 'base64url').toString('utf8')) }
}
async function writeSession(page, jar, session) {
  const host = new URL(BASE).hostname
  for (const c of jar) await page.deleteCookie({ name: c.name, url: BASE })
  const value = 'base64-' + Buffer.from(JSON.stringify(session)).toString('base64url')
  const CHUNK = 3180
  const chunks = value.length <= CHUNK ? [[AUTH, value]] : Array.from({ length: Math.ceil(value.length / CHUNK) }, (_, i) => [`${AUTH}.${i}`, value.slice(i * CHUNK, (i + 1) * CHUNK)])
  for (const [name, v] of chunks) await page.setCookie({ name, value: v, domain: host, path: '/', secure: true, sameSite: 'Lax', expires: Math.floor(Date.now() / 1000) + 3600 * 24 * 400 })
  return chunks.length
}

// ── every response of a submission, with its raw Set-Cookie (CDP extra-info carries what response.headers() may omit) ──
function watchCookies(cdp) {
  const seen = []
  const h = (e) => { const sc = e.headers['set-cookie'] ?? e.headers['Set-Cookie']; if (sc) seen.push(sc) }
  cdp.on('Network.responseReceivedExtraInfo', h)
  return { stop: () => cdp.off('Network.responseReceivedExtraInfo', h), cleared: () => seen.some((s) => s.split('\n').some((l) => l.startsWith(AUTH) && /max-age=0/i.test(l))), seen }
}
async function sessionAlive(page, label) {
  const { session } = await readSession(page)
  await page.reload({ waitUntil: 'networkidle2' })
  const url = page.url()
  ok(!!session && !url.includes('/login'), `${label}: session alive (auth cookie present, reload stays on ${new URL(url).pathname})`)
}

async function stepDuplicate(page, cdp, code, label) {
  await page.goto(BASE + '/inventory/locations/new', { waitUntil: 'networkidle2' })
  ok(new URL(page.url()).pathname === '/inventory/locations/new', `${label} step 2: the form opens (${page.url()})`)
  const w = watchCookies(cdp)
  await page.type('form input[name="code"]', code)
  await page.type('form input[name="name"]', 'ZZ close-out probe (duplicate, refused)')
  const form = await page.$('form:has(input[name="code"])')
  await (await form.$('button[type="submit"]')).click()
  let msg = null
  for (let i = 0; i < 60 && !msg; i++) {
    await sleep(500)
    msg = await page.evaluate((c) => { const t = document.body.innerText; return (t.includes(c) && (/already in use|已经被占用/.test(t))) ? (t.split('\n').find((l) => /already in use|已经被占用/.test(l)) || '').slice(0, 200) : null }, code)
  }
  w.stop()
  ok(!!msg, `${label} step 3①: the localized duplicate refusal is shown — "${msg}"`)
  ok(!w.cleared(), `${label} step 3②: no auth cookie cleared (Max-Age=0) in the ${w.seen.length} Set-Cookie header(s) of the submission`)
  await sessionAlive(page, `${label} step 3②`)
}

async function stepAvatar(page, cdp, userId, png, label) {
  await page.goto(BASE + '/me', { waitUntil: 'networkidle2' })
  const w = watchCookies(cdp)
  const input = await page.$('#avatar-file')
  ok(!!input, `${label} step 4: /me draws the avatar form`)
  await input.uploadFile(png)
  const form = await page.$('form:has(#avatar-file)')
  await (await form.$('button[type="submit"]')).click()
  let obj = null
  for (let i = 0; i < 60 && !obj; i++) { await sleep(500); obj = await avatarExists(userId) }
  ok(obj === true, `${label} step 4: successful submission (avatar upload) — object avatars/${userId}.webp exists`)
  ok(!w.cleared(), `${label} step 4: no auth cookie cleared in the upload's ${w.seen.length} Set-Cookie header(s)`)
  await sessionAlive(page, `${label} step 4 (after upload)`)
  const w2 = watchCookies(cdp)
  const rm = await page.$('form:has(#avatar-file) button[type="button"]')
  await rm.click()
  let gone = false
  for (let i = 0; i < 60 && !gone; i++) { await sleep(500); gone = !(await avatarExists(userId)) }
  w2.stop()
  ok(gone, `${label} step 4: successful submission (avatar remove) — the object is gone`)
  ok(!w2.cleared(), `${label} step 4: no auth cookie cleared in the removal's ${w2.seen.length} Set-Cookie header(s)`)
  await sessionAlive(page, `${label} step 4 (after remove)`)
  w.stop()
}

async function session1(png) {
  const stamp = Date.now()
  const a = await mintThrowaway({ prefix: 'mes8b2probe', label: 'co-s1', stamp, codes: ['module.inventory.view', 'module.inventory.edit'], signIn: false })
  s1User = a.userId   // the avatar object is removed by the form; beforeFinish removes it again by name and reads it back
  const loc = await svcGet('/rest/v1/storage_locations?select=code&is_active=eq.true&order=code&limit=1')
  const code = loc.body?.[0]?.code
  if (!code) throw new Error('no active location to collide with')
  console.log(`INFO|S1|account ${a.email} · codes ${a.codes.join(',')} · existing location used for the collision: ${code}`)
  const page = await browser.newPage()
  const cdp = await page.createCDPSession(); await cdp.send('Network.enable')
  // step 1 — sign in through the form
  await page.goto(BASE + '/login', { waitUntil: 'networkidle2' })
  await page.type('input[name="email"]', a.email); await page.type('input[name="password"]', a.password)
  await page.click('form button[type="submit"]')
  // the login action ends in a server-action redirect (a soft navigation): poll the URL rather than wait for a document load
  for (let i = 0; i < 60 && new URL(page.url()).pathname === '/login'; i++) await sleep(500)
  await page.waitForNetworkIdle({ idleTime: 500, timeout: 30000 }).catch(() => {})
  const s0 = await readSession(page)
  ok(!!s0.session && !page.url().includes('/login'), `S1 step 1: signed in through /login → ${new URL(page.url()).pathname}, auth cookie in ${s0.jar.length} part(s)`)
  await stepDuplicate(page, cdp, code, 'S1')
  await stepAvatar(page, cdp, a.userId, png, 'S1')
  // step 5 — move expires_at into the past (tokens untouched), then 2–4 again
  const s = await readSession(page)
  const before = { at: s.session.access_token.slice(-12), rt: s.session.refresh_token }
  s.session.expires_at = Math.floor(Date.now() / 1000) - 3600
  const n = await writeSession(page, s.jar, s.session)
  console.log(`INFO|S1 step 5|expires_at set to ${new Date(s.session.expires_at * 1000).toISOString()} (written in ${n} part(s)); access token …${before.at} unchanged`)
  await stepDuplicate(page, cdp, code, 'S1 step 5')
  const after = await readSession(page)
  ok(after.session && after.session.refresh_token !== before.rt && after.session.expires_at * 1000 > Date.now(),
    `S1 step 5: the server refreshed the session (new refresh token, expires_at ${after.session ? new Date(after.session.expires_at * 1000).toISOString() : '—'})`)
  await stepAvatar(page, cdp, a.userId, png, 'S1 step 5')
  await page.close()
}

async function pages14b() {
  const stamp = Date.now() + 1
  const acc = {}
  for (const r of ['admin', 'cfo', 'finance', 'warehouse']) acc[r] = await mintThrowaway({ prefix: 'mes8b2probe', label: `co-${r}`, stamp, codes: { cloneOf: r } })
  acc.floor = await mintThrowaway({ prefix: 'mes8b2probe', label: 'co-floor', stamp, codes: { realRole: 'floor_display' } })
  const get = async (who, path) => {
    const res = await fetch(BASE + path, { headers: { cookie: acc[who].cookie }, redirect: 'manual' }); const body = await res.text()
    return { status: res.status, location: res.headers.get('location'), body }
  }
  for (const who of ['floor', 'admin', 'cfo', 'finance', 'warehouse']) {
    const r = await get(who, '/display')
    // board tiles only: the V28 settings panel's checkboxes carry data-tile too (<input … data-tile=…>), so count the <div> tiles
    const tiles = (r.body.match(/<div[^>]*\sdata-tile="/g) || []).length
    const boxes = (r.body.match(/<input[^>]*\sdata-tile="/g) || []).length
    const refused = r.body.includes('data-access-denied')
    const refreshed = (r.body.match(/data-value="display-refreshed-at"[^>]*>([^<]*)</) || [])[1] ?? null
    console.log(`PAGE|${who}|${acc[who].codes.length} codes|/display|${r.status}|tiles=${tiles}|panel_checkboxes=${boxes}|refused=${refused}|refreshed=${refreshed}|chrome=${r.body.includes('data-nav=')}|settings_panel=${r.body.includes('data-section="floor-board-settings"')}`)
    if (who === 'floor' || who === 'admin' || who === 'cfo') ok(r.status === 200 && tiles === 23 && !refused && !!refreshed, `1.4b /display renders 23 tiles for ${who}`)
    else ok(r.status === 200 && refused && tiles === 0, `1.4b /display refused for ${who} (no data.view_floor_board)`)
  }
  for (const path of ['/', '/inventory', '/finance/month-end', '/finance/price-exposure', '/suppliers', '/me']) {
    const r = await get('floor', path)
    const back = /href="\/display"/.test(r.body)
    console.log(`PAGE|floor|/display-only|${path}|${r.status}|refused=${r.body.includes('data-access-denied')}|way_out_to_display=${back}|location=${r.location}`)
    ok((r.status === 200 && r.body.includes('data-access-denied') && back) || (r.status >= 300 && r.status < 400 && (r.location || '').includes('/display')),
      `1.4b floor_display-only session on ${path} is sent back to /display`)
  }
  for (const who of ['admin', 'cfo', 'finance', 'warehouse']) {
    const r = await get(who, '/finance/price-exposure')
    const kns = r.body.includes('data-section="exposure-kind-not-stated"')
    const list = (r.body.match(/data-value="exposure-kind-not-stated-list"[^>]*>([\s\S]*?)<\/p>/) || [])[1]?.replace(/<[^>]+>/g, '').slice(0, 160) ?? null
    const title = (r.body.match(/Kind not stated — [^<]*/) || [])[0] ?? null
    const total = (r.body.match(/data-value="exposure-total"[^>]*>([\s\S]*?)<\/p>/) || [])[1]?.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 220) ?? null
    console.log(`PAGE|${who}|/finance/price-exposure|${r.status}|refused=${r.body.includes('data-access-denied')}|kind_not_stated=${kns}|title=${title}|list=${list}|total=${total}`)
    if (who === 'warehouse') ok(r.status === 200 && r.body.includes('data-access-denied'), '1.4b price exposure refused for warehouse (no module.finance.view) — as MES-8b-2 §7')
    else ok(r.status === 200 && kns && /Incomplete/.test(total ?? ''), `1.4b price exposure for ${who}: "kind not stated" list and the incomplete total`)
  }
  // month-end at 390 px, in the browser
  for (const who of ['admin', 'cfo', 'finance', 'warehouse']) {
    const ctx = await browser.createBrowserContext(); const page = await ctx.newPage()
    await page.setViewport({ width: 390, height: 844 })
    await page.setCookie({ name: acc[who].cookieName, value: acc[who].cookieValue, domain: new URL(BASE).hostname, path: '/', secure: true, sameSite: 'Lax' })
    const res = await page.goto(BASE + '/finance/month-end', { waitUntil: 'networkidle2' })
    const m = await page.evaluate(() => ({ ovf: document.documentElement.scrollWidth - document.documentElement.clientWidth, h1: document.querySelector('h1')?.innerText ?? null,
      refused: !!document.querySelector('[data-access-denied]'), tables: document.querySelectorAll('table').length,
      scroller: [...document.querySelectorAll('table')].map((t) => getComputedStyle(t.parentElement).overflowX).join(',') }))
    console.log(`PAGE|${who}|/finance/month-end@390|${res.status()}|${JSON.stringify(m)}`)
    ok(res.status() === 200 && m.ovf === 0, `1.4b month-end at 390 px for ${who}: page overflow ${m.ovf} px`)
    await ctx.close()
  }
}

async function main() {
  const png = process.env.AVATAR_PNG
  const pc = process.env.PUPPETEER_CORE
  if (!png || !pc) { console.error('usage: PUPPETEER_CORE=… AVATAR_PNG=… node mes8b2-closeout-probe.mjs'); process.exit(2) }
  ;({ openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs'))
  ;({ acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs'))
  const puppeteer = (await import(pc)).default
  installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch {}; console.log(`CLOSEOUT_PROBE_EXIT=${code}`) },
    beforeFinish: async () => {
      try { await browser?.close() } catch {}
      if (s1User) { const st = await avatarRemove(s1User); const left = await avatarExists(s1User); console.log(`CLEANUP|avatar object of the S1 account: delete HTTP ${st}, still there: ${left}`); if (left) process.exitCode = 1 }
    } })
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('docs/surveys/MES-9/mes8b2-closeout-probe.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-9/mes8b2-closeout-probe.mjs'); await reapStalePlans()
  browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ['--no-first-run'] })
  await session1(png)
  await pages14b()
  console.log(`SUMMARY|failed assertions: ${bad}`)
  return exitAfterCleanup(bad ? 1 : 0)
}
main().catch((e) => { console.error('✗', e?.stack || e); if (exitAfterCleanup) exitAfterCleanup(2); else process.exit(2) })
