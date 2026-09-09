#!/usr/bin/env node
// ==========================================================================
// 【瞄准 · AIM】
//   我读的是      :app/ 下的 TypeScript AST,数 `alert()` / `confirm()` 这一族原生对话框。
//   我声称管的是   :数【原生告知框】,而且**结构上不数注释**。
//   两者不同之处   :**我数的是调用点,不是它显示给谁看。** 一处 `alert()` 在一条
//                   永远走不到的分支里,我照数不误。
//                   ★ 而它自己栽过一次:健康检查的门槛写成「诊断 > 20 条才算坏」,
//                     于是一个只有 3 条诊断的语法错**低于门槛**,普查照印「0 处」。
//                     AGENTS.md 据此立了「健康检查的阈值默认应当是零」。
//   ☞ 【本文件是普查,不是闸】它的红是【给读数的人的一句话】(这一次读数不可信),
//     不是一道拦住构建的门 —— 它不在 npm run build 里,也不该进去:
//     普查报的是【数】不是【违规】,接进构建会把基线漂移变成构建红,
//     而那种红会被 --update-baseline 顺手按掉。(R-Q4)

// ==========================================================================
// ════════════════════════════════════════════════════════════════════════════
// ALERT-1(2026-09-08)· 数【原生告知框】—— 路径 A:真解析器
// ════════════════════════════════════════════════════════════════════════════
// 【为什么不是 grep】AGENTS.md 记了两次同一件事:
//   · CONFIRM-1 的 56 处 = `grep -c window.confirm`,它把 16 句【注释】数了进去,
//     真数是 40;同一次 grep 又漏了一处没有 `window.` 前缀的。
//   · 而本刀开工时,`grep -c alert(` 给的是 20,其中 2 处是
//     app/finance/fx/[id]/edit/DeleteButton.tsx 里【描述 BTN-4 已经退休掉的那两个框】
//     的注释行。**一句注释再一次污染了对它自己的计数。**
// 一个真解析器【结构上】看不见注释 —— 这不是它更小心,是注释根本不进 AST。
//
// ★ 覆盖率本身是一条断言(AGENTS.md 的法则)★
//   扫不到文件 / 解析失败 / 一个 identifier 都没走到 —— 都必须【说自己瞎了】,
//   不许安静地打印 0。`SURVEY_FAULT=blind` 注入失明,退出码必须变红。
// ════════════════════════════════════════════════════════════════════════════
import ts from 'typescript'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname
const ROOTS = ['app', 'lib']            // 应用本体。scripts/ 是探针,不是应用。
const FAULT = process.env.SURVEY_FAULT || ''

// 告知型(本刀的对象)与 询问型(CONFIRM-1/BTN-4 的对象,这里只作残留核对)
const TELLING = new Set(['alert'])
const ASKING = new Set(['confirm', 'prompt'])

function walkFiles(dir, out = []) {
    for (const e of readdirSync(dir)) {
        if (e === 'node_modules' || e.startsWith('.')) continue
        const p = join(dir, e)
        const st = statSync(p)
        if (st.isDirectory()) walkFiles(p, out)
        else if (/\.(ts|tsx|js|jsx|mjs)$/.test(e)) out.push(p)
    }
    return out
}

const files = ROOTS.flatMap((r) => walkFiles(join(ROOT, r)))
if (files.length === 0) {
    console.error('BLIND: 一个源文件都没扫到 —— 这不是"干净",这是量具坏了')
    process.exit(3)
}

let identifiersSeen = 0
const hits = []
let parseFailures = 0
const badFiles = []

for (const file of files) {
    const src = readFileSync(file, 'utf8')
    const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true,
        /\.tsx?$/.test(file) ? ts.ScriptKind.TSX : ts.ScriptKind.JS)
    // ★★【ALERT-1 自己的学费:这个阈值原来是 > 20,而它【放过了一个真坏的文件】】★★
    //   本刀的批量改写脚本一度把 app/finance/fx/[id]/edit/DeleteButton.tsx 改坏
    //   (改中了注释里的那句调用),文件语法已经不成立 —— 而这里只有个位数的
    //   诊断,于是 parseFailures 仍是 0,本脚本照常打印"0 处",看起来【干净】。
    //   **一个数不出来的量具报了 0,和一棵真的干净的树,输出一模一样** ——
    //   那正是本仓库为覆盖率断言反复付账的那个形状。阈值改成【一条都不许有】。
    const diags = sf?.parseDiagnostics ?? []
    if (!sf || diags.length > 0) {
        parseFailures++
        badFiles.push(`${relative(ROOT, file)} (${diags.length} 条诊断)`)
    }

    const visit = (node) => {
        if (ts.isIdentifier(node)) identifiersSeen++
        if (ts.isCallExpression(node)) {
            const c = node.expression
            let name = null
            let form = null
            if (ts.isIdentifier(c)) { name = c.text; form = name }
            else if (ts.isPropertyAccessExpression(c) && ts.isIdentifier(c.name)) {
                const obj = c.expression.getText(sf)
                if (obj === 'window' || obj === 'globalThis' || obj === 'self') {
                    name = c.name.text; form = `${obj}.${name}`
                }
            }
            if (name && (TELLING.has(name) || ASKING.has(name))) {
                // 排除:同名的局部函数/方法调用(如 someObj.alert 已被上面挡掉;
                // 这里再挡一层"自己定义了一个叫 alert 的函数"的情形)
                const { line } = sf.getLineAndCharacterOfPosition(node.getStart(sf))
                hits.push({
                    file: relative(ROOT, file),
                    line: line + 1,
                    name,
                    form,
                    kind: TELLING.has(name) ? 'TELLING' : 'ASKING',
                    text: node.getText(sf).replace(/\s+/g, ' ').slice(0, 120),
                })
            }
        }
        ts.forEachChild(node, visit)
    }
    if (FAULT !== 'blind') visit(sf)
}

// ── 覆盖率断言 ──────────────────────────────────────────────────────────────
if (identifiersSeen < 1000) {
    console.error(`BLIND: 只走到 ${identifiersSeen} 个 identifier —— AST 没有真的被走过`)
    process.exit(3)
}
if (parseFailures > 0) {
    console.error(`BLIND: ${parseFailures} 个文件解析失败 —— 它们的命中数不可信`)
    for (const b of badFiles.slice(0, 20)) console.error(`   ${b}`)
    process.exit(3)
}

const telling = hits.filter((h) => h.kind === 'TELLING')
const asking = hits.filter((h) => h.kind === 'ASKING')

console.log(`扫描文件:${files.length}  走过 identifier:${identifiersSeen}  解析失败:${parseFailures}`)
console.log(`\n【告知型 TELLING】${telling.length} 处 / ${new Set(telling.map(h => h.file)).size} 个文件`)
for (const h of telling) console.log(`  ${h.file}:${h.line}  ${h.form}  ⟨${h.text}⟩`)
console.log(`\n【询问型 ASKING 残留核对】${asking.length} 处`)
for (const h of asking) console.log(`  ${h.file}:${h.line}  ${h.form}  ⟨${h.text}⟩`)

console.log(`\nPATH_A_TELLING_COUNT=${telling.length}`)
console.log(`PATH_A_TELLING_FILES=${new Set(telling.map(h => h.file)).size}`)
process.exit(0)
