#!/usr/bin/env node
// scripts/check-date-format.mjs
// ════════════════════════════════════════════════════════════════════════════
// DATE-1(2026-09-20)· 日期格式的【棘轮】—— 照 check-currency-literals 的先例
// ════════════════════════════════════════════════════════════════════════════
// 【它拦什么】三维,每一维都是"只许变少,不许变多":
//   ① `toLocaleDateString` / `toLocaleString` / `toLocaleTimeString`
//      —— 它们**随浏览器 locale 变**:en-US 是 `9/1/2026`,zh-CN 是 `2026/9/1`。
//      Tim 抱怨的「同一个日期读出三种样子」里,第二种就是它。
//   ② **新的本地日期格式化复制** —— DATE-1 之前树里有 5 份逐字节相同的
//      `formatDate` 外加一份 `fmtDate`。它们合并成了 `lib/dates.ts` 一份;
//      这一维拦的是第七份。
//      ★ **判据按【形状】,不按名字** —— AGENTS.md(BUGFIX-1b)记过:
//        按 `localize*Error` 这个名字数出 42 支,按形状数是 45 支,
//        差的 5 支做的是一模一样的事,只是不叫那个名字。
//   ③ ★ DATE-PICK-1(2026-10-05,Tim 的 Q38)起:原生日期 / 月份 / 日期时间框【一个都不许有】。
//      从前它"只许减少"(DATE-1 守着那笔债不再长);选择器那一刀把 134 处全部换成了
//      `app/components/ui/date-picker.tsx`,于是判据从【棘轮】变成【零】。
//      ☞ 而"零"是这一维最危险的读数 —— 一支瞎掉的扫描器也报零。所以它【两条互相独立的路】数
//        (语法树 · 字符),两个数必须相等;每一次运行先拿一段【金丝雀源码】试两条路,
//        数不出金丝雀里那 5 处就当场退 2(「我瞎了」),而不是报「干净」。
//      ☞ 两条路同时数【选择器的调用点】(DatePicker / PaymentDateInput):那是这 134 处搬去的地方,
//        它的总体 ≥ 100 是"扫描器确实走到了那些页面"的第二个证据。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★★【它【做不到】什么 —— 而这一段是本文件最要紧的几行】★★★
// ════════════════════════════════════════════════════════════════════════════
//
// > ### **一道棘轮拦得住「你写了一个不该写的东西」。**
// > ### **它拦不住「你【什么都没写】」。**
//
// ☞ 而「什么都没写」**正是 DATE-1 要修的那几百处的成因**:
//   DATE-0 实测,屏幕上最常见的日期长相是 **`{row.order_date}`** ——
//   一个**一个字节都没格式化**的 JSX 表达式,库原值直接上屏。
//   它不调用任何函数、不匹配任何模式、不写下任何一个这支脚本认得的词。
//   ★★ **一个什么都不写的新页面,会一路绿灯地把这笔债重新长出来。**
//
// ★ 所以:**一次绿的构建【不】意味着日期格式是统一的**;
//   它意味着**没有人【新写】一个走样的格式化**。
//   两句话不一样,而它们在退出码上是同一个字节 ——
//   与 check-currency-literals 末尾那段 CCY-VERIFY 是同一种限制,照它的样子写在这里。
//
// ────────────────────────────────────────────────────────────────────────────
// 【唯一能让「什么都没写」自己变红的那条路,以及它【为什么没有在这一刀里做】】
//
// 把日期从「一个字符串」变成「**一个必须被格式化才印得出来的东西**」:
// 让取数那一层吐一个 `BrandedDate`,而它**没有 `toString`** ——
// 于是 `{row.order_date}` **编译不过**。
// ★ 本仓库有一条同形的先例可以照抄理由:`lib/permissions.ts` 存在的全部理由
//   就是「`null` 已经有主了,所以拒绝不能用 `null` 表示」——
//   **让错误的写法【构造上不可能】,而不是靠记。**
//
// ⚠ **它没有在这一刀里做,而理由不是"太贵",是一条本仓库刚付过账的规矩:**
//   它要改**取数那一层**、改 `lib/database.types.ts` 的用法、几百处一次性全改 ——
//   ☞ **那把一件【改显示】的刀,变成一件【改数据层】的刀。**
//   而这棵树**刚刚为"把两个风险叠在一起"付过账**(BUGFIX-1a:一句为了让类型
//   过关而加的 `as never`,关掉的正是唯一看得见那个错的检查)。
//   Tim 在 D1 里对同一件事已经裁过一次同样的话:
//   **「把一件『看起来不一致』的事和一件『可能让人干不了活』的事绑在同一刀里,
//     等于让前者替后者背风险。」**
//
// ☞ **立案:`docs/known-issues.md` 的 `DATE1-BRANDED-DATE-DEBT`,连着这段理由。**
//   它是一条**带理由的债**,不是一件被忘掉的事。
// ════════════════════════════════════════════════════════════════════════════
//
// 【瞄准 · AIM】
//   我读的是      :`app/` `lib/` 下每一份 .ts/.tsx 的 **TypeScript AST**
//                   (调用点与函数体形状),以及同一批文件的**原始文本**
//                   (第二条独立计数用)。
//   我声称管的是   :走样的日期格式**不再新增**;原生日期控件**只减不增**。
//   两者不同之处   :★★ **我答的是「有没有人【新写】一个走样的格式化」,
//                   不是「屏幕上的日期是不是统一的」。**
//                   一个【什么都不写】的新页面照样把库原值印上屏,
//                   而它一行都不匹配我 —— 见上面那一整段。
//                   ☞ 这与 check-currency-literals 的 CCY-VERIFY 是同一种限制:
//                     **一个声称得比实际多的检查,比一个缺失的检查更坏。**
//
// 用法:node scripts/check-date-format.mjs
//       node scripts/check-date-format.mjs --update-baseline
//       node scripts/check-date-format.mjs --blind=ast|text   ← 致盲注入,必须退 2
//       node scripts/check-date-format.mjs --inject=native|native-expr|native-ternary|native-month|native-datetime|comment
//            ← 维度③ 的故障注入:往扫描集合里加一份【虚拟源码】;前五格必须退 1 并点名它,comment 那一格必须仍是 0
// 退出码:0 干净 · 1 新增了违规 · 2 量具自己坏了
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, statSync, readFileSync, writeFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import ts from 'typescript'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'
import { blankComments } from './lib/blank-comments.mjs'

const ROOT = process.cwd()
const BASELINE = join(ROOT, 'scripts/date-format-baseline.json')
const BLIND = (process.argv.find((a) => a.startsWith('--blind=')) || '').slice(8)
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9)

// ── 例外:每一条都要写理由。名单是列出来的,不是记在谁脑子里的。──────────────
const ALLOWLIST = [
    {
        path: 'lib/dates.ts',
        reason: '★ 这【就是】那一份。棘轮拦的是"第七份复制",而这是被复制的那个原本 —— '
            + '一道禁止写日期格式化的闸,不该把唯一一份合法的实现算成违规。',
    },
    {
        path: 'lib/format.ts',
        reason: 'formatTimestamp 在这里,而 DATE-1 把它的函数体改成委托给 '
            + 'lib/dates.ts 的 formatAuditStamp() —— 签名留着是为了不动它那 39 个调用点。'
            + '它自己不再是一份实现,是一层转发。',
    },
    {
        path: 'app/brand-sampler/',
        reason: '★ 取样页是【标准的载体】,不是一个普通页面(停止条件 (e) 专门盯着它)。'
            + '它按设计写死示例数据来展示版式,那些字符串不是从库里取的日期。',
    },
]
function allowed(rel) {
    return ALLOWLIST.some((a) => rel === a.path || rel.startsWith(a.path))
}

// ★★【注释会污染将来对它自己的计数 —— 而本刀差点又种了一次】★★
//   AGENTS.md(CONFIRM-1 / ALERT-1)记过三次:`grep -c` 一视同仁地把散文数进去。
//   本支的两条路第一次对不上,差额恰好是 **2 条注释** —— 其中一条
//   **是 DATE-1 自己刚写在 lib/format.ts 里的**(它在解释"从前这里是
//   `new Date(iso).toLocaleString(...)`")。
//   ☞ 处置照 CONFIRM-1 的两条:① 数之前把注释剥掉,让两条路数的是同一个总体;
//     ② **注释数与调用点数【分开报】** —— 只报一个总数的勘察,读者无从知道
//     它数的是代码还是散文。
// 涂注释那一支搬去了 scripts/lib/blank-comments.mjs(DATE-PICK-1:check-date-data-paths 的字符那条路也要它)

function* walk(dir) {
    for (const name of readdirSync(dir)) {
        if (name === 'node_modules' || name === '.next') continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if (/\.tsx?$/.test(name) && !name.endsWith('.d.ts')) yield p
    }
}

const LOCALE_CALLS = new Set(['toLocaleDateString', 'toLocaleTimeString', 'toLocaleString'])

// ════════════════════════════════════════════════════════════════════════════
// ── 维度 ③ 的两条路(DATE-PICK-1)────────────────────────────────────────────
// ════════════════════════════════════════════════════════════════════════════
// 【数的是什么】一个原生的日期类控件 = 下面五种写法里的任何一种,种类是 date · month · datetime-local · week · time:
//   ① JSX 属性 `type="date"`(任何标签 —— `<Input type="date">` 与 `<input>` 一样坏);
//   ② `type={'date'}` / `type={x ? 'date' : 'text'}`(表达式里出现那个字面量);
//   ③ `createElement('input', { type: 'date' })`;④ `el.type = 'date'`;⑤ `el.setAttribute('type', 'date')`。
// 【两条路怎么独立】路 A 走 TypeScript 语法树;路 B 只走字符(先把注释涂掉,字符串留着)。
//   两条路都不按行切(AGENTS.md:按行切会废掉含 \n 的字符类 —— 多行开标签的那一行到 `<input` 就断了)。
const NATIVE_KINDS = ['date', 'month', 'datetime-local', 'week', 'time']
const NATIVE_SET = new Set(NATIVE_KINDS)
const PICKER_TAGS = new Set(['DatePicker', 'PaymentDateInput'])
const KIND_ALT = NATIVE_KINDS.join('|')

/** 路 A:语法树。返回 { natives: [{line, how}], typeAttrs, pickers } */
function nativeByAst(rel, src) {
    const out = { natives: [], typeAttrs: 0, pickers: 0 }
    if (BLIND === 'ast') return out
    const sf = ts.createSourceFile(rel, src, ts.ScriptTarget.Latest, true,
        rel.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
    const at = (n) => sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1
    const literalKinds = (expr) => {
        const found = []
        const v = (n) => {
            if ((ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)) && NATIVE_SET.has(n.text)) found.push(n.text)
            ts.forEachChild(n, v)
        }
        v(expr)
        return found
    }
    const visit = (n) => {
        if (ts.isJsxSelfClosingElement(n) || ts.isJsxOpeningElement(n)) {
            if (PICKER_TAGS.has(n.tagName.getText(sf))) out.pickers++
        }
        if (ts.isJsxAttribute(n) && n.name.getText(sf) === 'type') {
            out.typeAttrs++
            const init = n.initializer
            if (init && ts.isStringLiteral(init) && NATIVE_SET.has(init.text)) out.natives.push({ line: at(n), how: `type="${init.text}"` })
            else if (init && ts.isJsxExpression(init) && init.expression) {
                for (const k of literalKinds(init.expression)) out.natives.push({ line: at(n), how: `type={…'${k}'…}` })
            }
        }
        if (ts.isCallExpression(n)) {
            const callee = n.expression
            const nm = ts.isIdentifier(callee) ? callee.text : ts.isPropertyAccessExpression(callee) ? callee.name.text : ''
            if (nm === 'createElement' && n.arguments.length >= 2 && ts.isObjectLiteralExpression(n.arguments[1])) {
                for (const p of n.arguments[1].properties) {
                    if (ts.isPropertyAssignment(p) && p.name.getText(sf) === 'type') {
                        for (const k of literalKinds(p.initializer)) out.natives.push({ line: at(n), how: `createElement(…{ type: '${k}' })` })
                    }
                }
            }
            if (nm === 'setAttribute' && n.arguments.length >= 2 && ts.isStringLiteral(n.arguments[0]) && n.arguments[0].text === 'type') {
                for (const k of literalKinds(n.arguments[1])) out.natives.push({ line: at(n), how: `setAttribute('type', '${k}')` })
            }
        }
        if (ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken
            && ts.isPropertyAccessExpression(n.left) && n.left.name.text === 'type') {
            for (const k of literalKinds(n.right)) out.natives.push({ line: at(n), how: `.type = '${k}'` })
        }
        ts.forEachChild(n, visit)
    }
    visit(sf)
    return out
}

/** 路 B:字符。注释先涂掉(字符串留着),整份源码跑正则 —— 不按行切。 */
function nativeByText(rel, src) {
    const out = { natives: [], typeAttrs: 0, pickers: 0 }
    if (BLIND === 'text') return out
    const s = blankComments(src)
    const lineOf = (i) => s.slice(0, i).split('\n').length
    const pats = [
        [new RegExp(`\\btype=["'](${KIND_ALT})["']`, 'g'), (k) => `type="${k}"`],
        [new RegExp(`\\btype=\\{[^}]*?['"\`](${KIND_ALT})['"\`][^}]*\\}`, 'g'), (k) => `type={…'${k}'…}`],
        [new RegExp(`createElement\\(\\s*['"]input['"]\\s*,\\s*\\{[^}]*\\btype\\s*:\\s*['"](${KIND_ALT})['"]`, 'g'), (k) => `createElement(…{ type: '${k}' })`],
        [new RegExp(`\\.type\\s*=\\s*['"](${KIND_ALT})['"]`, 'g'), (k) => `.type = '${k}'`],
        [new RegExp(`setAttribute\\(\\s*['"]type['"]\\s*,\\s*['"](${KIND_ALT})['"]`, 'g'), (k) => `setAttribute('type', '${k}')`],
    ]
    for (const [re, how] of pats) for (const m of s.matchAll(re)) out.natives.push({ line: lineOf(m.index), how: how(m[1]) })
    out.typeAttrs = (s.match(/(?<![\w.$-])type=(?=["'{])/g) || []).length
    out.pickers = (s.match(/<(DatePicker|PaymentDateInput)(?=[\s/>]|$)/g) || []).length
    return out
}

// ★ 金丝雀:每一次运行都先拿它试两条路。五处原生(三种 JSX 写法 + 一个多行开标签 + 一句赋值)、
//   一处只在注释里(必须【不】算)、一个选择器调用点。任何一条路数不对,本支退 2 —— 一支瞎掉的扫描器
//   必须说「我瞎了」,不许报一个漂亮的零(AGENTS.md「覆盖率本身必须是一条断言」)。
const CANARY = [
    "export function Canary({ k }: { k: boolean }) {",
    "    return (",
    "        <form>",
    "            <input type=\"date\" />",
    "            <input",
    "                type=\"month\"",
    "            />",
    "            <input type={'datetime-local'} />",
    "            <input type={k ? 'week' : 'text'} />",
    "            {/* <input type=\"date\" /> 注释里的不算 */}",
    "            <DatePicker name=\"d\" />",
    "        </form>",
    "    )",
    "}",
    "export function poke(el: HTMLInputElement) { el.type = 'time' }",
].join('\n')
const CANARY_NATIVES = 5, CANARY_PICKERS = 1

// 维度③ 的故障注入:一份【虚拟】源码进扫描集合,走与真文件完全相同的两条路
const INJECTIONS = {
    'native': '<input type="date" name="x" />',
    'native-expr': "<input type={'date'} />",
    'native-ternary': "<input type={wide ? 'datetime-local' : 'text'} />",
    'native-month': '<input\n    type="month"\n/>',
    'native-datetime': '<input type="datetime-local" />',
    'comment': '{/* <input type="date" /> 只在注释里 */}<input type="text" />',
}
const INJECT_REL = 'app/__inject__/DatePickInjection.tsx'
const INJECT_SRC = INJECT && INJECTIONS[INJECT]
    ? `export function Injected({ wide }: { wide: boolean }) {\n    return (<div>${INJECTIONS[INJECT]}</div>)\n}\n` : null
if (INJECT && !INJECT_SRC) {
    console.error(`✗ check-date-format:不认识的注入 --inject=${INJECT}(认的是:${Object.keys(INJECTIONS).join(' · ')})`)
    process.exit(2)
}

const files = []
for (const d of ['app', 'lib']) for (const f of walk(join(ROOT, d))) files.push(f)

// ── 维度 ①②:AST 那一条路 ──────────────────────────────────────────────────
const counts = Object.create(null)          // "rel :: kind" -> n
const detail = []
let astCalls = 0                            // 所有 CallExpression(覆盖用)
let parsed = 0

/**
 * ★ 维度 ② 的判据按【形状】,不按名字(AGENTS.md / BUGFIX-1b)。
 * 一支手搓的日期格式化长这样:函数体里既 padStart 补零、又从一个 Date 上取分量。
 * 名字可以叫 formatDate、fmtDate、dateLabel、或者任何东西 —— 形状不会变。
 */
function isHandRolledDateFormatter(body, sf) {
    if (!body) return false
    let pads = false, parts = false
    const visit = (n) => {
        if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)) {
            const nm = n.expression.name.getText()
            if (nm === 'padStart') pads = true
            if (/^get(UTC)?(FullYear|Month|Date|Hours|Minutes|Seconds)$/.test(nm)) parts = true
        }
        ts.forEachChild(n, visit)
    }
    visit(body)
    void sf
    return pads && parts
}

for (const file of files) {
    const rel = relative(ROOT, file)
    if (rel.includes('database.types')) continue
    const src = readFileSync(file, 'utf8')
    const sf = ts.createSourceFile(rel, src, ts.ScriptTarget.Latest, true,
        rel.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
    if ((sf.parseDiagnostics ?? []).length) {
        console.error(`✗ check-date-format:${rel} 解析失败 —— 门槛是一条都不许有。`)
        process.exit(2)
    }
    parsed++
    const at = (n) => sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1
    const bump = (kind, n, text) => {
        const k = `${rel} :: ${kind}`
        counts[k] = (counts[k] ?? 0) + 1
        detail.push({ rel, kind, line: at(n), text: text.replace(/\s+/g, ' ').slice(0, 100) })
    }

    const visit = (n) => {
        if (ts.isCallExpression(n)) {
            astCalls++
            // ★ 致盲注入 'ast':把这一条路弄瞎。它必须让覆盖断言红,而不是让结果变绿。
            if (BLIND !== 'ast' && ts.isPropertyAccessExpression(n.expression)) {
                const nm = n.expression.name.getText()
                if (LOCALE_CALLS.has(nm) && !allowed(rel)) bump(`locale-call:${nm}`, n, n.getText(sf))
            }
        }
        if (BLIND !== 'ast' && !allowed(rel)) {
            let body = null
            if (ts.isFunctionDeclaration(n) || ts.isFunctionExpression(n) || ts.isArrowFunction(n)
                || ts.isMethodDeclaration(n)) body = n.body
            if (body && isHandRolledDateFormatter(body, sf)) {
                bump('hand-rolled-date-formatter', n, n.getText(sf).slice(0, 80))
            }
        }
        ts.forEachChild(n, visit)
    }
    visit(sf)
}

// ── 维度 ③:原生日期控件 —— 两条路各数一遍(DATE-PICK-1)────────────────────
let nativeInputs = 0                        // 路 A(语法树)数出的原生控件
const nativeByFile = Object.create(null)
const nativeDetail = []
let textNatives = 0, astTypeAttrs = 0, textTypeAttrs = 0, astPickers = 0, textPickers = 0
{
    // 金丝雀先跑:两条路都必须数出它
    const ca = nativeByAst('canary.tsx', CANARY), cb = nativeByText('canary.tsx', CANARY)
    if (ca.natives.length !== CANARY_NATIVES || cb.natives.length !== CANARY_NATIVES
        || ca.pickers !== CANARY_PICKERS || cb.pickers !== CANARY_PICKERS) {
        console.error('✗ check-date-format:**覆盖断言失败 —— 金丝雀没有被看见,这一次读数不作数。**')
        console.error(`    金丝雀里有 ${CANARY_NATIVES} 处原生日期控件、${CANARY_PICKERS} 个选择器;`
            + `语法树数出 ${ca.natives.length} / ${ca.pickers},字符数出 ${cb.natives.length} / ${cb.pickers}。`)
        console.error('  ☞ 这【不是】"代码有问题"(那是 exit 1)。这是量具自己说它瞎了 —— 一支瞎掉的扫描器报出来的零不是零。')
        process.exit(2)
    }
    const scan = [...files.map((f) => [relative(ROOT, f), null]), ...(INJECT_SRC ? [[INJECT_REL, INJECT_SRC]] : [])]
    for (const [rel, injected] of scan) {
        if (rel.includes('database.types')) continue
        const src = injected ?? readFileSync(join(ROOT, rel), 'utf8')
        const a = nativeByAst(rel, src), b = nativeByText(rel, src)
        if (a.natives.length) {
            nativeInputs += a.natives.length
            nativeByFile[rel] = a.natives.length
            for (const x of a.natives) nativeDetail.push({ rel, ...x })
        }
        textNatives += b.natives.length
        astTypeAttrs += a.typeAttrs; textTypeAttrs += b.typeAttrs
        astPickers += a.pickers; textPickers += b.pickers
    }
}
let textualLocaleCalls = 0                  // 第二条独立路(覆盖用)
let commentLocaleMentions = 0               // ★ 注释里提到的,分开报
let commentNativeMentions = 0               // ★ 同上,维度③
for (const file of files) {
    const rel = relative(ROOT, file)
    if (rel.includes('database.types')) continue
    const src = readFileSync(file, 'utf8')
    if (BLIND !== 'text') {
        // ★★【维度③ 第一版也是【连注释一起数】的,而它当场咬了本刀自己一口】★★
        //   `lib/dates.ts` 的抬头新写了一段注释,里面提到 `<input type="date">` ——
        //   于是这一维从 144 涨到 145,报「原生日期控件变多了」。
        //   ☞ **这是同一个形状在这一刀里的第【五】次**(CONFIRM-1 / ALERT-1 记过三次,
        //     本刀的 toLocale* 计数是第四次,这里是第五次)。
        //   而它每一次的解药都一样:**数之前把注释剥掉,并把注释数分开报。**
        const rawNative = new RegExp(`\\btype=["'](${KIND_ALT})["']`, 'g')
        commentNativeMentions += (src.match(rawNative) || []).length - (blankComments(src).match(rawNative) || []).length
        textualLocaleCalls += (blankComments(src).match(/\.toLocale(Date|Time)?String\s*\(/g) || []).length
        commentLocaleMentions += (src.match(/\.toLocale(Date|Time)?String\s*\(/g) || []).length
            - (blankComments(src).match(/\.toLocale(Date|Time)?String\s*\(/g) || []).length
    }
}

// ════════════════════════════════════════════════════════════════════════════
// ── 覆盖断言:★ 两条【互相独立】的路数同一个总体 ────────────────────────────
// 一个瞎掉的棘轮必须说「我瞎了」,不许说「干净」——
// 而 AGENTS.md 明写这条法则**不是**"把 N 写进基线":要的是
// **同一次运行里的第二条独立路径**,不是上一次运行的记忆。
// ════════════════════════════════════════════════════════════════════════════
assertPopulation('check-date-format', 'app/ lib/ 下解析成功的源码', parsed, 500)
assertPopulation('check-date-format', 'AST 走过的 CallExpression', astCalls, 5000)
// ★ DATE-PICK-1:原生日期控件的总体【应当】是零,所以它不能再当覆盖的证据 ——
//   覆盖改由三件事证明:金丝雀被两条路都数出来了(上面,已经过了);两条路都看见了几百个 type= 属性;
//   两条路都数到了 ≥ 100 个选择器调用点(那 134 处搬去的地方)。
assertPopulation('check-date-format', '语法树看见的 JSX type= 属性', astTypeAttrs, 500)
assertPopulation('check-date-format', '字符看见的 type= 属性', textTypeAttrs, 500)
assertPopulation('check-date-format', '语法树数出的日期选择器调用点', astPickers, 100)
assertPinned('check-date-format', '日期选择器调用点:语法树 ↔ 字符', astPickers, textPickers,
    '对不上说明其中一条路瞎了一半 —— 而瞎掉的那一半可能正好装着一个原生控件。')
assertPinned('check-date-format', '原生日期控件:语法树 ↔ 字符', nativeInputs, textNatives,
    '两条路对原生控件的计数不同 —— 其中一条看不见某一种写法。先查是哪一条,再看判词。')

// 路 A:AST 数 toLocale*String 调用(含豁免的,否则两条路口径不同)
let astLocaleAll = 0
for (const file of files) {
    const rel = relative(ROOT, file)
    if (rel.includes('database.types')) continue
    const src = readFileSync(file, 'utf8')
    const sf = ts.createSourceFile(rel, src, ts.ScriptTarget.Latest, true,
        rel.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
    const v = (n) => {
        if (BLIND !== 'ast' && ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
            && LOCALE_CALLS.has(n.expression.name.getText())) astLocaleAll++
        ts.forEachChild(n, v)
    }
    v(sf)
}
// 路 B:正则数同一件事。两条路【一个走语法树、一个走字符】,互不依赖。
assertPinned('check-date-format', 'toLocale*String:AST 数出的 ↔ 文本数出的',
    astLocaleAll, textualLocaleCalls,
    '对不上说明其中一条路瞎了 —— 而一条瞎掉的路会安静地让棘轮放行。')

// ── 基线 ────────────────────────────────────────────────────────────────────
const snapshot = {
    note: '★ 不要为了让门变绿而刷新基线。先确认每一处新增是不是真的该留。',
    nativeDateInputs: 0,
    sites: Object.fromEntries(Object.entries(counts).sort((a, b) => a[0].localeCompare(b[0]))),
}

if (process.argv.includes('--update-baseline')) {
    writeFileSync(BASELINE, JSON.stringify(snapshot, null, 2) + '\n')
    console.log(`✓ 基线已刷新:${Object.keys(counts).length} 个〈文件 · 类型〉`
        + ` · 原生日期控件 ${nativeInputs} 处`)
    process.exit(0)
}

let base
try { base = JSON.parse(readFileSync(BASELINE, 'utf8')) } catch {
    console.error('✗ check-date-format:读不到 scripts/date-format-baseline.json。')
    console.error('  ★ 读不到【不是】一份空基线 —— 那会把历史债当成今天的新增,')
    console.error('    也会让 `type="date"` 那一维从 0 起步,于是它永远不会红。')
    console.error('  头一次生成:node scripts/check-date-format.mjs --update-baseline')
    process.exit(2)
}

const added = []
for (const [k, n] of Object.entries(counts)) {
    const was = base.sites?.[k] ?? 0
    if (n > was) added.push({ k, was, now: n })
}
const gone = Object.keys(base.sites ?? {}).filter((k) => (counts[k] ?? 0) < base.sites[k])

// 维度 ③:DATE-PICK-1 起是零,不看基线(基线里那一格钉成 0,只是给读基线的人看)
const nativeGrew = nativeInputs > 0

console.log(`check-date-format:解析 ${parsed} 份源码 · CallExpression ${astCalls} 个`)
console.log(`  维度①② 在册 ${Object.values(counts).reduce((a, b) => a + b, 0)} 处`
    + `(${Object.keys(counts).length} 个〈文件 · 类型〉)`)
console.log(`  维度③  原生日期控件 ${nativeInputs} 处(判据:零)· 语法树 ${nativeInputs} = 字符 ${textNatives}`
    + ` · 选择器调用点 ${astPickers} = ${textPickers} · type= 属性 ${astTypeAttrs} / ${textTypeAttrs} · 金丝雀 ✓`)
console.log(`  toLocale*String:调用点 ${textualLocaleCalls} 处 · ★ 另有【注释里提到】${commentLocaleMentions} 处`)
console.log(`  原生日期控件   :代码里 ${nativeInputs} 处 · ★ 另有【注释里提到】${commentNativeMentions} 处`)
console.log(`           (两个数分开报 —— 只报一个总数的勘察,读者无从知道它数的是代码还是散文)`)

if (gone.length) {
    console.log('· 少了几处 —— 有人改好了。基线可以收紧:')
    for (const k of gone) console.log(`     ${k}   ${base.sites[k]} → ${counts[k] ?? 0}`)
}

let bad = false
if (added.length) {
    bad = true
    console.error('')
    console.error('✗ 【新增】了走样的日期格式化:')
    for (const a of added) {
        console.error(`   ${a.k}   (在册 ${a.was} 处,现在 ${a.now} 处)`)
        for (const d of detail.filter((x) => `${x.rel} :: ${x.kind}` === a.k)) {
            console.error(`      第 ${d.line} 行: ${d.text}`)
        }
    }
    console.error('')
    console.error('【怎么改】日期显示走 lib/dates.ts:')
    console.error('   formatDate(v, locale)       单据日期  → 01 Sep 2026 / 2026年9月1日')
    console.error('   formatDateTime(v, locale)   带时刻    → 01 Sep 2026 14:33')
    console.error('   formatAuditStamp(v)         审计戳    → 2026-09-01 14:33(不随语言变)')
    console.error('   toYmd(v) / toYearMonth(v)   ★ 给机器的:控件 value、URL 过滤、FormData')
    console.error('☞ toLocale*String 随【浏览器】的 locale 变,不随界面语言变 ——')
    console.error('  那正是 Tim 抱怨的「同一个日期读出三种样子」里的第二种。')
}
if (nativeGrew) {
    bad = true
    console.error('')
    console.error(`✗ 原生日期 / 月份 / 日期时间控件 ${nativeInputs} 处 —— DATE-PICK-1 之后这一维的判据是【零】:`)
    for (const d of nativeDetail) console.error(`   ${d.rel}:${d.line}  ${d.how}`)
    console.error('  ☞ 改用 app/components/ui/date-picker.tsx 的 <DatePicker>(kind="month" / kind="datetime"):')
    console.error('    框里是 DD/MM/YYYY、周一开头的月历、敲错的日子拦住提交,表单收到的仍是 ISO。')
    console.error('  ★ 原生日期框按【操作系统 locale】画它的字,CSS 够不到、JS 改不了 —— 那正是 Tim 抱怨的「三种样子」之一。')
}
if (bad) process.exit(1)

console.log('✓ 没有【新增】走样的日期格式化;原生日期控件没有变多')
console.log('')
console.log('⚠ 而这句绿【不】等于「屏幕上的日期是统一的」——')
console.log('  一个什么都不写的新页面(`{row.order_date}`)照样把库原值印上屏,')
console.log('  它一行都不匹配本闸。治本那条路(BrandedDate)立案在')
console.log('  docs/known-issues.md 的 DATE1-BRANDED-DATE-DEBT,连着它为什么不在这一刀里做。')
