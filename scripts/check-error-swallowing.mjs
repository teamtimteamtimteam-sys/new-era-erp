#!/usr/bin/env node
// scripts/check-error-swallowing.mjs
//
// 【为什么有这个检查】`?? []` 把查询失败变成空数组,于是页面回 HTTP 200 说
// "没有待办 / 没有发票 / 没有库存"。冒烟测试断言 2xx,正好从它旁边走过去 ——
// 一个读不到数据的页面必须【报错】,否则没有任何门抓得住它(AGENTS.md
// 「A failed query must fail — never `?? []`」)。
//
// 【为什么现在才有】docs/error-swallowing-audit.md 四轮清点出 320 处,并当场说了
// 一句要紧的话:这是【当年的写法】,不是 320 次个人失误。清完不装检查,
// 第 321 处会照原样写出来 —— OPS-12 把那 12 处残留清完的同时把这道检查装上,
// 否则那次清扫只买到一个干净的计数。
//
// 判据:查询结果(`.data` / 解构出来的 `data`)后面跟着 `?? []` / `?? 0` /
// `?? null`。政策与助手在 lib/db-helpers.ts:mustRows / mustOne / mustCount。
//
// ════════════════════════════════════════════════════════════════════════════
// 【它看不见什么 —— 写在这里,免得"✓ 通过"被当成"没有吞错"】
// 这一类【不能完全机械化】,下面三种形状本检查抓不到:
//   * `if (error) return []` / `.catch(() => [])` —— 同样的吞,不同的句法;
//   * 压根不解构 error,直接 `data?.map(...)` —— 失败时 data 为 null,
//     可选链把它变成"零行",没有 `??` 可抓;
//   * 把查询结果传进一个自己会兜底的辅助函数。
// 抓得到的是【最常见的那一种】,也就是那 320 处的主流形状。
// 剩下的只能靠评审时问一句"这个查询失败会怎样" —— 这句话没法自动化,
// 所以它就明写在这里,而不是伪装成检查已经覆盖了。
// ════════════════════════════════════════════════════════════════════════════
//
// 用法:node scripts/check-error-swallowing.mjs   (退出码 0 = 干净)
import { readdirSync, statSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname

// 例外:path 是路径前缀,match(可选)是该行必须包含的片段。reason 必填 ——
// 与 check-currency-literals / check_mirrors 同一个做法:名单是列出来的,
// 不是记在谁脑子里的。【只放误伤,不放"还没修"】。
const ALLOWLIST = [
    {
        path: 'lib/db-helpers.ts', match: 'res.data ?? []',
        reason: '这就是 mustRows 本身 —— 它在上一行 `if (res.error) fail(...)` 抛过了,'
            + '这里的 ?? [] 是【成功但零行】的合法回退。政策的实现处不该被政策拦下。',
    },
    {
        path: 'lib/permissions.ts', match: 'data ?? []',
        reason: 'getMyPermissions 在上一行显式 `throw new Error(...)`;'
            + '走到这里就是 RPC 成功返回,空数组是【真的没有权限】。'
            + '两者的区别正是 FIN-7-fu 修它的理由,注释就在旁边。',
    },
    {
        path: 'app/customers/export/route.ts', match: 'data ?? []',
        reason: '导出路由在上面 `if (error) return new Response(..., { status: 500 })` —— '
            + '失败已经变成 500,?? [] 到不了。',
    },
    { path: 'app/materials/export/route.ts', match: 'data ?? []', reason: '同 customers/export:error 先返回 500。' },
    { path: 'app/suppliers/export/route.ts', match: 'data ?? []', reason: '同 customers/export:error 先返回 500。' },
    {
        path: 'app/finance/bank/import/ImportStatementForm.tsx', match: 'setCsvRows(res.data',
        reason: '【不是查询】这是 PapaParse 的解析结果(res.data 是 CSV 行),'
            + '不是 Supabase 的 { data, error }。同名不同物 —— 本检查靠名字判断,'
            + '所以这一处需要明写豁免。',
    },
]

const allowed = (h) => ALLOWLIST.some((a) =>
    h.rel.startsWith(a.path) && (!a.match || h.full.includes(a.match)))

// `xxxRes.data ?? []` / `.data ?? 0` / 解构出来的 `data ?? null`
const PATTERN = /(\w*(?:Res|res|result)?\??\.data|\bdata)\s*\?\?\s*(\[\]|0\b|null)/

function* walk(dir) {
    for (const name of readdirSync(dir)) {
        if (name === 'node_modules' || name === '.next') continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if (/\.tsx?$/.test(name) && !name.endsWith('.d.ts')) yield p
    }
}

const hits = []
for (const dir of ['app', 'lib']) {
    for (const file of walk(join(ROOT, dir))) {
        const rel = file.slice(ROOT.length)
        if (rel.includes('database.types')) continue
        readFileSync(file, 'utf8').split('\n').forEach((line, i) => {
            const t = line.trim()
            if (t.startsWith('//') || t.startsWith('*')) return
            if (PATTERN.test(line)) {
                hits.push({ rel, line: i + 1, text: t.slice(0, 110), full: line })
            }
        })
    }
}

const bad = hits.filter((h) => !allowed(h))
for (const h of bad) console.log(`  ${h.rel}:${h.line}  ${h.text}`)
console.log(`\nswallowed query errors: ${bad.length} unallowed, ${hits.length - bad.length} allowlisted`)
if (bad.length) {
    console.log('查询失败必须【失败】—— 用 lib/db-helpers.ts 的 mustRows / mustOne / mustCount。')
    console.log('`?? []` 只对【不是查询结果】的东西成立(已取到的行上的嵌套字段、Map.get、客户端状态)。')
    console.log('确有例外就加进 ALLOWLIST 并写明理由。')
    process.exit(1)
}
console.log('✓ 没有把查询失败读成空集的地方(本检查看得见的那一类)')
