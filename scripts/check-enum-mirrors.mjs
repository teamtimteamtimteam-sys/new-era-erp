#!/usr/bin/env node
// scripts/check-enum-mirrors.mjs — 代码里【转录】了一份数据库枚举的地方,必须与真源逐字相同。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么需要它】有些地方非要在【运行期】拿到一份枚举值不可 —— 比如
// MovementMixChart 要对 12 种 movement_type 各发一次 count。它不能像
// check-i18n 那样"检查的时候现读 SQL",它得把值写在 TypeScript 里。
//
// **于是那份数组就是同一件事的第二份陈述,而两份陈述必然漂开。**
// 漂开的后果不报错:库里加了第 13 种流水,这张图【少一根条】,
// 而少的那一根与"那一类今天是零"在屏幕上长得一模一样。
//
// 【这正是本仓库反复付账的那个形状】check-i18n 的抬头写着"后缀集合不写死在这里,
// 每次运行都从真源现读";`lib/maskedTables.ts` 是生成的而不是手写的;
// AGENTS.md 里"写死一份清单只会烂在这里"出现过好几次。
// **本检查是那条规矩用在【非写不可的那份转录】上:允许转录,但要求它被钉住。**
//
// 【判据】双向差集都必须为空 —— 少一个(漏了新值)与多一个(SQL 删了值)
// 都要红。**只查一个方向的检查会在删除那天保持绿色。**
//
// 退出码 0 = 全部对得上;1 = 有漂移;2 = 解析器坏了(解析出 0 个 ≠ 空集合)。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { assertPopulation } from './lib/selfproof.mjs'
import { readInList, countLiteralsOutsideComments, selfCells } from './lib/sql-in-list.mjs'

// ★ F13 的故障注入:ENUM_READER_FAULT=old-regex 把读法换回旧的那一句(截到第一个 `)`,不剥注释)—— 下面那两格【必须】都红;
//   ENUM_READER_FAULT=old-regex-strip 换回本文件【原来】那一支的原样(截完再剥 `--`)—— 截短那一格红,'ghost' 那一格绿(原来那一支本来就剥注释)。
const READER_MODE = ['old-regex', 'old-regex-strip'].includes(process.env.ENUM_READER_FAULT ?? '') ? process.env.ENUM_READER_FAULT : 'chars'

const ROOT = new URL('..', import.meta.url).pathname

//
// ==========================================================================
// 【瞄准 · AIM】
//   我读的是      :`MIRRORS` 这张**手写清单**里点名的那几对文件,各读一段。
//   我声称管的是   :代码里【转录】了一份数据库枚举的地方,必须与真源逐字相同。
//   两者不同之处   :★★ **我管的是【我自己这张清单】,不是树里的转录。**
//                   我**没有任何发现步骤**:谁在哪里又写死了一份枚举,我看不见。
//                   抬头那句「加一条 = 加一行」的言下之意是**靠人记得加** ——
//                   而本仓库的记录是,靠人记得的规矩会被破。
//                   ☞ 已登记为 NARROW-COVERAGE-2:补一个发现步骤是单独一刀,
//                     因为「什么算一份枚举转录」需要一条判据,而那条判据本身
//                     正是这一族最容易写窄的东西。
// ==========================================================================

/** 要钉的转录。加一条 = 加一行,不是加一个脚本。 */
const MIRRORS = [
    {
        what: 'MOVEMENT_TYPES',
        tsFile: 'app/inventory/reports/MovementMixChart.tsx',
        tsConst: 'MOVEMENT_TYPES',
        sqlFile: 'db/tables/inventory_movements.sql',
        sqlColumn: 'movement_type',
        why: 'CHART-1 ④ B3:12 根条各发一次 count,运行期非要这份清单不可',
    },
]

/** 从表镜像里读 CHECK (col IN ('a','b',…)) —— ★ F13(MES-7b-1):与 check-i18n 用【同一份】按字符走的读法(scripts/lib/sql-in-list.mjs)。
 *  此前这里先用 `([^)]+)` 截到第一个 `)` 再剥 `--` 注释:列表中间一句注释里只要有一个 `)`,列表就被截短,而剥得再干净也晚了
 *  (MES7A2-ENUM-PARSERS-STOP-AT-A-COMMENT)。现在注释里的 `)` 与 `'词'` 都碰不到括号深度与取值。
 *  ★ 覆盖断言:读出来的个数必须等于另一条路数出来的字面量个数(先删注释、再数引号对)—— 对不上就退 2(量具坏了)。 */
function sqlEnum(file, col) {
    const src = readFileSync(ROOT + file, 'utf8')
    const { values, span } = readInList(src, col, { checkOnly: true, mode: READER_MODE })
    const independent = countLiteralsOutsideComments(span)
    if (values.length !== independent) {
        throw new Error(`${file} 的 CHECK (${col} IN (...)):读出 ${values.length} 个值,另一条路数出 ${independent} 个字面量 —— 两条路对不上,这次读数不作数`)
    }
    return values
}

/** 从 TS 里读 `const NAME = [ 'a', 'b', … ] as const`。 */
function tsConstArray(file, name) {
    const src = readFileSync(ROOT + file, 'utf8')
    const m = src.match(new RegExp(String.raw`const ${name}\s*=\s*\[([\s\S]*?)\]\s*as const`))
    if (!m) throw new Error(`${file} 里找不到 const ${name} = [...] as const`)
    const body = m[1].split('\n').map((l) => l.replace(/\/\/.*$/, '')).join('\n')
    return [...body.matchAll(/'([^']+)'/g)].map((x) => x[1])
}

assertPopulation('check-enum-mirrors', 'MIRRORS 里在钉的转录', MIRRORS.length)

// ★ F13 两格(每一次运行都跑):列表中间一句注释里有 `)` 不许截短;注释里有 'ghost' 不许多出一个值。任一格红 → 退 2:读法本身坏了,
//   下面的比对一个都不作数。
{
    const cells = selfCells(READER_MODE)
    if (cells.length) {
        console.error(`✗ check-enum-mirrors:读法的自检没过(${cells.length} 格)—— 这一次的比对不作数`)
        for (const c of cells) console.error('   ' + c)
        if (READER_MODE !== 'chars') console.error('   ★ 故障注入:ENUM_READER_FAULT=old-regex(这两格红,正是它们该做的)')
        process.exit(2)
    }
}

let bad = 0
for (const m of MIRRORS) {
    let sql, ts
    try {
        sql = sqlEnum(m.sqlFile, m.sqlColumn)
        ts = tsConstArray(m.tsFile, m.tsConst)
    } catch (e) {
        console.error(`✗ check-enum-mirrors:解析器坏了 —— ${e.message}`)
        console.error('   【解析出 0 个不是"空集合"】所以这里退 2,不是悄悄通过。')
        process.exit(2)
    }
    // 解析出 0 个 = 解析器坏了,不是"这个枚举是空的"
    if (sql.length === 0 || ts.length === 0) {
        console.error(`✗ check-enum-mirrors:${m.what} 解析出 0 个值 —— 解析器坏了,不是空集合`)
        process.exit(2)
    }
    const sqlSet = new Set(sql)
    const tsSet = new Set(ts)
    const missing = sql.filter((v) => !tsSet.has(v))   // SQL 有、TS 没有
    const extra = ts.filter((v) => !sqlSet.has(v))     // TS 有、SQL 没有
    if (missing.length || extra.length) {
        bad++
        console.error(`✗ ${m.tsFile} 的 ${m.tsConst} 与 ${m.sqlFile} 的 CHECK(${m.sqlColumn})对不上:`)
        if (missing.length) console.error(`    SQL 有、TS 【漏了】:${missing.join(', ')}  ← 图上会少这几根条`)
        if (extra.length) console.error(`    TS 有、SQL 【没有】:${extra.join(', ')}  ← 会对一个不存在的值发查询`)
        console.error(`    (为什么允许这份转录:${m.why})`)
    } else {
        console.log(`  ✓ ${m.tsConst} ↔ ${m.sqlColumn}:${sql.length} 个值,两个方向都对得上`)
    }
}

if (bad) {
    console.error(`\n✗ check-enum-mirrors:${bad} 处转录漂移`)
    process.exit(1)
}
console.log(`✓ check-enum-mirrors:${MIRRORS.length} 处转录,全部与真源逐字相同`)
