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
//   FAIL:文案里有占位符、调用点没传(静态可判定的那些)—— 解析器对认不出的
//         占位符原样保留,于是屏幕上印出「1,234.00 {ccy}。」。同一个病的第二种
//         形态:一串机器字走到人面前(ASY-3 在财务成本结算面板上撞见)。
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

// t('key', { … }) 的第二个实参:从 key 之后开始,按花括号配对切出对象字面量源码。
// 没有第二个实参返回 null(与"传了但缺某个键"是两种不同的失败)。
// 三种结果,必须分开 —— 把第三种当成第一种就会误报(BulkPricesForm 传的是
// state.result 这样一个变量,实参齐不齐【静态判不出来】):
//   null       第二个实参根本没有
//   'dynamic'  有第二个实参,但不是对象字面量 → 判不了,不算失败(同 MANIFEST 的 'data')
//   其它字符串 对象字面量的源码
function argsAt(src, from) {
    let i = from
    while (i < src.length && /\s/.test(src[i])) i++
    if (src[i] !== ',') return null
    i++
    while (i < src.length && /\s/.test(src[i])) i++
    if (src[i] !== '{') return 'dynamic'
    let depth = 0
    for (let j = i; j < src.length; j++) {
        if (src[j] === '{') depth++
        else if (src[j] === '}') {
            depth--
            if (depth === 0) return src.slice(i + 1, j)
        }
    }
    return 'dynamic'
}

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
                // 第二个参数(插值实参)照原样带上 —— 占位符体检要用(见文件头 FAIL 第四条)。
                // 【从源码里按花括号配对取,不截窗口】:第一版用 rest(200 字符)去
                // 匹配 /,\s*\{([^}]*)\}/,遇到跨行的实参对象就截断成"一个实参都没传",
                // 于是 StatusPanel 那个传齐了三个的调用被误报。误报比漏报更坏 ——
                // 它教人忽略这条检查。
                staticUses.push({ key: mm[1], file: rel, line, args: argsAt(src, at + mm[0].length) })
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
// PROC-4:字典型清单的真源【不再是 CHECK】,是那张字典的引导 INSERT。
// sqlEnum 读的是 `CHECK (col IN (...))`;而 substances 落地之后那八条 CHECK 没了,
// 它会抛"找不到 CHECK" —— **那次失败是这套机制在正常工作**(解析不出来 ≠ 空集合),
// 但判据得跟着真源走。这一支读 `INSERT INTO public.<table> (code, ...) VALUES` 里
// 每一行的第一个字面量,也就是 code。
// 【为什么仍然要求 metals.<code> 有翻译】名字留在 i18n 里,而这条判据保证
// "加了一行字典却没配名字"会在 npm run build 当场被点名 —— 一份【被检查的】镜像,
// 与 lib/database.types.ts 之于 schema 是同一个形状。
function sqlSeedCodes(file, table) {
    const src = readFileSync(join(ROOT, file), 'utf8')
    const m = src.match(new RegExp(String.raw`INSERT INTO public\.${table}[^;]*?VALUES([\s\S]*?);`, 'm'))
    if (!m) throw new Error(`${file} 里找不到 INSERT INTO public.${table} ... VALUES`)
    const codes = [...m[1].matchAll(/\(\s*'([^']+)'/g)].map((x) => x[1])
    if (codes.length === 0) throw new Error(`${file} 的引导 INSERT 解析出 0 个 code —— 解析不出来不是空集合`)
    return codes
}
// PROC-6:sqlEnum 要求 `CHECK (col IN (...))` 紧挨着写。而 weight_basis 那条是
// `CHECK (weight_basis IS NULL OR weight_basis IN (...))` —— 因为"没记过"要合法。
// 这一支在整份文件里找 `col IN ('a','b')`,两种写法都认。
// 解析出 0 个仍然抛错(解析不出来【不是】空集合)。
function sqlEnumAnywhere(file, col) {
    const src = readFileSync(join(ROOT, file), 'utf8')
    const m = src.match(new RegExp(String.raw`\b${col} IN\s*\(([^)]+)\)`))
    if (!m) throw new Error(`${file} 里找不到 ${col} IN (...)`)
    const vals = [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1])
    if (vals.length === 0) throw new Error(`${file} 的 ${col} IN (...) 解析出 0 个取值`)
    return vals
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
// 表镜像里 CHECK (col IN ('a','b',...)) 推导出来的枚举列。
// 【找不到就抛,不返回空集】—— 与 sqlCaseAs 同一条:一个 0 必须是一次测量,不是一次缺席。
function sqlCheckIn(file, column) {
    const src = readFileSync(join(ROOT, file), 'utf8')
    const m = src.match(new RegExp(String.raw`CHECK \(${column} IN\s*\(([\s\S]*?)\)\)`))
    if (!m) throw new Error(`${file} 里找不到 CHECK (${column} IN (...))`)
    return [...m[1].matchAll(/'(\w+)'/g)].map((x) => x[1])
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
    // ── 财务 ────────────────────────────────────────────────────────────────
    // FIN-30:现金流量表的活动类别。后缀集合【就是】cash_flow_statement 里那个
    // CASE 的分支(investing/financing 来自 accounts.cash_flow_section 的 CHECK,
    // operating 是残差,unclassified/fx_effect 是函数自己定义的两类)——
    // 从函数镜像现读,加一个分支这道检查自动跟着变宽。
    'finance.cashflowSectionName.':
                            { kind: 'enum', values: () => tsRegex('db/functions/cash_flow_statement.sql',
                                  /(?:THEN|ELSE) '(\w+)'/g) },
    // EQP-1c-b:一张采购单是材料单还是设备单。后缀集合【就是】下单表单里那个
    // ORDER_KINDS 数组 —— 从组件现读,将来多一种就自动变宽。
    'purchasing.form.kind.': { kind: 'enum', values: () => tsRegex(
                                  'app/purchasing/orders/new/NewOrderForm.tsx',
                                  /const ORDER_KINDS = \['(\w+)', '(\w+)'\] as const/g) },
    // EQP-1c-c:资本支出的两扇门(新建一台机器 / 给已登记的机器加成本)。
    // 后缀集合【就是】开支表单里那个 CAPITAL_MODES 数组 —— 从组件现读。
    'expense.form.capitalMode.': { kind: 'enum', values: () => tsRegex(
                                  'app/finance/expenses/new/NewExpenseForm.tsx',
                                  /const CAPITAL_MODES = \['(\w+)', '(\w+)'\] as const/g) },
    'expense.form.capitalModeHint.': { kind: 'enum', values: () => tsRegex(
                                  'app/finance/expenses/new/NewExpenseForm.tsx',
                                  /const CAPITAL_MODES = \['(\w+)', '(\w+)'\] as const/g) },
    // GST-2:F5 钻回去的那一行是【什么单据】。后缀集合【就是】f5_box_detail
    // 里那三个字面量('invoice' / 'credit_note' / 'journal_entry')——
    // 从函数镜像现读,将来销项侧多接一种单据族,这道检查自动要求两个语言补句子。
    // 【为什么是这个真源而不是一份写死的清单】那三个字符串是函数【返回给屏幕】的
    // 值本身;写死一份清单,加一种单据时它只会烂在这里,而屏幕上会印出一个
    // 原始的机器串 —— docs/machine-text-reaching-humans.md 记的正是这一类。
    'gst.docKind.': { kind: 'enum', values: () => tsRegex('db/functions/f5_box_detail.sql',
                                  /SELECT '(\w+)'::text/g) },
    // AGING-1:账龄的【金额口径】。后缀集合就是 app/finance/agingAsOf.ts 里那个
    // AMOUNT_BASES 数组 —— TypeScript 的类型也从同一行派生,所以类型与这道检查
    // 读的是同一处;而【库那侧真的吐哪两个令牌】由 db/fixtures/135 钉住,
    // 三者合起来才关得住:改了令牌名,构建或闸会红,而不是屏幕上冒出一个机器串。
    'finance.agingAsOf.basis.': { kind: 'enum', values: () => tsRegex(
                                  'app/finance/agingAsOf.ts',
                                  /const AMOUNT_BASES = \['(\w+)', '(\w+)'\] as const/g) },
    // ── 看板 ─────────────────────────────────────────────────────────────────
    // OPS-18:后缀集合就是 operations_now 的支列表 —— 从视图镜像现读,加一支自动变宽。
    // (镜像里每一支都显式写了 AS item_type;pg_get_viewdef 只保留【显式】别名,
    // 漏写别名的支会被 normalize 成 AS text,从这里【静默消失】。全部漏写才会
    // 触发下面的 0 后缀 FAIL —— 漏写【一支】只会让那一支的键失守,所以新支必须
    // 带显式别名,这句话就是写给加支的人看的。)
    'dashboard.item.':      { kind: 'enum', values: () => sqlLiteralAs('db/views/operations_now.sql', 'item_type') },
    // CHASE-1:四个前缀,四个真源都在库那一侧 —— 加一种联系方式/结局/单据种类,
    // 键检查【自动跟着变宽】,而不是等着谁记得来补一行。
    'chases.errors.':       { kind: 'enum', values: () => tsSet('app/finance/collections/chaseErrorCodes.ts', 'CHASE_ERROR_CODES') },
    'chases.channel_':      { kind: 'enum', values: () => sqlCheckIn('db/tables/collection_chases.sql', 'channel') },
    'chases.outcome_':      { kind: 'enum', values: () => sqlCheckIn('db/tables/collection_promises.sql', 'outcome') },
    'chases.subject_':      { kind: 'enum', values: () => sqlCheckIn('db/tables/collection_chase_documents.sql', 'subject_type') },
    // CASHFLOW-1:四个前缀,四个真源都在库那一侧 —— 加一种频率/来源/理由,
    // 键检查【自动跟着变宽】,而不是等着谁记得来补一行。
    'cashForecast.errors.':  { kind: 'enum', values: () => tsSet('app/finance/cashForecastErrorCodes.ts', 'CASH_FORECAST_ERROR_CODES') },
    // CLAIM-1:两个前缀,两个真源都在别处 —— 加一个状态或一个错误码,
    // 键检查【自动跟着变宽】。★ 注意前缀是 expenseClaims.*,不是 claims.* ——
    // 后者是【医疗报销】已经占着的命名空间,而两块面板并排出现在 /me 上。
    'expenseClaims.errors.': { kind: 'enum', values: () => tsSet('app/finance/claims/claimErrorCodes.ts', 'EXPENSE_CLAIM_ERROR_CODES') },
    'expenseClaims.status_': { kind: 'enum', values: () => sqlCheckIn('db/tables/expense_claims.sql', 'status') },
    'cashForecast.cadence_': { kind: 'enum', values: () => sqlCheckIn('db/tables/cash_forecast_lines.sql', 'cadence') },
    'cashForecast.undated_': { kind: 'enum', values: () => tsRegex('db/functions/cash_forecast_data.sql',
                                   /'(no_date|before_window)'/g) },
    'cashForecast.conf_':    { kind: 'enum', values: () => tsRegex('db/functions/cash_forecast_data.sql',
                                   /'(committed|estimated|manual)'::text/g) },
    'cashForecast.source_':  { kind: 'enum', values: () => tsRegex('db/functions/cash_forecast_data.sql',
                                   /'(ar|ap|po_instalment|payroll|manual)'(?:::text)?(?: AS source)?,/g) },
    // OPS-20:批次毛利算不出来时的两种原因 + ok。后缀集合就是 batch_margin 里那个
    // CASE 的分支 —— 从视图镜像现读,加一种原因这道检查自动跟着变宽。
    'margin.status.':       { kind: 'enum', values: () => tsRegex('db/views/batch_margin.sql',
                                  /(?:THEN|ELSE) '(\w+)'::text\s*$/gm) },
    'margin.statusHint.':   { kind: 'enum', values: () => tsRegex('db/views/batch_margin.sql',
                                  /(?:THEN|ELSE) '(\w+)'::text\s*$/gm) },
    // REC-1:回收率算不出来的原因。后缀集合就是 processing_metal_recovery 里那个
    // CASE 的分支(input_not_measured / output_not_measured / input_measured_zero)——
    // 从视图镜像现读,加一种原因这道检查自动跟着变宽。写死清单只会烂在这里。
    // AUD-1(2026-08-17):真源换了文件 —— recovery_blocked_by 那个 CASE 随推导搬进了
    // 【基视图】processing_metal_recovery_all(判据挪到外层那一刀)。对外那一张
    // 现在只是一层 SELECT,里面一个字面量都没有,于是这个解析器解出 0 个后缀。
    // **而它报的是"解析器坏了",不是"没有值"** —— 那条规矩当场救了这一处:
    // 若把 0 读成空集,这一族的键从此无人看管。改的是指向,不是判据。
    'processing.recovery.blocked.': { kind: 'enum', values: () => tsRegex('db/views/processing_metal_recovery_all.sql',
                                  /THEN '(\w+)'::text/g) },
    // AUDEL-3:已删除记录的种类。真源是【视图自己那几个字面量】——
    // deleted_records 的每一支都写着 'inbound_batch'::text 之类,加一支就自动被查到。
    // 【判据是每一支 UNION 的第一列】pg_get_viewdef 只给第一支写 `AS record_kind`,
    // 其余几支归一化成 `AS text` —— 两种写法都收,加一支就自动被查到。
    'deleted.kind.': { kind: 'enum', values: () => tsRegex('db/views/deleted_records.sql',
                                  /SELECT '(\w+)'::text AS (?:record_kind|text)/g) },
    // AUDEL-1b:删除那一族的具名拒绝。接真源那个 Set —— 加一个码,检查自动跟上。
    'deletion.errors.': { kind: 'enum', values: () => tsSet('app/components/inventory/deletionErrorCodes.ts', 'DELETION_ERROR_CODES') },
    'tasks.opErrors.':      { kind: 'enum', values: () => tsSet('app/tasks/taskErrorCodes.ts', 'TASK_ERROR_CODES') },
    // LOG-1c:物流的具名拒绝。真源是那个 Set —— 与 tasks.opErrors 同一种接法。
    'logistics.opErrors.': { kind: 'enum', values: () => tsSet('app/logistics/logisticsErrorCodes.ts', 'LOGISTICS_ERROR_CODES') },
    // EQP-2d:设备三张表的拒绝。**真源是那个 Set,而它装的多半是【约束名】** ——
    // equipment_maintenance / equipment_downtime / equipment_service_intervals
    // 没有任何 RPC,拒绝到达浏览器时是 Postgres 的约束违反,不是 `CODE|args`。
    // 加一条 CHECK 就要来那个 Set 里加一个名字,于是这道检查立刻要求两个语言
    // 都补上句子 —— 与 logistics.milestoneLabel 接表上那条 CHECK 是同一种接法。
    'equipment.errors.': { kind: 'enum', values: () => tsSet('app/finance/assets/equipmentErrorCodes.ts', 'EQUIPMENT_ERROR_CODES') },
    // IMPORT-1:加一条导入拒绝而不配句子,这里当场红。
    'import.errors.': { kind: 'enum', values: () => tsSet('app/settings/import/importErrorCodes.ts', 'IMPORT_ERROR_CODES') },
    'import.table.':  { kind: 'enum', values: () => tsArray('lib/importTables.ts', 'IMPORT_TABLES') },
    // EQP-2d:活的种类。**真源是 equipment_maintenance 表上那条 CHECK** ——
    // 往库里加一种活(EQP-2c 的 known-issue 里那条 service_type 就会),
    // 这道检查立刻要求两个语言都补上标签。写死一份清单只会烂在这里。
    'equipment.kind.': { kind: 'enum', values: () => sqlCheckIn('db/tables/equipment_maintenance.sql', 'kind') },
    // PROC-2b:物料与进料状态轴的拒绝。**真源是那个 Set,而它同时装着具名码与
    // 【约束名】** —— PROC-1/PROC-2 的守卫抛具名码,而五条轴的外键与那条多值主键
    // 直接抛约束名。加一条守卫或一条约束就来那个 Set 里加一个名字,
    // 于是这道检查立刻要求两个语言都补上句子。
    'materials.errors.': { kind: 'enum', values: () => tsSet('app/materials/materialErrorCodes.ts', 'MATERIAL_ERROR_CODES') },
    // LOG-2b:集装箱里程碑。**真源是表上那条 CHECK**(db/tables/container_milestones.sql)——
    // 往库里加一个里程碑,这道检查立刻要求两个语言都补上标签,于是页面那份清单
    // 也不会被悄悄落下。写死一份清单只会烂在这里。
    'logistics.milestoneLabel.': { kind: 'enum', values: () => sqlCheckIn('db/tables/container_milestones.sql', 'milestone') },
    // LME-1b:行情出处。真源是 metal_prices 那条 CHECK —— 加一种出处要改 CHECK
    // (一支迁移),这个检查因此自动跟上。**四个值都要有文案,包括 unknown**:
    // 它不在录入下拉里,但十条老行情在列表上就读它。
    'metalPrices.source.': { kind: 'enum', values: () => sqlEnum('db/tables/metal_prices.sql', 'source') },
    // PAYEE-1b:应付往来对象的种类(供应商 / 员工)。真源是 ap_open_items
    // 那个 CASE 里的两个字面量 —— 库里加第三种往来对象,这里自动跟上。
    // 【为什么不接 payments_counterparty_type_check 的三个值】那一条含 'customer',
    // 而这个前缀只用在【应付】那一侧(账龄分组、看板逾期),客户不会出现在那里。
    'finance.counterpartyKind.': { kind: 'enum', values: () => tsRegex('db/views/ap_open_items.sql',
                                  /THEN '(\w+)'::text\s*\n\s*ELSE '(\w+)'::text\s*\n\s*END AS counterparty_kind/g) },
    // GRN-1b:收货差异的种类。真源是【视图自己拼 kinds 的那几个字面量】——
    // grn_discrepancies 每一支写着 ARRAY['short'::text] 之类,加一种就自动被查到。
    // 【接视图而不是接一份 TS 常量】是因为判断"是哪一种"从头到尾只发生在视图里:
    // 应用层一个字都没重复它,所以也没有第二份可接 —— 那正是这一刀想要的样子。
    'grn.kind.': { kind: 'enum', values: () => tsRegex('db/views/grn_discrepancies.sql',
                                  /ARRAY\['(\w+)'::text\]/g) },
    // ── AUD-2:客户审计报告 ──────────────────────────────────────────────
    // 【回收率算不出的原因】与 processing.recovery.blocked. 同一个真源
    // (基视图里的那个 CASE),外加一个【本地兜底键】unspecified:
    // 视图只产出三种原因,但屏幕与 PDF 共用的 recoveryText 还有一条"认不出的
    // 第四种"的分支 —— 它宁可说"算不出",也不编一个数。那条分支要有键可用,
    // 所以并进来;而三种真原因仍然【现读真源】,视图加一种,检查自动跟上。
    'traceability.blocked.': { kind: 'enum', values: union(
                                  () => tsRegex('db/views/processing_metal_recovery_all.sql', /THEN '(\w+)'::text/g),
                                  () => ['unspecified']) },
    // 具名拒绝:接那个 Set 的真源。
    'traceability.errors.': { kind: 'enum', values: () => tsSet('app/output/traceabilityErrorCodes.ts', 'TRACEABILITY_ERROR_CODES') },
    // APR-2c:采购单审批状态。后缀集合就是 purchase_orders 的 CHECK —— 真源现读。
    'purchasing.approvalState.': { kind: 'enum', values: () => sqlEnum('db/tables/purchase_orders.sql', 'approval_status') },
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
    // ATTEND-1:考勤期间状态。真源是 attendance_periods 的 CHECK,不是这里抄一份。
    'attendance.status.':   { kind: 'enum', values: () => sqlCheckIn('db/tables/attendance_periods.sql', 'status') },
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
    'tasks.history.type.':  { kind: 'enum', values: () => sqlEnum('db/tables/task_history.sql', 'change_type') },
    // ── suppliers / customers / materials ───────────────────────────────────
    'suppliers.status.':        { kind: 'enum', values: () => tsArray('app/suppliers/[id]/edit/statusMachine.ts', 'SUPPLIER_STATUSES') },
    'suppliers.statusAction.':  { kind: 'enum', values: () => tsArray('app/suppliers/[id]/edit/statusMachine.ts', 'SUPPLIER_STATUSES') },
    'suppliers.attachments.cat.': { kind: 'enum', values: () => tsArray('app/suppliers/[id]/edit/AttachmentsPanel.tsx', 'DOC_CATEGORIES') },
    'customers.attachments.cat.': { kind: 'enum', values: () => tsArray('app/customers/[id]/edit/AttachmentsPanel.tsx', 'DOC_CATEGORIES') },
    'materials.attachments.cat.': { kind: 'enum', values: () => tsArray('app/materials/[id]/edit/AttachmentsPanel.tsx', 'DOC_CATEGORIES') },
    // ── inventory / pricing / inbound / output / processing ─────────────────
    'movements.type.':      { kind: 'enum', values: () => sqlEnum('db/tables/inventory_movements.sql', 'movement_type') },
    // SO-2:流水的【桶】。与 movements.type. 同一张表、同一种读法 —— 往
    // stock_status 的 CHECK 里加一个值,这条检查自动跟着变宽(第四个桶落地
    // 那天,漏了译文会当场红,而不是在屏幕上印出 movements.bucket.xxx)。
    'movements.bucket.':    { kind: 'enum', values: () => sqlEnum('db/tables/inventory_movements.sql', 'stock_status') },
    'metals.':              { kind: 'enum', values: () => sqlSeedCodes('db/tables/substances.sql', 'substances') },
    'assay.basis_':         { kind: 'enum', values: () => sqlEnumAnywhere('db/tables/assay_results.sql', 'weight_basis') },
    'assay.party_':         { kind: 'enum', values: () => sqlEnumAnywhere('db/tables/assay_results.sql', 'result_party') },
    'pricing.direction.':   { kind: 'enum', values: () => sqlEnum('db/tables/pricing_formulas.sql', 'direction') },
    'assay.pricingStatus.': { kind: 'enum', values: () => sqlEnum('db/tables/inbound_batches.sql', 'pricing_status') },
    'inbound.pricing.errors.': { kind: 'enum', values: () => tsSet('app/inbound/[id]/edit/pricingActions.ts', 'PRICING_ERROR_CODES') },
    'output.sale.errors.':  { kind: 'enum', values: () => tsSet('app/output/[id]/edit/saleErrorCodes.ts', 'SALE_ERROR_CODES') },
    // ASY-P2:化验要求写入口的具名拒绝。接真源 —— 往那个 Set 里加一个码,
    // 检查自动跟上,不需要有人记得回来改这一行。
    'materials.assayPolicy.errors.': { kind: 'enum', values: () => tsSet('app/materials/materialPolicyErrorCodes.ts', 'MATERIAL_POLICY_ERROR_CODES') },
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
    // FX-RATES-1:牌价写入口抛的码。真源是那份 Set —— 加一条码,检查自动跟着变宽。
    'finance.fxPage.errors.': { kind: 'enum', values: () => tsSet('app/finance/fxErrorCodes.ts', 'FX_ERROR_CODES') },
    'invoice.errors.':      { kind: 'enum', values: () => tsSet('app/finance/invoiceErrorCodes.ts', 'INVOICE_ERROR_CODES') },
    'expense.errors.':      { kind: 'enum', values: () => tsSet('app/finance/expenseErrorCodes.ts', 'EXPENSE_ERROR_CODES') },
    'pricing.errors.':      { kind: 'enum', values: () => tsSet('app/pricing/pricingErrorCodes.ts', 'PRICING_ERROR_CODES') },
    'assay.errors.':        { kind: 'enum', values: () => tsSet('app/inbound/assayErrorCodes.ts', 'ASSAY_ERROR_CODES') },
    'stocktakes.errors.':   { kind: 'enum', values: () => tsSet('app/stocktakes/stocktakeErrorCodes.ts', 'STOCKTAKE_ERROR_CODES') },
    'locations.errors.':    { kind: 'enum', values: () => tsSet('app/inventory/locations/locationErrorCodes.ts', 'LOCATION_ERROR_CODES') },
    'stock.errors.':        { kind: 'enum', values: () => tsSet('app/components/inventory/stockErrorCodes.ts', 'STOCK_ERROR_CODES') },
    // IOD-2:告警走的是【返回值】那条通道,集合与拒绝分开(见那个文件的抬头)。
    // 分开登记而不是并进上一行 —— 两个集合本来就不该混,合并会让"把告警当拒绝"
    // 这件事重新变得写得出来。
    'stock.warnings.':      { kind: 'enum', values: () => tsSet('app/components/inventory/stockErrorCodes.ts', 'STOCK_WARNING_CODES') },
    // NTF-1:事件类型的集合就是 notifications 表上的 CHECK —— 加一种事件,
    // 键检查自动跟着变宽,两个 locale 因此是【必须】而不是可选。
    'notifications.event.': { kind: 'enum', values: () => sqlEnum('db/tables/notifications.sql', 'event_type') },
    'sales.errors.':        { kind: 'enum', values: () => tsSet('app/sales/orders/salesOrderErrorCodes.ts', 'SALES_ORDER_ERROR_CODES') },
    // SO-1b:订单留痕的改动类型 —— 后缀集合就是 sales_order_history 的 CHECK,
    // 真源现读。加一种改动,这条检查自动跟着变宽(而漏了译文会当场红,
    // 不是在屏幕上印出 sales.changeType.header_update)。
    'sales.changeType.':    { kind: 'enum', values: () => sqlEnum('db/tables/sales_order_history.sql', 'change_type') },
    // SO-4b:报价。状态与留痕类型接真源的 CHECK,错误码接那个 Set ——
    // 加一种状态 / 一个错误码,这条检查自动跟着变宽。
    'quotes.changeType.':   { kind: 'enum', values: () => sqlEnum('db/tables/quote_history.sql', 'change_type') },
    'quotes.errors.':       { kind: 'enum', values: () => tsSet('app/sales/quotes/quoteErrorCodes.ts', 'QUOTE_ERROR_CODES') },
    // CN-1:贷项凭证。行的类型接 credit_note_lines 的 CHECK(加一种冲减类型,
    // 这条检查自动跟着变宽);错误码接那个 Set —— 与 sales.errors. 同一种读法。
    'cn.kind.':             { kind: 'enum', values: () => sqlEnum('db/tables/credit_note_lines.sql', 'kind') },
    'cn.errors.':           { kind: 'enum', values: () => tsSet('app/finance/creditNoteErrorCodes.ts', 'CREDIT_NOTE_ERROR_CODES') },
    // STATEMENT-1:对账单一族的错误码,真源是那支 Set(逐条从函数体枚举出来的)。
    'statements.errors.':   { kind: 'enum', values: () => tsSet('app/finance/statements/statementErrorCodes.ts', 'STATEMENT_ERROR_CODES') },
    'processing.errors.':   { kind: 'enum', values: () => tsSet('app/processing/errorCodes.ts', 'PROCESSING_ERROR_CODES') },
    // WO-1c:工单。状态与留痕类型都接真源的 CHECK —— 数据库里加一个状态 /
    // 一种改动类型,这条检查自动跟着变宽,而不是等屏幕上出现一个键名才有人发现。
    'processing.wo.status.':     { kind: 'enum', values: () => sqlEnum('db/tables/work_orders.sql', 'status') },
    'processing.wo.changeType.': { kind: 'enum', values: () => sqlEnum('db/tables/work_order_history.sql', 'change_type') },
    'finance.accountType.': { kind: 'enum', values: () => sqlEnum('db/tables/accounts.sql', 'account_type') },
    'finance.aging.':       { kind: 'enum', values: () => tsArray('app/finance/agingBuckets.ts', 'BUCKETS') },
    'finance.direction.':   { kind: 'enum', values: () => sqlEnum('db/tables/payments.sql', 'direction') },
    'finance.source.':      { kind: 'enum', values: () => sqlEnum('db/tables/journal_entries.sql', 'source_type') },
    'assets.category.':     { kind: 'enum', values: () => sqlEnum('db/tables/fixed_assets.sql', 'category') },
    'processing.lineage.kind_': { kind: 'enum', values: () => ['inbound', 'output'] },
    'assets.status.':       { kind: 'enum', values: () => sqlEnum('db/tables/fixed_assets.sql', 'status') },
    'finance.status.':      { kind: 'enum', values: () => sqlEnum('db/tables/expenses.sql', 'status') }, // posted/reversed,与 payments/journal 同形
    'finance.bank.':        { kind: 'enum', values: () => sqlEnum('db/tables/bank_statements.sql', 'bank_account_code') },
    'finance.docKind.':     { kind: 'enum', values: union(
                                  () => sqlLiteralAs('db/views/ap_open_items.sql', 'doc_kind'),
                                  () => sqlLiteralAs('db/views/ar_open_items.sql', 'doc_kind')) },
    // FRT-1:运费。三者都接真源 —— 口径与付款状态接表上的 CHECK,错误码接那个 Set,
    // 于是加一种口径 / 加一个错误码,键检查自动跟着变宽。
    // PUR-2:改动类型接表上的 CHECK —— 加一种改动,键检查自动跟着变宽。
    'purchasing.amend.change.': { kind: 'enum', values: () => sqlEnum('db/tables/purchase_order_history.sql', 'change_type') },
    'finance.freight.basis.':   { kind: 'enum', values: () => sqlEnum('db/tables/freight_documents.sql', 'allocation_basis') },
    'finance.freight.payment.': { kind: 'enum', values: () => sqlEnum('db/tables/freight_documents.sql', 'payment_status') },
    // LOG-4b:两个前缀,同一条 CHECK —— 往库里加第三个方向,两个语言会同时被要求补标签。
    'finance.freight.direction.': { kind: 'enum', values: () => sqlEnum('db/tables/freight_documents.sql', 'direction') },
    'finance.freight.directionShort.': { kind: 'enum', values: () => sqlEnum('db/tables/freight_documents.sql', 'direction') },
    'finance.freight.errors.':  { kind: 'enum', values: () => tsSet('app/finance/freightErrorCodes.ts', 'FREIGHT_ERROR_CODES') },
    'finance.presets.':     { kind: 'enum', values: () => tsRegex('app/finance/pnl/page.tsx', /\{ key: '(\w+)'/g) },
    'finance.fxPage.rateType.': { kind: 'enum', values: () => sqlEnum('db/tables/fx_rates.sql', 'rate_type') },
    'processing.costTypes.': { kind: 'enum', values: () => sqlEnum('db/tables/processing_cost_entries.sql', 'cost_type') },
    'finance.monthEnd.step_': { kind: 'enum', values: () => tsRegex('app/finance/month-end/page.tsx', /key: '(\w+)', href/g) },
    'finance.yearClose.check_': { kind: 'enum', values: () => tsRegex('app/finance/close/page.tsx', /\{ key: '(\w+)', ok:/g) },
    'finance.monthEnd.state_': { kind: 'enum', values: () => ['done', 'outstanding', 'blocked', 'na'] },
    'expense.status.':      { kind: 'enum', values: () => sqlEnum('db/tables/expenses.sql', 'payment_status') },
    'invoice.paymentState.': { kind: 'enum', values: () => tsRegex('app/finance/invoices/[id]/page.tsx',
                                  /paymentState = [^\n]*?'(\w+)'[^\n]*?'(\w+)'[^\n]*?'(\w+)'/g) },
    'bank.status.':         { kind: 'enum', values: () => sqlEnum('db/tables/bank_statements.sql', 'status') },
    'bank.lineStatus.':     { kind: 'enum', values: () => sqlEnum('db/tables/bank_statement_lines.sql', 'match_status') },
    // BANK-REC:差额说明的类型。真源是表上那条 CHECK —— 加一个种类,
    // 检查的射程自动跟着变宽,不需要同时改这里。
    'bank.varianceKind.':   { kind: 'enum', values: () => sqlEnum('db/tables/bank_reconciliation_variance_items.sql', 'item_kind') },
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

// 1. 静态键 + 键样字面量(同一处只报一次)。
// 下划线结尾的动态前缀('finance.monthEnd.step_')长得像完整键,会被字面量收网
// 误捕 —— 是前缀就交给清单那条路,不按静态键报缺。
const prefixSet = new Set([...dynamicUses.map((d) => d.prefix), ...Object.keys(MANIFEST)])
const reported = new Set()
for (const u of [...staticUses, ...keyLiterals]) {
    if (prefixSet.has(u.key)) continue
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
// ── 占位符体检(CCY-1)────────────────────────────────────────────────────────
// 文案里写了 {ccy},调用点没传 —— 解析器【对认不出的占位符原样保留】(见
// lib/i18n/client.tsx 的 replace 回调),于是屏幕上真的印着「1,234.00 {ccy}。」。
// 与"键不存在就原样印键名"是同一个病的第二种形态:一串机器字走到人面前,
// 而在 ASY-3 之前没有任何检查看得见它 —— 财务成本结算面板就那样印了不知多久。
// 这里只判【静态可判定】的调用:键是字面量、实参是对象字面量。判不了的不算失败。
for (const u of [...staticUses]) {
    const text = EN.get(u.key) ?? ZH.get(u.key)
    if (typeof text !== 'string') continue
    const need = [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1])
    if (!need.length) continue
    if (u.args === 'dynamic') continue   // 实参是变量/展开:静态判不了,不算失败
    if (u.args === null || u.args === undefined) {
        failures.push({ key: u.key, file: u.file, line: u.line,
            why: `文案要 {${need.join('} {')}},调用点一个实参都没传 —— 屏幕上会原样印出占位符` })
        continue
    }
    const passed = new Set([...u.args.matchAll(/(?:^|[,\s])(\w+)\s*(?::|,|$)/g)].map((m) => m[1]))
    const missing = need.filter((n) => !passed.has(n))
    if (missing.length) {
        failures.push({ key: u.key, file: u.file, line: u.line,
            why: `文案要 {${need.join('} {')}},调用点没传 {${missing.join('} {')}} —— 屏幕上会原样印出它` })
    }
}

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
