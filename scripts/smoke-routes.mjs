#!/usr/bin/env node
// scripts/smoke-routes.mjs — 路由冒烟:把 Tim 手点的事一次跑完(OPS 级,按需运行)。
//
// 【为什么存在】两页断了几个月、每道门都是绿的 —— build 只编译、从不渲染;
// RSC 的序列化错误、查询错误只有真的渲染那一页才炸。手点一页一页找,脚本一把全找。
//
// 做什么:起 dev server → 建一次性 admin 会话(admin API + service key)→
// 请求 app/ 下每一条路由(动态段现从库里取一个真实 id,数据变了脚本照样活)→
// 断言 2xx(或预期中的重定向/预期 404)→ 失败的连同【服务端】错误堆栈一起报 ——
// 浏览器那句话什么都不说,上两只虫都因此多绕了一圈。收尾删掉临时会话。
//
// 用法:node scripts/smoke-routes.mjs        (退出码 0 = 全通;1 = 有失败)
// 【不进 db/gate.py】整跑约 2-4 分钟且要起 dev server —— 慢门会被跳过,
// check_mirrors 的教训。按需跑:每次改了页面渲染层,或 Tim 又用手找到一只虫之后。
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3199
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

// ── 路由枚举 ────────────────────────────────────────────────────────────────
function* walk(dir) {
    for (const name of readdirSync(dir)) {
        const p = join(dir, name)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if (name === 'page.tsx' || name === 'route.ts') yield p
    }
}
const routes = [...walk(join(ROOT, 'app'))].map((p) =>
    p.slice(ROOT.length + 3).replace(/\/(page\.tsx|route\.ts)$/, '') || '/')

// ── 动态段的真实 id 从哪来(PostgREST + service key,随数据变化自动跟上)────
const ID_SOURCES = {
    '[id]': {
        '/customers': 'customers', '/finance/bank/statements': 'bank_statements',
        '/finance/expenses': 'expenses', '/finance/fx': 'fx_rates',
        '/finance/invoices': 'invoices', '/finance/journal': 'journal_entries',
        '/finance/payments': 'payments', '/hr/claims': 'medical_claims',
        '/hr/departments': 'departments', '/hr/employees': 'employees',
        '/hr/leave': 'leave_requests', '/hr/payroll': 'payroll_periods',
        '/hr/reviews': 'performance_reviews', '/hr/training': 'training_records',
        '/inbound/receive/done': 'inbound_batches', '/inbound': 'inbound_batches',
        '/materials': 'materials', '/metal-prices': 'metal_prices',
        '/my-reviews': 'performance_reviews', '/output': 'output_batches',
        '/pricing/formulas': 'pricing_formulas', '/processing': 'processing_runs',
        '/purchasing/orders': 'purchase_orders', '/purchasing/payment-terms': 'payment_term_templates',
        '/settings/permissions/roles': 'roles', '/stocktakes': 'stocktakes',
        '/suppliers': 'suppliers',
    },
    '[assayId]': { '': 'assay_results' },
    '[batchId]': { '': 'inbound_batches' },
    '[saleId]': { '': 'sales_records' },
    '[materialId]': { '': 'materials' },
}
// 预期中的"非 200":这些不是坏,是设计(第一轮全量报告逐条核实后收编)
const EXPECTED = {
    '/logout': [307, 303],          // 登出即重定向
    '/my-reviews/[id]': [404],      // admin 不是该行的评估人 —— notFound 是契约(HR 用 /hr/reviews)
    '/welcome': [200, 307],
    '/set-password': [200, 307],
    '/purchasing': [307],           // 索引页重定向到 /purchasing/orders
    '/hr/payroll/[id]/edit': [200, 307],    // 已过账的期间不可编辑 → 设计上重定向去详情
    '/stocktakes/[id]/review': [200, 307],  // 非可复核状态 → 设计上重定向去详情
    '/finance/bank/statements/[id]/reconcile': [200, 307],  // 已对平的报表 → 设计上重定向回详情
}

async function rest(path, opts = {}) {
    const r = await fetch(URL_ + path, { ...opts,
        headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(opts.headers ?? {}) } })
    return r
}
// 有软删列的表跳过已删行 —— 详情页对已删行 404 是契约,不是坏
const SOFT_DELETED = new Set(['customers','suppliers','materials','bank_statements','expenses',
    'inbound_batches','invoices','leave_requests','medical_claims','metal_prices','output_batches',
    'payroll_periods','payment_term_templates','pricing_formulas','processing_runs','purchase_orders',
    'review_cycles','stocktakes','training_records','fx_rates','employees','departments','sales_records'])
async function firstId(table, extra = '') {
    const del = SOFT_DELETED.has(table) ? '&deleted_at=is.null' : ''
    const r = await rest(`/rest/v1/${table}?select=id&limit=1${del}${extra}`)
    const rows = await r.json()
    return rows?.[0]?.id ?? null
}

async function main() {
    // ── 一次性 admin 会话 ────────────────────────────────────────────────────
    const email = `smoke-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'smoke-pass-1', email_confirm: true }) })).json()
    const roleRows = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST',
        body: JSON.stringify({ user_id: cu.id, role_id: roleRows[0].id }) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'smoke-pass-1' }) })).json()
    const cookie = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token=base64-'
        + Buffer.from(JSON.stringify(sess)).toString('base64url')

    // ── dev server ───────────────────────────────────────────────────────────
    const logChunks = []
    const dev = spawn('npx', ['next', 'dev', '-p', String(PORT)], { cwd: ROOT })
    dev.stdout.on('data', (d) => logChunks.push(d.toString()))
    dev.stderr.on('data', (d) => logChunks.push(d.toString()))
    for (let i = 0; i < 60; i++) {
        await new Promise((r) => setTimeout(r, 1000))
        if (logChunks.join('').includes('Ready in')) break
    }

    const failures = []
    let ok = 0, skipped = 0
    try {
        for (const route of routes.sort()) {
            let url = route
            let skip = null
            // 父子路由的 id 必须【配套】:先取子行,再用它的外键定父段
            if (route === '/inbound/[id]/assays/[assayId]') {
                const r = await rest('/rest/v1/assay_results?select=id,inbound_batch_id&limit=1')
                const rows = await r.json()
                if (!rows?.[0]) { skipped++; console.log(`  SKIP ${route}  (no data in assay_results)`); continue }
                url = route.replace('[id]', rows[0].inbound_batch_id).replace('[assayId]', rows[0].id)
            }
            for (const [seg, srcs] of Object.entries(ID_SOURCES)) {
                if (!url.includes(seg)) continue
                const prefix = Object.keys(srcs).filter((p) => route.startsWith(p) || p === '')
                    .sort((a, b) => b.length - a.length)[0]
                const id = await firstId(srcs[prefix])
                if (!id) { skip = `no data in ${srcs[prefix]}`; break }
                url = url.replace(seg, id)
            }
            if (skip) { skipped++; console.log(`  SKIP ${route}  (${skip})`); continue }
            const before = logChunks.length
            const res = await fetch(`http://localhost:${PORT}${url}`, {
                headers: { cookie }, redirect: 'manual' })
            const allow = EXPECTED[route] ?? []
            const pass = (res.status >= 200 && res.status < 300) || allow.includes(res.status)
                || (res.status >= 300 && res.status < 400 && allow.length === 0 && route === '/logout')
            if (pass) { ok++ }
            else {
                await new Promise((r) => setTimeout(r, 500))
                const errLog = logChunks.slice(before).join('')
                const stack = [...errLog.matchAll(/⨯[\s\S]{0,600}?digest[^\n]*\n?\}/g)].map((m) => m[0]).join('\n')
                    || errLog.split('\n').filter((l) => /Error|error|⨯/.test(l)).slice(0, 8).join('\n')
                failures.push({ route, url, status: res.status, stack })
                console.log(`  FAIL ${route} → ${res.status}`)
            }
        }
    } finally {
        dev.kill('SIGTERM')
        await rest(`/rest/v1/user_roles?user_id=eq.${cu.id}`, { method: 'DELETE' })
        await rest(`/auth/v1/admin/users/${cu.id}`, { method: 'DELETE' })
    }

    console.log(`\n== ${routes.length} routes: ${ok} ok, ${skipped} skipped (no data), ${failures.length} FAILED`)
    for (const f of failures) {
        console.log(`\n✗ ${f.route} (${f.url}) → HTTP ${f.status}`)
        if (f.stack) console.log(f.stack.split('\n').map((l) => '    ' + l).join('\n'))
    }
    process.exit(failures.length ? 1 : 0)
}
main()
