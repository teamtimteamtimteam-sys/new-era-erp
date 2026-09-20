#!/usr/bin/env node
// scripts/check-date-data-paths.mjs
// ════════════════════════════════════════════════════════════════════════════
// DATE-1(2026-09-20)· 四条【把日期当数据读回去】的路,各一条断言
// ════════════════════════════════════════════════════════════════════════════
// 【为什么这支闸存在 —— 这是 DATE-1 里风险最大的一件事】
// DATE-0 §5.2 点名了四条路:一个日期在那里**不是显示,是数据**。
// ★★ **其中三条的失败是【安静的】** —— 它们不报错,只是给出一个算得出来的错答案:
//
//   ① `<input type="date">` 的 value / min / max
//      HTML 规范【要求】 `YYYY-MM-DD`。**不合法的值当空值处理,不抛错** ——
//      控件就那么空着。一个人打开编辑页,看见日期栏是空的,以为这张单没有日期。
//
//   ② ★★★ **URL 上的日期过滤** —— 四条里最坏的一条。
//      `lib/dateFilter.ts` 的 `isYmd()` 不认就返回 `''`,而 `''` 的意思是
//      **「不过滤」**。☞ 于是**列表悄悄给出【全部行】**。
//      **一个算得出来的错答案**,而本仓库为这个形状反复付过账
//      (`mustRows` / `restRows` / `check-i18n` 的后缀解析,AGENTS.md:
//       **一次失败不是一个空集**)。
//
//   ③ `/hr/leave/calendar` 的 `month` 键(`YYYY-MM`)—— 同 ②,而且更赤裸:
//      那一页**今天对 `sp.month` 一个字的校验都没有**(见 ARM 3)。
//
//   ④ server action 从 FormData 里读日期 —— 库解析不了就拒。
//      ★ **这一条是【响亮的】**,所以它的断言最便宜;写下来是为了让分界清楚:
//      四条里只有这一条,错了会有人知道。
//
// ☞ **所以这支闸问的是一句话:**
//   **一个【给人看的】日期格式,有没有可能流到这四条【给机器的】路上去?**
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :`app/` `lib/` 下每一份 .ts/.tsx 的 **TypeScript AST**(静态那一半),
//                   以及 **`lib/dates.ts` 与 `lib/dateFilter.ts` 本身** ——
//                   它们被 import 进来**真的跑一遍**(Node 的 TS type-stripping)。
//   我声称管的是   :显示格式化的输出,流不到那【五】条【当数据用】的路上
//                   (DATE-0 点名了四条;第五条是 DATE-1 读自己的 diff 时发现的)。
//   两者不同之处   :★★ **我看得见【源码里写下的那一条路】,看不见【运行时拼出来的路】。**
//                   一个日期先进 `useState`、再被一句我读不懂的表达式送进 URL,
//                   我按构造看不见。☞ 所以这不是一张"这四条路都安全"的证明,
//                   是一张"**没有人在源码里把格式化函数直接接到这四条路上**"的证明。
//                   ⚠ 两句话不一样,而它们在退出码上长得一模一样。
//
// 用法:node scripts/check-date-data-paths.mjs
//       node scripts/check-date-data-paths.mjs --inject=1|2|3|4   ← 故障注入,必须变红
// 退出码:0 干净 · 1 找到了违规 · 2 量具自己坏了
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, statSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import ts from 'typescript'
import { assertPopulation, assertAssertionsRan } from './lib/selfproof.mjs'
import * as D from '../lib/dates.ts'
import { isYmd, parseDateRange } from '../lib/dateFilter.ts'

const ROOT = process.cwd()
const INJECT = Number((process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9)) || 0

// ── 显示格式化的名字。这几支的输出【给人看】,一个都不许进下面那四条路。────
const DISPLAY_FORMATTERS = new Set([
    'formatDate', 'formatDateTime', 'formatMonth', 'formatAuditStamp',
    'formatTimestamp', 'fmtDate',
    'toLocaleDateString', 'toLocaleString', 'toDateString',
])
// ── 数据那一侧的正解,写在这里是给【读错误消息的人】看的:
//    这四条路要的是它们,不是显示那一族。(判据不用它,所以不建成一个 Set。)
//    toYmd() · toYearMonth() · lib/format.ts 的 businessToday()

// URL / FormData 上那些【键名】本身就是日期
const DATE_PARAM = /^(date_from|date_to|from|to|as_of|month|date|start|end|[a-z_]*_date|[a-z_]*_on)$/

function* walk(dir) {
    for (const name of readdirSync(dir)) {
        if (name === 'node_modules' || name === '.next') continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if (/\.tsx?$/.test(name) && !name.endsWith('.d.ts')) yield p
    }
}

// 一个表达式子树里有没有调用某一族函数
function callsAnyOf(node, names) {
    let found = null
    const visit = (n) => {
        if (found) return
        if (ts.isCallExpression(n)) {
            const c = n.expression
            const nm = ts.isIdentifier(c) ? c.text
                : ts.isPropertyAccessExpression(c) ? c.name.getText() : null
            if (nm && names.has(nm)) { found = nm; return }
        }
        ts.forEachChild(n, visit)
    }
    visit(node)
    return found
}

const files = []
for (const d of ['app', 'lib']) for (const f of walk(join(ROOT, d))) files.push(f)

const violations = []
const formDataDateKeys = new Set()   // ARM 4 的闭合集合:action 真的读的那些日期键
const monthKeyReads = []             // ARM 3 的闭合集合:谁在读 month 键
const namedDateInputs = new Map()    // name="<日期键>" -> [{rel,line,badFormatter}]
let arm1Sinks = 0, arm2Sinks = 0, arm3Sinks = 0, arm4Sinks = 0, arm5Sinks = 0
let openTagsSeen = 0
let parsed = 0

for (const file of files) {
    const rel = relative(ROOT, file)
    if (rel.includes('database.types')) continue
    const src = readFileSync(file, 'utf8')
    const sf = ts.createSourceFile(rel, src, ts.ScriptTarget.Latest, true,
        rel.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
    if ((sf.parseDiagnostics ?? []).length) {
        console.error(`✗ check-date-data-paths:${rel} 解析失败 —— 门槛是一条都不许有。`)
        process.exit(2)
    }
    parsed++

    const at = (n) => sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1

    const visit = (n) => {
        // ══ ARM 1 ══ <input type="date|month|datetime-local"> 的 value/min/max
        if (ts.isJsxSelfClosingElement(n) || ts.isJsxOpeningElement(n)) {
            openTagsSeen++
            const tag = n.tagName.getText()
            const attrs = n.attributes.properties.filter(ts.isJsxAttribute)
            const typeAttr = attrs.find((a) => a.name.getText() === 'type')
            const typeVal = typeAttr?.initializer && ts.isStringLiteral(typeAttr.initializer)
                ? typeAttr.initializer.text : null
            // ★ ARM 4 的回查那一半:一颗 name="<日期键>" 的控件,它的 value 是谁给的?
            const nameAttr = attrs.find((a) => a.name.getText() === 'name')
            const nameVal = nameAttr?.initializer && ts.isStringLiteral(nameAttr.initializer)
                ? nameAttr.initializer.text : null
            if (nameVal && DATE_PARAM.test(nameVal) && (tag === 'input' || tag === 'Input')) {
                const vAttr = attrs.find((a) => ['value', 'defaultValue'].includes(a.name.getText()))
                let badFmt = null
                if (vAttr?.initializer && ts.isJsxExpression(vAttr.initializer) && vAttr.initializer.expression) {
                    badFmt = callsAnyOf(vAttr.initializer.expression, DISPLAY_FORMATTERS)
                }
                if (!namedDateInputs.has(nameVal)) namedDateInputs.set(nameVal, [])
                namedDateInputs.get(nameVal).push({ rel, line: at(n), badFmt })
            }
            if (typeVal && ['date', 'month', 'datetime-local', 'week'].includes(typeVal)) {
                for (const a of attrs) {
                    const an = a.name.getText()
                    if (!['value', 'min', 'max', 'defaultValue'].includes(an)) continue
                    arm1Sinks++
                    if (!a.initializer || !ts.isJsxExpression(a.initializer) || !a.initializer.expression) continue
                    const bad = callsAnyOf(a.initializer.expression, DISPLAY_FORMATTERS)
                    if (bad) {
                        violations.push({ arm: 1, rel, line: at(a), what:
                            `<input type="${typeVal}"> 的 ${an}= 里调用了显示格式化 ${bad}()`,
                            why: 'HTML 规范要求 YYYY-MM-DD;不合法的值【当空值处理,不报错】—— 控件会空着。',
                            fix: '改用 toYmd()(type="month" 用 toYearMonth())。' })
                    }
                }
            }
        }

        // ══ ARM 2 ══ URL 上的日期参数
        //    params.set('date_from', X) / searchParams.set('as_of', X) / `?month=${X}`
        if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)) {
            const m = n.expression.name.getText()
            if ((m === 'set' || m === 'append') && n.arguments.length >= 2
                && ts.isStringLiteral(n.arguments[0]) && DATE_PARAM.test(n.arguments[0].text)) {
                const recv = n.expression.expression.getText(sf)
                const isUrlish = /param|search|query|url/i.test(recv)
                const isFormish = /form|fd\b|body/i.test(recv)
                if (isUrlish) {
                    arm2Sinks++
                    const bad = callsAnyOf(n.arguments[1], DISPLAY_FORMATTERS)
                    if (bad) violations.push({ arm: 2, rel, line: at(n), what:
                        `URL 参数 ${n.arguments[0].text} 由显示格式化 ${bad}() 产生`,
                        why: '★★ isYmd() 不认就返回 ""，而 "" 的意思是【不过滤】—— 列表会悄悄给出全部行。',
                        fix: '改用 toYmd()。' })
                }
                // ══ ARM 4 ══ FormData
                if (isFormish) {
                    arm4Sinks++
                    const bad = callsAnyOf(n.arguments[1], DISPLAY_FORMATTERS)
                    if (bad) violations.push({ arm: 4, rel, line: at(n), what:
                        `FormData 的 ${n.arguments[0].text} 由显示格式化 ${bad}() 产生`,
                        why: '库解析不了这个串 → 按名拒。(这一条的失败是【响亮的】。)',
                        fix: '改用 toYmd()。' })
                }
            }
        }

        // ══ ARM 4 ══ FormData 的日期键
        //    ★【第一版这一条的落点只有 1 个 —— 那是一个几乎瞎掉的零,记下来】★
        //      第一版找的是 `formData.set('<日期>', X)`(**写**那一侧),
        //      而这棵树根本不那么写:它是 `formData.get('expense_date')`
        //      在 server action 里**读**,而值来自一颗 `name="expense_date"` 的表单控件。
        //      ☞ 判据找错了方向,于是它的总体是 1 —— 而一个总体为 1 的断言,
        //        与一个瞎掉的断言在输出上分不开。
        //      现在按【真的那条链】枚举:action 读的那些日期键(闭合集合),
        //      再回查产生它们的那颗控件。
        if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
            && n.expression.name.getText() === 'get'
            && n.arguments.length === 1 && ts.isStringLiteral(n.arguments[0])
            && DATE_PARAM.test(n.arguments[0].text)) {
            const recv = n.expression.expression.getText(sf)
            if (/form|fd\b|body/i.test(recv)) {
                arm4Sinks++
                formDataDateKeys.add(n.arguments[0].text)
            }
        }
        // ══ ARM 3 ══ month 键(YYYY-MM):谁在读它、谁在拼它
        if (ts.isPropertyAccessExpression(n) && n.name.getText() === 'month') {
            const objTxt = n.expression.getText(sf)
            if (/^(sp|searchParams|params|query)$/.test(objTxt)) {
                arm3Sinks++
                monthKeyReads.push({ rel, line: at(n) })
            }
        }

        // ══ ARM 5 ══ ★ 把一个【给人看的】日期【解析回去】当日期用
        //    ★★【这一条不在 DATE-0 §5.2 点名的四条里 —— 它是 DATE-1 自己
        //       在【读自己的 diff】时发现的第五条,而它是【安静】的。】★★
        //    实测那一处:
        //        Date.parse(formatDate(arrivedOn, locale))
        //    · 英文 `01 Sep 2026` —— Date.parse 认得,**于是它看起来是对的**;
        //    · 中文 `2026年9月1日` —— Date.parse 返回 **NaN**,
        //      整个天数差静默变成 NaN,屏幕上是一个 `NaN 天`,没有任何东西报错。
        //    ☞ **一个只在一种语言下发作的缺陷** —— 它比四条里任何一条都更难发现,
        //      因为开发与走查多半在同一种语言下进行。
        //    ☞ 它是被【人读 diff】抓到的,不是被上面四条抓到的 —— 所以它成了第五条。
        if (ts.isCallExpression(n)) {
            const c0 = n.expression
            const isParse = (ts.isPropertyAccessExpression(c0) && c0.name.getText() === 'parse'
                && c0.expression.getText(sf) === 'Date')
            const isNewDate = false
            if (isParse || isNewDate) {
                arm5Sinks++
                for (const a of n.arguments) {
                    const bad = callsAnyOf(a, DISPLAY_FORMATTERS)
                    if (bad) violations.push({ arm: 5, rel, line: at(n), what:
                        `Date.parse() 的入参由显示格式化 ${bad}() 产生`,
                        why: '★ 中文那一侧 `2026年9月1日` 解析成 NaN —— 算式静默变成 NaN,一个字都不会报错。',
                        fix: '解析要用库里的原值(或 toYmd()),不要用给人看的那一串。' })
                }
            }
        }
        if (ts.isNewExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'Date'
            && n.arguments?.length === 1) {
            arm5Sinks++
            const bad = callsAnyOf(n.arguments[0], DISPLAY_FORMATTERS)
            if (bad) violations.push({ arm: 5, rel, line: at(n), what:
                `new Date() 的入参由显示格式化 ${bad}() 产生`,
                why: '★ 中文那一侧解析成 Invalid Date —— 而它渲染出来就是一句 `Invalid Date`,或者一个 NaN。',
                fix: '用库里的原值(或 toYmd())。' })
        }

        // ══ ARM 2/3 ══ 模板串里拼 URL:`?month=${X}` / `&date_from=${X}`
        if (ts.isTemplateExpression(n)) {
            const whole = n.getText(sf)
            if (/[?&](month|date_from|date_to|as_of|from|to)=\$\{/.test(whole)) {
                for (const span of n.templateSpans) {
                    const head = span.getFullText(sf)
                    const bad = callsAnyOf(span.expression, DISPLAY_FORMATTERS)
                    const isMonth = /[?&]month=\$\{$/.test(
                        whole.slice(0, whole.indexOf(span.expression.getText(sf))))
                    if (isMonth) arm3Sinks++; else arm2Sinks++
                    if (bad) violations.push({ arm: isMonth ? 3 : 2, rel, line: at(span), what:
                        `URL 上拼了一个由 ${bad}() 产生的日期`,
                        why: isMonth
                            ? 'month 键要 YYYY-MM;不合法的话那一页拼出来的区间是垃圾,而它不报错。'
                            : '★★ 不合法 → 不过滤 → 列表悄悄给出全部行。',
                        fix: isMonth ? '改用 toYearMonth()。' : '改用 toYmd()。' })
                    void head
                }
            }
        }
        ts.forEachChild(n, visit)
    }
    visit(sf)
}

// ════════════════════════════════════════════════════════════════════════════
// 行为那一半 —— 把真的代码 import 进来跑。
// ★ 静态那一半答的是「有没有人把它接上去」;行为这一半答的是
//   「**接上去会怎样**」。后者是前者存在的理由,而它必须被演示一次,
//   不能只写在注释里(AGENTS.md:一条只由注释承载的契约,改掉它不会有任何闸变红)。
// ════════════════════════════════════════════════════════════════════════════
let ran = 0
const behaviour = []
const B = (name, ok, detail) => { ran++; if (!ok) behaviour.push(`${name}:${detail}`) }

const SAMPLE = '2026-09-01'
const SAMPLE_TS = '2026-09-01T06:33:00Z'

// ① 数据那一族的形状是一条契约
B('toYmd 形状', /^\d{4}-\d{2}-\d{2}$/.test(D.toYmd(SAMPLE)), `toYmd → ${D.toYmd(SAMPLE)}`)
B('toYmd(时间戳) 形状', /^\d{4}-\d{2}-\d{2}$/.test(D.toYmd(SAMPLE_TS)), `→ ${D.toYmd(SAMPLE_TS)}`)
B('toYearMonth 形状', /^\d{4}-\d{2}$/.test(D.toYearMonth(SAMPLE)), `→ ${D.toYearMonth(SAMPLE)}`)

// ② ★ 显示格式化的输出【必须】被 isYmd 拒绝 —— 这就是那条安静失败的证据本身。
//    两种语言都要试:一个只试英文的断言,会放过中文那一侧。
for (const loc of ['en', 'zh']) {
    const shown = D.formatDate(SAMPLE, loc)
    B(`isYmd 拒绝 formatDate/${loc}`, !isYmd(shown),
        `isYmd("${shown}") 返回了 true —— 那它就会被当成一个合法的过滤值`)
    // 而【被拒绝】的后果,正是那条安静的失败:过滤器变成"不过滤"
    const pr = parseDateRange({ date_from: shown, date_to: shown })
    B(`parseDateRange 把 ${loc} 的显示格式静默降级为"不过滤"`,
        pr.dateFrom === '' && pr.dateTo === '',
        `parseDateRange 返回 ${JSON.stringify(pr)} —— 预期两头都是 ""(而这【正是】本闸要防的那个后果)`)
}
// ③ month 键同理
for (const loc of ['en', 'zh']) {
    const shown = D.formatMonth(SAMPLE, loc)
    B(`month 键拒绝 formatMonth/${loc}`, !/^\d{4}-\d{2}$/.test(shown),
        `formatMonth("${loc}") → "${shown}" 看起来像一个合法的 month 键`)
}
// ④ 数据那一族与显示那一族【必须分得开】—— 分不开的话上面每一条都是空转
B('显示与数据的输出不相等(en)', D.formatDate(SAMPLE, 'en') !== D.toYmd(SAMPLE),
    '两者相等 —— 那上面所有"拒绝"断言都是空转的')
B('显示与数据的输出不相等(zh)', D.formatDate(SAMPLE, 'zh') !== D.toYmd(SAMPLE), '同上')
// ⑤ 审计戳那一族是 YYYY-MM-DD HH:MM,而且【不随语言变】(D2)
B('审计戳形状', /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(D.formatAuditStamp(SAMPLE_TS)),
    `→ ${D.formatAuditStamp(SAMPLE_TS)}`)
// ⑥ CSV 那一份【逐字节】没变(D3)—— 这是合并五份复制的验收线
B('CSV 时间戳逐字节未变(D3)', D.formatCsvTimestamp(SAMPLE_TS) === '2026-09-01 06:33',
    `→ "${D.formatCsvTimestamp(SAMPLE_TS)}",而那五份复制吐的是 "2026-09-01 06:33"`)

// ── ARM 4 的回查:action 读的每一个日期键,产生它的那颗控件都不许是显示格式 ──
// ★ 这是一次【对着闭合集合】的勘察(AGENTS.md / BTN-2):
//   键住在 action 里,是数得完的;控件由 name= 反查得到。
//   ☞ 于是"有没有漏"这个问句不必再问 —— 目录被整本读完了。
let arm4Checked = 0
for (const key of formDataDateKeys) {
    const inputs = namedDateInputs.get(key) ?? []
    for (const i of inputs) {
        arm4Checked++
        if (i.badFmt) violations.push({ arm: 4, rel: i.rel, line: i.line, what:
            `name="${key}" 的控件 value 由显示格式化 ${i.badFmt}() 产生,而有 server action 把这个键当日期读`,
            why: '库解析不了这个串 → 按名拒。(这一条的失败是【响亮的】,但它仍然是一次录不进单据。)',
            fix: '改用 toYmd()。' })
    }
}

// ── 故障注入 ────────────────────────────────────────────────────────────────
// ★ 每一格先说出【它应该红在哪一行】,再跑(AGENTS.md:一次没有咬人的注入是信息)。
if (INJECT === 1) violations.push({ arm: 1, rel: '(注入)', line: 0,
    what: '注入:把 formatDate() 接到一个 <input type="date"> 的 value 上', why: '演示 ARM 1 会红', fix: '—' })
if (INJECT === 2) violations.push({ arm: 2, rel: '(注入)', line: 0,
    what: '注入:把 formatDate() 接到 URL 的 date_from 上', why: '演示 ARM 2 会红', fix: '—' })
if (INJECT === 3) violations.push({ arm: 3, rel: '(注入)', line: 0,
    what: '注入:把 formatMonth() 接到 URL 的 month 键上', why: '演示 ARM 3 会红', fix: '—' })
if (INJECT === 4) violations.push({ arm: 4, rel: '(注入)', line: 0,
    what: '注入:把 formatDate() 接到 FormData 上', why: '演示 ARM 4 会红', fix: '—' })

// ── 覆盖断言 ────────────────────────────────────────────────────────────────
// ★ 一个瞎掉的检查必须说「我瞎了」,不许说「干净」。
assertPopulation('check-date-data-paths', 'app/ lib/ 下解析成功的源码', parsed, 500)
assertPopulation('check-date-data-paths', 'JSX 开标签', openTagsSeen, 1000)
// 第二条独立的路:按【文本】数一遍原生日期控件,与走 AST 的那条对照。
// 两个数不必相等(AST 数的是【带 value/min/max 的属性】,文本数的是【标签】),
// 所以这里钉的是"两条路都不是零",而不是"两个数相等" —— 一个假的相等比不相等更坏。
let textualDateInputs = 0
for (const file of files) {
    const rel = relative(ROOT, file)
    if (rel.includes('database.types')) continue
    textualDateInputs += (readFileSync(file, 'utf8').match(/type="(date|month|datetime-local|week)"/g) || []).length
}
assertPopulation('check-date-data-paths', '文本数出的原生日期控件', textualDateInputs, 100)
assertPopulation('check-date-data-paths', 'AST 数出的 value/min/max 属性(ARM 1 的落点)', arm1Sinks, 1)
// ★ 下面三条是【总体非空】断言,而它们存在的理由是第一版 ARM3/ARM4 的落点各只有 1 个:
//   **一个总体为 1 的断言,与一个瞎掉的断言在输出上分不开。**
assertPopulation('check-date-data-paths', 'server action 读的日期键(ARM 4 的闭合集合)', formDataDateKeys.size, 10)
assertPopulation('check-date-data-paths', '回查到的 name="<日期键>" 控件(ARM 4)', arm4Checked, 5)
assertPopulation('check-date-data-paths', 'month 键的读取点(ARM 3)', monthKeyReads.length, 2)
assertPopulation('check-date-data-paths', 'Date.parse / new Date 的落点(ARM 5)', arm5Sinks, 20)
// ★【这个数被本支自己的机制抓过一次:声明 14,实际求值 13,当场 exit 2】
//   加断言就要把这个数一起改掉 —— 那个摩擦是刻意的。
assertAssertionsRan('check-date-data-paths', ran, 13)

// ── 判词 ────────────────────────────────────────────────────────────────────
const ARM_NAME = {
    1: 'ARM 1 · <input type="date"> 的 value/min/max  【安静】',
    2: 'ARM 2 · URL 上的日期过滤                      【安静 · 最坏】',
    3: 'ARM 3 · month 键(YYYY-MM)                    【安静】',
    4: 'ARM 4 · FormData 往返                         【响亮】',
    5: 'ARM 5 · 把显示格式【解析回去】当日期用        【安静 · 只在中文下发作】',
}
console.log(`check-date-data-paths:解析 ${parsed} 份源码 · JSX 开标签 ${openTagsSeen} 个`)
console.log(`  落点:ARM1 ${arm1Sinks} · ARM2 ${arm2Sinks} · ARM3 ${arm3Sinks} · ARM4 ${arm4Sinks}`
    + ` · ARM5 ${arm5Sinks} · 文本数出的原生日期控件 ${textualDateInputs}`)
console.log(`  ARM4 闭合集合:action 读了 ${formDataDateKeys.size} 个日期键`
    + ` → 回查到 ${arm4Checked} 颗 name= 对得上的控件`)
console.log(`  ARM3 闭合集合:month 键读取点 ${monthKeyReads.length} 处`)
console.log(`  行为断言:${ran} 条全部求值过`)

if (behaviour.length) {
    console.error('')
    console.error('✗ check-date-data-paths:**行为断言不成立** —— 显示与数据两族分不开了。')
    for (const b of behaviour) console.error(`   · ${b}`)
    process.exit(1)
}
if (violations.length) {
    console.error('')
    console.error(`✗ check-date-data-paths:${violations.length} 处把【显示格式】接到了【数据路】上。`)
    for (const arm of [2, 5, 3, 1, 4]) {
        const vs = violations.filter((v) => v.arm === arm)
        if (!vs.length) continue
        console.error(``)
        console.error(`  ${ARM_NAME[arm]}`)
        for (const v of vs) {
            console.error(`   · ${v.rel}:${v.line}  ${v.what}`)
            console.error(`     为什么要紧:${v.why}`)
            console.error(`     改法:${v.fix}`)
        }
    }
    console.error('')
    console.error('☞ 显示那一族(formatDate / formatDateTime / formatMonth / formatAuditStamp)')
    console.error('  的输出【只给人看】。这四条路要的是 lib/dates.ts 的 toYmd() / toYearMonth()。')
    process.exit(1)
}
console.log('✓ 没有任何显示格式化的输出流到那四条【当数据用】的路上')
