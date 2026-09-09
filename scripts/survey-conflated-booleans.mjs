#!/usr/bin/env node
// ==========================================================================
// 【瞄准 · AIM】
//   我读的是      :app/ 下的 TypeScript AST(合取/析取式 + 跨组件的污点传播),
//                   外加一条**宽口径全文**交叉核对。
//   我声称管的是   :「权限与记录状态混在一个布尔里」的那一族,分桶计数。
//   两者不同之处   :★ **两条臂看的不是同一个总体:交叉核对只扫 `&&`,AST 两个运算符都看。**
//                   于是那把本该当超集用的粗筛子,**结构上看不见 `||` 那一半** ——
//                   实测今天恰好 1 处(WorkOrderActions.tsx)。
//                   ☞ NARROW-COVERAGE-1 把这条差额**钉住**了(见文件末尾断言 ③)。
//                   ★ 另外两条【已登记、本刀没有修】:`STATE_FIELD` 的词边界漏掉
//                     `retention_state` 与 `reviewType`(改词表会移动分桶数,而那
//                     是 ALERT-2d 的收工读数)。见 NARROW-COVERAGE-2。
//   ☞ 【本文件是普查,不是闸】它的红是【给读数的人的一句话】(这一次读数不可信),
//     不是一道拦住构建的门 —— 它不在 npm run build 里,也不该进去:
//     普查报的是【数】不是【违规】,接进构建会把基线漂移变成构建红,
//     而那种红会被 --update-baseline 顺手按掉。(R-Q4)

// ==========================================================================
// ════════════════════════════════════════════════════════════════════════════
// ALERT-2c(2026-09-08)· 量【权限与记录状态混在一个布尔里】的那一族
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么不是一条正则】ALERT-2a 用的是 `perm && [^&]*state`,而 `[^&]*`
//   跨不过第二个 `&&`。于是
//     app/hr/kpi/score/page.tsx  `mayScore && !!chosen && !locked && ...`
//     app/sales/quotes/[id]/page.tsx `canEdit && !isConverted && !isDeclined`
//   这两个教科书式的实例【从判据底下溜过去】,而它数出来的 13 因此只是一个下界。
//   ☞ 本脚本走 AST:整条合取式一次求值,并且【跟着 prop 跨文件走】——
//     一个在服务端页面里算出来、当 prop 传下去的布尔,与写在原地的那一个
//     是同一处缺陷(DBLOCK-1 当场修的两处正是这个形状)。
//
// 【四个桶,而第四个是这次新分出来的】(Tim 在 ALERT-2c 第一轮闸上裁定)
//   ① 权限 × 记录状态          —— 在 PIECE 2 范围内,改法是拆成两个 prop
//   ② 纯记录状态                —— 不在范围内
//   ③ 纯权限                    —— 不在范围内(它正是 PermissionGate 该挂的形状)
//   ④ 还掺着【第三种东西】      —— 在范围内,但【两个 prop 的改法不适用】
//      第三种 = 既不是权限也不是记录状态:`!!chosen`(还没选月份)、
//      `isPending`(瞬态)、`rows.length > 0`(空表)。
//      给"还没选月份"写一句权限或状态的话都是假话 —— 它要的是空态,不是拒绝。
//
// ★【覆盖率自己必须是一条断言】★(本仓库的房规,check-confirm-subject 判据④)
//   一个悄悄漏抓的解析器和一棵干净的树,输出【一模一样】,都是 EXIT 0。
//   所以本脚本:
//     · 断言磁盘上找到的文件数 == 真正解析成功的文件数;
//     · 跑一条【独立的交叉核对】,机制与主 pass 不同(见下),两者不一致就红;
//     · 提供 --inject=<cell> 故障注入,把解析器弄瞎,确认这一跑【会红】。
//
// ★【交叉核对为什么算独立 —— 它的失败方式不一样】★
//   主 pass:AST + 【出处】判权限(顺着 `can()` 的赋值与 prop 传递做污点传播)。
//     它的失败方式是【跟丢一次 prop 传递】。
//   交叉核对:不建 AST,把注释与字符串整体剥掉之后在【全文】上做括号配平取合取式,
//     并且用【命名约定】判权限(can* / may* / allowed / 权限码字面量)。
//     它的失败方式是【一个名字起得不像权限的布尔】。
//   ☞ 两者都【不是行式的】—— 委托书点名的那个 311/470 陷阱正是行式工具撞的:
//     一条跨行的合取式,行式工具看见的是两个半截。本脚本两条路都在全文上走。
//
// 用法:
//   node scripts/survey-conflated-booleans.mjs            # 报告 + 覆盖率断言
//   node scripts/survey-conflated-booleans.mjs --list     # 逐站点列出
//   node scripts/survey-conflated-booleans.mjs --inject=blind-parser
//   node scripts/survey-conflated-booleans.mjs --inject=blind-taint
// ════════════════════════════════════════════════════════════════════════════

import ts from 'typescript'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative, dirname, resolve } from 'node:path'

const ROOT = process.cwd()
const SCAN_DIRS = ['app']
const ARGS = process.argv.slice(2)
const LIST = ARGS.includes('--list')
const INJECT = (ARGS.find((a) => a.startsWith('--inject=')) || '').split('=')[1] || ''
// --why=<file>::<name> —— 打印某个绑定/形参【为什么】被判成权限。
// 这个开关是本刀自己需要的:AmendOrderForm 的 `status` 一度被判成权限,
// 而靠读代码猜不出那条污点边在哪。一条查不出出处的判据,不配拿来数数。
const WHY = (ARGS.find((a) => a.startsWith('--why=')) || '').split('=').slice(1).join('=') || ''

// ── 权限的【种子】:lib/permissions.ts 真正导出的那几个 ──────────────────────
// 不是猜的名字 —— 这张表对着 `grep '^export' lib/permissions.ts` 抄下来。
const PERM_CALLS = new Set([
    'can', 'canViewPrices', 'canViewPay', 'canViewIdentity',
    'canViewBanking', 'canManagePermissions', 'getMyPermissions',
])
// 权限码字面量的形状(`module.finance.edit` / `data.view_prices` / `action.*`)
const PERM_CODE = /['"](?:module|data|action)\.[a-z_]+(?:\.[a-z_]+)?['"]/

// ── 记录状态的形状 ──────────────────────────────────────────────────────────
// 【为什么是"和一个字面量比"而不是一张字段名单】一张名单永远漏字段;
// 而"这个布尔是拿一条记录的字段去和一个常量比出来的"是这一族的真实长相。
const STATE_FIELD = /\b(status|state|locked|locked_at|posted|posted_at|closed|closed_at|approved|approved_at|submitted|voided|void_at|cancelled|canceled|deleted_at|is_active|active|month_locked|frozen|issued|converted|declined|paid|paid_at|settled|reversed|finalized)\b/i
const STATE_SUFFIX = /\.\w*_at\b/

// ── 【"这一行是不是我的"】也是一次权限答复,不是"第三种东西" ──────────────────
// `isReviewer = myEmployeeId !== null && r.reviewer_employee_id === myEmployeeId`
// 判的是【关系授权】:你能不能写这一行,取决于你是不是这一行点名的那个人。
// 它和 `can('module.hr.edit')` 是同一个问题的两种答法 —— 被它挡住的人
// 【不是】"再等等流程",而是"这件事不归你"。所以它算权限。
// ☞ 不这样算的后果是具体的:委托书点名的旗舰站点
//   `canEditGoals={canWrite && r.status === 'draft'}`(canWrite = canHrEdit || isReviewer)
//   会因为 isReviewer 被判成第三种东西而从桶 ① 掉进桶 ④ ——
//   而 known-issues 的 DBLOCK-CONFLATED-BOOLEANS 正是拿它当"权限×状态"的样板。
const ACTOR = /\b(uid|myEmployeeId|myUserId|currentUserId|meId|myId)\b/

const files = []
for (const d of SCAN_DIRS) walk(join(ROOT, d))
function walk(dir) {
    for (const e of readdirSync(dir)) {
        if (e === 'node_modules' || e === '.next' || e === '.git') continue
        const p = join(dir, e)
        if (statSync(p).isDirectory()) walk(p)
        else if (/\.tsx?$/.test(p) && !/\.d\.ts$/.test(p)) files.push(p)
    }
}

// ── 解析 ────────────────────────────────────────────────────────────────────
// ★★【语法树必须来自 Program 本身】★★ 头一版另起一次 ts.createSourceFile,
//   然后拿那些节点去问 program 的 checker —— **检查器不认识别人家的节点**,
//   于是 325 次询问答出 0 个 boolean,污点传播被整条掐断(轮数 = 1)。
//   报告照样打印,数字照样好看。**是那条"检查器自己也要被证明是活的"断言
//   把它顶出来的** —— 覆盖率断言这一条房规,这一刀自己付了一次学费。
const tsconfigPath = join(ROOT, 'tsconfig.json')
const rawCfg = ts.readConfigFile(tsconfigPath, ts.sys.readFile)
const parsedCfg = ts.parseJsonConfigFileContent(rawCfg.config, ts.sys, ROOT)
const program = ts.createProgram(files, { ...parsedCfg.options, noEmit: true, skipLibCheck: true })
const checker = program.getTypeChecker()

const parsed = new Map()   // abs path -> { src, sf }
for (const f of files) {
    const src = readFileSync(f, 'utf8')
    // ★ 注入格 blind-parser:按 JSON 解析 .tsx —— 语法树还在,但里面什么都没有。
    //   这正是"解析器悄悄漏抓"的样子,而覆盖率断言必须咬住它。
    const sf = INJECT === 'blind-parser'
        ? ts.createSourceFile(f, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.JSON)
        : program.getSourceFile(f)
    if (sf) parsed.set(f, { src, sf })
}

const rel = (f) => relative(ROOT, f)
const lineOf = (sf, node) => sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1
const txt = (n) => n.getText().replace(/\s+/g, ' ').trim()

// ════════════════════════════════════════════════════════════════════════════
// PASS A —— 每个文件里的布尔绑定 + 组件形参
// ════════════════════════════════════════════════════════════════════════════
const bindings = new Map()      // `${file}::${name}` -> expression text
const bindNode = new Map()      // `${file}::${name}` -> 声明节点(给类型检查器用)
const paramsOf = new Map()      // `${file}::${name}` -> Set(param names) 组件形参
const importMap = new Map()     // `${file}::${localName}` -> resolved abs file

function resolveImport(fromFile, spec) {
    if (!spec.startsWith('.') && !spec.startsWith('@/')) return null
    const base = spec.startsWith('@/') ? join(ROOT, spec.slice(2)) : resolve(dirname(fromFile), spec)
    for (const cand of [base + '.tsx', base + '.ts', join(base, 'index.tsx'), join(base, 'index.ts')]) {
        if (parsed.has(cand)) return cand
    }
    return null
}

for (const [f, { sf }] of parsed) {
    const visit = (n) => {
        // import 解析 —— 跨 prop 走的那一步靠它
        if (ts.isImportDeclaration(n) && ts.isStringLiteral(n.moduleSpecifier)) {
            const target = resolveImport(f, n.moduleSpecifier.text)
            if (target && n.importClause) {
                if (n.importClause.name) importMap.set(`${f}::${n.importClause.name.text}`, target)
                const nb = n.importClause.namedBindings
                if (nb && ts.isNamedImports(nb)) {
                    for (const el of nb.elements) importMap.set(`${f}::${el.name.text}`, target)
                }
            }
        }
        // const X = <expr>
        if (ts.isVariableDeclaration(n) && n.name && ts.isIdentifier(n.name) && n.initializer) {
            bindings.set(`${f}::${n.name.text}`, txt(n.initializer))
            bindNode.set(`${f}::${n.name.text}`, n.name)
        }
        // ★★【解构也是绑定 —— 这一条是本脚本自己漏抓过一次的地方】★★
        //   `const [canHrEdit, canSeePay] = await Promise.all([can('module.hr.edit'), ...])`
        //   是本仓库取权限的【主要写法】,而头一版只认 `ts.isIdentifier(n.name)`,
        //   于是 canHrEdit 从来没有被污染,canWrite = canHrEdit || isReviewer 跟着干净,
        //   `canEditGoals={canWrite && r.status === 'draft'}` —— 委托书点名的那一处 ——
        //   就这样从 AST 底下溜过去了。**与它要抓的缺陷是同一个形状的漏抓。**
        //   是交叉核对把它顶出来的(它按命名认 canWrite,不管出处),
        //   这正是"两条路必须失败得不一样"要买的东西。
        //   ★★【而它必须【按位】拆开 —— 这是本脚本第二次自己漏抓/错抓的地方】★★
        //     头一版把【整条初始化表达式】绑给每一个解构出来的名字,于是
        //     `const [rows, canEdit] = await Promise.all([supabase…, can('x')])`
        //     里的 `rows` 也含着 `can(`,跟着被判成权限。后果是一片
        //     **和权限调用【同排】取出来的业务数据**全被污染 ——
        //     AmendOrderForm 的 `status`、CloseReopenControls 的
        //     `unappliedPrepayment`、Participants 的 `assignable` 都是这样虚高的。
        //     一个虚高的数会让 PIECE 2 去拆一批纯状态的布尔,那比漏掉更坏。
        if (ts.isVariableDeclaration(n) && n.name && n.initializer &&
            (ts.isArrayBindingPattern(n.name) || ts.isObjectBindingPattern(n.name))) {
            // 剥掉 await,找到底下的 Promise.all([...]) 或数组/对象字面量
            let init = n.initializer
            if (ts.isAwaitExpression(init)) init = init.expression
            let elems = null
            if (ts.isCallExpression(init) && /Promise\.(all|allSettled)$/.test(init.expression.getText()) &&
                init.arguments.length === 1 && ts.isArrayLiteralExpression(init.arguments[0])) {
                elems = init.arguments[0].elements
            } else if (ts.isArrayLiteralExpression(init)) {
                elems = init.elements
            }
            if (elems && ts.isArrayBindingPattern(n.name)) {
                n.name.elements.forEach((el, i) => {
                    if (ts.isBindingElement(el) && ts.isIdentifier(el.name) && elems[i]) {
                        bindings.set(`${f}::${el.name.text}`, txt(elems[i]))
                        bindNode.set(`${f}::${el.name.text}`, el.name)
                    }
                })
            } else if (ts.isObjectLiteralExpression(init) && ts.isObjectBindingPattern(n.name)) {
                const byName = new Map()
                for (const pr of init.properties) {
                    if (pr.name && ts.isIdentifier(pr.name)) {
                        byName.set(pr.name.text, ts.isPropertyAssignment(pr) ? txt(pr.initializer) : pr.name.text)
                    }
                }
                for (const el of n.name.elements) {
                    if (ts.isBindingElement(el) && ts.isIdentifier(el.name)) {
                        const src = byName.get((el.propertyName && ts.isIdentifier(el.propertyName) ? el.propertyName.text : el.name.text))
                        if (src !== undefined) {
                            bindings.set(`${f}::${el.name.text}`, src)
                            bindNode.set(`${f}::${el.name.text}`, el.name)
                        }
                    }
                }
            }
            // ☞ 拆不开的形状(解构一个函数返回值、解构一个 props 对象)【不绑】。
            //   宁可少一条出处,也不要把一整排业务数据染成权限。
        }
        // 组件形参(解构式 props):function C({ a, b }) / const C = ({ a, b }) =>
        if ((ts.isFunctionDeclaration(n) || ts.isArrowFunction(n) || ts.isFunctionExpression(n)) && n.parameters.length) {
            const p0 = n.parameters[0]
            if (p0.name && ts.isObjectBindingPattern(p0.name)) {
                let cname = null
                if (ts.isFunctionDeclaration(n) && n.name) cname = n.name.text
                else if (n.parent && ts.isVariableDeclaration(n.parent) && ts.isIdentifier(n.parent.name)) cname = n.parent.name.text
                else if (ts.isExportAssignment(n.parent ?? {})) cname = 'default'
                if (ts.isFunctionDeclaration(n) && !n.name && n.modifiers?.some((m) => m.kind === ts.SyntaxKind.DefaultKeyword)) cname = 'default'
                const names = new Set()
                for (const el of p0.name.elements) {
                    if (ts.isBindingElement(el) && ts.isIdentifier(el.name)) {
                        names.add(el.name.text)
                        bindNode.set(`${f}::${el.name.text}`, el.name)
                    }
                }
                if (cname) paramsOf.set(`${f}::${cname}`, names)
                // default export 的组件在调用点用的是 import 的本地名,统一挂 'default'
                if (ts.isFunctionDeclaration(n) && n.modifiers?.some((m) => m.kind === ts.SyntaxKind.DefaultKeyword)) {
                    paramsOf.set(`${f}::default`, names)
                }
            }
        }
        ts.forEachChild(n, visit)
    }
    visit(sf)
}

// ════════════════════════════════════════════════════════════════════════════
// PASS B —— 权限污点传播(出处,不是命名),做到不动点
// ════════════════════════════════════════════════════════════════════════════
// ★★【污点扫标识符之前必须把【字面量】剥掉 —— 第三个自己踩的坑】★★
//   `.select('id, code, status, order_date, …')` 是一个【字符串】,可里面的
//   `code` / `status` 长得和标识符一模一样。头一版直接在绑定原文上扫标识符,
//   于是任何一条 select 里带 `code` 的查询,都被同名的已污染标识符染成权限;
//   `order` → `o` → `<AmendOrderForm status={o.status}>` → AmendOrderForm 的
//   `status` 成了"权限",四条纯状态的布尔跟着进了桶 ①。
//   ☞ 判权限【种子】时仍然要看原文(权限码本身就是字符串字面量),
//     判【标识符】时必须先剥。两件事,两种读法。
function stripLits(text) {
    let out = ''
    for (let i = 0; i < text.length; i++) {
        const c = text[i]
        if (c === "'" || c === '"' || c === '`') {
            for (i++; i < text.length; i++) {
                if (text[i] === '\\') { i++; continue }
                if (text[i] === c) break
            }
            out += ' '
            continue
        }
        out += c
    }
    return out
}

// ════════════════════════════════════════════════════════════════════════════
// ★★★【污点只在【布尔】之间传 —— 这是第四个、也是最贵的一个自踩的坑】★★★
// ════════════════════════════════════════════════════════════════════════════
//   实测的污点链(--why 打出来的):
//     canSeeFinance(真权限)→ invLines(一批发票行)→ liveInvoices → invCodeById
//     → code → o → `<AmendOrderForm status={o.status}>` → AmendOrderForm 的 status
//   于是 `!isDraft && !addOnly && status !== 'confirmed' && …` ——
//   **四条纯记录状态的布尔** —— 整条进了桶 ①。
//   两条错都在同一个根上:**污点顺着【不是布尔的东西】爬**。
//     ① 一批【受权限影响的数据】不是【一个权限答复】。
//        "这些发票行你看不到"和"这个钮你按不了"是两件事。
//     ② `order as unknown as { id: string; code: string; … }` 里的 `code`
//        是一个【类型注解上的属性名】,不是一次值引用 —— 文本扫标识符分不出来。
//   ☞ 药是【真的类型检查器】,不是又一条正则:只有当目标绑定的类型确实是
//     boolean 时才让污点过去。类型注解、数组、Map、字符串因此一次全部出局。
let __boolProbe = 0, __probeTotal = 0
function isBooleanish(key) {
    __probeTotal++
    const node = bindNode.get(key)
    if (!node) return true            // 看不到声明就不拦(宁可多一条,也不要凭猜少一条)
    try {
        const t = checker.getTypeAtLocation(node)
        const s = checker.typeToString(t)
        const ok = /\bboolean\b/.test(s) || s === 'true' || s === 'false'
        if (ok) __boolProbe++
        return ok
    } catch { return true }
}

const permTainted = new Set()   // `${file}::${name}`

function seedsPermission(exprText) {
    if (INJECT === 'blind-taint') return false     // ★ 注入格:把种子拿掉
    if (PERM_CODE.test(exprText)) return true
    for (const c of PERM_CALLS) {
        if (new RegExp(`\\b${c}\\s*\\(`).test(exprText)) return true
    }
    return false
}

for (const [key, expr] of bindings) if (seedsPermission(expr)) permTainted.add(key)

let changed = true
let rounds = 0
while (changed && rounds < 25) {
    changed = false
    rounds++
    // (i) 局部:一个绑定引用了已污染的标识符
    for (const [key, expr] of bindings) {
        if (permTainted.has(key)) continue
        const file = key.split('::')[0]
        for (const id of stripLits(expr).matchAll(/\b[A-Za-z_$][A-Za-z0-9_$]*\b/g)) {
            if (permTainted.has(`${file}::${id[0]}`)) {
                if (!isBooleanish(key)) break        // 不是布尔,污点到此为止(见抬头)
                permTainted.add(key); changed = true
                if (WHY && key.includes(WHY)) console.log(`[why] ${key}  ←  局部绑定引用了已污染的 ${id[0]}:  ${expr.slice(0, 100)}`)
                break
            }
        }
    }
    // (ii) 跨 prop:<Comp p={已污染的表达式}> ⇒ Comp 那个文件里的形参 p 也污染
    for (const [f, { sf }] of parsed) {
        const visit = (n) => {
            if (ts.isJsxAttribute(n) && n.name && ts.isIdentifier(n.name) && n.initializer &&
                ts.isJsxExpression(n.initializer) && n.initializer.expression) {
                const tag = n.parent?.parent
                let tagName = null
                if (tag && (ts.isJsxSelfClosingElement(tag) || ts.isJsxOpeningElement(tag))) {
                    tagName = tag.tagName.getText()
                }
                if (tagName) {
                    const e = txt(n.initializer.expression)
                    let tainted = seedsPermission(e)
                    if (!tainted) {
                        for (const id of stripLits(e).matchAll(/\b[A-Za-z_$][A-Za-z0-9_$]*\b/g)) {
                            if (permTainted.has(`${f}::${id[0]}`)) { tainted = true; break }
                        }
                    }
                    if (tainted) {
                        const target = importMap.get(`${f}::${tagName}`)
                        if (target) {
                            for (const cname of [tagName, 'default']) {
                                const params = paramsOf.get(`${target}::${cname}`)
                                if (params && params.has(n.name.text)) {
                                    const k = `${target}::${n.name.text}`
                                    if (!permTainted.has(k) && isBooleanish(k)) {
                                        permTainted.add(k); changed = true
                                        if (WHY && k.includes(WHY)) {
                                            console.log(`[why] ${k}  ←  <${tagName} ${n.name.text}={${e}}>  在 ${rel(f)}`)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            ts.forEachChild(n, visit)
        }
        visit(sf)
    }
}

// ════════════════════════════════════════════════════════════════════════════
// PASS C —— 展开每一条合取式,给每个操作数分类
// ════════════════════════════════════════════════════════════════════════════
// ════════════════════════════════════════════════════════════════════════════
// 分类 —— 返回一个【类别集合】,不是单一类别
// ════════════════════════════════════════════════════════════════════════════
// ★★【为什么是集合,以及为什么展开只走"裸标识符"这一条边】★★
//   头一版做两件错事,两件都是手工核对着源码抓出来的:
//
//   ① 展开时把标识符的绑定【无差别】拼进文本再做正则,于是
//      `!!chosen`(chosen = cycles.find(c => c.id === chosenId))
//      把 `cycles` 那条 select 的文本(里面有 locked_at / status)一并拖进来,
//      被判成"记录状态"。**可 `!!chosen` 的意思是【还没选月份】** ——
//      它既不是权限也不是记录状态,正是 Tim 裁定的第 ④ 桶。
//      委托书点名的旗舰例子被自己的分类器放错了桶。
//      ☞ 所以:**只有当操作数是一个【裸标识符】(可带 ! / !!)时才顺着绑定往下走。**
//        `x.locked_at`、`x.status === 'closed'` 这种带属性/比较的,就地判,不展开 ——
//        否则 `locked = !!chosen?.locked_at` 会把 chosen 的"选择"含义也吸进来。
//
//   ② 复合布尔只给一个类别。`showForm = canEdit && (state === 'unexplained' || editing)`
//      同时是权限、记录状态、和一个瞬态开关;压成一个类别,
//      `canEdit && !showForm && state !== 'fromPo'` 就会被算成【干净的两类混合】,
//      而它其实是三类。**桶 ① 和桶 ④ 的分界正好卡在这里。**
const CATS_DEPTH = 8
function catsOfNode(file, node, depth = 0, seen = new Set()) {
    const out = new Set()
    if (depth > CATS_DEPTH) return out
    let n = node
    while (ts.isParenthesizedExpression(n)) n = n.expression
    // ! / !! —— 极性不改变"这句话在说什么",穿过去
    while (ts.isPrefixUnaryExpression(n) && n.operator === ts.SyntaxKind.ExclamationToken) n = n.operand
    while (ts.isParenthesizedExpression(n)) n = n.expression

    // 链:类别取【并集】
    if (ts.isBinaryExpression(n) &&
        (n.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken ||
         n.operatorToken.kind === ts.SyntaxKind.BarBarToken)) {
        for (const c of catsOfNode(file, n.left, depth + 1, seen)) out.add(c)
        for (const c of catsOfNode(file, n.right, depth + 1, seen)) out.add(c)
        return out
    }

    const own = txt(n)
    if (seedsPermission(own)) out.add('PERM')
    for (const m of stripLits(own).matchAll(/\b[A-Za-z_$][A-Za-z0-9_$]*\b/g)) {
        if (permTainted.has(`${file}::${m[0]}`)) out.add('PERM')
    }

    // ★ 关系授权("这一行是不是我的")要在【顺绑定往下走之前】判 ——
    //   否则 `!!myEmployeeId` 会先被它的绑定(一次查询)答成 OTHER 就返回了。
    if (ACTOR.test(own)) out.add('PERM')

    // 裸标识符 → 顺着它的绑定往下走一层(唯一一条展开边,见抬头 ①)
    if (ts.isIdentifier(n)) {
        const key = `${file}::${n.text}`
        const b = bindings.get(key)
        if (b && !seen.has(key)) {
            seen.add(key)
            try {
                const tmp = ts.createSourceFile('t.tsx', `(${b})`, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
                const st = tmp.statements[0]
                if (st && ts.isExpressionStatement(st)) {
                    for (const c of catsOfNode(file, st.expression, depth + 1, seen)) out.add(c)
                }
            } catch { /* 解析不动就按叶子处理 */ }
        }
        if (out.size) return out
    }

    // 叶子:判记录状态
    if (STATE_SUFFIX.test(own) || STATE_FIELD.test(own)) out.add('STATE')
    if (!out.size) out.add('OTHER')
    return out
}

const CONTROL = /<(?:button|form|input|select|textarea|Button|ConfirmButton|PermissionGate|EditableTable|AddRowPanel|Link)\b/

// ── 预扫:每个文件里【真的落在控件闸位上】的那些标识符 ──────────────────────
// 【为什么需要它】`const { data } = canX && ids.length ? await query : []` 里,
//   那条布尔挡的是【一次查询】,不是一个控件 —— 而"先问权限再决定读不读"
//   正是本仓库明文规定的做法(app/hr/payroll/page.tsx:50 那段注释)。
//   把它算成缺陷,数就虚高;而虚高的数会让 PIECE 2 去拆一批不该拆的布尔。
//   所以「存成一个变量」只有在【那个变量真的走到控件闸上】时才算闸位。
const gateNames = new Map()   // file -> Set(identifier)
for (const [f, { sf }] of parsed) {
    const names = new Set()
    const add = (node) => {
        for (const m of txt(node).matchAll(/\b[A-Za-z_$][A-Za-z0-9_$]*\b/g)) names.add(m[0])
    }
    const visit = (n) => {
        if (ts.isJsxAttribute(n) && n.name && ts.isIdentifier(n.name) && n.initializer &&
            ts.isJsxExpression(n.initializer) && n.initializer.expression &&
            /^(disabled|allowed|readOnly|editable|hidden|can[A-Z]|may[A-Z]|is[A-Z]\w*Allowed)/.test(n.name.text)) {
            add(n.initializer.expression)
        }
        if (ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken &&
            CONTROL.test(txt(n.right))) add(n.left)
        if (ts.isConditionalExpression(n) && CONTROL.test(txt(n))) add(n.condition)
        if (ts.isIfStatement(n) && n.thenStatement) {
            const b = txt(n.thenStatement)
            if (/return\s+null/.test(b) || CONTROL.test(b)) add(n.expression)
        }
        ts.forEachChild(n, visit)
    }
    visit(sf)
    gateNames.set(f, names)
}

// ════════════════════════════════════════════════════════════════════════════
// 闸位 —— 这条布尔是不是真的在【挡一个控件】
// ════════════════════════════════════════════════════════════════════════════
// ★★【三个盲点,全是交叉核对顶出来的,记在这里免得下一个人再踩】★★
//   ① `disabled={pending || !canFinance || !date}` —— 【或】不是【与】。
//      按德摩根它等价于 `enabled = !pending && canFinance && date`:
//      **同一个缺陷的反极性写法**。头一版只认 `&&`,于是
//      app/hr/claims/[id]/ClaimControls.tsx:69 整条溜过去。
//   ② `if (!showProbation && !canPay) return null` —— 【藏】也是一道闸,
//      而且按 DBLOCK-1 的裁定是最坏的那一种(它教人"这个功能不存在")。
//   ③ 三元的【条件位】:`cond ? <button> : <p>`。
function isGate(node, file) {
    let p = node.parent
    while (p && ts.isBinaryExpression(p) &&
           (p.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken ||
            p.operatorToken.kind === ts.SyntaxKind.BarBarToken)) p = p.parent
    while (p && ts.isParenthesizedExpression(p)) p = p.parent
    if (!p) return false

    if (CONTROL.test(txt(node.parent ?? node))) return true
    if (ts.isConditionalExpression(p) && CONTROL.test(txt(p))) return true
    if (ts.isIfStatement(p) && p.thenStatement) {
        const b = txt(p.thenStatement)
        if (/return\s+null/.test(b) || CONTROL.test(b)) return true
    }
    let q = node.parent
    for (let i = 0; i < 5 && q; i++, q = q.parent) {
        if (ts.isJsxAttribute(q) && q.name && ts.isIdentifier(q.name)) {
            if (/^(disabled|allowed|readOnly|editable|hidden|can[A-Z]|may[A-Z]|is[A-Z]\w*Allowed)/.test(q.name.text)) return true
        }
        // 存成一个布尔 —— 只有当这个名字【真的走到控件闸上】才算(见 gateNames 抬头)
        if (ts.isVariableDeclaration(q) && q.name && ts.isIdentifier(q.name)) {
            return (gateNames.get(file) ?? new Set()).has(q.name.text)
        }
    }
    return false
}

const chains = []
let OP = ts.SyntaxKind.AmpersandAmpersandToken
for (const [f, { sf }] of parsed) {
    // ★★【括号里的操作数要【钻进去】,不要丢掉 —— ALERT-2d 的仪器修正】★★
    //   头一版把 ParenthesizedExpression 原样 push 出来,再被下面那句 filter
    //   整个丢掉。于是 `perm && (a || b)` 展开成【一个】操作数,parts.length < 2,
    //   **整条链一次都没有进过 chains** —— 不是分错桶,是【结构上看不见】。
    //   而那正是委托书点名的旗舰形状:hr/reviews/[id]/page.tsx 的
    //   `canAssess={canWrite && (r.status === 'draft' || r.status === 'self_review')}`。
    //   ☞ 修法:先剥括号再判。剥出来的若还是同一个运算符,继续摊平;
    //     若是【另一个】运算符(`&&` 里套 `||`),把它整个当一个操作数交给
    //     catsOfNode —— 它对链取类别【并集】,这正是"一个操作数里裹着几类"
    //     该有的读法(桶 ① 与桶 ④ 的分界就卡在这上面)。
    const flat = (n, acc = []) => {
        while (ts.isParenthesizedExpression(n)) n = n.expression
        if (ts.isBinaryExpression(n) && n.operatorToken.kind === OP) {
            flat(n.left, acc); flat(n.right, acc)
        } else acc.push(n)
        return acc
    }
    const visit = (n) => {
        // ★ 【与】和【或】都要看:或是同一个缺陷的反极性写法(德摩根),见 isGate 抬头
        if (ts.isBinaryExpression(n) &&
            (n.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken ||
             n.operatorToken.kind === ts.SyntaxKind.BarBarToken)) {
            OP = n.operatorToken.kind
            const p = n.parent
            const top = !(ts.isBinaryExpression(p) && p.operatorToken.kind === OP)
            if (top) {
                // ☞ `isParenthesizedExpression` 这一项【删掉了】:flat() 已经剥干净,
                //   留着它就是那条把括号操作数丢掉的判据本身。
                const parts = flat(n).filter((x) => !ts.isJsxElement(x) && !ts.isJsxFragment(x) &&
                                                    !ts.isJsxSelfClosingElement(x))
                if (parts.length >= 2) {
                    const catSets = parts.map((x) => catsOfNode(f, x))
                    const kinds = catSets.map((cs) => [...cs].sort().join('+'))
                    chains.push({
                        file: rel(f), line: lineOf(sf, n), text: txt(n).slice(0, 160),
                        parts: parts.map((x, i) => ({ t: txt(x), k: kinds[i] })),
                        kinds, gate: isGate(n, f),
                        op: OP === ts.SyntaxKind.BarBarToken ? '||' : '&&',
                    })
                }
            }
        }
        ts.forEachChild(n, visit)
    }
    visit(sf)
}

// ── 分桶 ────────────────────────────────────────────────────────────────────
const bucket = { 1: [], 2: [], 3: [], 4: [] }
for (const c of chains) {
    if (!c.gate) continue
    const all = new Set(c.kinds.join('+').split('+').filter(Boolean))
    const hasPerm = all.has('PERM')
    const hasState = all.has('STATE')
    const hasOther = all.has('OTHER')
    if (hasPerm && hasOther) bucket[4].push(c)            // ④ 掺了第三种东西
    else if (hasPerm && hasState) bucket[1].push(c)       // ① 权限 × 记录状态
    else if (hasPerm) bucket[3].push(c)                   // ③ 纯权限
    else if (hasState) bucket[2].push(c)                  // ② 纯记录状态
}

// ════════════════════════════════════════════════════════════════════════════
// 交叉核对 —— 不建 AST,全文剥字面量后括号配平;权限靠【命名约定】
// ════════════════════════════════════════════════════════════════════════════
function stripCommentsAndStrings(s) {
    let out = ''
    for (let i = 0; i < s.length; i++) {
        const c = s[i]
        if (c === '/' && s[i + 1] === '/') { while (i < s.length && s[i] !== '\n') i++; out += ' '; continue }
        if (c === '/' && s[i + 1] === '*') { i += 2; while (i < s.length && !(s[i] === '*' && s[i + 1] === '/')) i++; i++; out += ' '; continue }
        if (c === "'" || c === '"' || c === '`') {
            const q = c
            let lit = ''
            for (i++; i < s.length; i++) {
                if (s[i] === '\\') { i++; continue }
                if (s[i] === q) break
                lit += s[i]
            }
            // 权限码字面量要留下来,它是交叉核对判权限的一半证据
            out += /^(?:module|data|action)\.[a-z_.]+$/.test(lit) ? `"${lit}"` : ' '
            continue
        }
        out += c
    }
    return out
}
const XPERM_NAME = /\b(can[A-Z]\w*|may[A-Z]\w*|allowed|isAllowed|hasPermission|canWrite|canEdit|canPay|canClose|canProduce|canScore)\b/
const xChains = []
for (const [f, { src }] of parsed) {
    // ★ 全文(不是逐行):把换行折成空格,跨行的合取式因此不会被切成两半 ——
    //   委托书点名的 311/470 就是行式工具切出来的。
    const clean = stripCommentsAndStrings(src).replace(/\s+/g, ' ')
    let idx = 0
    while ((idx = clean.indexOf('&&', idx)) !== -1) {
        // 往左右各取一段,直到括号不平或撞上分隔符
        let l = idx, depth = 0
        for (let i = idx - 1; i >= 0; i--) {
            const c = clean[i]
            if (c === ')' || c === '}') depth++
            else if (c === '(' || c === '{') { if (depth === 0) break; depth-- }
            else if (depth === 0 && (c === ';' || c === ',' || c === '?')) break
            l = i
        }
        let r = idx + 2; depth = 0
        for (let i = idx + 2; i < clean.length; i++) {
            const c = clean[i]
            if (c === '(' || c === '{') depth++
            else if (c === ')' || c === '}') { if (depth === 0) break; depth-- }
            else if (depth === 0 && (c === ';' || c === ',' || c === '?')) break
            r = i + 1
        }
        const seg = clean.slice(l, r).trim()
        if (XPERM_NAME.test(seg) || PERM_CODE.test(seg)) xChains.push({ file: rel(f), seg: seg.slice(0, 160) })
        idx += 2
    }
}
// 交叉核对按【文件】聚合(它切不出准确的站点边界,聚到文件才是它能担保的粒度)
const xFiles = new Set(xChains.map((c) => c.file))
const astPermFiles = new Set([...bucket[1], ...bucket[3], ...bucket[4]].map((c) => c.file))

// ════════════════════════════════════════════════════════════════════════════
// 报告 + 覆盖率断言
// ════════════════════════════════════════════════════════════════════════════
const findings = []
console.log('── ALERT-2c · 权限/状态混合布尔普查 ──────────────────────────────')
console.log(`磁盘上的 .ts/.tsx(app/)      ${files.length}`)
console.log(`真正解析的                    ${parsed.size}`)
console.log(`布尔链(整条,AST,&&与||)   ${chains.length}`)
console.log(`其中落在闸位上的              ${chains.filter((c) => c.gate).length}`)
console.log(`污点传播轮数                  ${rounds}`)
console.log(`被判为权限的绑定/形参         ${permTainted.size}`)
console.log(`类型检查器认出的 boolean      ${__boolProbe} / ${__probeTotal} 次询问`)
console.log('')
console.log('  ① 权限 × 记录状态   (PIECE 2 范围内)      ' + bucket[1].length)
console.log('  ② 纯记录状态        (不在范围内)          ' + bucket[2].length)
console.log('  ③ 纯权限            (不在范围内)          ' + bucket[3].length)
console.log('  ④ 掺了第三种东西    (范围内,改法不同)    ' + bucket[4].length)
console.log('')
console.log(`交叉核对(全文/命名):命中文件 ${xFiles.size},AST 命中文件 ${astPermFiles.size}`)
const onlyX = [...xFiles].filter((f) => !astPermFiles.has(f))
const onlyA = [...astPermFiles].filter((f) => !xFiles.has(f))
console.log(`  只有交叉核对看见的文件 ${onlyX.length}`)
console.log(`  只有 AST 看见的文件   ${onlyA.length}`)

if (LIST) {
    for (const b of [1, 4, 3]) {
        console.log(`\n─── 桶 ${b} ─────────────────────────────────────────────`)
        for (const c of bucket[b]) {
            console.log(`${c.file}:${c.line}`)
            console.log(`   ${c.text}`)
            console.log(`   ${c.parts.map((p) => `${p.k}[${p.t.slice(0, 46)}]`).join(' && ')}`)
        }
    }
    console.log('\n─── 只有交叉核对看见的文件 ───')
    for (const f of onlyX) console.log('  ' + f)
    console.log('\n─── 只有 AST 看见的文件 ───')
    for (const f of onlyA) console.log('  ' + f)
}

// ── 断言 ①:解析覆盖 ────────────────────────────────────────────────────────
if (parsed.size !== files.length) findings.push(`解析覆盖不全:${files.length} 个文件,只解析了 ${parsed.size}`)
// ── 断言 ②:解析器没有被弄瞎(合取式为 0 或权限绑定为 0,都是"什么都没看见")
if (chains.length === 0) findings.push('AST 一条合取式都没找到 —— 解析器瞎了,不是树干净了')
if (permTainted.size === 0) findings.push('污点传播一个权限绑定都没找到 —— 种子瞎了,不是仓库里没有权限')
// ── 断言 ③:两条路必须互相看得见 ────────────────────────────────────────────
if (__probeTotal > 0 && __boolProbe === 0) findings.push('类型检查器一个 boolean 都没认出来 —— 它自己瞎了(污点会被整条掐断)')
if (xFiles.size === 0) findings.push('交叉核对一个文件都没命中 —— 它自己瞎了')
if (astPermFiles.size === 0) findings.push('AST 一个权限文件都没命中 —— 它自己瞎了')

// ★★【NARROW-COVERAGE-1(2026-09-09):这一条【钉住差额】,不再只断言两边非空】★★
//
// 上面那三条的说明写着「两条路必须互相看得见」,而它们实际断言的只是
// **两边都不为空**。实跑:交叉核对命中 78 个文件、AST 命中 5 个,
// **74 个文件的差额照常通过** —— 而 AST 那条臂若明天退化到只看见 1 个文件,
// 这三条仍然全绿。**与 check-confirm-subject 那条 `<` 同形:单向。**
//
// 【为什么不把 74 写成一个数】那个数随任何一次无关的增删文件而漂,
// 而一道天天假红的闸三刀之内会被人关掉(AGENTS.md 明写)。
// **要钉的不是那个数,是那条【结构不变量】:**
//
//     交叉核对是一次宽口径全文扫,所以它【应当是 AST 的超集】——
//     AST 精确地认出来的每一处,那把粗筛子都该命中。
//
// 【实测它今天【不成立】,而漏的那一处是有原因的、可以点名的】
//   `app/operation/orders/[id]/WorkOrderActions.tsx` 只有 AST 看得见。
//   原因:**交叉核对那条臂只扫 `&&`**(它逐字符找 `&&` 然后 `idx += 2`),
//   而该处是 `noPerm || (status !== 'draft' ? … : '')` —— 一个 `||`。
//   AST 那条臂**刻意两个运算符都看**(见 isGate 抬头:「或是同一个缺陷的
//   反极性写法(德摩根)」)。也就是说那把"粗筛子"**结构上看不见半个总体**,
//   而两条臂被写下来时是当作互相校验用的。
//
// 【所以断言下在【它能成立】的那一半上,并把另一半按名豁免】
//   凡是 AST 通过 `&&` 认出来的文件,交叉核对必须命中。一个都不许漏。
//   `||` 那一半按名列出 —— 名单变长就是一次发现,要么补上那条臂,要么说明理由。
//   ☞ 补 `||` 那条臂**不在本刀里**:它会改变 xFiles,而 `onlyX`/`onlyA` 两个数
//     是 ALERT-2d 的收工读数。已登记为 NARROW-COVERAGE-2。
const astAmpFiles = new Set(
    [...bucket[1], ...bucket[3], ...bucket[4]].filter((c) => c.op === '&&').map((c) => c.file)
)
const ampMissedByX = [...astAmpFiles].filter((f) => !xFiles.has(f))
if (ampMissedByX.length > 0) {
    findings.push(
        `交叉核对漏掉了 ${ampMissedByX.length} 个【AST 靠 && 认出来的】文件 —— ` +
        `那把粗筛子应当是 AST 的超集,漏了就说明它自己有洞:` +
        ampMissedByX.join(', ')
    )
}
// `||` 那一半:今天恰好 1 个,按名钉住。多一个少一个都要有人看一眼。
const OR_ONLY_KNOWN = ['app/operation/orders/[id]/WorkOrderActions.tsx']
const orOnly = [...astPermFiles].filter((f) => !xFiles.has(f) && !astAmpFiles.has(f))
const orOnlyUnexpected = orOnly.filter((f) => !OR_ONLY_KNOWN.includes(f))
const orOnlyVanished = OR_ONLY_KNOWN.filter((f) => !orOnly.includes(f))
if (orOnlyUnexpected.length) {
    findings.push(
        `又多了 ${orOnlyUnexpected.length} 个【只有 AST 看得见、且是 || 形状】的文件:` +
        `${orOnlyUnexpected.join(', ')} —— 交叉核对只扫 &&,这一族它结构上看不见。` +
        `要么给它补上 ||,要么把这个文件写进 OR_ONLY_KNOWN 并说明理由。`
    )
}
if (orOnlyVanished.length) {
    findings.push(
        `OR_ONLY_KNOWN 里 ${orOnlyVanished.length} 条今天命不中:${orOnlyVanished.join(', ')} —— ` +
        `那一处改好了(请删掉这一条),或者 AST 那条臂瞎了。两种都要红。`
    )
}

if (findings.length) {
    console.log('\n✗ 覆盖率断言失败:')
    for (const f of findings) console.log('  · ' + f)
    process.exit(1)
}
console.log('\n✓ 覆盖率断言通过')
