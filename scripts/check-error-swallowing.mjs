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
// 【CHECK-1(2026-08-31):此前抬头点名的三个盲区,两个补上了,一个补不了】
//
// 抬头原本写着三种抓不到的形状。CHECK-1 逐个量了一遍:
//
//   ① `if (error) return []` / `return null` / `return 0` —— **补上了**(swallow-return)。
//      全仓实测【1 处】:app/hr/leave/actions.ts:153,`previewLeaveDays` 把
//      RPC 失败读成 null。
//   ② `.catch(() => …)` —— **补上了**(swallow-catch)。全仓实测【1 处】:
//      app/inbound/[id]/assays/new/AssayForm.tsx:86,计价预览失败只是把转圈停掉。
//   ③ 压根不解构 error、直接 `data?.map(...)` —— **没补,而且不打算补**。
//      全仓实测【0 处】,但那不是不补的理由。不补的理由是:`?.` 在这个仓库里
//      绝大多数用在【已经取到的行】上的可空字段,而那是完全正确的写法。
//      要把"这个 `data` 是不是一个没检查过的查询结果"判出来,需要跟着变量走 ——
//      **那是类型/数据流分析,不是文本匹配**。硬做出来的近似会把成百上千处
//      正确的可选链判红,于是这道检查会被关掉。
//      **所以它是一条【写下来的约定】,不是一条检查**(Step 1 的最后一条)。
//      约定:*一个查询结果在被 `?.` 之前,必须先有人看过它的 error。*
//   ④ 把查询结果传进一个自己会兜底的辅助函数 —— 同 ③,同一个理由,同样不补。
//
// 【它看得见什么 —— 三类,各有各的判据】
//   swallow-coalesce  `data ?? []` / `?? 0` / `?? null`(原有的那一类)
//   swallow-return    `if (…error…) return []/null/0/{}`(单行与跨行都认)
//   swallow-catch     `.catch(() => …)` —— 【空手接住】,不重抛、不报错
//
// 【它仍然看不见什么 —— 点名,免得"✓ 通过"被当成"没有吞错"】
//   ✗ 上面的 ③ 与 ④,理由如上,是约定不是检查;
//   ✗ `.catch(err => { … })` 里【用了】err 的:那可能是正当的错误处理,
//     也可能是"打个 console.log 就算了"。判不出来,所以不判 —— 只抓空手接住的;
//   ✗ 跨函数的兜底(A 查、B 兜)。
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
        path: 'app/settings/import/page.tsx', match: 'res.data ?? []',
        reason: 'IMPORT-2:上一行就是 `if (res.error) return { status: "unavailable" }` —— '
            + '**失败有自己的一种状态,而且屏幕上说得出来**(guideUnavailable:"拿不到"'
            + '不等于"这张表没有受限列")。走到这一句就是成功返回,空数组是【真的零列】。'
            + '这正是本检查要的那个区别,只是它看不见上一行。',
    },
    {
        path: 'app/settings/import/template/[table]/route.ts', match: 'data ?? []',
        reason: 'IMPORT-2:上面几行已经显式 `if (error) return 503/403` 了 —— 走到这一句'
            + '就是 RPC 成功返回。而且紧接着还有一条 `cols.length === 0 → 503`:'
            + '**零列不是"这张表没有列",是模板来源坏了**,它按名报出来而不是发一张空表头。'
            + '也就是说这里的 ?? [] 之后【没有】任何一条路把空当成正常。',
    },
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

// ── QUEUED:【真缺陷,在册,不是豁免】────────────────────────────────────────
// ★ 这张表与上面的 ALLOWLIST 【意思相反,不要混】★
//   ALLOWLIST = "这不是缺陷"(上一行已经把 error 处理掉了,这里的 ?? 到不了)。
//   QUEUED    = "**这是缺陷**,只是不在这一刀里修" —— 它每一次都会被打印出来,
//               并且必须写明【去处】。
//
// 【为什么不放进 ALLOWLIST】放进去就等于断言它们是对的,而我不相信那句话:
// 一个静默返回 null 的请假天数预览,正是这个仓库已经付过账的那个形状
// (FIN-6:页面读不到数据却回 200)。**把一个没被认定为正确的东西记成"已豁免",
// 是让下一个读的人以为有人核过了。**
//
// 【为什么不在这一刀修】CHECK-1 是一刀【只动工具】的切次(R1)。这两处的修法各自
// 要判断"失败时这个屏幕该说什么",那是权限与错误处理那一刀的活。
// 【在册清单:CLEANUP-A 之后是【空的】—— 而它是被【做完】清空的,不是被改小的】
//
// CHECK-1 在这里立了两条,去处都写着「cleanup A」。CLEANUP-A(2026-08-31)把两条
// 都修掉了,于是它们从这张表里【删除】,而不是改判成 ALLOWLIST 或放宽判据:
//   · app/hr/leave/actions.ts —— previewLeaveDays 从前 `if (error) return null`,
//     而 null 在 LeaveForm 里【已经有主】(「两头日期还没填全」,渲染成「—」)。
//     现在它返回一个可判别的两支 { days } | { error },失败在屏幕上有自己的红字。
//   · app/inbound/[id]/assays/new/AssayForm.tsx —— 那个 .catch 从前只关转圈。
//     实测它比在册说的还坏一层:preview 保持【上一次的值】,于是过期的价格留在
//     屏幕上,而 applyBlocked = !!preview.error 仍是 false,"记录并应用"照样是主按钮。
//     现在它说话【并且】把过期结果清掉。
//
// 两处的 .catch 现在都带参数并且真的用了它(console.error + 面向用户的文案),
// 所以本检查按它自己写明的规矩不再判它们 —— 「空手接住」才是它要抓的东西,
// 而这两处不再是空手。**没有为它们加任何 ALLOWLIST 条目**:
// 加一条豁免等于让下一个读的人以为有人核过了,而事实是它们被修好了。
const QUEUED = []

const allowed = (h) => ALLOWLIST.some((a) =>
    h.rel.startsWith(a.path) && (!a.match || h.full.includes(a.match)))
const queued = (h) => QUEUED.find((a) =>
    h.rel.startsWith(a.path) && (!a.match || h.full.includes(a.match)))

// ① `xxxRes.data ?? []` / `.data ?? 0` / 解构出来的 `data ?? null`
const PATTERN = /(\w*(?:Res|res|result)?\??\.data|\bdata)\s*\?\?\s*(\[\]|0\b|null)/

// ② `if (…error…) return []/null/0/{}` —— 同一个吞,不同的句法。
//    【只认 return 一个空值的】:`if (error) return { ok:false, msg }` 是在【报告】失败,
//    不是在吞它 —— 那正是本检查希望人写的东西,判它红就是在惩罚正确的写法。
const RETURN_PATTERN = /\bif\s*\([^)]*\b[eE]rror\b[^)]*\)\s*\{?\s*return\s*(\[\]|null|0|\{\})\s*[;\n}]/

// ③ `.catch(() => …)` —— 【空手接住】。带参数的(`.catch(e => …)`)不判:
//    它可能在正当地处理,判不出来就不判(抬头点名过)。
const CATCH_PATTERN = /\.catch\(\s*(?:async\s*)?\(\s*\)\s*=>/

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
        const lines = readFileSync(file, 'utf8').split('\n')
        lines.forEach((line, i) => {
            const t = line.trim()
            if (t.startsWith('//') || t.startsWith('*')) return
            // 【跨行也要认】`if (error) {` 换行再 `return null` 是同一个吞。
            // 取两行的窗口而不是一行 —— 实测本仓库今天 0 处,而"今天没有"
            // 不是"抓不到也没关系"的理由:第 321 处正是这么写出来的。
            const window = line + '\n' + (lines[i + 1] ?? '')
            let kind = null
            if (PATTERN.test(line)) kind = 'coalesce'
            else if (RETURN_PATTERN.test(window)) kind = 'return'
            else if (CATCH_PATTERN.test(line)) kind = 'catch'
            if (kind) {
                hits.push({ rel, line: i + 1, text: t.slice(0, 110), full: line, kind })
            }
        })
    }
}

const KIND_LABEL = {
    coalesce: '?? 空值',
    return: 'if (error) return 空值',
    catch: '.catch(() => …) 空手接住',
}

const bad = [], onQueue = []
for (const h of hits) {
    if (allowed(h)) continue
    const q = queued(h)
    if (q) onQueue.push({ ...h, q })
    else bad.push(h)
}

for (const h of bad) console.log(`  ${h.rel}:${h.line}  [${KIND_LABEL[h.kind]}]  ${h.text}`)

// ── 在册的真缺陷:每一次都打印出来,而且说得出去处 ─────────────────────────
// 【为什么不是安静地跳过】R3:一个被压下去的违规,与一个不存在的违规,
// 在输出上长得一模一样。在册不等于消失。
if (onQueue.length) {
    console.log('')
    console.log(`· 在册的吞错 ${onQueue.length} 处 —— **这些是真缺陷,不是豁免**:`)
    for (const h of onQueue) {
        console.log(`     ${h.rel}:${h.line}  [${KIND_LABEL[h.kind]}]`)
        console.log(`       ${h.q.why}`)
        console.log(`       去处:${h.q.to}`)
    }
}

const nAllow = hits.filter(allowed).length
console.log(`\nswallowed query errors: ${bad.length} unallowed, `
    + `${onQueue.length} queued(真缺陷,在册), ${nAllow} allowlisted(不是缺陷)`)
console.log(`   按类别:` + Object.entries(KIND_LABEL)
    .map(([k, v]) => `${v} ${hits.filter((h) => h.kind === k).length}`).join(' · '))

if (bad.length) {
    console.log('查询失败必须【失败】—— 用 lib/db-helpers.ts 的 mustRows / mustOne / mustCount。')
    console.log('`?? []` 只对【不是查询结果】的东西成立(已取到的行上的嵌套字段、Map.get、客户端状态)。')
    console.log('【两张表,意思相反,别放错】')
    console.log('  · 确认它【不是缺陷】(上一行已经处理了 error)→ ALLOWLIST,写明理由;')
    console.log('  · 它【是缺陷】但不在这一刀修 → QUEUED,写明理由【和去处】。')
    console.log('  放错的代价不对称:错记成 ALLOWLIST,下一个读的人会以为有人核过了。')
    process.exit(1)
}
console.log('✓ 没有【新增】把查询失败读成空集的地方(本检查看得见的那三类)')
