#!/usr/bin/env node
// db/scripts/2026-10-19-norole-live-proof.mjs —— NOROLE-SURFACE 的线上证明(Step 0 Q14,Tim 2026-10-19)
//
// 两个相位,都对着【线上 Supabase】与【部署着的应用】(PROOF_BASE,默认 https://new-era-erp.vercel.app —— 本刀没有一行应用代码,
// 所以迁移前后部署着的是同一份代码,两次读数之间唯一变了的是库):
//   --phase=pages   迁移【之前】:七个真角色各一个一次性克隆(cloneOf),打开读那九个对象的每一页,记下状态码 · 跳转 · <tr> 行数 ·
//                   有没有「受限 / Restricted」,写进 --out <json>。
//   --phase=full    迁移【之后】:同样的页再读一遍并与 --pages <json> 逐格比;外加
//                   · 一个没有角色的一次性账号(先给一个一次性角色再收回授权 —— mintThrowaway 不造零码的账号)、一个只挂 floor_display 的
//                     一次性账号(realRole,floor_display 不是系统角色),与七个克隆:经 PostgREST 读九个对象(行数),经 Storage API 在
//                     19 个桶里各 list · download · upload · upsert · remove 一次,判词按裁定(Step 0 §3 + Tim 施工中的 Q21)逐格比;
//                   · 三条 PDF 路由的孤儿清理(cod / po / traceability):持路由那个码的克隆把它自己传上去的一份孤儿 remove 掉 ——
//                     与路由在记录失败时调的是同一个 storage.remove(app/inbound/[id]/cod/pdf/route.tsx:209 等);
//                   · 两份已签发 COD 的字节:以服务端身份下载,sha256 必须等于 cod_issues 里记下的。
// 清理按计划(scripts/ephemeral.mjs):每一个一次性账号 / 角色 / 授权,以及本脚本会传上去的【每一个】存储路径,删除步先于它落盘;
//   收尾之后以服务端身份逐桶读回:没有一份 noroleprobe/ 文件留下。
// 退出:0 全部与裁定一致 · 1 有一格不一致(逐格点名)· 5 线上锁被占 · 6 收尾没完成(scripts/ephemeral.mjs 的口径)
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { readFileSync, writeFileSync } from 'node:fs'
import { createHash, randomUUID } from 'node:crypto'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, planDelete, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, ORDER } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
const ROLE_CLONES = ['admin', 'cco', 'cfo', 'cto', 'finance', 'gm', 'warehouse']
const ACTIVITY_COOKIE = 'evoltrya-last-activity'
const arg = (k) => (process.argv.find((a) => a.startsWith(`--${k}=`)) || '').split('=').slice(1).join('=') || null
const PHASE = arg('phase')
const STAMP = Date.now()
const PROBE_PREFIX = `noroleprobe/${STAMP}`

let locked = false
installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`NOROLE_PROOF_EXIT=${code}`)
    },
})

let env_ = null
function env() {
    if (!env_) {
        const t = readFileSync(new URL('../../.env.local', import.meta.url), 'utf8')
        const g = (k) => (t.match(new RegExp(`^${k}=(.*)$`, 'm')) || [])[1]?.trim().replace(/^"|"$/g, '')
        env_ = { URL_: g('NEXT_PUBLIC_SUPABASE_URL'), ANON: g('NEXT_PUBLIC_SUPABASE_ANON_KEY'), SERVICE: g('SUPABASE_SERVICE_ROLE_KEY') }
        if (!env_.URL_ || !env_.ANON || !env_.SERVICE) throw new Error('env: .env.local lacks the URL, anon or service key')
    }
    return env_
}
const svcH = () => ({ apikey: env().SERVICE, Authorization: `Bearer ${env().SERVICE}` })
const userH = (a) => ({ apikey: env().ANON, Authorization: `Bearer ${a.token}` })

const bad = []
const must = (ok, msg) => { if (!ok) { bad.push(msg); console.log('  ✗ ' + msg) } }

// ── the rulings, as data (Step 0 §2–§3; Tim's build Q21 for the four permission tables) ─────────────────────────────
const ANY = (...cs) => (C) => cs.some((c) => C.has(c))
const REL = {
    user_roles: ANY('action.manage_permissions', 'module.hr.view', 'data.view_change_log'),
    roles: ANY('action.manage_permissions', 'data.view_change_log'),
    role_permissions: ANY('action.manage_permissions', 'data.view_change_log'),
    permissions: ANY('action.manage_permissions', 'data.view_change_log'),
    metal_prices: ANY('module.pricing.view', 'module.suppliers.view', 'module.inventory.view', 'module.materials.view'),
    metal_price_indices: ANY('module.pricing.view', 'module.suppliers.view', 'action.metal_prices'),
    pricing_settings: ANY('module.pricing.view', 'module.inventory.view'),
    accounts: ANY('module.finance.view'),
    collection_promise_status: ANY('module.finance.view'),
}
const NONE = () => false
// bucket: read · upload · update(upsert) · delete-orphan · content type
const PDF = ['application/pdf', Buffer.from('%PDF-1.4\n% noroleprobe\n%%EOF\n')]
const PNG = ['image/png', Buffer.from('89504e470d0a1a0a0000000d4948445200000001000000010806000000' +
    '1f15c4890000000d49444154789c6360000002000154a24f5b0000000049454e44ae426082', 'hex')]
const WEBP = ['image/webp', Buffer.from('524946461a000000574542505650384c0d0000002f0000001007101111888808', 'hex')]
const B = {
    'avatars': { read: NONE, up: NONE, upd: NONE, del: NONE, ct: WEBP, own: true },
    'capture-photos': { read: ANY('module.inbound.view', 'module.logistics.view'), up: ANY('action.confirm_capture'), upd: NONE, del: NONE, ct: PNG },
    'cn-documents': { read: ANY('module.finance.view'), up: ANY('module.finance.edit'), upd: NONE, del: NONE, ct: PDF },
    'coa-documents': { read: ANY('module.output.view'), up: ANY('action.issue_coa'), upd: NONE, del: ANY('action.issue_coa'), ct: PDF },
    'cod-documents': { read: ANY('action.issue_cod'), up: ANY('action.issue_cod'), upd: NONE, del: ANY('action.issue_cod'), ct: PDF },
    'company-assets': { read: ANY('module.finance.view', 'module.purchasing.view', 'module.sales.view', 'action.ship_goods', 'action.issue_cod',
                                  'module.processing.view', 'module.output.view', 'module.compliance.view'),
                        up: ANY('action.finance_settings'), upd: ANY('action.finance_settings'), del: ANY('action.finance_settings'), ct: PNG },
    'compliance-documents': { read: ANY('module.compliance.view'), up: ANY('action.compliance_pack'), upd: NONE, del: ANY('action.compliance_pack'), ct: PDF },
    'customer-attachments': { read: ANY('module.customers.view'), up: ANY('module.customers.edit'), upd: NONE, del: ANY('module.customers.edit'), ct: PDF },
    'finance-attachments': { read: ANY('module.finance.view'), up: ANY('module.finance.edit'), upd: NONE, del: ANY('module.finance.edit'), ct: PDF },
    'invoice-documents': { read: ANY('module.finance.view'), up: ANY('module.finance.edit'), upd: NONE, del: NONE, ct: PDF },
    'material-attachments': { read: ANY('module.materials.view'), up: ANY('module.materials.edit'), upd: NONE, del: ANY('module.materials.edit'), ct: PDF },
    'po-documents': { read: ANY('module.purchasing.view'), up: ANY('module.purchasing.edit'), upd: NONE, del: ANY('module.purchasing.edit'), ct: PDF },
    'qt-documents': { read: ANY('module.sales.view'), up: ANY('module.sales.edit'), upd: NONE, del: NONE, ct: PDF },
    'shipment-documents': { read: ANY('module.sales.view', 'action.ship_goods'), up: ANY('action.ship_goods'), upd: NONE, del: NONE, ct: PDF },
    'so-documents': { read: ANY('module.sales.view'), up: ANY('module.sales.edit'), upd: NONE, del: NONE, ct: PDF },
    'statement-documents': { read: ANY('module.finance.view'), up: ANY('module.finance.edit'), upd: NONE, del: NONE, ct: PDF },
    'supplier-attachments': { read: ANY('module.suppliers.view'), up: ANY('module.suppliers.edit'), upd: NONE, del: ANY('module.suppliers.edit'), ct: PDF },
    'supplier-statement-documents': { read: ANY('module.finance.view'), up: ANY('module.finance.edit'), upd: NONE, del: ANY('module.finance.edit'), ct: PDF },
    'traceability-documents': { read: ANY('module.sales.view', 'module.processing.view'), up: ANY('module.sales.edit', 'module.processing.edit'),
                                upd: NONE, del: ANY('module.sales.edit', 'module.processing.edit'), ct: PDF },
}
const ext = (ct) => ({ 'application/pdf': 'pdf', 'image/png': 'png', 'image/webp': 'webp' })[ct[0]]

// ── HTTP helpers ─────────────────────────────────────────────────────────────────────────────────────────────────
async function restCount(path, headers) {
    const r = await fetch(env().URL_ + `/rest/v1/${path}`, { headers: { ...headers, Prefer: 'count=exact', Range: '0-0' } })
    const cr = r.headers.get('content-range') || ''
    await r.text()
    if (!(r.status === 200 || r.status === 206)) return { status: r.status, n: null }
    return { status: r.status, n: Number(cr.split('/')[1]) }
}
async function svcJson(path, init = {}) {
    const r = await fetch(env().URL_ + path, { ...init, headers: { ...svcH(), 'Content-Type': 'application/json', ...(init.headers || {}) } })
    const t = await r.text()
    if (!r.ok) throw new Error(`service ${path}: HTTP ${r.status} ${t.slice(0, 200)}`)
    return t ? JSON.parse(t) : null
}
async function upload(headers, bucket, path, ct, upsert = false) {
    const r = await fetch(env().URL_ + `/storage/v1/object/${bucket}/${path}`, { method: 'POST',
        headers: { ...headers, 'Content-Type': ct[0], 'x-upsert': upsert ? 'true' : 'false' }, body: ct[1] })
    await r.text()
    return r.status
}
async function exists(bucket, path) {
    const j = await svcJson(`/storage/v1/object/list/${bucket}`, { method: 'POST',
        body: JSON.stringify({ prefix: path.split('/').slice(0, -1).join('/'), limit: 1000, search: path.split('/').pop() }) })
    return (j || []).some((o) => o.name === path.split('/').pop())
}
async function listCount(headers, bucket, prefix) {
    const r = await fetch(env().URL_ + `/storage/v1/object/list/${bucket}`, { method: 'POST',
        headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ prefix, limit: 1000 }) })
    const t = await r.text()
    if (r.status !== 200) return -r.status
    return JSON.parse(t).length
}
async function download(headers, bucket, path) {
    const r = await fetch(env().URL_ + `/storage/v1/object/authenticated/${bucket}/${path}`, { headers })
    const b = Buffer.from(await r.arrayBuffer())
    return { status: r.status, bytes: b }
}
async function remove(headers, bucket, path) {
    const r = await fetch(env().URL_ + `/storage/v1/object/${bucket}`, { method: 'DELETE',
        headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ prefixes: [path] }) })
    await r.text()
    return r.status
}
function planObject(bucket, path) {
    planDelete(`/storage/v1/object/${bucket}/${path}`, `删一次性文件 ${bucket}/${path}`, ORDER.OTHER)
}

// ── pages (the same list, before and after) ─────────────────────────────────────────────────────────────────────────
async function pageList() {
    const one = async (path, q) => (await svcJson(`/rest/v1/${path}?select=id&limit=1${q || ''}`))?.[0]?.id
    const ids = {
        role: await one('roles', '&code=eq.finance'), journal: await one('journal_entries', '&order=created_at.desc'),
        expense: await one('expenses', '&order=created_at.desc'), contract: await one('contracts', '&order=created_at.desc'),
        metal: await one('metal_prices', '&deleted_at=is.null&order=price_date.desc'), formula: await one('pricing_formulas', '&order=created_at.desc'),
        employee: await one('employees', '&user_id=eq.476bf8c8-c248-4352-9a75-945bf52ca390'),
        material: (await svcJson('/rest/v1/output_batches?select=material_id&deleted_at=is.null&limit=1'))?.[0]?.material_id,
    }
    const P = ['/settings/roles', `/settings/roles/${ids.role}`, '/settings/accounts', '/settings/approvals', '/settings/reference',
        '/settings/dictionaries', '/settings/change-history', '/tools/pricing/metal-prices', '/tools/pricing/metal-prices/bulk',
        `/tools/pricing/metal-prices/${ids.metal}/edit`, '/tools/pricing/formulas/new', `/tools/pricing/formulas/${ids.formula}/edit`,
        '/contracts', `/contracts/${ids.contract}`, '/inventory', `/inventory/output/${ids.material}`, '/finance/journal',
        '/finance/journal/new', `/finance/journal/${ids.journal}`, '/finance/trial-balance', '/finance/bank', '/finance/expenses',
        '/finance/expenses/new', `/finance/expenses/${ids.expense}`, '/finance/assets', '/finance/claims', `/hr/employees/${ids.employee}`]
    // a dynamic page whose subject does not exist on live is SKIPPED BY NAME (e.g. there is no contract) — never read as "nothing to see"
    const out = P.filter((p) => !p.includes('/undefined'))
    for (const p of P.filter((x) => x.includes('/undefined'))) console.log(`SKIP|${p}|no such record on live — this page has no subject to open`)
    return out
}
async function readPage(acct, path) {
    const ck = `${acct.cookieName}=${acct.cookieValue}; ${ACTIVITY_COOKIE}=${Date.now()}`
    const r = await fetch(BASE + path, { headers: { cookie: ck }, redirect: 'manual' })
    const html = r.status === 200 ? await r.text() : (await r.text(), '')
    return { status: r.status, location: r.headers.get('location') || '', tr: (html.match(/<tr[\s>]/g) || []).length,
             restricted: /Restricted|受限/.test(html), denied: /permissionDenied|You don.t have permission|没有权限|需要权限/.test(html) }
}

async function main() {
    if (PHASE !== 'pages' && PHASE !== 'full') { console.error('usage: --phase=pages --out=<json> | --phase=full --pages=<json>'); return exitAfterCleanup(2) }
    if (heldBy()) { console.log(`live lock held by ${heldBy()} — not now`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-19-norole-live-proof.mjs', { ownExit: false }); locked = true
    openPlan('db/scripts/2026-10-19-norole-live-proof.mjs')
    await reapStalePlans()
    { const r = await fetch(BASE + '/login', { redirect: 'manual' }); must(r.status === 200, `${BASE}/login answered ${r.status}`) }

    const clones = {}
    for (const role of ROLE_CLONES) clones[role] = await mintThrowaway({ prefix: 'noroleprobe', label: `clone-${role}`, stamp: STAMP, codes: { cloneOf: role } })
    const pages = await pageList()
    const readings = {}
    for (const role of ROLE_CLONES) for (const p of pages) readings[`${role} ${p.replace(/[0-9a-f-]{36}/g, '<id>')}`] = await readPage(clones[role], p)

    if (PHASE === 'pages') {
        writeFileSync(arg('out'), JSON.stringify(readings, null, 1))
        console.log(`pages: ${Object.keys(readings).length} readings (${ROLE_CLONES.length} clones × ${pages.length} pages) → ${arg('out')}`)
        return exitAfterCleanup(bad.length ? 1 : 0)
    }

    // ── full: pages against the pre reading ───────────────────────────────────────────────────────────────────────
    const before = JSON.parse(readFileSync(arg('pages'), 'utf8'))
    const table = []
    for (const [k, v] of Object.entries(readings)) {
        const b = before[k]
        const same = b && b.status === v.status && b.tr === v.tr && b.restricted === v.restricted && b.denied === v.denied
        table.push(`PAGE|${k}|before=${b ? `${b.status}/${b.tr}tr/${b.restricted ? 'R' : '-'}${b.denied ? 'D' : '-'}` : '?'}|after=${v.status}/${v.tr}tr/${v.restricted ? 'R' : '-'}${v.denied ? 'D' : '-'}|${same ? 'same' : 'DIFF'}`)
        must(same, `page ${k}: before ${JSON.stringify(b)} after ${JSON.stringify(v)}`)
    }
    table.forEach((l) => console.log(l))

    // ── identities: no-role and display ───────────────────────────────────────────────────────────────────────────
    const ids = { ...clones }
    ids.norole = await mintThrowaway({ prefix: 'noroleprobe', label: 'norole', stamp: STAMP, codes: ['module.tasks.view'] })
    await svcJson(`/rest/v1/user_roles?user_id=eq.${ids.norole.userId}`, { method: 'DELETE' })
    ids.display = await mintThrowaway({ prefix: 'noroleprobe', label: 'display', stamp: STAMP, codes: { realRole: 'floor_display' } })
    const codesOf = {}
    for (const [k, a] of Object.entries(ids)) {
        const r = await fetch(env().URL_ + '/rest/v1/rpc/current_user_permissions', { method: 'POST', headers: { ...userH(a), 'Content-Type': 'application/json' }, body: '{}' })
        codesOf[k] = new Set(await r.json())
        console.log(`WHO|${k}|codes=${codesOf[k].size}`)
    }
    must(codesOf.norole.size === 0, 'the no-role account holds a code')
    must(codesOf.display.size === 1 && codesOf.display.has('data.view_floor_board'), 'the display account is not display-only')

    // ── PostgREST: the nine objects ────────────────────────────────────────────────────────────────────────────────
    const total = {}
    for (const o of Object.keys(REL)) total[o] = (await restCount(`${o}?select=*`, svcH())).n
    total.collection_promise_status = (await restCount('collection_promises?select=id', svcH())).n
    for (const [k, a] of Object.entries(ids)) for (const o of Object.keys(REL)) {
        const got = await restCount(`${o}?select=*`, userH(a))
        let exp = REL[o](codesOf[k]) ? total[o] : 0
        if (o === 'user_roles' && !REL[o](codesOf[k])) exp = k === 'norole' ? 0 : 1          // its own grant row (Q3)
        console.log(`REST|${k}|${o}|${got.n}|expected ${exp}`)
        must(got.n === exp, `REST ${k} ${o}: ${got.n} (expected ${exp})`)
    }

    // ── Storage: every bucket, every identity ──────────────────────────────────────────────────────────────────────
    const buckets = (await svcJson('/storage/v1/bucket')).map((b) => b.id).sort()
    must(buckets.length === 19 && buckets.every((b) => B[b]), `buckets: ${buckets.join(',')}`)
    for (const b of buckets) {
        const R = B[b]
        const svcPath = `${PROBE_PREFIX}/svc.${ext(R.ct)}`
        planObject(b, svcPath)
        must((await upload(svcH(), b, svcPath, R.ct)) === 200, `service probe upload into ${b}`)
        for (const [k, a] of Object.entries(ids)) {
            const C = codesOf[k]
            const ownPath = R.own ? `${a.userId}.webp` : `${PROBE_PREFIX}/${k}.${ext(R.ct)}`
            planObject(b, ownPath)
            const vis = await listCount(userH(a), b, PROBE_PREFIX)
            const dl = await download(userH(a), b, svcPath)
            const up = await upload(userH(a), b, ownPath, R.ct)
            const upOk = up === 200
            const upd = upOk ? await upload(userH(a), b, ownPath, R.ct, true) : null
            if (upOk) await remove(userH(a), b, ownPath)
            const ownGone = upOk ? !(await exists(b, ownPath)) : null
            await remove(userH(a), b, svcPath)
            const svcGone = !(await exists(b, svcPath))
            if (svcGone) must((await upload(svcH(), b, svcPath, R.ct)) === 200, `service probe re-upload into ${b}`)
            const readOk = R.own ? false : R.read(C)
            const expUp = R.own ? true : R.up(C)
            const expDel = R.own ? true : R.del(C)
            const expUpd = R.own ? true : R.upd(C)
            console.log(`STORE|${k}|${b}|list=${vis}|download=${dl.status}|upload=${up}|upsert=${upd ?? '-'}|remove_own=${ownGone ?? '-'}|remove_orphan=${svcGone}`)
            must(readOk ? vis >= 1 : vis === 0, `${k} ${b}: list ${vis} (read ${readOk})`)
            must(readOk ? dl.status === 200 : dl.status !== 200, `${k} ${b}: download ${dl.status} (read ${readOk})`)
            must(upOk === expUp, `${k} ${b}: upload ${up} (expected ${expUp ? 'allowed' : 'refused'})`)
            if (upOk) must((upd === 200) === expUpd, `${k} ${b}: upsert ${upd} (expected ${expUpd ? 'allowed' : 'refused'})`)
            if (upOk) must(ownGone === expDel, `${k} ${b}: remove of its own orphan ${ownGone ? 'removed' : 'kept'} (expected ${expDel ? 'removed' : 'kept'})`)
            must(svcGone === (R.own ? false : R.del(C)), `${k} ${b}: remove of the service orphan ${svcGone ? 'removed' : 'kept'}`)
        }
    }

    // ── the three PDF routes' orphan cleanup: the route's code holder removes its own orphan (the same storage.remove call) ──
    for (const [b, who] of [['cod-documents', 'warehouse'], ['po-documents', 'finance'], ['traceability-documents', 'cto']]) {
        const p = `${PROBE_PREFIX}/route-orphan-${randomUUID()}.pdf`
        planObject(b, p)
        const up = await upload(userH(ids[who]), b, p, PDF)
        await remove(userH(ids[who]), b, p)
        const gone = !(await exists(b, p))
        console.log(`ROUTE_CLEANUP|${b}|as ${who} clone|upload=${up}|orphan removed=${gone}`)
        must(up === 200 && gone, `route cleanup ${b} as ${who}: upload ${up}, removed ${gone}`)
    }

    // ── the two issued CODs: their stored bytes ────────────────────────────────────────────────────────────────────
    const issues = await svcJson('/rest/v1/cod_issues?select=file_path,sha256,cod_id')
    for (const i of issues) {
        const d = await download(svcH(), 'cod-documents', i.file_path)
        const h = createHash('sha256').update(d.bytes).digest('hex')
        console.log(`COD_BYTES|${i.file_path}|${d.bytes.length} bytes|sha256 ${h}|recorded ${i.sha256}|${h === i.sha256 ? 'identical' : 'DIFFERENT'}`)
        must(h === i.sha256, `COD bytes ${i.file_path} differ from the recorded sha256`)
    }
    console.log(bad.length ? `NOROLE_PROOF: ✗ ${bad.length} cell(s) differ` : 'NOROLE_PROOF: ✓ every cell matches the rulings')
    return exitAfterCleanup(bad.length ? 1 : 0)
}

main().catch((e) => { console.error('✗ ' + (e.stack || e.message)); return exitAfterCleanup(1) })
