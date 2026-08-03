#!/usr/bin/env node
// scripts/check-i18n.mjs — i18n 键体检:代码里用到的键,两个文案文件里必须都有。
//
// 【为什么存在】lib/i18n 的解析器找不到键时【原样返回键本身】(方便发现漏翻),
// 于是缺一个键 = 屏幕上印一串 hr.alertType.salary_not_set,而任何检查都不会红。
// 它咬过三次:五个 hr_alerts 类型、三个页面的 hr.title、一格 "null days" ——
// 全靠肉眼。员工账号发出去之后,下一个是员工先看见。
//
// 【口径】
//   FAIL:代码里静态引用的键(含 key:/labelKey:/titleKey= 等字面量),en 或 zh 缺。
//   FAIL:动态构造的键(前缀 + 运行期后缀),后缀集合可枚举、而枚举出的某个键缺 ——
//         三次事故全住在这类键里,所以不许静默跳过。
//   FAIL:出现了清单(MANIFEST)之外的动态前缀 —— 新的动态写法必须被归类;
//         没归类的是盲区,不是通过。
//   REPORT(不 FAIL):定义了但从未引用的键 —— 死键是不整洁,不是坏。
//   REPORT(不 FAIL):后缀集合静态不可知的动态构造(kind:'data')—— 点名留档。
//     (本仓库现状:62 个动态前缀全部可枚举,'data' 分支眼下为空,留给将来。)
//
// 【后缀集合的取数】不写死在这里:每次运行都从【真源】现读 ——
//   db/tables/*.sql 的 CHECK (col IN (...))、db/views/*.sql 的 'x'::text AS 别名、
//   *ErrorCodes.ts 的 new Set([...])、组件里的 as const 数组。
//   加一个枚举值,本检查自动跟着变宽;写死清单只会烂在这里。
//   真源解析出 0 个后缀视为解析器坏了 → FAIL,不是"没有值"。
//
// 用法:node scripts/check-i18n.mjs   (退出码 0 = 干净;1 = 有缺)
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname

// ────────────────────────────────────────────────────────────── message files
function loadMessages(file, varName) {
    let src = readFileSync(join(ROOT, 'messages', file), 'utf8')
    src = src.replace(/^import type.*$/m, '')
    src = src.replace(/\} as const( satisfies Messages)?/, '}')
    src = src.replace(/export default \w+/, '')
    return new Function(`${src}; return ${varName}`)()
}

function flatten(obj, prefix = '', out = new Map()) {
    for (const [k, v] of Object.entries(obj)) {
        const key = prefix ? `${prefix}.${k}` : k
        if (v && typeof v === 'object') flatten(v, key, out)
        else out.set(key, String(v))
    }
    return out
}

const EN = flatten(loadMessages('en.ts', 'en'))
const ZH = flatten(loadMessages('zh.ts', 'zh'))
const TOP_SECTIONS = new Set([...EN.keys()].map((k) => k.split('.')[0]))

// ────────────────────────────────────────────────────────────── source scan
function* walk(dir) {
    for (const name of readdirSync(dir)) {
        const p = join(dir, name)
        const st = statSync(p)
        if (st.isDirectory()) {
            if (name === 'node_modules' || name === '.next') continue
            yield* walk(p)
        } else if (/\.(ts|tsx)$/.test(name) && !p.endsWith('database.types.ts')) {
            yield p
        }
    }
}

// lib/i18n 自身不扫:解析器内部与注释里的 t('key') 示例是文档,不是用法
const files = [...walk(join(ROOT, 'app')), ...walk(join(ROOT, 'lib'))].filter(
    (p) => !p.includes('/lib/i18n/')
)
const lineOf = (src, idx) => src.slice(0, idx).split('\n').length

const staticUses = []   // { key, file, line }             t('key')
const dynamicUses = []  // { prefix, file, line }          t('prefix' + x) / t(`prefix${x}`)
const variableUses = [] // { expr, file, line }            t(item.key) 等 —— 靠字面量收网覆盖
const keyLiterals = []  // { key, file, line }             键样字面量(key: 属性、JSX 属性、任意位置)
const aliasNotes = []

// 键样字面量的"任意位置"收网要排除的上下文:supabase 查询、路由、revalidate ——
// 这些字符串长得像键但不是键。排除是按【调用形状】而不是按值,免得误杀真键。
const NOT_A_KEY_CONTEXT =
    /(?:\.(?:eq|neq|gt|gte|lt|lte|like|ilike|is|in|not|or|order|select|filter|rpc|from|contains|overlaps|match|csv)|revalidatePath|redirect|push|href|src|import)\s*\(?\s*$/

const KEY_PATTERN = /^[a-z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9_]+)+$/

for (const abs of files) {
    const src = readFileSync(abs, 'utf8')
    const rel = relative(ROOT, abs)

    // 本文件里翻译函数叫什么(几乎总是 t;不是 t 的报出来 —— 漏扫的形状是盲区)
    const names = new Set(['t'])
    for (const m of src.matchAll(/const\s+(\w+)\s*=\s*(?:await\s+)?(?:getTranslations|useTranslations)\(\)/g)) {
        names.add(m[1])
        if (m[1] !== 't') aliasNotes.push(`${rel}:${lineOf(src, m.index)} 译名为 ${m[1]}`)
    }

    // 两种调用形状:具名 t(...) 与【直呼】(await getTranslations())(...) ——
    // 后者从不落到叫 t 的变量上,曾把 4 个 *.errors. 前缀整族藏掉(processing/
    // stocktakes/assay/bank/invoice/expense/pricing…),所以单独扫。
    const callSites = []
    for (const name of names) {
        for (const m of src.matchAll(new RegExp(String.raw`\b${name}\(\s*`, 'g'))) {
            callSites.push(m)
        }
    }
    for (const m of src.matchAll(/\(await getTranslations\(\)\)\(\s*/g)) {
        callSites.push(m)
    }
    {
        for (const m of callSites) {
            const at = m.index + m[0].length
            const rest = src.slice(at, at + 200)
            const line = lineOf(src, m.index)
            let mm
            if ((mm = rest.match(/^'([^']+)'\s*\+/)) || (mm = rest.match(/^"([^"]+)"\s*\+/))) {
                dynamicUses.push({ prefix: mm[1], file: rel, line })
            } else if ((mm = rest.match(/^'([^']+)'/)) || (mm = rest.match(/^"([^"]+)"/))) {
                staticUses.push({ key: mm[1], file: rel, line })
            } else if ((mm = rest.match(/^`([^`$]+)\$\{/))) {
                dynamicUses.push({ prefix: mm[1], file: rel, line })
            } else if ((mm = rest.match(/^`([^`$]+)`/))) {
                staticUses.push({ key: mm[1], file: rel, line })
            } else if (/^[A-Za-z_$(]/.test(rest)) {
                variableUses.push({ expr: rest.split(/[,)]/)[0].trim().slice(0, 50), file: rel, line })
            }
        }
    }

    // 键样字面量收网:t(变量) 的粮仓 —— key:/labelKey:/titleKey: 属性、titleKey="…" JSX
    // 属性、对象字面量的带点字符串键、以及其余任何位置的键样字符串(按上下文排噪)。
    for (const m of src.matchAll(/['"]([a-z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9_]+)+)['"]/g)) {
        const lit = m[1]
        if (!KEY_PATTERN.test(lit) || !TOP_SECTIONS.has(lit.split('.')[0])) continue
        const before = src.slice(Math.max(0, m.index - 40), m.index)
        if (NOT_A_KEY_CONTEXT.test(before)) continue
        keyLiterals.push({ key: lit, file: rel, line: lineOf(src, m.index) })
    }
}

// ─────────────────────────────────────────────── dynamic-suffix resolvers(真源现读)
function sqlEnum(file, col) {
    const src = readFileSync(join(ROOT, file), 'utf8')
    const m = src.match(new RegExp(String.raw`CHECK \(\s*${col} IN\s*\(([^)]+)\)`, 's'))
    if (!m) throw new Error(`${file} 里找不到 CHECK (${col} IN (...))`)
    return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1])
}
function sqlLiteralAs(file, alias) {
    const src = readFileSync(join(ROOT, file), 'utf8')
    return [...new Set([...src.matchAll(new RegExp(String.raw`'(\w+)'::text AS ${alias}`, 'g'))].map((x) => x[1]))]
}
function tsSet(file, name) {
    const src = readFileSync(join(ROOT, file), 'utf8')
    const m = src.match(new RegExp(String.raw`${name}\s*=\s*new Set\(\[([\s\S]*?)\]\)`))
    if (!m) throw new Error(`${file} 里找不到 ${name} = new Set([...])`)
    return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1])
}
function tsArray(file, name) {
    const src = readFileSync(join(ROOT, file), 'utf8')
    const m = src.match(new RegExp(String.raw`${name}[^=]*=\s*\[([\s\S]*?)\]`))
    if (!m) throw new Error(`${file} 里找不到 ${name} = [...]`)
    return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1])
}
function tsRegex(file, pattern) {
    const src = readFileSync(join(ROOT, file), 'utf8')
    return [...new Set([...src.matchAll(pattern)].flatMap((m) => m.slice(1).filter(Boolean)))]
}
const union = (...fns) => () => [...new Set(fns.flatMap((f) => f()))]
// 视图里 CASE ... END AS 别名 推导出来的枚举列:收该块里 THEN/ELSE 的字面量
function sqlCaseAs(file, alias) {
    const src = readFileSync(join(ROOT, file), 'utf8')
    const m = src.match(new RegExp(String.raw`CASE([\s\S]*?)END AS ${alias}`))
    if (!m) throw new Error(`${file} 里找不到 CASE ... END AS ${alias}`)
    return [...m[1].matchAll(/(?:THEN|ELSE)\s+'(\w+)'/g)].map((x) => x[1])
}
// leave_balance_internal 里 'status' 是 jsonb 键值:CASE 分支 + 直接字面量两种写法
function grantStatusValues() {
    const src = readFileSync(join(ROOT, 'db/functions/leave_balance_internal.sql'), 'utf8')
    const out = new Set()
    const caseBlock = src.match(/'status', CASE([\s\S]*?)END/)
    if (caseBlock) for (const m of caseBlock[1].matchAll(/(?:THEN|ELSE)\s+'(\w+)'/g)) out.add(m[1])
    for (const m of src.matchAll(/'status', '(\w+)'/g)) out.add(m[1])
    if (out.size === 0) throw new Error('leave_balance_internal.sql 里找不到 status 字面量')
    return [...out]
}

// 【清单】每一个动态前缀都必须在此归类:
//   { kind:'enum', values } —— 后缀可枚举,values() 现读真源;
//   { kind:'data', reason } —— 后缀是业务数据,静态不可知,点名放行(现状:无)。
// 清单外的动态前缀 = FAIL。
const MANIFEST = {
    // ── HR ──────────────────────────────────────────────────────────────────
    'hr.alertType.':        { kind: 'enum', values: () => sqlLiteralAs('db/views/hr_alerts.sql', 'alert_type') },
    'hr.severity.':         { kind: 'enum', values: union(
                                  () => sqlLiteralAs('db/views/hr_alerts.sql', 'severity'),
                                  () => tsRegex('db/views/hr_alerts.sql', /(?:THEN|ELSE) '(\w+)'::text$/gm)) },
    'hr.changeType.':       { kind: 'enum', values: () => sqlEnum('db/tables/employment_history.sql', 'change_type') },
    'hr.employmentType.':   { kind: 'enum', values: () => sqlEnum('db/tables/employees.sql', 'employment_type') },
    'hr.employmentStatus.': { kind: 'enum', values: () => sqlEnum('db/tables/employees.sql', 'employment_status') },
    'hr.workCategory.':     { kind: 'enum', values: () => sqlEnum('db/tables/employees.sql', 'work_category') },
    'hr.residency.':        { kind: 'enum', values: () => sqlEnum('db/tables/employees.sql', 'residency_status') },
    'hr.separationType.':   { kind: 'enum', values: () => sqlEnum('db/tables/employees.sql', 'separation_type') },
    'hr.trainingCategory.': { kind: 'enum', values: () => sqlEnum('db/tables/training_records.sql', 'category') },
    'hr.payrollStatus.':    { kind: 'enum', values: () => sqlEnum('db/tables/payroll_periods.sql', 'status') },
    'hr.errors.':           { kind: 'enum', values: () => tsSet('app/hr/hrErrorCodes.ts', 'HR_ERROR_CODES') },
    'leave.status_':        { kind: 'enum', values: () => sqlEnum('db/tables/leave_requests.sql', 'status') },
    'leave.finalState_':    { kind: 'enum', values: () => tsRegex('app/hr/leave/[id]/DecideControls.tsx',
                                  /status === '(\w+)' \|\| status === '(\w+)'/g) },
    'leave.grantType_':     { kind: 'enum', values: () => sqlEnum('db/tables/leave_grants.sql', 'grant_type') },
    'leave.grantStatus_':   { kind: 'enum', values: grantStatusValues }, // leave_balance_internal 的 jsonb 'status'
    'leave.entry_':         { kind: 'enum', values: () => sqlEnum('db/tables/leave_consumption.sql', 'entry_type') },
    // settlement_state = 索赔单自身状态直通(<> approved 时) ∪ 视图 CASE 推导值
    'claims.state_':        { kind: 'enum', values: union(
                                  () => sqlEnum('db/tables/medical_claims.sql', 'status'),
                                  () => sqlCaseAs('db/views/medical_claim_status.sql', 'settlement_state')) },
    'reviews.status_':      { kind: 'enum', values: () => sqlEnum('db/tables/performance_reviews.sql', 'status') },
    'reviews.type_':        { kind: 'enum', values: () => sqlEnum('db/tables/performance_reviews.sql', 'review_type') },
    'reviews.outcome_':     { kind: 'enum', values: () => sqlEnum('db/tables/performance_reviews.sql', 'probation_outcome') },
    'reviews.cycleStatus_': { kind: 'enum', values: () => sqlEnum('db/tables/review_cycles.sql', 'status') },
    'reviews.errors.':      { kind: 'enum', values: () => tsSet('app/hr/reviews/reviewErrorCodes.ts', 'REVIEW_ERROR_CODES') },
    // ── tasks ───────────────────────────────────────────────────────────────
    'tasks.status.':        { kind: 'enum', values: () => sqlEnum('db/tables/tasks.sql', 'status') },
    'tasks.priority.':      { kind: 'enum', values: () => sqlEnum('db/tables/tasks.sql', 'priority') },
    'tasks.type.':          { kind: 'enum', values: () => sqlEnum('db/tables/tasks.sql', 'task_type') },
    // ── suppliers / customers / materials ───────────────────────────────────
    'suppliers.status.':        { kind: 'enum', values: () => tsArray('app/suppliers/[id]/edit/statusMachine.ts', 'SUPPLIER_STATUSES') },
    'suppliers.statusAction.':  { kind: 'enum', values: () => tsArray('app/suppliers/[id]/edit/statusMachine.ts', 'SUPPLIER_STATUSES') },
    'suppliers.attachments.cat.': { kind: 'enum', values: () => tsArray('app/suppliers/[id]/edit/AttachmentsPanel.tsx', 'DOC_CATEGORIES') },
    'customers.attachments.cat.': { kind: 'enum', values: () => tsArray('app/customers/[id]/edit/AttachmentsPanel.tsx', 'DOC_CATEGORIES') },
    'materials.attachments.cat.': { kind: 'enum', values: () => tsArray('app/materials/[id]/edit/AttachmentsPanel.tsx', 'DOC_CATEGORIES') },
    // ── inventory / pricing / inbound / output / processing ─────────────────
    'movements.type.':      { kind: 'enum', values: () => sqlEnum('db/tables/inventory_movements.sql', 'movement_type') },
    'metals.':              { kind: 'enum', values: () => sqlEnum('db/tables/assay_result_metals.sql', 'metal') },
    'pricing.direction.':   { kind: 'enum', values: () => sqlEnum('db/tables/pricing_formulas.sql', 'direction') },
    'assay.pricingStatus.': { kind: 'enum', values: () => sqlEnum('db/tables/inbound_batches.sql', 'pricing_status') },
    'inbound.pricing.errors.': { kind: 'enum', values: () => tsSet('app/inbound/[id]/edit/pricingActions.ts', 'PRICING_ERROR_CODES') },
    'output.sale.errors.':  { kind: 'enum', values: () => tsSet('app/output/[id]/edit/saleErrorCodes.ts', 'SALE_ERROR_CODES') },
    'processing.allocation.basis.': { kind: 'enum', values: () => sqlEnum('db/tables/processing_runs.sql', 'allocation_basis') },
    // ── purchasing ──────────────────────────────────────────────────────────
    'purchasing.status.':   { kind: 'enum', values: () => sqlEnum('db/tables/purchase_orders.sql', 'status') },
    'purchasing.trigger.':  { kind: 'enum', values: () => sqlEnum('db/tables/payment_term_template_lines.sql', 'trigger_event') },
    // 同一前缀两处喂:purchasingErrorCodes 自家的族 + paymentErrorCodes 的采购侧码
    'purchasing.errors.':   { kind: 'enum', values: union(
                                  () => tsSet('app/purchasing/purchasingErrorCodes.ts', 'PURCHASING_ERROR_CODES'),
                                  () => tsSet('app/finance/paymentErrorCodes.ts', 'PURCHASING_SIDE_CODES')) },
    // ── finance / bank ──────────────────────────────────────────────────────
    'finance.errors.':      { kind: 'enum', values: union(
                                  () => tsSet('app/finance/financeErrorCodes.ts', 'FINANCE_ERROR_CODES'),
                                  () => tsSet('app/finance/paymentErrorCodes.ts', 'PAYMENT_ERROR_CODES')) },
    'bank.errors.':         { kind: 'enum', values: () => tsSet('app/finance/bankErrorCodes.ts', 'BANK_ERROR_CODES') },
    'invoice.errors.':      { kind: 'enum', values: () => tsSet('app/finance/invoiceErrorCodes.ts', 'INVOICE_ERROR_CODES') },
    'expense.errors.':      { kind: 'enum', values: () => tsSet('app/finance/expenseErrorCodes.ts', 'EXPENSE_ERROR_CODES') },
    'pricing.errors.':      { kind: 'enum', values: () => tsSet('app/pricing/pricingErrorCodes.ts', 'PRICING_ERROR_CODES') },
    'assay.errors.':        { kind: 'enum', values: () => tsSet('app/inbound/assayErrorCodes.ts', 'ASSAY_ERROR_CODES') },
    'stocktakes.errors.':   { kind: 'enum', values: () => tsSet('app/stocktakes/stocktakeErrorCodes.ts', 'STOCKTAKE_ERROR_CODES') },
    'processing.errors.':   { kind: 'enum', values: () => tsSet('app/processing/errorCodes.ts', 'PROCESSING_ERROR_CODES') },
    'finance.accountType.': { kind: 'enum', values: () => sqlEnum('db/tables/accounts.sql', 'account_type') },
    'finance.aging.':       { kind: 'enum', values: () => tsArray('app/finance/agingBuckets.ts', 'BUCKETS') },
    'finance.direction.':   { kind: 'enum', values: () => sqlEnum('db/tables/payments.sql', 'direction') },
    'finance.source.':      { kind: 'enum', values: () => sqlEnum('db/tables/journal_entries.sql', 'source_type') },
    'finance.status.':      { kind: 'enum', values: () => sqlEnum('db/tables/expenses.sql', 'status') }, // posted/reversed,与 payments/journal 同形
    'finance.bank.':        { kind: 'enum', values: () => sqlEnum('db/tables/bank_statements.sql', 'bank_account_code') },
    'finance.docKind.':     { kind: 'enum', values: union(
                                  () => sqlLiteralAs('db/views/ap_open_items.sql', 'doc_kind'),
                                  () => sqlLiteralAs('db/views/ar_open_items.sql', 'doc_kind')) },
    'finance.presets.':     { kind: 'enum', values: () => tsRegex('app/finance/pnl/page.tsx', /\{ key: '(\w+)'/g) },
    'finance.fxPage.rateType.': { kind: 'enum', values: () => sqlEnum('db/tables/fx_rates.sql', 'rate_type') },
    'expense.status.':      { kind: 'enum', values: () => sqlEnum('db/tables/expenses.sql', 'payment_status') },
    'invoice.paymentState.': { kind: 'enum', values: () => tsRegex('app/finance/invoices/[id]/page.tsx',
                                  /paymentState = [^\n]*?'(\w+)'[^\n]*?'(\w+)'[^\n]*?'(\w+)'/g) },
    'bank.status.':         { kind: 'enum', values: () => sqlEnum('db/tables/bank_statements.sql', 'status') },
    'bank.lineStatus.':     { kind: 'enum', values: () => sqlEnum('db/tables/bank_statement_lines.sql', 'match_status') },
    'bank.parseError.':     { kind: 'enum', values: () => tsRegex('lib/bankCsv.ts', /reason: '(\w+)'/g) },
    'finance.attachments.cat.': { kind: 'enum', values: () => tsArray('app/components/finance/financeAttachmentTypes.ts', 'FINANCE_DOC_TYPES') },
    'finAttach.docTypes.':  { kind: 'enum', values: () => tsArray('app/components/finance/financeAttachmentTypes.ts', 'FINANCE_DOC_TYPES') },
}

// ────────────────────────────────────────────────────────────── evaluate
const failures = []
const gaps = []

function missingFrom(key) {
    const miss = []
    if (!EN.has(key)) miss.push('en')
    if (!ZH.has(key)) miss.push('zh')
    return miss
}

// 1. 静态键 + 键样字面量(同一处只报一次)
const reported = new Set()
for (const u of [...staticUses, ...keyLiterals]) {
    const miss = missingFrom(u.key)
    const sig = `${u.file}:${u.line}:${u.key}`
    if (miss.length && !reported.has(sig)) {
        reported.add(sig)
        failures.push({ ...u, why: `缺于 ${miss.join(' 与 ')}` })
    }
}

// 2. 动态前缀:必须在清单里;可枚举的逐个查
const seenPrefixes = new Map()
for (const d of dynamicUses) if (!seenPrefixes.has(d.prefix)) seenPrefixes.set(d.prefix, d)
let enumChecked = 0
for (const [prefix, d] of seenPrefixes) {
    const entry = MANIFEST[prefix]
    if (!entry) {
        failures.push({ key: prefix + '…', file: d.file, line: d.line, why: '动态前缀不在清单(MANIFEST)里 —— 归类它:可枚举就接真源,不可知就点名' })
        continue
    }
    if (entry.kind === 'data') {
        gaps.push(`  ${prefix}*  —— ${entry.reason}  (${d.file}:${d.line})`)
        continue
    }
    let values
    try {
        values = entry.values()
    } catch (e) {
        failures.push({ key: prefix + '…', file: d.file, line: d.line, why: `真源解析失败:${e.message}` })
        continue
    }
    if (values.length === 0) {
        failures.push({ key: prefix + '…', file: d.file, line: d.line, why: '真源解析出 0 个后缀 —— 解析器坏了,不是没有值' })
        continue
    }
    for (const v of values) {
        enumChecked++
        const miss = missingFrom(prefix + v)
        if (miss.length) failures.push({ key: prefix + v, file: d.file, line: d.line, why: `缺于 ${miss.join(' 与 ')}(后缀自真源枚举)` })
    }
}

// 3. en/zh 结构差(satisfies 编译时也拦;这里一并报,免得只跑本检查时漏)
for (const k of EN.keys()) if (!ZH.has(k)) failures.push({ key: k, file: 'messages/zh.ts', line: 1, why: 'en 有、zh 没有' })
for (const k of ZH.keys()) if (!EN.has(k)) failures.push({ key: k, file: 'messages/en.ts', line: 1, why: 'zh 有、en 没有' })

// 4. 死键(报告,不 FAIL)
const usedStatic = new Set([...staticUses, ...keyLiterals].map((u) => u.key))
const deadKeys = []
for (const key of EN.keys()) {
    if (usedStatic.has(key)) continue
    if ([...seenPrefixes.keys()].some((p) => key.startsWith(p))) continue
    deadKeys.push(key)
}

// ────────────────────────────────────────────────────────────── report
console.log('== i18n 键体检 ==')
console.log('\n-- 扫到的调用形状(漏掉的形状是盲区,不是通过)--')
console.log(`   ${String(staticUses.length).padStart(4)}  t('key') 静态字符串`)
console.log(`   ${String(dynamicUses.length).padStart(4)}  t('prefix' + x) / t(\`prefix\${x}\`) 动态前缀(去重后 ${seenPrefixes.size} 个)`)
console.log(`   ${String(variableUses.length).padStart(4)}  t(变量) —— 经由键样字面量收网覆盖`)
console.log(`   ${String(keyLiterals.length).padStart(4)}  键样字面量(key:/labelKey:/titleKey= 属性、对象键、其余位置)`)
if (aliasNotes.length) for (const a of aliasNotes) console.log(`   ⚠ ${a}`)

const uncovered = [...seenPrefixes.keys()].filter((p) => !MANIFEST[p])
console.log(`\n-- 动态前缀 ${seenPrefixes.size} 个:可枚举 ${[...seenPrefixes.keys()].filter((p) => MANIFEST[p]?.kind === 'enum').length},点名不可知 ${gaps.length},未归类 ${uncovered.length};枚举出的键共查 ${enumChecked} 个 --`)
if (gaps.length) {
    console.log('\n-- 静态不可知、点名放行的(named gaps)--')
    for (const g of gaps) console.log(g)
}

if (deadKeys.length) {
    console.log(`\n-- 定义了但未见引用的键 ${deadKeys.length} 个(报告,不视为失败)--`)
    for (const k of deadKeys) console.log(`   ${k}`)
}

if (failures.length) {
    console.log(`\n✗ 失败 ${failures.length} 处:\n`)
    for (const f of failures) console.log(`   ${f.file}:${f.line}  ${f.key}  —— ${f.why}`)
    console.log('\ni18n 键体检不通过。')
    process.exit(1)
} else {
    console.log('\n✓ 代码引用的每一个键(含可枚举的动态键)en 与 zh 都在。')
}
