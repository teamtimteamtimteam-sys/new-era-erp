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

const ROOT = new URL('..', import.meta.url).pathname

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

/** 从表镜像里读 CHECK (col IN ('a','b',…)) —— 与 check-i18n 的 sqlEnum 同一种读法。 */
function sqlEnum(file, col) {
    const src = readFileSync(ROOT + file, 'utf8')
    const m = src.match(new RegExp(String.raw`CHECK \(\s*${col} IN\s*\(([^)]+)\)`, 's'))
    if (!m) throw new Error(`${file} 里找不到 CHECK (${col} IN (...))`)
    // 【剥掉行内注释】那条 CHECK 中间夹着 -- 注释(IOD-1 那两行),
    // 不剥的话注释里的引号会被当成值 —— 一个安静地多出几个"值"的解析器。
    const body = m[1].split('\n').map((l) => l.replace(/--.*$/, '')).join('\n')
    return [...body.matchAll(/'([^']+)'/g)].map((x) => x[1])
}

/** 从 TS 里读 `const NAME = [ 'a', 'b', … ] as const`。 */
function tsConstArray(file, name) {
    const src = readFileSync(ROOT + file, 'utf8')
    const m = src.match(new RegExp(String.raw`const ${name}\s*=\s*\[([\s\S]*?)\]\s*as const`))
    if (!m) throw new Error(`${file} 里找不到 const ${name} = [...] as const`)
    const body = m[1].split('\n').map((l) => l.replace(/\/\/.*$/, '')).join('\n')
    return [...body.matchAll(/'([^']+)'/g)].map((x) => x[1])
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
