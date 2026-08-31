#!/usr/bin/env node
// scripts/check-scratch-rows.mjs —— 临时行体检:【报告,不删除】
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么是报告而不是清扫 —— 这一句是本文件存在的理由】
//
// 一次清扫必须【依据一个它无法核实的判断去动手】:这一行是上次崩掉的残骸,
// 还是另一个进程此刻正在用的?两者长得一模一样。sweepScratch 就是这么在
// 2026-08-10 把另一个会话正在跑的账号删掉的(docs/concurrency-one-tree-one-smoke.md)。
// 它没有归属信息,也没有年龄判据 —— 而把它扩到更多张表,只会让同一个 bug 的
// 爆炸半径更大。
//
// 【归属与年龄,正是清扫不能安全知道、而报告可以照直说出来的东西。】
// 同样的不确定,两种代价:报告说错了,人多看一眼;清扫做错了,正在跑的活被毁掉。
// 所以这里只【陈述】判断,不【依据】它动手。
//
// 【它当场就证明了自己】第一次跑,它在 materials 里找到 ZZ-SMOKE-PROBE ——
// 一个命名像残骸的行,而【一张在册的真批次 IN-2026-0180(Acme,100,000 kg)
// 正引用着它】。一次按命名规则清扫的动作会把它删掉,并让那张真批次指向一个
// 已删的物料。所以"有没有人在引用它"是本报告的第三列,不是可选的装饰。
// ════════════════════════════════════════════════════════════════════════════
//
// 用法:node scripts/check-scratch-rows.mjs      (也在冒烟开跑时自动跑一次)
// 退出码:0 = 没有滞留行;1 = 有滞留行(【报告,不动手】—— 由人决定怎么处置)
import { readFileSync } from 'node:fs'

const ROOT = new URL('..', import.meta.url).pathname
const env = readFileSync(ROOT + '.env.local', 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

// 【年龄门槛:2 小时】判据是【实测出来的最长一跑】—— --reach 量到 65 分 44 秒
// (2026-08-11,见 AGENTS.md)。门槛必须明显高于它,否则一次 --reach 跑到一半,
// 它自己的行就会被本报告点名为"滞留" —— 那正是"喊狼来了的报告没人看"的开始。
// 2 小时给了将近一倍的余量,同时仍然抓得住隔夜的残骸。
//
// 【为什么用年龄而不是运行标记】运行标记要么改表结构(给 employees 加一列,
// 只为体检用),要么只覆盖冒烟自己写的那几张表 —— 而实测发现的残骸【不是冒烟
// 写的】,是 2026-08-06 一次没有回滚的 fixture/探针留下的。年龄对每一种来源
// 都成立,而且不需要任何一方配合。
const STRANDED_AFTER_MS = 2 * 60 * 60 * 1000

// 扫哪些表、按什么命名认临时行。【只认命名,不认内容】—— 命名是这个仓库自己
// 定的约定(smoke-* 账号、ZZ-SMOKE-* 业务行、fixture-* / probe-* 角色)。
const TARGETS = [
    { table: 'materials',        like: 'ZZ-SMOKE%', refs: [['inbound_batches', 'material_id'], ['output_batches', 'material_id']] },
    { table: 'suppliers',        like: 'ZZ-SMOKE%', refs: [['inbound_batches', 'supplier_id'], ['purchase_orders', 'supplier_id']] },
    { table: 'customers',        like: 'ZZ-SMOKE%', refs: [['sales_records', 'customer_id']] },
    { table: 'employees',        like: 'ZZ-SMOKE%', refs: [['performance_reviews', 'employee_id']] },
    { table: 'inbound_batches',  like: 'ZZ-SMOKE%', refs: [['processing_inputs', 'inbound_batch_id']] },
    { table: 'output_batches',   like: 'ZZ-SMOKE%', refs: [['sales_records', 'output_batch_id']] },
    { table: 'purchase_orders',  like: 'ZZ-SMOKE%', refs: [['inbound_batches', 'purchase_order_id']] },
    { table: 'processing_runs',  like: 'ZZ-SMOKE%', refs: [] },
    { table: 'roles',            like: 'fixture-%', refs: [['user_roles', 'role_id']] },
    { table: 'roles',            like: 'probe-%',   refs: [['user_roles', 'role_id']] },
]

const rest = (p) => fetch(URL_ + p, {
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } })

async function rows(path, ctx) {
    const r = await rest(path)
    const body = await r.text()
    let out = null
    try { out = JSON.parse(body) } catch {}
    // 查询失败 ≠ 没有临时行 —— 与 restRows / mustRows 同一条规矩:失败必须响亮
    if (!r.ok || !Array.isArray(out))
        throw new Error(`临时行查询失败(${ctx}): HTTP ${r.status} ${body.slice(0, 200)}`)
    return out
}

async function main() {
    const now = Date.now()
    const recent = []
    const stranded = []

    for (const { table, like, refs } of TARGETS) {
        // 有 deleted_at 的表也要查:软删的行仍然占着编号与外键
        const found = await rows(
            `/rest/v1/${table}?select=id,code,created_at&code=like.${encodeURIComponent(like)}`,
            `${table} ← ${like}`)
        for (const row of found) {
            const age = now - new Date(row.created_at).getTime()
            const rec = { table, code: row.code, id: row.id, ageH: (age / 3600000).toFixed(1), refs: [] }
            if (age < STRANDED_AFTER_MS) { recent.push(rec); continue }
            // 【第三列:还有谁在引用它】—— 这一列把"残骸"与"有人依赖的残骸"分开,
            // 而后者【不能删】。第一次跑就抓到一个(见文件抬头)。
            for (const [refTable, col] of refs) {
                const hits = await rows(
                    `/rest/v1/${refTable}?select=id&${col}=eq.${row.id}&limit=5`,
                    `${refTable}.${col} ← ${row.code}`)
                if (hits.length) rec.refs.push(`${refTable}.${col} × ${hits.length}`)
            }
            stranded.push(rec)
        }
    }

    const accounts = await (await rest('/auth/v1/admin/users?per_page=1000')).json()
    const authUsers = accounts?.users ?? []
    for (const u of authUsers) {
        if (!(u.email ?? '').startsWith('smoke-') || !(u.email ?? '').endsWith('@test.local')) continue
        const age = now - new Date(u.created_at).getTime()
        const rec = { table: 'auth.users', code: u.email, id: u.id, ageH: (age / 3600000).toFixed(1), refs: [] }
        ;(age < STRANDED_AFTER_MS ? recent : stranded).push(rec)
    }

    // ════════════════════════════════════════════════════════════════════════
    // 【幽灵授权:user_roles 里 user_id 在 auth.users 中根本不存在的行】
    //
    // ★ CLEANUP-A(2026-08-31)为什么加这一段 ★
    //   上面那一圈按【命名】认残骸,而幽灵授权指向的是【真的 admin 角色】,
    //   名字上没有任何可疑之处。ACCOUNTS-CLEAN 在 2026-08-24 手工删掉 66 条,
    //   **一周后又长回 21 条(8 条 08-26 + 13 条 08-31)** —— 而这段时间里
    //   没有任何一支检查看得见它们:
    //     · 冒烟自己的 sweepScratch 是【列出账号再清理】,账号一旦被删,
    //       那行授权此后【永远】不在它的视野里;
    //     · 本文件从前只扫 roles 的 fixture-% / probe-%,而这些指向真 admin。
    //   于是第三次清扫只能靠人偶然去数一遍 —— 那不是机制。
    //
    // 【为什么不加外键了事】fixtures 用 gen_random_uuid() 造 user_roles 行(约二十支),
    //   一条指向 auth.users 的外键会当场把它们全部打死。结构上绑定这条路是关着的,
    //   所以检测就是可走的那条。
    //
    // 【判据是"auth 行不存在",不是"这个人登不进来"】两者是完全不同的事实。
    //   Choo Er Teh(chef1949@126.com)的 auth 行【在】,只是邮箱从未验证 ——
    //   她的授权是真的,按这条判据不可能被点名。**登不进来 ≠ 认不到人。**
    const roleRows = await rows('/rest/v1/roles?select=id,code', '角色码')
    const roleCode = new Map(roleRows.map((r) => [r.id, r.code]))
    const grants = await rows(
        '/rest/v1/user_roles?select=id,user_id,role_id,granted_at,revoked_at', '授权')
    const authIds = new Set(authUsers.map((u) => u.id))
    // 【账号列表分页截断了就不要下判断】per_page=1000 若刚好取满,说明可能还有下一页,
    // 而"没在这一页里"就不再等于"不存在" —— 那会把真人的授权错报成幽灵。
    // 报告说错了人多看一眼,但这一条错得【方向不对】:它会诱人去删一条真的授权。
    if (authUsers.length >= 1000) {
        console.log('\n⚠ auth 账号可能不止一页(取到 1000 条),本轮【跳过】幽灵授权检查 —— ' +
            '"没在这一页里"不等于"不存在"。')
    } else {
        for (const g of grants) {
            if (authIds.has(g.user_id)) continue
            if (g.revoked_at) continue          // 已撤销的不再是一处暴露
            const age = now - new Date(g.granted_at).getTime()
            const rec = {
                table: 'user_roles', code: `${roleCode.get(g.role_id) ?? '?'} ← ${g.user_id}`,
                id: g.id, ageH: (age / 3600000).toFixed(1),
                refs: [],
                // 【与"仍被引用"相反的处置】那一类的忠告是"不要直接删"(删了会让真单据
                // 指向已删的行);幽灵授权【正好相反】—— 它背后没有人,而它让
                // "这个角色有几个持有人"这个会被人据以行动的数字说假话。
                note: '【认不到人】auth.users 里没有这个 user_id —— '
                    + '这一条与上面"仍被引用"的处置相反:它应当删掉。'
                    + '判据是 auth 行不存在,不是"这个人登不进来"(后者是真人,不要动)。',
            }
            ;(age < STRANDED_AFTER_MS ? recent : stranded).push(rec)
        }
    }

    if (recent.length) {
        console.log(`\n临时行(${(STRANDED_AFTER_MS / 3600000)} 小时以内 —— 可能是【正在跑的那一次】,不是残骸):`)
        for (const r of recent) console.log(`  · ${r.table.padEnd(18)} ${r.code}  (${r.ageH}h)`)
        console.log('  这些不需要处理:下一次冒烟开跑时的 sweepScratch 会带走它自己那几张表的行。')
    }

    if (!stranded.length) {
        console.log(`\n✓ 没有滞留的临时行(超过 ${(STRANDED_AFTER_MS / 3600000)} 小时的一条都没有)`)
        return 0
    }

    console.log(`\n⚠ 滞留的临时行 ${stranded.length} 条（超过 ${(STRANDED_AFTER_MS / 3600000)} 小时，没有哪一次运行还应当持有它们）:`)
    for (const r of stranded) {
        const tail = r.note
            ? `\n      ← ${r.note}`
            : r.refs.length
                ? `  ← 【仍被引用:${r.refs.join('、')}】不要直接删`
                : '  (无人引用)'
        console.log(`  · ${r.table.padEnd(18)} ${r.code}  (${r.ageH}h)${tail}`)
    }
    console.log('\n【本检查只报告,不删除】归属与年龄正是一次清扫无法安全知道、而报告可以')
    console.log('照直说出来的东西:同样的不确定,报告说错了人多看一眼,清扫做错了正在跑的活被毁掉。')
    console.log('怎么处置由人决定 —— 尤其是上面标着【仍被引用】的那些:删掉它们会让一张真单据')
    console.log('指向一个已删的行,而那比留着残骸坏得多。')
    return 1
}

let code = 0
try { code = await main() } catch (e) { console.error('✗ ' + e.message); code = 1 }
process.exit(code)
