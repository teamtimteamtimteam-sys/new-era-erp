#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-1(Tim 2026-10-25 Q8 · Q9)· 84 张列表页上的每一张表都开着排序
// ════════════════════════════════════════════════════════════════════════════
// Tim 的 Q8:「每一张列表页」= Step 0 量到的那 84 张(含 8 张 CellsTable 页与 3 张可编辑的表;12 张卡片清单不算)。
// Q9:一次读全体的在浏览器里排,分页 / 截断的在数据库里排。**一张新写的、或被人改过的列表页悄悄少了 `sorting`,
// 屏幕上一点都看不出来** —— 表照常画,只是表头不可点。所以这件事要一道闸,不能靠下一个人记得。
//
// 【瞄准 · AIM】
//   我读的是      :下面 LIST_ROUTES 里每一条路由【目录本层】的 .tsx 源码(注释剥掉),其中每一个
//                   `<DataTable` / `<EditableTable` / `<CellsTable` 开标签(跨行也认,花括号与字符串里的 > 不算结束)。
//   我声称管的是   :那些开标签每一个都带一个 `sorting` 属性 —— 浏览器排或数据库排,二选一。
//   两者不同之处   :★ 我只看【路由目录本层】的文件。一张表若画在别处的共享组件里(例如 app/components/pricing/TermsRequestsPanel.tsx),
//                   我看不见它 —— 那几处由转换刀逐个读过,列在 docs/table-features.md。
//                   ★ 我证的是「属性写了」,不是「排得对」:数据库排序走的是不是读者读的那一张关系、空值排在哪,
//                   由 lib/listSort.ts 与线上证明(db/scripts/2026-10-25-table-features-1-live-proof.mjs)回答。
//                   ★ LIST_ROUTES 是 Step 0 那一次量出来的名单(docs/surveys/TABLE-FEATURES-1/survey-lists.md §2);
//                   以后新开的列表页要自己加进来 —— 一条新路由不在名单上,我看不见它。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const SELF = 'check-list-sorting'
const ROOT = process.cwd()

/** Tim 2026-10-25 Q8 的 84 张(Step 0 量的名单,原样)+ SYSTEM-MAP-1 D4 的 4 张(Tim 2026-10-27:每一张都带排序与导出)+ SYSTEM-MAP-2 的待办 1 张
 *  + SYSTEM-MAP-4 的 ESG 两张(Tim 2026-10-30 Q1:能耗强度 · 回收,共享表、排序、导出)+ ESG-2 的四张(Tim 2026-10-31)。 */
const LIST_ROUTES = [
    // SYSTEM-MAP-2(Tim 2.4 (9)):工作台 › 待办
    '/workbench',
    // SYSTEM-MAP-4(Tim 2026-10-30 Q1):ESG 的两张只读新页 —— 共享表、排序、Excel/CSV 导出
    '/safety/energy',
    '/safety/recovery',
    // ESG-2(Tim 2026-10-31):回收之后的四条新菜单行 —— 安全率 · 培训合规 · 制度登记簿 · 举报登记簿(共享表、排序、导出)
    '/safety/rates',
    '/safety/training',
    '/safety/policies',
    '/safety/whistleblowing',
    // SYSTEM-MAP-1 D4
    '/claims',
    '/compliance/cod',
    '/compliance/supplier-certificates',
    '/operation/spare-parts',
    '/compliance/packs',
    '/contracts',
    '/finance/assets',
    '/finance/bank',
    '/finance/bank/statements',
    '/finance/claims',
    '/finance/close',
    '/finance/credit-notes',
    '/finance/electricity',
    '/finance/expenses',
    '/finance/freight',
    '/finance/fx',
    '/finance/gst',
    '/finance/invoices',
    '/finance/journal',
    '/finance/packs',
    '/finance/payment-requests',
    '/finance/payments',
    '/finance/self-approved',
    '/finance/supplier-statements',
    '/finance/wht',
    '/hr/attendance',
    '/hr/claims',
    '/hr/departments',
    '/hr/employees',
    '/hr/kpi',
    '/hr/kpi/score',
    '/hr/leave',
    '/hr/leave/balances',
    '/hr/leave/holidays',
    '/hr/leave/types',
    '/hr/overtime',
    '/hr/payroll',
    '/hr/reviews',
    '/hr/reviews/scale',
    '/hr/training',
    '/inbound',
    '/inventory',
    '/inventory/locations',
    '/inventory/reports/ledger',
    '/logistics/containers',
    '/logistics/forwarders',
    '/materials',
    '/me',
    '/my-reviews',
    '/operation/blending',
    '/operation/calibration',
    '/operation/capture',
    '/operation/capture/inbox',
    '/operation/contamination',
    '/operation/devices',
    '/operation/equipment',
    '/operation/handovers',
    '/operation/operation-types',
    '/operation/orders',
    '/operation/processing',
    '/operation/weighbridge',
    '/operation/wip',
    '/output',
    '/purchasing/licences',
    '/purchasing/orders',
    '/purchasing/payment-terms',
    '/quality/coa',
    '/quality/disputes',
    '/quality/ncr',
    '/quality/samples',
    '/safety/environment',
    '/safety/incidents',
    '/safety/inspections',
    '/sales/commissions',
    '/sales/customers',
    '/sales/orders',
    '/sales/quotes',
    '/settings/deleted',
    '/settings/dictionaries',
    '/settings/import',
    '/settings/pending-values',
    '/settings/reference',
    '/settings/roles',
    '/stocktakes',
    '/suppliers',
    '/suppliers/scorecards',
    '/tools/pricing/formulas',
    '/tools/pricing/metal-prices',
]

function stripComments(src) {
    return src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
        .replace(/(^|[^:'"`])\/\/.*$/gm, (m, a) => a)
}

/** 从 `<Tag` 起走到开标签结束的那个 `>`(花括号深度 0、不在字符串里)。 */
function openingTag(src, start) {
    let depth = 0, q = null
    for (let i = start + 1; i < src.length; i++) {
        const c = src[i]
        if (q) { if (c === '\\') { i++; continue } if (c === q) q = null; continue }
        if (c === '"' || c === "'" || c === '`') { q = c; continue }
        if (c === '{') depth++
        else if (c === '}') depth--
        else if (c === '>' && depth === 0) return src.slice(start, i + 1)
    }
    return src.slice(start)
}

/**
 * 名单里路由目录本层、却【不需要】在开标签上写 sorting 的文件 —— 每一条带理由,而且每一条都被【当场核对】:
 *  · kind 'detail':这个文件住在列表路由的目录里,画的却是【详情页】的面板。核对:列表路由目录本层没有任何文件渲染它(`<名字`)。
 *  · kind 'prop':这张表的排序由调用方经一个 prop 交进来(浏览器排 / 数据库排二选一,或「读满 1,000 行就关」)。
 *    核对:列表页那个调用点确实把那个 prop 传了(`caller` 文件里 `<名字 … prop` 出现)。
 * 一条核对不过的豁免 = 红,与「一条命不中任何东西的豁免」同一条(scripts/lib/selfproof.mjs ③)。
 */
const EXEMPT = [
    { file: 'app/operation/devices/KeysPanel.tsx', kind: 'detail', name: 'KeysPanel', reason: '设备详情页 /operation/devices/[id] 的面板' },
    { file: 'app/operation/devices/MeterPanel.tsx', kind: 'detail', name: 'MeterPanel', reason: '设备详情页 /operation/devices/[id] 的面板' },
    { file: 'app/sales/customers/ChasePanel.tsx', kind: 'detail', name: 'ChasePanel', reason: '客户详情页 /sales/customers/[id] 的面板' },
    { file: 'app/sales/customers/ContactsPanel.tsx', kind: 'detail', name: 'ContactsPanel', reason: '客户详情页与供应商编辑页的面板' },
    { file: 'app/sales/customers/StatementPanel.tsx', kind: 'detail', name: 'StatementPanel', reason: '客户详情页 /sales/customers/[id] 的面板' },
    { file: 'app/suppliers/MeasuresTable.tsx', kind: 'detail', name: 'MeasuresTable', reason: '供应商编辑页的评分卡面板' },
    { file: 'app/operation/equipment/CellsTable.tsx', kind: 'prop', name: 'CellsTable', caller: null, reason: '共享外壳:排序由每一个调用点的 sorting prop 决定(本支在调用点上逐个查 <CellsTable … sorting>)' },
    { file: 'app/quality/coa/CoaTable.tsx', kind: 'prop', name: 'CoaTable', caller: ['app/quality/coa/page.tsx', /\bclientSort\b/], reason: '与产出批编辑页共用;只有列表页传 clientSort' },
    { file: 'app/safety/inspections/InspectionTables.tsx', kind: 'prop', name: 'RunsTable', caller: ['app/safety/inspections/page.tsx', /\bsort=\{/], reason: '巡检记录表与模板详情页共用;列表页传 sort(数据库排)' },
    { file: 'app/operation/contamination/ContaminationChecksList.tsx', kind: 'prop', name: 'ContaminationChecksList', caller: ['app/operation/contamination/page.tsx', /\bsorting=\{/], reason: '与产出批编辑页共用;列表页传 sorting(数据库排)' },
    { file: 'app/settings/reference/PermissionReferenceTable.tsx', kind: 'prop', name: 'PermissionReferenceTable', caller: ['app/settings/reference/page.tsx', /\bsortable=\{/], reason: '整次读取读满 1,000 行时由页面关掉排序(一张表只看得见自己那一类)' },
]
const exemptFiles = new Set(EXEMPT.map((e) => e.file))
for (const e of EXEMPT) {
    if (!existsSync(join(ROOT, e.file))) { console.error(`✗ ${SELF}:豁免 ${e.file} 指着一个不存在的文件`); process.exit(1) }
    const routeDir = LIST_ROUTES.map((r) => `app${r}`).find((d) => e.file.startsWith(d + '/') && !e.file.slice(d.length + 1).includes('/'))
    if (!routeDir) { console.error(`✗ ${SELF}:豁免 ${e.file} 不在任何一张列表路由的目录本层 —— 它是一条死豁免`); process.exit(1) }
    if (e.kind === 'detail') {
        for (const n of readdirSync(join(ROOT, routeDir)).filter((n) => n.endsWith('.tsx'))) {
            if (new RegExp(`<${e.name}(?=[\\s>])`).test(stripComments(readFileSync(join(ROOT, routeDir, n), 'utf8')))) {
                console.error(`✗ ${SELF}:豁免 ${e.file}(详情页面板)被列表页的 ${routeDir}/${n} 渲染了 —— 那它就是列表页上的一张表,要开排序`); process.exit(1)
            }
        }
    }
    if (e.kind === 'prop' && e.caller) {
        const [cf, re] = e.caller
        const src = stripComments(readFileSync(join(ROOT, cf), 'utf8'))
        const at = src.search(new RegExp(`<${e.name}(?=[\\s>])`))
        if (at < 0 || !re.test(openingTag(src, at))) { console.error(`✗ ${SELF}:${cf} 的 <${e.name}> 没有把排序的 prop 传进来(豁免 ${e.file} 的前提不成立)`); process.exit(1) }
    }
}

assertPinned(SELF, '列表页名单(Tim Q8 的 84 + SYSTEM-MAP-1 D4 的 4 + SYSTEM-MAP-2 待办 1 + SYSTEM-MAP-4 ESG 2 + ESG-2 的 4 —— Tim 2026-10-30 SYSTEM-MAP-4 Q1 · 2026-10-31:新 ESG 页在共享表上、带排序与导出)', LIST_ROUTES.length, 95, '名单不再是 95 条 —— 改它要有一条裁定')
let files = 0, tags = 0, rough = 0
const bad = []
for (const r of LIST_ROUTES) {
    const dir = join(ROOT, 'app', r)
    if (!existsSync(join(dir, 'page.tsx'))) { bad.push(`${r}:路由不存在了(page.tsx 找不到)`); continue }
    for (const n of readdirSync(dir)) {
        const p = join(dir, n)
        if (!n.endsWith('.tsx') || statSync(p).isDirectory()) continue
        files++
        const src = stripComments(readFileSync(p, 'utf8'))
        rough += (src.match(/<(DataTable|EditableTable|CellsTable)(?=[\s>])/g) ?? []).length
        for (const m of src.matchAll(/<(DataTable|EditableTable|CellsTable)(?=[\s>])/g)) {
            tags++
            const tag = openingTag(src, m.index)
            if (!/\bsorting\s*=/.test(tag) && !exemptFiles.has(`app${r}/${n}`)) bad.push(`app${r}/${n}:${src.slice(0, m.index).split('\n').length} <${m[1]}> 没有 sorting`)
        }
    }
}
assertPopulation(SELF, '名单里路由目录本层的 .tsx', files)
assertPopulation(SELF, '表格开标签', tags)
assertPinned(SELF, '表格开标签', tags, rough, '判据与粗计数不一样多 —— 有一种开标签写法判据没认出来')

if (process.env.CHECK_LIST_SORTING_FAULT === 'inject') bad.push('INJECTED')

if (bad.length) {
    console.error(`✗ ${SELF}:${bad.length} 处:`)
    for (const b of bad) console.error(`    ${b}`)
    console.error('  ☞ 一次读全体的表:sorting={{ mode: \'client\', coverage: \'complete\' }}(CellsTable:sorting="client");分页 / 截断的表在数据库里排(lib/listSort.ts)。见 docs/table-features.md。')
    process.exit(1)
}
console.log(`✓ ${SELF}:${LIST_ROUTES.length} 张列表页 · ${files} 个文件 · ${tags} 个表格开标签,每一个都开着排序`)
