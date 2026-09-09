#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// CONFIRM-1(2026-09-06)· 【一个 subject 只有类型是守不住的】
// ════════════════════════════════════════════════════════════════════════════
// ConfirmContent.subject 是必填 prop,编译器会拦住"不写"。可它拦不住
// 【写了等于没写】—— 而这三种写法,正是本刀开工前那 40 处的实际长相:
//
//   ① 空的         subject=""  /  subject={''}  /  subject={``}
//   ② 整句式       subject={t('materials.deleteConfirm')}
//                  → 那句英文是 'Delete this attachment?' ——
//                    **它就是本刀要消灭的东西**,搬进主语格不算改好。
//   ③ 不来自作用域 subject="Attachment"
//                  → 一个常量在十行表格里对每一行都说同一句话,
//                    那正是 window.confirm 当年答不出"哪一个"的原因。
//
// ★【为什么判据要下到英文原文,而不只看代码】★
//   ② 那一类在代码里长得完全正常:一个 t() 调用,一个存在的键。
//   坏的地方在【它指向的那句话】。所以本脚本把 t('a.b.c') 解析到 messages/en.ts,
//   拿真正的英文去问:里面有没有 "this "。有,就是整句式,就红。
//   一条不下到原文的检查,会把 ② 全部放过 —— 而 ② 是 40 处里的 28 处。
//
// 【基线是 0,不是一张名单】本刀把 40 处全部转完,所以这里没有例外表。
//   下一个人加一处不点名的确认,当场红 —— 这就是这道闸的全部用途。
//
// ★【故障注入验过】★ 见 docs/base-components.md §十一。三种都注过,都咬到了;
//   撤掉之后回到 EXIT 0 / 0 finding。
//   一条没被证明会红的断言,和没有这条断言是一样的。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :app/ 与 lib/ 下 .ts/.tsx 的源码文本(**先剥掉注释**),
//                   从里面抽 `subject=` 的表达式原文,并把 t('a.b.c') 解析到
//                   messages/en.ts 的**那句英文**。
//   我声称管的是  :每一处确认对话框的调用点,主语都点得出【它在确认哪一个】。
//   两者不同之处  :**它读的是源码,不是屏幕。** 一处主语在代码里引用了作用域
//                   (于是三条判据全过),渲染出来仍然可能是空的或一样的 ——
//                   `subject={r.label}` 而 `r.label` 运行期为空字符串,本闸看不见。
//                   它保证的是【写法点得出行】,不是【屏幕上真的点出了行】。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【NARROW-COVERAGE-1(2026-09-09)修了两件,它们是同一个缺陷的两半】★★
// ════════════════════════════════════════════════════════════════════════════
// 本支此前是 `docs/forward-queue.md` 的 NARROW-COVERAGE-1 里点名的**实例 4**,
// 而它的性质是:**它数错了,而且它自己永远发现不了。**
//
// ① 断言只有一个方向。原来是 `subjects.length < openings` ——
//    拦得住解析器【漏抓】,拦不住它【凭空多抓】。
// ② 于是它真的多抓了一处,线上报 **58 处 subject / 57 个 JSX 开标签**:
//    · 文件级筛子跑在**没有去掉注释的原文**上,于是
//      app/components/ui/action-message.tsx:13(一行 `//` 注释里提到组件名)
//      让整个文件进了扫描范围;
//    · :143 的 `data-action-message-subject={e.subject}` 被主语正则吃了下去——
//      `\bsubject\s*=` 的 `\b` **在连字符后面是成立的**。
//    · 而那个文件的 openings 是 0、subjects 是 1,`1 < 0` 为假,**它静静地通过**。
//
// 【修法,两条都对着上面那两半】
//   · 判据改成 `(?<![-\w$])subject\s*=` —— 连字符与标识符字符后面的 `subject`
//     不再算主语。实测:`data-action-message-subject={e.subject}` → 不匹配;
//     `subject={r.code}` / `<ConfirmButton subject="…"` → 照旧匹配。
//   · 文件级筛子与所有计数一律跑在**剥掉注释之后**的源码上。
//   · 断言改成**逐文件相等**(assertPinned):JSX 抽出的主语数必须【等于】
//     JSX 开标签数,多一个少一个都红。useConfirm 那一支单独计数、单独断言 ——
//     它没有 JSX 开标签,混在一起数就等于把这条断言重新弄成单向的。
//
// 用法:node scripts/check-confirm-subject.mjs        (退出码 0 = 干净)
// ════════════════════════════════════════════════════════════════════════════

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import { assertPinned, assertPopulation } from './lib/selfproof.mjs'

const ROOT = process.cwd()
const SCAN_DIRS = ['app', 'lib']
const COMPONENT_FILE = 'app/components/ui/confirm-dialog.tsx'

// ── messages/en.ts:把 t('a.b.c') 解析成真正的那句英文 ────────────────────────
// 【为什么不 import 它】那是 TS 模块,而本脚本是裸 node。这里只要键→字符串,
// 所以按嵌套的键路径做一次朴素扫描就够;解析不出来的键【不拿它做判据】
// (宁可漏一次,也不要凭一次解析失败去红一个无辜的调用点)。
function loadEnglish() {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const out = new Map()
    const path = []
    for (const raw of src.split('\n')) {
        const line = raw.trim()
        if (line.startsWith('//')) continue
        const open = line.match(/^([A-Za-z0-9_$]+)\s*:\s*\{$/)
        if (open) { path.push(open[1]); continue }
        if (/^\}[,)]?;?$/.test(line)) { path.pop(); continue }
        const kv = line.match(/^([A-Za-z0-9_$]+)\s*:\s*(['"])([\s\S]*)$/)
        if (kv) {
            const quote = kv[2]
            const rest = kv[3]
            // 只取到同一行上未转义的收尾引号为止(跨行字符串不参与判据)。
            let value = ''
            for (let i = 0; i < rest.length; i++) {
                if (rest[i] === '\\') { value += rest[i] + (rest[i + 1] ?? ''); i++; continue }
                if (rest[i] === quote) break
                value += rest[i]
            }
            out.set([...path, kv[1]].join('.'), value)
        }
    }
    return out
}

// ── 找出每一处 subject={...} 的那段表达式原文 ────────────────────────────────
// 【为什么自己数括号,而不是一条正则】subject 里有模板串、有三元、有嵌套对象,
// 正则数不了嵌套。这里从 `subject=` 之后第一个 `{` 起做一次括号配平,
// 期间跳过字符串与模板串 —— 够用,而且看得懂。
function readBraced(src, from) {
    let depth = 0
    let quote = null
    for (let i = from; i < src.length; i++) {
        const c = src[i]
        if (quote) {
            if (c === '\\') { i++; continue }
            if (c === quote) quote = null
            continue
        }
        if (c === "'" || c === '"' || c === '`') { quote = c; continue }
        if (c === '{') depth++
        else if (c === '}') { depth--; if (depth === 0) return { expr: src.slice(from + 1, i), end: i } }
    }
    return null
}

// ★【注释要先剥掉,而且要【等长】地剥】★
// 原来的文件级筛子跑在没剥注释的原文上,于是一个只在 `//` 注释里提到组件名的
// 文件也会被扫 —— 那正是那处幽灵主语进来的门。
// 【为什么用等长空格替换,而不是删掉】下面所有的 `lineOf(src, index)` 都靠
// 字符下标算行号。删掉注释会让每一处报错的行号往前漂,而一个行号会漂的检查,
// 与一个不报行号的检查一样难用。
function stripComments(src) {
    return src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
              .replace(/(^|[^:])\/\/[^\n]*/g, (m, p1) => p1 + ' '.repeat(m.length - p1.length))
}

function findSubjects(src) {
    const found = []
    // JSX:subject={expr} 或 subject="literal"
    // ★【`\b` 在连字符后面是成立的,所以它【不够】】★
    //   `data-action-message-subject={e.subject}` 里,`-subject` 的 `\b` 成立,
    //   于是一个 data-* 属性被当成了确认框主语(线上实测,58 对 57 的那一处)。
    //   改用负向后顾:前一个字符是连字符或标识符字符时,这不是一个 subject prop。
    const re = /(?<![-\w$])subject\s*=\s*(\{|")/g
    let m
    while ((m = re.exec(src)) !== null) {
        if (m[1] === '"') {
            const close = src.indexOf('"', m.index + m[0].length)
            if (close === -1) continue
            found.push({ index: m.index, via: 'jsx', expr: JSON.stringify(src.slice(m.index + m[0].length, close)) })
            continue
        }
        const braced = readBraced(src, m.index + m[0].length - 1)
        if (!braced) continue
        found.push({ index: m.index, via: 'jsx', expr: braced.expr })
        re.lastIndex = braced.end
    }
    // useConfirm():对象字面量里的 `subject: expr` —— 目前没有调用点,
    // 但这道闸要在【有】的那一天已经就位,而不是那天再补。
    // ☞ 只在文件真的用了 useConfirm 时才走这一支,否则 JSX 属性里的对象
    //   会被数第二遍(同一处主语算两次,覆盖率断言就跟着说谎)。
    if (/\buseConfirm\b/.test(src)) {
        const re2 = /^[ \t]*subject\s*:\s*(.+?),?[ \t]*$/gm
        while ((m = re2.exec(src)) !== null) {
            if (/^\s*subject\s*:\s*string\b/.test(m[0])) continue   // 类型声明,不是调用点
            found.push({ index: m.index, via: 'useConfirm', expr: m[1].trim().replace(/,$/, '') })
        }
    }
    return found
}

// ★【覆盖率自己也要被守着】★
// 头一版跑出来 43 处,而 `<ConfirmButton` 全库数出来 48 处 —— 那 5 处的差额
// 后来查明是【注释里提到组件名】,不是漏抓。可**当时没有任何东西能证明这一点**:
// 一个解析器悄悄跳过五个调用点,和它抓到了五个坏调用点,输出长得一模一样。
// 所以这里把它变成断言:一个文件里有几个真的 JSX 开标签,就得抽出几处主语。
// **多一个也红**(NARROW-COVERAGE-1)—— 见抬头,原来那条只拦少不拦多,
// 于是它自己多抓了一处,而且永远发现不了。
//
// 【入参已经是剥掉注释的源码】所以这里不再自己跳 `//` 行:
// 那个跳法只认【整行注释】,一句 `const x = 1 // <ConfirmButton 见下` 它就漏了。
function countJsxOpenings(src) {
    return (src.match(/<(?:ConfirmButton|ConfirmDialog)\b/g) ?? []).length
}

const lineOf = (src, index) => src.slice(0, index).split('\n').length

// 逐字符剥掉字面文字,只留下代码:
//   'x' / "x"        → 整段丢掉
//   `a${expr}b`      → a 与 b 丢掉,**expr 留下**(它是代码,不是文字)
function stripLiterals(expr) {
    let out = ''
    for (let i = 0; i < expr.length; i++) {
        const c = expr[i]
        if (c === "'" || c === '"') {
            for (i++; i < expr.length; i++) {
                if (expr[i] === '\\') { i++; continue }
                if (expr[i] === c) break
            }
            out += ' '
            continue
        }
        if (c === '`') {
            for (i++; i < expr.length; i++) {
                if (expr[i] === '\\') { i++; continue }
                if (expr[i] === '`') break
                if (expr[i] === '$' && expr[i + 1] === '{') {
                    // 洞里可能再嵌模板串/对象 —— 数括号找到它的收尾。
                    let depth = 0
                    const from = i + 1
                    let j = from
                    for (; j < expr.length; j++) {
                        if (expr[j] === '{') depth++
                        else if (expr[j] === '}') { depth--; if (depth === 0) break }
                    }
                    out += ' ' + stripLiterals(expr.slice(from + 1, j)) + ' '
                    i = j
                }
            }
            out += ' '
            continue
        }
        out += c
    }
    return out
}

// ── 三条判据 ────────────────────────────────────────────────────────────────
function judge(expr, english) {
    const trimmed = expr.trim()

    // ① 空
    const asLiteral = trimmed.match(/^(['"`])([\s\S]*)\1$/)
    if (trimmed === '' || (asLiteral && asLiteral[2].trim() === '')) {
        return { code: 'EMPTY', why: '主语是空的 —— 必填 prop 只保证"写了",保证不了"说了话"' }
    }

    // ② 整句式:字面量本身,或它引用的每一个 t('key') 的英文原文
    const texts = []
    if (asLiteral && !asLiteral[2].includes('${')) texts.push(asLiteral[2])
    for (const k of trimmed.matchAll(/\bt\(\s*['"]([A-Za-z0-9_$.]+)['"]/g)) {
        const en = english.get(k[1])
        if (en !== undefined) texts.push(en)
    }
    for (const text of texts) {
        if (/\bthis\s/i.test(text)) {
            return {
                code: 'SENTENCE',
                why: `主语读起来是一整句旧消息(含 "this "):${JSON.stringify(text.slice(0, 72))}`,
            }
        }
    }

    // ③ 不来自作用域:把所有【字面文字】拿掉之后,还剩不剩一个标识符。
    //    剩 → 它引用了作用域里的东西;不剩 → 它是个常量,对每一行说同一句话。
    //
    //    ★【为什么要一个扫描器,不是几条 replace】★ 头一版用正则整段吃掉反引号串,
    //      于是 `${r.code} — ${label(r)}` 连同【洞里的表达式】一起没了 ——
    //      一个完全正当的调用点被判成常量。**判据比它要判的东西还糙,就是这个下场。**
    //      模板串里洞【外】的是文字,洞【里】的是代码,只有逐字符走才分得清。
    //    ☞ t('a.b') 不必单独处理:它的参数是字面量,剥掉之后只剩 `t()`,
    //      而 t 本身在下面被排除 —— 所以纯 t() 主语自然落进这一条。
    //      而 t('a.' + r.kind) 剥掉之后仍剩 r.kind,自然放行。
    const idents = (stripLiterals(trimmed).match(/[A-Za-z_$][A-Za-z0-9_$]*/g) ?? [])
        .filter((w) => !['t', 'true', 'false', 'null', 'undefined', 'String', 'Number'].includes(w))
    if (idents.length === 0) {
        return { code: 'NOT_FROM_SCOPE', why: '主语不引用作用域里的任何东西 —— 它对每一行说的是同一句话' }
    }

    return null
}

// ── 走文件 ──────────────────────────────────────────────────────────────────
function walk(dir, out = []) {
    for (const name of readdirSync(dir)) {
        if (name === 'node_modules' || name === '.next' || name.startsWith('.')) continue
        const full = join(dir, name)
        if (statSync(full).isDirectory()) walk(full, out)
        else if (/\.tsx?$/.test(name)) out.push(full)
    }
    return out
}

const english = loadEnglish()
const findings = []
let sites = 0
let scanned = 0
let jsxOpenings = 0
let jsxSubjects = 0
let hookSubjects = 0
let filesWalked = 0

for (const dir of SCAN_DIRS) {
    for (const file of walk(join(ROOT, dir))) {
        filesWalked++
        const rel = relative(ROOT, file)
        if (rel === COMPONENT_FILE) continue          // 组件自己声明 subject,不是调用点
        // ★ 一切都跑在【剥掉注释】的源码上 —— 文件级筛子也是。
        //   原来筛子跑在原文上,于是一个只在注释里提到组件名的文件也会被扫,
        //   而它里面的 data-* 属性就成了那处幽灵主语。
        const src = stripComments(readFileSync(file, 'utf8'))
        if (!src.includes('subject')) continue
        if (!/ConfirmButton|ConfirmDialog|useConfirm/.test(src)) continue
        scanned++
        const subjects = findSubjects(src)
        const openings = countJsxOpenings(src)
        const viaJsx = subjects.filter((s) => s.via === 'jsx').length

        // ★★【两个方向都拦】★★ 逐文件:JSX 抽出的主语数必须【等于】JSX 开标签数。
        //   少 → 解析器漏抓;多 → 解析器凭空多抓(线上就发生过,见抬头)。
        //   useConfirm 那一支【不并进来数】:它没有 JSX 开标签,并进来就等于
        //   给这条断言重新开一个只能变大的方向 —— 那正是原来那条的毛病。
        assertPinned(
            'check-confirm-subject',
            `${rel} 的 JSX 主语数 ↔ JSX 开标签数`,
            viaJsx, openings,
            'subject 是必填 prop,所以每一个 <ConfirmButton>/<ConfirmDialog> 开标签' +
            '都应当恰好对应一处 subject=。对不上就是判据出了问题,不是代码干净。',
        )

        jsxOpenings += openings
        jsxSubjects += viaJsx
        hookSubjects += subjects.length - viaJsx
        for (const s of subjects) {
            sites++
            const bad = judge(s.expr, english)
            if (bad) findings.push({ rel, line: lineOf(src, s.index), expr: s.expr.trim(), ...bad })
        }
    }
}

// ── 覆盖断言:零必须是一次测量 ──────────────────────────────────────────────
// 【为什么四条都要】走文件、筛文件、解析词条、抽主语,是四段各自会独立瞎掉的
// 管道。只断言最后一个数,前几段瞎掉时它同样是 0,而 0 会被读成"全都合规"。
// 【下界一律是 1】—— 见 selfproof.mjs 里那段:一个凭感觉写下的下界会在树缩小
// 那天误报,而"零必须是一次测量"只要求区分 0 与非 0。
assertPopulation('check-confirm-subject', 'app/ 与 lib/ 下走到的 .ts/.tsx 文件', filesWalked)
assertPopulation('check-confirm-subject', '含确认调用点的文件', scanned)
assertPopulation('check-confirm-subject', 'messages/en.ts 解析出的词条', english.size)
assertPinned('check-confirm-subject', '全库 JSX 主语总数 ↔ JSX 开标签总数', jsxSubjects, jsxOpenings)

console.log(`check-confirm-subject: ${sites} 处 subject(JSX ${jsxSubjects} · useConfirm ${hookSubjects})` +
            ` / ${jsxOpenings} 个 JSX 开标签,来自 ${scanned} 个文件,English 词条 ${english.size} 条`)
if (findings.length === 0) {
    console.log('EXIT 0 — 每一处确认都点得出它在确认什么。')
    process.exit(0)
}
for (const f of findings) {
    console.error(`✗ ${f.rel}:${f.line}  [${f.code}]  ${f.why}`)
    console.error(`    subject = ${f.expr.replace(/\s+/g, ' ').slice(0, 120)}`)
}
console.error(`\n${findings.length} 处主语说不出它在确认什么。`)
process.exit(1)
