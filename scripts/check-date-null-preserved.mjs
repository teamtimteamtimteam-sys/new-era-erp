#!/usr/bin/env node
// scripts/check-date-null-preserved.mjs
// ════════════════════════════════════════════════════════════════════════════
// DATE-1(2026-09-20)· 一个格式化函数【不许】把一个有主的 null 变成真值
// ════════════════════════════════════════════════════════════════════════════
// ★★★【这道闸不在委托书里。它是 DATE-1 自己的改动【差点带上线】的那个缺陷。】★★★
//
// `lib/dates.ts` 的 formatDate(null) 按设计返回 `'—'` —— **屏幕上要的正是这个**。
// 而本刀的批量改写把它用在了**投影**上:
//
//     inServiceDate: formatDate(a.in_service_date, locale)     ← ✗ 这一行
//
// 于是一个本来是 `null` 的字段变成了字符串 `'—'`,而 ★ **`'—'` 是真值**。
// 下游每一处 `x ? … : …` / `x ?? …` 当场翻边。实测抓到的两处后果:
//
//   · `app/finance/assets/AssetActions.tsx:50`
//     `inServiceDate ? t('assets.blocked.alreadyInService', …) : …`
//     → ★ **「这台设备已经投用」的拦阻信息,对【没有投用】的设备也显示了。**
//       那不是少了一句话,是**屏幕主动说了一句假话**,而且它拦住了一个合法动作。
//   · `AssetActions.tsx:39` `useState(plannedInServiceDate ?? '')`
//     → 那个 state 喂的是一颗 `<input type="date">`,而 ★★ **HTML 规范说
//       值不合法就【当空值处理,不报错】** —— 控件就那么空着。
//
// ☞ **它是怎么被抓到的:** `--mode=drift` 报 `/finance/assets` 的手机行高
//   **109.5 → 465.5(+356px)**,而那张表的列宽**逐字未变**。
//   ★ 一个"行高涨了 356px 而宽度一个像素没动"的读数,是一个**看起来荒谬的输出** ——
//   与 DATE-0 §3.4 那个 `function toLocaleString() { [native code] }1111` 同一族:
//   **它是被荒谬抓到的,不是被任何断言抓到的。** 这道闸就是那次替换。
//
// ════════════════════════════════════════════════════════════════════════════
// ★ 判据,一句话 —— 它就是本仓库 CLEANUP-A 那一条,换了个场景:
//
// > ### **这个值的 `null` 是不是【已经有主】了?**
// > 「已经有主」= `null` 在表达一个**合法状态**,而且**有人在读它**。
// > 是的话,一个把 null 映射成显示串的格式化函数,就是
// > **把拒绝/缺失伪装成一个合法答案** —— 它会渲染成那个合法状态,
// > 于是没有任何人、任何时候会看见它。
//
// 【规矩】
//   · **投影 / 传给组件当 prop**(值会被下游拿去判断)→ 必须保 null:
//       `v ? formatDate(v, locale) : null`(消费端类型非空时用 `'—'`)
//   · **直接印在 JSX 里** → 不必保,`'—'` 正是屏幕上要的
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :`app/` `lib/` 的 **TypeScript 类型检查器** —— 每一处落在
//                   【投影 / JSX prop】位置上的日期格式化调用,它第一个入参的**类型**。
//   我声称管的是   :一个可能是 null 的日期,不会被无条件格式化成一个真值。
//   两者不同之处   :★★ **我答的是「类型上可不可能是 null」,不是「下游有没有在读那个 null」。**
//                   一个**类型上非空**的字段,我一句话都不说 —— 而它可能是
//                   一句 `as string` 断言出来的(树里就有六处)。
//                   ☞ 也就是说:**一句 `as string` 能让这道闸闭嘴**,
//                     与 AGENTS.md 那条「一句 cast 关掉的正是唯一看得见这一处的检查」
//                     逐字同形。**它没有被关掉,它只是够不着。**
//
// 用法:node scripts/check-date-null-preserved.mjs
//       node scripts/check-date-null-preserved.mjs --blind    ← 致盲注入,必须退 2
// 退出码:0 干净 · 1 找到了违规 · 2 量具自己坏了
// 实测成本:~2s(它自己建一个 ts.Program;`next build` 那次不复用)
// ════════════════════════════════════════════════════════════════════════════
import ts from 'typescript'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const ROOT = process.cwd()
const BLIND = process.argv.includes('--blind')
const FMT = new Set(['formatDate', 'formatDateTime', 'formatMonth', 'formatAuditStamp'])

const cfgPath = ts.findConfigFile(ROOT, ts.sys.fileExists, 'tsconfig.json')
if (!cfgPath) { console.error('✗ check-date-null-preserved:找不到 tsconfig.json'); process.exit(2) }
const cfg = ts.parseJsonConfigFileContent(
    ts.readConfigFile(cfgPath, ts.sys.readFile).config, ts.sys, ROOT)
const program = ts.createProgram(cfg.fileNames, cfg.options)
const checker = program.getTypeChecker()

const violations = []
let filesWalked = 0
let fmtCallsSeen = 0        // 所有位置上的格式化调用(第二条独立路)
let sinksExamined = 0       // 落在【投影 / prop】上的那些

for (const sf of program.getSourceFiles()) {
    if (sf.isDeclarationFile) continue
    const rel = sf.fileName.replace(ROOT + '/', '')
    if (!rel.startsWith('app/') && !rel.startsWith('lib/')) continue
    filesWalked++

    const visit = (n) => {
        if (ts.isCallExpression(n) && ts.isIdentifier(n.expression) && FMT.has(n.expression.text)) {
            fmtCallsSeen++
            const p = n.parent
            const isProjection = !!p && ts.isPropertyAssignment(p) && p.initializer === n
            const isProp = !!p && ts.isJsxExpression(p) && !!p.parent && ts.isJsxAttribute(p.parent)
            if ((isProjection || isProp) && !BLIND && n.arguments.length >= 1) {
                sinksExamined++
                const arg = n.arguments[0]
                if (!ts.isConditionalExpression(arg)) {
                    const t = checker.getTypeAtLocation(arg)
                    const nullish = (x) => (x.flags & ts.TypeFlags.Null) || (x.flags & ts.TypeFlags.Undefined)
                    const canBeNull = nullish(t) || (t.isUnion() && t.types.some(nullish))
                    if (canBeNull) {
                        const { line } = sf.getLineAndCharacterOfPosition(n.getStart(sf))
                        const name = isProjection
                            ? (ts.isIdentifier(p.name) || ts.isStringLiteral(p.name) ? p.name.text : '?')
                            : p.parent.name.getText()
                        violations.push({
                            rel, line: line + 1, name,
                            text: n.getText(sf).replace(/\s+/g, ' ').slice(0, 96),
                            arg: arg.getText(sf).slice(0, 60),
                        })
                    }
                }
            }
        }
        ts.forEachChild(n, visit)
    }
    visit(sf)
}

// ── 覆盖断言:两条独立的路 ──────────────────────────────────────────────────
// 路 A:类型检查器走过的文件数;路 B:见到的格式化调用总数(不经过"是不是投影"那一层)。
assertPopulation('check-date-null-preserved', 'app/ lib/ 下走过的源码文件', filesWalked, 500)
assertPopulation('check-date-null-preserved', '见到的日期格式化调用(所有位置)', fmtCallsSeen, 100)
assertPopulation('check-date-null-preserved', '落在【投影 / prop】上的那些(判据的落点)', sinksExamined, 50)
// 落点必须是总数的真子集 —— 相等说明"是不是投影"那一层没在判,全都算进去了。
assertPinned('check-date-null-preserved', '落点是不是总数的真子集(判据真的在筛)',
    sinksExamined < fmtCallsSeen, true,
    `落点 ${sinksExamined} vs 总数 ${fmtCallsSeen} —— 相等说明筛选那一层没有生效。`)

console.log(`check-date-null-preserved:${filesWalked} 份源码 · 日期格式化调用 ${fmtCallsSeen} 处`
    + ` · 其中落在【投影 / prop】上 ${sinksExamined} 处`)

if (violations.length) {
    console.error('')
    console.error(`✗ check-date-null-preserved:${violations.length} 处把一个【可能是 null 的日期】无条件格式化了。`)
    for (const v of violations) {
        console.error(`   · ${v.rel}:${v.line}  ${v.name}: ${v.text}`)
        console.error(`     ${v.arg} 的类型含 null/undefined,而 formatDate(null) 返回 '—' —— ★ 一个【真值】。`)
    }
    console.error('')
    console.error('【为什么要紧】下游每一处 `x ? … : …` / `x ?? …` 会当场翻边。')
    console.error('  实测后果:「这台设备已经投用」的拦阻信息对没有投用的设备也显示了;')
    console.error('  以及一个 `?? \'\'` 把 \'—\' 喂进了 <input type="date">,而控件就那么空着。')
    console.error('【改法】投影要保 null:')
    console.error('     X: v ? formatDate(v, locale) : null        ← 下游还要读那个 null')
    console.error('     X: v ? formatDate(v, locale) : \'—\'         ← 消费端类型非空(作者已断言值一定在)')
    console.error('  ★ 直接印在 JSX 里的【不用改】—— 那里 \'—\' 正是屏幕上要的。')
    process.exit(1)
}
console.log('✓ 没有任何【可能是 null 的日期】被无条件格式化成真值')
