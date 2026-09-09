// scripts/check-reminder-arms.mjs
// ════════════════════════════════════════════════════════════════════════════
// CONV-7 ①(2026-09-04)· 视图有一支,屏幕上就得有一支
// ════════════════════════════════════════════════════════════════════════════
//
// 【它防的是一处实测出来的缺陷,不是一种假想】
//   量的时候:db/views/operations_now.sql 有 34 支,app/page.tsx 的 TILES 有 32 块。
//   `promise_overdue` 与 `wht_due` 在库里活着、在屏幕上不存在,而当时【五处】
//   都已经对齐了 —— 视图的谓词、messages 的 i18n 键、fixture 111 的 v_expected、
//   fixture 138 的正面断言、乃至 app/finance/wht/actions.ts 那句
//   「首页那一支 wht_due 的谓词刚刚变了」+ revalidatePath('/')。
//   **代码相信那块牌子存在。它不存在。** 而这件事躺了多久没人知道:
//   fixture 111 钉的是【视图】的支列表,它管不到 TypeScript;
//   check-i18n 钉的是【键】的后缀集合,它只保证有一句翻译,不保证有人渲染。
//   两道检查各自盯着一半,中间那一格【谁都没有看】。这条检查就是那一格。
//
// 【判法与 check-i18n 的 sqlLiteralAs 同源】读同一个视图镜像、认同一批字面量。
//   不是新机制 —— 是把已经在用的那一套接到第二根线上。
//
// 【为什么比【名字】而不是比【个数】】两边都是 34 而其中一支拼错了,比个数是绿的。
//   本仓库为"一个恒绿的判词是装饰,不是检查"付过很多次账。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :`db/views/operations_now.sql` 与 `lib/reminders.ts` 两份**源码文本**,
//                   各用一条正则抽出一组支名。
//   我声称管的是  :视图里有一支提醒,首页上就得有一块对应的牌子。
//   两者不同之处  :**我读的是注册表,不是屏幕。** `lib/reminders.ts` 里有一条
//                   `itemType`,不等于那块牌子真的渲染出来了 ——
//                   渲染那一段(`app/page.tsx` 怎么用这份清单)我一个字都没看。
//                   我保证的是【两份清单对齐】,不是【那块牌子出现在人眼前】。
//
// ★★【NARROW-COVERAGE-1(2026-09-09):下面那道自检【只装在一条臂上】】★★
//   `declared !== view.size` 这一条治的是**视图那一侧**字符集写窄了。
//   而 `tilesOf` 用的是**同一个字符集** `[a-z0-9_]+`,跑在 `lib/reminders.ts` 上,
//   **却没有任何独立计数守着它** —— 注册表那一侧的字符集写窄了,
//   两边会同时丢掉同样的支,集合比较照样相等,检查照旧印绿勾。
//   **也就是说那条注释描述的病,在它自己旁边留了一半没治。**
//   处置:注册表那一侧也独立数一遍 `itemType:` 的出现次数。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { assertPinned, assertPopulation } from './lib/selfproof.mjs'

const VIEW = 'db/views/operations_now.sql'
const REG = 'lib/reminders.ts'

// 【与 check-i18n 的解析器认同一种写法】'<name>'::text AS item_type。
// 【字符集必须含数字】—— ap_over_90 / ar_over_90 三支带数字,一个 [a-z_]+ 的
//   正则会【安静地漏掉它们】,而漏掉之后两边同时少同样的两支,比较照样是绿的。
//   这一行本身就是"一个看起来对的检查其实什么都没查"的现成例子。
const armsOf = (sql) =>
    new Set([...sql.matchAll(/'([a-z0-9_]+)'::text AS item_type/g)].map((m) => m[1]))

const tilesOf = (ts) =>
    new Set([...ts.matchAll(/itemType:\s*'([a-z0-9_]+)'/g)].map((m) => m[1]))

const viewSrc = readFileSync(VIEW, 'utf8')
const regSrc = readFileSync(REG, 'utf8')
const view = armsOf(viewSrc)
const reg = tilesOf(regSrc)

// ★★【解析器自己要被查一遍 —— 这一段是故障注入逼出来的,不是设计出来的】★★
// 把上面的字符集从 [a-z0-9_]+ 写成 [a-z_]+(一个非常容易犯的手误),
// **两边会同时丢掉 ap_over_90 / ar_over_90 / output_unsold_aging 那几支,
// 于是集合仍然相等,检查照旧印一个绿勾** —— 只是数字从 34 变成 32。
// 一个"两边同时错、于是永远相等"的比较,正是本仓库反复付账的那个形状
// (OPS-17 的 pnl-对-balance_sheet 是同一个病)。
//
// 所以这里【独立地】数一遍 `AS item_type` 出现了多少次 —— 那个计数不经过
// 名字的字符集,于是它抓得住字符集写窄了这件事。两个数对不上就红。
const declared = (viewSrc.match(/AS item_type/g) ?? []).length
if (declared !== view.size) {
    console.error(
        `✗ check-reminder-arms:${VIEW} 里 \`AS item_type\` 出现 ${declared} 次,` +
            `而名字只解析出 ${view.size} 个 —— **解析器的字符集写窄了**,` +
            `不是视图少了一支。两边同时漏掉同一支的话,集合比较会保持绿色。`
    )
    process.exit(1)
}

// ★★【注册表那一侧,同一条自检 —— NARROW-COVERAGE-1 补的】★★
// 与上面那条逐字同形,只是换了一侧:有几处 `itemType: '…'`,就该解析出几个名字。
// 少了 = `tilesOf` 的字符集写窄了,而两边同时窄下去的话集合比较仍然相等。
//
// ★【独立计数【不许】用被守的那个字符集】★ 这一条守的就是 `[a-z0-9_]+` 写窄了,
//   所以独立那一路只认"冒号后面跟着一个引号",一个字符类都不带。
// ★【`itemType: string` 是类型声明,不是一支】★ 数它就把 34 数成 35 ——
//   本刀第一版正是这么写的,当场把这道断言自己弄红了。
//   **一个数错的常见原因不是数错了,是它数的东西和它的名字对不上**(AGENTS.md)。
//   同一处豁免在 check-confirm-subject 的 `subject: string` 上已经有先例。
const declaredTiles = (regSrc.match(/itemType:\s*'/g) ?? []).length
assertPinned(
    'check-reminder-arms',
    `${REG} 的 \`itemType:\` 出现次数 ↔ 解析出的支名个数`,
    reg.size, declaredTiles,
    '少了就是注册表那一侧的字符集写窄了,不是清单少了一支 —— ' +
    '两边同时漏掉同一支的话,下面那个集合比较会保持绿色。',
)

// 【解析器坏了要红,不能当成"两边都是空的所以相等"】
// gen-masked-tables.mjs 同一条:解析出 0 条 = 解析器坏了,不是没有条目。
assertPopulation('check-reminder-arms', `${VIEW} 解析出的提醒支`, view.size)
assertPopulation('check-reminder-arms', `${REG} 解析出的牌子`, reg.size)

const missing = [...view].filter((a) => !reg.has(a)).sort()
const extra = [...reg].filter((a) => !view.has(a)).sort()

if (missing.length || extra.length) {
    console.error('✗ check-reminder-arms:提醒清单与视图对不上。')
    if (missing.length) {
        console.error(
            `  ${VIEW} 有、${REG} 没有(这一支【在库里活着、在屏幕上不存在】):\n` +
                missing.map((a) => `    · ${a}`).join('\n')
        )
    }
    if (extra.length) {
        console.error(
            `  ${REG} 有、${VIEW} 没有(这一支画得出来、而永远不会有行):\n` +
                extra.map((a) => `    · ${a}`).join('\n')
        )
    }
    console.error(
        '  加一支 = 同时改 db/views/operations_now.sql · lib/reminders.ts ·' +
            ' docs/dashboard-arm-inventory.md · messages/{zh,en}.ts。'
    )
    process.exit(1)
}

console.log(`✓ check-reminder-arms:${view.size} 支,视图与提醒清单逐支对齐。`)
