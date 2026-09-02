#!/usr/bin/env node
// scripts/render-pdf-samples.mjs —— 把每一份对外单据【真的渲染成 PDF】并落盘。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么需要它:构建绿 ≠ 这张纸是对的】(PDF-1,2026-09-02)
// ════════════════════════════════════════════════════════════════════════════
// 本仓库已经记着"构建编译页面但从不渲染它们",而 PDF 这条路更极端:
// 一份【字体错了】的 PDF 生成时是完全成功的 —— 对账单把
// `上海金属回收有限公司` 印成 `wÑ^Þ6 Plø`,HTTP 200,没有任何一道门变红。
//
// 所以这一支不断言,它【取字节】:走真路由、带真会话、拿真数据,把每一份单据
// 落到磁盘上,让人(或下一支工具)去看那张纸。**判据是那张纸,不是退出码。**
//
// 【它刻意不做断言】—— 说清楚,免得下一个人以为它是一道门。
// "这份版式好不好看""字标在不在""中文有没有印出来"都不是文本判据能回答的;
// 硬写一条只会得到一个看起来在把关、其实什么都没查的检查(本仓库为这一族付过
// 多次账)。它的产物是【证据】,给人看的。
//
// 用法:
//   node scripts/smoke-routes.mjs 之外单跑时,自己先起 dev server:
//     PORT=3199 npx next dev -p 3199
//   然后:
//     node scripts/render-pdf-samples.mjs --out /tmp/pdf-before
//
// 【一次性账号会被清理】与冒烟同一条:开跑先扫、收尾再删,因为 kill 挡不住 finally。
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = process.cwd()
const PORT = Number(process.env.PORT ?? 3199)
const BASE = `http://localhost:${PORT}`
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

const outArg = process.argv.indexOf('--out')
const OUT = outArg > -1 ? process.argv[outArg + 1] : '/tmp/pdf-samples'

const rest = (p, o = {}) =>
    fetch(URL_ + p, { ...o, headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`,
        'Content-Type': 'application/json', ...(o.headers ?? {}) } })

async function rows(p, ctx) {
    const r = await rest(p)
    const body = await r.text()
    let j = null
    try { j = JSON.parse(body) } catch {}
    // 查询失败 ≠ 没有数据 —— 与 smoke-routes 的 restRows 同一条规矩。
    if (!r.ok || !Array.isArray(j)) throw new Error(`${ctx}: HTTP ${r.status} ${body.slice(0, 200)}`)
    return j
}

/**
 * 每一份对外单据:一条路由 + 它的 id 从哪张表来。
 * 【报表那四条没有 id】—— 它们是整库范围的,直接取。
 */
// ★【挑【有明细的】那一行,不是最新的那一行】★
// 第一版取 created_at 最新的一行,结果送货单与销售订单都挑中了【0 行明细】的
// ZZ2B-* 临时单 —— 渲染成功、抬头页脚都对,而**表格那一段一次都没有被走到**。
// 一份证据如果没有走到要证明的那一段,它证明的就不是它声称的那件事。
// 所以有明细表的单据先从【子表】拿一个真的有行的父 id;拿不到才退回最新那一行,
// 并在产物里说清楚它是空的。
const LINE_TABLES = {
    invoices: 'invoice_lines?select=invoice_id',
    credit_notes: 'credit_note_lines?select=credit_note_id',
    purchase_orders: 'purchase_order_lines?select=purchase_order_id',
    sales_orders: 'sales_order_lines?select=sales_order_id',
    quotes: 'quote_lines?select=quote_id',
    shipments: 'shipment_lines?select=shipment_id',
}

const DOCS = [
    { name: 'invoice',       table: 'invoices',        route: (id) => `/finance/invoices/${id}/pdf` },
    { name: 'credit-note',   table: 'credit_notes',    route: (id) => `/finance/credit-notes/${id}/pdf` },
    { name: 'statement',     table: 'customer_statements', route: (id) => `/finance/statements/${id}/pdf` },
    { name: 'purchase-order', table: 'purchase_orders', route: (id) => `/purchasing/orders/${id}/pdf` },
    { name: 'sales-order',   table: 'sales_orders',    route: (id) => `/sales/orders/${id}/pdf` },
    { name: 'quotation',     table: 'quotes',          route: (id) => `/sales/quotes/${id}/pdf` },
    { name: 'delivery-note', table: 'shipments',       route: (id) => `/sales/shipments/${id}/pdf` },
    { name: 'traceability',  table: 'output_batches',  route: (id) => `/output/${id}/traceability/pdf` },
    { name: 'report-snapshot',   table: null, route: () => '/inventory/reports/snapshot/pdf' },
    { name: 'report-ledger',     table: null, route: () => '/inventory/reports/ledger/pdf' },
    { name: 'report-safety',     table: null, route: () => '/inventory/reports/safety/pdf' },
    { name: 'report-violations', table: null, route: () => '/inventory/reports/violations/pdf' },
]

const main = async () => {
    mkdirSync(OUT, { recursive: true })

    // ── 一次性 admin 会话(形状取自 scripts/smoke-routes.mjs)────────────────
    const stamp = Date.now()
    const email = `pdfsample-${stamp}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'pdf-pass-1', email_confirm: true }) })).json()
    const roleRows = await rows('/rest/v1/roles?select=id&code=eq.admin', 'roles ← admin')
    await rest('/rest/v1/user_roles', { method: 'POST',
        body: JSON.stringify({ user_id: cu.id, role_id: roleRows[0].id }) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'pdf-pass-1' }) })).json()
    if (!sess?.access_token) throw new Error(`登录失败:${JSON.stringify(sess).slice(0, 200)}`)
    const cookie = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token=base64-'
        + Buffer.from(JSON.stringify(sess)).toString('base64url')

    const results = []
    try {
        for (const d of DOCS) {
            let id = null
            if (d.table) {
                // 【哪些表有软删,是查出来的,不是记的】实测 2026-09-02:
                // output_batches / purchase_orders / quotes / sales_orders 有 deleted_at;
                // invoices / credit_notes / customer_statements / shipments 【没有】。
                // 对没有那一列的表加过滤,PostgREST 回 42703 —— 而那不是"没有数据"。
                const del = ['output_batches', 'purchase_orders', 'quotes', 'sales_orders'].includes(d.table)
                    ? '&deleted_at=is.null' : ''
                // 先试"有明细的那一行"
                const lt = LINE_TABLES[d.table]
                if (lt) {
                    const kids = await rows(`/rest/v1/${lt}&limit=200`, `${d.name} ← 明细`)
                    const fk = lt.split('select=')[1]
                    const parents = [...new Set(kids.map((k) => k[fk]).filter(Boolean))]
                    if (parents.length) {
                        const ok = await rows(
                            `/rest/v1/${d.table}?select=id&limit=1${del}&id=in.(${parents.join(',')})` +
                            `&order=created_at.desc,id.desc`, `${d.name} ← ${d.table}(有明细)`)
                        id = ok[0]?.id ?? null
                    }
                }
                if (!id) {
                    const r = await rows(
                        `/rest/v1/${d.table}?select=id&limit=1${del}&order=created_at.desc,id.desc`,
                        `${d.name} ← ${d.table}`)
                    id = r[0]?.id ?? null
                }
                // 【没有数据不是失败,但必须【说出来】】—— 一份没渲染的单据与一份
                // 渲染过的单据,在产物目录里长得一样(都不存在那个文件)。所以记账。
                if (!id) { results.push({ ...d, status: 'NO DATA', bytes: 0 }); continue }
            }
            const url = BASE + d.route(id)
            const res = await fetch(url, { headers: { cookie } })
            const buf = Buffer.from(await res.arrayBuffer())
            const ct = res.headers.get('content-type') ?? ''
            if (res.ok && ct.includes('pdf')) {
                writeFileSync(join(OUT, `${d.name}.pdf`), buf)
                results.push({ ...d, status: `${res.status} ok`, bytes: buf.length })
            } else {
                writeFileSync(join(OUT, `${d.name}.FAILED.txt`), buf)
                results.push({ ...d, status: `${res.status} ${ct.slice(0, 40)}`, bytes: buf.length })
            }
        }
    } finally {
        await rest(`/rest/v1/user_roles?user_id=eq.${cu.id}`, { method: 'DELETE' })
        await rest(`/auth/v1/admin/users/${cu.id}`, { method: 'DELETE' })
    }

    console.log(`\n渲染产物 → ${OUT}\n`)
    for (const r of results) {
        console.log(`  ${r.name.padEnd(20)} ${String(r.status).padEnd(24)} ${r.bytes ? (r.bytes / 1024).toFixed(1) + ' KB' : ''}`)
    }
    const bad = results.filter((r) => !String(r.status).endsWith('ok'))
    console.log(`\n${results.length - bad.length}/${results.length} 份渲染成功`)
    if (bad.length) console.log(`未出 PDF:${bad.map((b) => b.name + '(' + b.status + ')').join('、')}`)
}

main().catch((e) => { console.error(e); process.exit(1) })
