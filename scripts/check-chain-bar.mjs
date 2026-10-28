#!/usr/bin/env node
// scripts/check-chain-bar.mjs
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-3(Tim 2026-10-26 裁定 2.4 (12) · 2026-10-27 scope D)· 每一种链上单据的详情页都画那条上下游链条
// ════════════════════════════════════════════════════════════════════════════
// 委托书 D:「A build check that fails if a detail page of a chain document type does not render the bar,
//   with a fault injection proving it bites.」—— 这一支就是那道构建闸。
//
// 【瞄准 · AIM】
//   我读的是      :lib/chains.ts 里 CHAINS-BEGIN … CHAINS-END 那一段字面量(不经 TypeScript,eval 成 JS 值);
//                   下面 PLACES 那张表(每一步落在哪一个文件、哪一种写法);那些文件的源码文本;
//                   db/tables/document_types.sql 的种子(种类 → 表);db/fixtures/296 里抄着的四条链定义。
//   我声称管的是   :① 链上每一步都有一个落点 —— 自己的详情页画着 <DocumentChains>,并且写明它站在【这一条链的这一步】;
//                   或者住在宿主页上的那几步,宿主页上真有那个锚点;
//                   ② 链上每一种单据都在登记表里,产出批那一步恰好是登记表里 output_batches 的全部前缀;
//                   ③ fixture 296 里抄的四条链与 lib/chains.ts 说的是同一件事(fixture 证的就是这一份定义)。
//   两者不同之处   :★ 我读【源码】,不读渲染出来的页面:一个写着 <DocumentChains> 却被某个分支跳过的页面我看不见 ——
//                   那一半由版式勘察与线上证明(真的打开每一种页面数 nav[data-chain])回答。
//                   ★ 我不判一条链【该有哪几步】:那是 Tim 的裁定(docs/system-map.md 2.4 (12)),写在 lib/chains.ts。
//
// 判据 ④ 覆盖是断言(AGENTS.md「覆盖率本身必须是一条断言」):PLACES 里的页面数 = 树里 `<DocumentChains` 出现的 page.tsx 数
//   (两条独立的路:表 vs 全树扫描),链的步数 = PLACES 的步数;一个都不许少,一个都不许多。
//
// 故障注入(CHECK_CHAIN_BAR_FAULT=…,每一格都要红在它说的那一行):
//   unbar:<文件>      假装那个文件里没有 <DocumentChains> → exit 1 并点名那一步
//   unanchor:<锚点>   假装宿主页上没有那个锚点(pricing / reservations / cost-allocation / line)→ exit 1
//   drift:<链>        把 fixture 那一份的边删掉一条 → exit 1(fixture 证的不再是这一份定义)
//   drift297:<链>     只动 fixture 297 那一份(CHAIN-WALK-COST)→ exit 1
//   blind             全树扫描读出 0 个页面 → exit 2,不许报"干净"
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const SELF = 'check-chain-bar'
const ROOT = new URL('..', import.meta.url).pathname
const FAULT = process.env.CHECK_CHAIN_BAR_FAULT ?? ''
const read = (p) => readFileSync(join(ROOT, p), 'utf8')

// ── 每一步落在哪里 ────────────────────────────────────────────────────────────
//   page   = 那一步自己的详情页:必须画 <DocumentChains>,并写着 { chain: '<链>', step: '<步>' }
//   anchor = 住在宿主页上的那一步:那个文件里必须有那个锚点(那一页本身作为另一步的 page 画着链条)
const PLACES = {
    'purchasing.purchase_order': { page: 'app/purchasing/orders/[id]/page.tsx' },
    'purchasing.inbound_batch': { page: 'app/inbound/[id]/edit/page.tsx' },
    'purchasing.assay': { page: 'app/inbound/[id]/assays/[assayId]/page.tsx' },
    'purchasing.pricing': { anchor: 'app/inbound/[id]/edit/page.tsx', needle: 'id="pricing"' },
    'purchasing.payable': { page: 'app/finance/payables/[batchId]/page.tsx' },
    'purchasing.payment_request': { page: 'app/finance/payment-requests/[id]/page.tsx' },
    'purchasing.payment': { page: 'app/finance/payments/[id]/page.tsx' },
    'purchasing.bank_reconciliation': { page: 'app/finance/bank/statements/[id]/page.tsx' },
    'processing.work_order': { page: 'app/operation/orders/[id]/page.tsx' },
    'processing.processing_run': { page: 'app/operation/processing/[id]/page.tsx' },
    'processing.input_batches': { page: 'app/inbound/[id]/edit/page.tsx' },
    'processing.output_batches': { page: 'app/output/[id]/edit/page.tsx' },
    'processing.cost_allocation': { anchor: 'app/operation/processing/[id]/page.tsx', needle: 'id="cost-allocation"' },
    'sales.quote': { page: 'app/sales/quotes/[id]/page.tsx' },
    'sales.sales_order': { page: 'app/sales/orders/[id]/page.tsx' },
    'sales.reservation': { anchor: 'app/sales/orders/[id]/ReservationSection.tsx', needle: 'id="reservations"' },
    'sales.shipment': { page: 'app/sales/shipments/[id]/page.tsx' },
    'sales.container': { page: 'app/logistics/containers/[id]/page.tsx' },
    'sales.invoice': { page: 'app/finance/invoices/[id]/page.tsx' },
    'sales.receipt': { page: 'app/finance/payments/[id]/page.tsx' },
    'sales.credit_note': { page: 'app/finance/credit-notes/[id]/page.tsx' },
    'people.attendance': { page: 'app/hr/attendance/[id]/page.tsx' },
    'people.overtime': { page: 'app/hr/overtime/[id]/page.tsx' },
    'people.leave': { page: 'app/hr/leave/[id]/page.tsx' },
    'people.payroll_period': { page: 'app/hr/payroll/[id]/page.tsx' },
    'people.payroll_payment': { page: 'app/finance/journal/[id]/page.tsx' },
}
// 「银行对账」的落点是对账单页上匹配的那一行:行带 id(rowAnchor)+ 页面挂 <HashTarget prefix="line-">
const LINE_ANCHOR = [
    { file: 'app/finance/bank/statements/[id]/StatementLinesTable.tsx', needle: 'rowAnchor={(r) => (r.isTotal ? undefined : `line-${r.id}`)}' },
    { file: 'app/finance/bank/statements/[id]/page.tsx', needle: '<HashTarget prefix="line-" />' },
]

// ── lib/chains.ts 的那一段字面量 ──────────────────────────────────────────────
const chainsSrc = read('lib/chains.ts')
const b = chainsSrc.indexOf('// CHAINS-BEGIN'), e = chainsSrc.indexOf('// CHAINS-END')
if (b < 0 || e < b) { console.error(`✗ ${SELF}:lib/chains.ts 里找不到 CHAINS-BEGIN / CHAINS-END`); process.exit(2) }
const CHAINS = (0, eval)('(' + chainsSrc.slice(b + '// CHAINS-BEGIN'.length, e) + ')')
const walkDef = (c) => ({ steps: c.steps.map((s) => ({ keys: s.keys, filter: s.filter ?? null })), edges: c.edges })

// ── 登记表种子:种类 → 表 ──────────────────────────────────────────────────────
const seed = read('db/tables/document_types.sql')
const kinds = new Map([...seed.matchAll(/^\s*\('([a-z_]+)', '([A-Z]+)', '([a-z_]+)', '(?:gapless|gapped)'/gm)].map((m) => [m[1], m[3]]))

const problems = []

// ① 每一步都有落点
let steps = 0
const pageFiles = new Set()
for (const c of CHAINS) {
    for (const s of c.steps) {
        steps++
        const id = `${c.id}.${s.id}`
        const place = PLACES[id]
        if (!place) { problems.push(`${id} 在 lib/chains.ts 里,而 PLACES 里没有它的落点 —— 给它一张详情页,或写明它住在哪个宿主页上`); continue }
        if (place.page) {
            pageFiles.add(place.page)
            let src = read(place.page)
            if (FAULT === `unbar:${place.page}`) src = src.replaceAll('<DocumentChains', '<NoChains')
            if (!/<DocumentChains\s+table=/.test(src)) problems.push(`${id}:${place.page} 没有画 <DocumentChains>(单据链条)`)
            else if (!src.includes(`{ chain: '${c.id}', step: '${s.id}' }`)) problems.push(`${id}:${place.page} 画着链条,但没有写明它站在「${c.id} · ${s.id}」这一步`)
        } else {
            let src = read(place.anchor)
            if (FAULT === `unanchor:${place.needle.replace(/^id="|"$/g, '')}`) src = src.replaceAll(place.needle, '')
            if (!src.includes(place.needle)) problems.push(`${id}:宿主页 ${place.anchor} 上没有锚点 ${place.needle} —— 链条上那一步会落在页顶`)
        }
        if (s.anchor === 'line') {
            for (const a of LINE_ANCHOR) {
                let src = read(a.file)
                if (FAULT === 'unanchor:line') src = src.replaceAll(a.needle, '')
                if (!src.includes(a.needle)) problems.push(`${id}:${a.file} 少了「匹配上的那一行」的锚点(${a.needle})`)
            }
        }
        // ② 每一种单据都在册
        for (const k of s.keys) if (!kinds.has(k)) problems.push(`${id}:单据种类 ${k} 不在 db/tables/document_types.sql 的种子里`)
    }
}
for (const id of Object.keys(PLACES)) {
    const [cid, sid] = id.split('.')
    if (!CHAINS.some((c) => c.id === cid && c.steps.some((s) => s.id === sid))) problems.push(`PLACES 里的 ${id} 不在 lib/chains.ts 里 —— 一条过期的落点`)
}
// ② 产出批那一步 = 登记表里 output_batches 的全部前缀
const outStep = CHAINS.find((c) => c.id === 'processing')?.steps.find((s) => s.id === 'output_batches')
const outKinds = [...kinds].filter(([, t]) => t === 'output_batches').map(([k]) => k).sort()
assertPopulation(SELF, '登记表里 output_batches 的种类', outKinds.length)
assertPinned(SELF, '加工链「产出批」那一步的种类 ↔ 登记表里 output_batches 的种类', [...(outStep?.keys ?? [])].sort().join(','), outKinds.join(','),
    '登记表多了(或少了)一个产出批前缀,而链条那一步没有跟上 —— 那一种产出批的页面上会没有加工链')

// ③ fixture 296 与 297 抄的四条链 = lib/chains.ts(297:CHAIN-WALK-COST 的按角色计时 —— 它计时的也必须是这一份定义)
for (const fxFile of ['db/fixtures/296-every-adjacent-pair-on-the-four-chains-links-both-ways.sql',
                      'db/fixtures/297-the-chain-walk-and-the-trail-stay-cheap-for-seven-roles-at-a-years-volume.sql']) {
    const fxNo = fxFile.match(/fixtures\/(\d+)/)[1]
    const fx = read(fxFile)
    const copies = new Map([...fx.matchAll(/^\s*c_[a-z]+\s+constant jsonb := '(\{.*\})';\s*-- CHAIN ([a-z]+)\s*$/gm)].map((m) => [m[2], m[1]]))
    for (const c of CHAINS) {
        let copy = copies.get(c.id)
        if (!copy) { problems.push(`fixture ${fxNo} 里没有「-- CHAIN ${c.id}」那一行 —— 它证的不是这一条链`); continue }
        if (FAULT === `drift:${c.id}` || FAULT === `drift${fxNo}:${c.id}`) { const j = JSON.parse(copy); j.edges.pop(); copy = JSON.stringify(j) }
        if (JSON.stringify(JSON.parse(copy)) !== JSON.stringify(walkDef(c))) {
            problems.push(`fixture ${fxNo} 抄的 ${c.id} 链与 lib/chains.ts 不一样 —— 改了链就要同一个提交改 fixture(它证的是这一份定义)`)
        }
    }
    assertPinned(SELF, `fixture ${fxNo} 里的链条数 ↔ lib/chains.ts 的链条数`, copies.size, CHAINS.length, 'fixture 抄的链多了或少了')
}

// ④ 覆盖:表里的页面 = 全树里画着 <DocumentChains> 的 page.tsx(两条独立的路)
const scanned = []
const walk = (dir) => {
    for (const n of readdirSync(join(ROOT, dir))) {
        const p = join(dir, n)
        if (statSync(join(ROOT, p)).isDirectory()) { if (n !== 'node_modules') walk(p) }
        else if (n === 'page.tsx' && /<DocumentChains\s+table=/.test(read(p))) scanned.push(p)   // JSX 的形状,不是名字(注释里提到它不算)
    }
}
walk('app')
const scannedCount = FAULT === 'blind' ? 0 : scanned.length
assertPopulation(SELF, '全树里画着 <DocumentChains> 的 page.tsx', scannedCount)
assertPinned(SELF, 'PLACES 里的页面数 ↔ 全树扫描数到的页面数', pageFiles.size, scannedCount,
    '一张页面画了链条却不在 PLACES 里(它站在哪一步没人核对),或者 PLACES 里的页面没画')
assertPinned(SELF, 'PLACES 的步数 ↔ lib/chains.ts 的步数', Object.keys(PLACES).length, steps, 'PLACES 与链的步骤对不上')

if (problems.length) {
    console.error(`✗ ${SELF}:${problems.length} 处`)
    for (const p of problems) console.error(`    ${p}`)
    console.error('  ☞ 裁定 2.4 (12)(docs/system-map.md):四条链上每一种单据的详情页都有那条上下游链条;没有自己页面的那几步住在宿主页的锚点上。')
    process.exit(1)
}
console.log(`✓ ${SELF}:${CHAINS.length} 条链 · ${steps} 步各有落点 · ${pageFiles.size} 张详情页画着链条(全树扫描数到 ${scannedCount}) · fixture 296 / 297 抄的四条链与 lib/chains.ts 一致`)
