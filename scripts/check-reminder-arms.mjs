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
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'

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
const view = armsOf(viewSrc)
const reg = tilesOf(readFileSync(REG, 'utf8'))

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

// 【解析器坏了要红,不能当成"两边都是空的所以相等"】
// gen-masked-tables.mjs 同一条:解析出 0 条 = 解析器坏了,不是没有条目。
if (view.size === 0 || reg.size === 0) {
    console.error(
        `✗ check-reminder-arms:解析出 ${view.size} 支(视图)/ ${reg.size} 支(清单)——` +
            ` 0 意味着解析器坏了,不是"没有支"。`
    )
    process.exit(1)
}

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
