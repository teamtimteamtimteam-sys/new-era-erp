#!/usr/bin/env node
// scripts/check-org-tree.mjs — 汇报树的六种脏数据,逐个钉住。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么这条检查非有不可 —— 它守的分支,线上【永远走不到】】
// CHART-1 ③ 点名六种情况:没有上级 / 多个根 / 上级已删或停用 / 空部门 / 汇报环。
// 而线上今天(实测 2026-09-03)是:9 个未删员工,**manager_id 非空 0 个**。
// 也就是说 **六种里有五种在真实数据上一次都不会发生** —— 打开那一页看一眼,
// 看到的永远是"全是根"这一种。
// **一条只在打不到的分支里成立的正确性,等于没有被验证过。**
// 所以这里把六种情况各喂一次,断言它们各自渲染成什么。
//
// 【它不连数据库】纯函数进、纯结构出。库里有没有这些行与本检查无关 ——
// 这正是它能测到那五个分支的原因。**线上那一半由 db/fixtures/181 另外钉。**
//
// 【故障注入怎么做】改 lib/orgTree.ts 里对应的那一行,本脚本必须变红并指名道姓。
// 退出码 0 = 全过;1 = 有断言不成立。
// ════════════════════════════════════════════════════════════════════════════
import { buildOrgTree, isDeparted, showsStatus, flattenForList } from '../lib/orgTree.ts'

let failures = 0
const fails = []
function check(name, cond, detail) {
    if (cond) return
    failures++
    // 【失败要报得出 file:line】一句"某条断言不成立"会让人回来数括号。
    // 从调用栈里取本文件的那一帧 —— 断言写在哪一行,红就指哪一行。
    const at = (new Error().stack || '').split('\n')
        .find((l) => l.includes('check-org-tree.mjs') && !l.includes('at check '))
    const loc = at ? at.replace(/^.*?\(?(scripts\/check-org-tree\.mjs:\d+:\d+)\)?\s*$/, '$1') : '?'
    fails.push(`${loc}  ${name}${detail ? ` —— ${detail}` : ''}`)
}

// 造人的小工具。**默认在职、无上级、无部门** —— 每个用例只写它自己关心的那一格。
let seq = 0
const emp = (over = {}) => ({
    id: over.id ?? `e${++seq}`,
    code: over.code ?? `EMP-${seq}`,
    name: over.name ?? `P${seq}`,
    manager_id: null,
    department_id: null,
    employment_status: 'active',
    ...over,
})

// ── ① 没有上级的人 → 一个根,而且【不带 issue】────────────────────────────
{
    const a = emp({ id: 'a', name: 'Alice' })
    const t = buildOrgTree([a], [])
    check('①-a 没有上级的人落在 roots 上', t.roots.length === 1 && t.roots[0].emp.id === 'a',
        `roots=${t.roots.map((r) => r.emp.id).join(',')}`)
    check('①-b 没有上级【不是】一处毛病(issue 必须为 null)', t.roots[0]?.issue === null,
        `issue=${JSON.stringify(t.roots[0]?.issue)}`)
    check('①-c 没有汇报边', t.linkedCount === 0, `linkedCount=${t.linkedCount}`)
    check('①-d 深度 1', t.maxDepth === 1, `maxDepth=${t.maxDepth}`)
}

// ── ② 多个根 → 全部保留,一个都不吞 ────────────────────────────────────────
{
    const es = [emp({ id: 'r1', name: 'R1' }), emp({ id: 'r2', name: 'R2' }), emp({ id: 'r3', name: 'R3' })]
    const t = buildOrgTree(es, [])
    check('②-a 三个人全是根', t.rootCount === 3, `rootCount=${t.rootCount}`)
    check('②-b 一个人都没丢', t.total === 3 && flattenForList(t.roots).length === 3,
        `total=${t.total} flat=${flattenForList(t.roots).length}`)
}

// ── ③ 上级【本页看不见】(已软删 / 被 RLS 挡住)───────────────────────────
//     要求:落到顶层,**并且带着 manager_not_visible** —— 与"没有上级"分得开。
{
    const child = emp({ id: 'c', name: 'Child', manager_id: 'ghost' })
    const t = buildOrgTree([child], [])
    check('③-a 上级看不见的人仍然渲染(不被丢掉)', t.total === 1 && t.roots.length === 1,
        `total=${t.total} roots=${t.roots.length}`)
    check('③-b 带着 manager_not_visible,并说得出指向谁',
        t.roots[0]?.issue?.kind === 'manager_not_visible' && t.roots[0]?.issue?.managerId === 'ghost',
        `issue=${JSON.stringify(t.roots[0]?.issue)}`)
    check('③-c 它与【没有上级】不是同一种(后者 issue 为 null)',
        buildOrgTree([emp({ id: 'x' })], [])[ 'roots' ][0].issue === null)
}

// ── ④ 上级【已离岗但没删】→ 照画,而那个人认得出是离岗的 ───────────────────
{
    const boss = emp({ id: 'b', name: 'Boss', employment_status: 'separated' })
    const sub = emp({ id: 's', name: 'Sub', manager_id: 'b' })
    const t = buildOrgTree([boss, sub], [])
    check('④-a 停用的上级仍是根,下属挂在他下面',
        t.roots.length === 1 && t.roots[0].emp.id === 'b' && t.roots[0].children.length === 1,
        `roots=${t.roots.length} children=${t.roots[0]?.children.length}`)
    check('④-b 已离岗认得出来', isDeparted(boss) === true && isDeparted(sub) === false)
    // ★ 窄判据:服通知期的人【还在上班】,不算离岗 —— 但状态仍然要显示出来
    check('④-e notice【不】算离岗(人还在上班)',
        isDeparted(emp({ employment_status: 'notice' })) === false)
    check('④-f 但 notice 的状态仍然显示在名字旁边',
        showsStatus(emp({ employment_status: 'notice' })) === true &&
        showsStatus(emp({ employment_status: 'active' })) === false)
    check('④-c 这条边算【连上了】', t.linkedCount === 1, `linkedCount=${t.linkedCount}`)
    check('④-d 深度 2', t.maxDepth === 2, `maxDepth=${t.maxDepth}`)
}

// ── ⑤ 一个成员都没有的部门 → 单独列出来,不是"不存在" ───────────────────────
{
    const d1 = { id: 'd1', code: 'Dep-001', name: 'Finance' }
    const d2 = { id: 'd2', code: 'Dep-002', name: 'Empty Dept' }
    const a = emp({ id: 'a', department_id: 'd1' })
    const t = buildOrgTree([a], [d1, d2])
    check('⑤-a 空部门被点名', t.emptyDepartments.length === 1 && t.emptyDepartments[0].id === 'd2',
        `empty=${t.emptyDepartments.map((d) => d.code).join(',')}`)
    check('⑤-b 有人的部门不算空', !t.emptyDepartments.some((d) => d.id === 'd1'))
    check('⑤-c 没有部门行时,空部门清单是空的(不是崩)', buildOrgTree([a], []).emptyDepartments.length === 0)
}

// ── ⑥ 汇报环 A→B→A —— 最要紧的一条 ────────────────────────────────────────
//     要求:**报出来**(cycles 非空)、**不静默丢人**(total 仍然是 2)、
//     **不出现在 roots 上**(它不是一棵树的根)、**不爆栈**。
{
    const a = emp({ id: 'a', name: 'A', manager_id: 'b' })
    const b = emp({ id: 'b', name: 'B', manager_id: 'a' })
    const t = buildOrgTree([a, b], [])
    check('⑥-a 环被报出来', t.cycles.length === 1, `cycles=${t.cycles.length}`)
    check('⑥-b 环上两个人都在里面',
        t.cycles[0]?.members.length === 2 &&
        new Set(t.cycles[0].members.map((m) => m.emp.id)).size === 2,
        `members=${t.cycles[0]?.members.map((m) => m.emp.id).join(',')}`)
    check('⑥-c 环上的人【不】出现在 roots 上', t.roots.length === 0, `roots=${t.roots.length}`)
    check('⑥-d 一个人都没被丢掉', t.total === 2, `total=${t.total}`)
}

// ── ⑥bis 自环 A→A(一个人是自己的上级)—— 同样是环,同样要报 ────────────────
{
    const a = emp({ id: 'a', name: 'A' })
    a.manager_id = 'a'
    const t = buildOrgTree([a], [])
    check('⑥bis-a 自环被当成环报出来', t.cycles.length === 1, `cycles=${t.cycles.length}`)
    check('⑥bis-b 自环上的人不在 roots 上', t.roots.length === 0, `roots=${t.roots.length}`)
    check('⑥bis-c 没被丢掉', t.total === 1)
}

// ── ⑥ter 挂在环下面的人 —— 他不是环的一部分,但也【不能消失】 ────────────────
{
    const a = emp({ id: 'a', name: 'A', manager_id: 'b' })
    const b = emp({ id: 'b', name: 'B', manager_id: 'a' })
    const c = emp({ id: 'c', name: 'C', manager_id: 'a' }) // 挂在环成员 a 下面
    const t = buildOrgTree([a, b, c], [])
    check('⑥ter-a 环仍然只有两个成员', t.cycles[0]?.members.length === 2,
        `members=${t.cycles[0]?.members.length}`)
    check('⑥ter-b 环下面那个人挂在 a 下面,没有消失',
        t.cycles[0]?.members.find((m) => m.emp.id === 'a')?.children.some((x) => x.emp.id === 'c') === true,
        `a.children=${t.cycles[0]?.members.find((m) => m.emp.id === 'a')?.children.map((x) => x.emp.id).join(',')}`)
    check('⑥ter-c 他也不在 roots 上(他有一个看得见的上级)', t.roots.length === 0, `roots=${t.roots.length}`)
    check('⑥ter-d 三个人一个都没丢', t.total === 3)
}

// ── ⑦ 两条互不相干的环,同时存在 → 报两条,不是一条 ─────────────────────────
{
    const es = [
        emp({ id: 'a', name: 'A', manager_id: 'b' }), emp({ id: 'b', name: 'B', manager_id: 'a' }),
        emp({ id: 'c', name: 'C', manager_id: 'd' }), emp({ id: 'd', name: 'D', manager_id: 'c' }),
    ]
    const t = buildOrgTree(es, [])
    check('⑦-a 两条环分别报出来', t.cycles.length === 2, `cycles=${t.cycles.length}`)
    check('⑦-b 四个人都在环上', t.cycles.flatMap((c) => c.members).length === 4)
}

// ── ⑧ 空输入 → 不崩,而且说得出"零" ───────────────────────────────────────
{
    const t = buildOrgTree([], [])
    check('⑧-a 空输入不崩,total=0', t.total === 0 && t.roots.length === 0 && t.cycles.length === 0)
    check('⑧-b 没有人时深度是 0,不是 1', t.maxDepth === 0, `maxDepth=${t.maxDepth}`)
}

// ── ⑨ 线上今天【就是】这一种:全是根、零汇报边 ─────────────────────────────
//     它不是脏数据,但它是【实际会渲染的那一支】,所以也钉住。
{
    const es = Array.from({ length: 9 }, (_, i) => emp({ id: `p${i}`, name: `P${i}` }))
    const t = buildOrgTree(es, [{ id: 'd1', code: 'Dep-001', name: 'Finance Department' }])
    check('⑨-a 九个人全是根', t.rootCount === 9 && t.linkedCount === 0,
        `rootCount=${t.rootCount} linked=${t.linkedCount}`)
    check('⑨-b 没有环', t.cycles.length === 0)
    check('⑨-c 唯一那个部门算【空】(没有人挂在它上面)', t.emptyDepartments.length === 1)
}

// ── ⑩ 深链 —— 不许 O(n²) 走法,也不许爆栈 ─────────────────────────────────
{
    const N = 2000
    const es = []
    for (let i = 0; i < N; i++) es.push(emp({ id: `n${i}`, name: `N${i}`, manager_id: i === 0 ? null : `n${i - 1}` }))
    const t0 = Date.now()
    const t = buildOrgTree(es, [])
    const ms = Date.now() - t0
    check('⑩-a 2000 人的一条链推得出来', t.total === N && t.rootCount === 1 && t.maxDepth === N,
        `total=${t.total} roots=${t.rootCount} depth=${t.maxDepth}`)
    check('⑩-b 一秒之内(不是 O(n²))', ms < 1000, `${ms}ms`)
}

// ── 报告 ──────────────────────────────────────────────────────────────────
if (failures) {
    console.error(`✗ check-org-tree:${failures} 条断言不成立`)
    for (const f of fails) console.error(`   · ${f}`)
    console.error('\n  这些分支线上一次都走不到(manager_id 非空 0 个),所以它们只有这里守着。')
    process.exit(1)
}
console.log('✓ check-org-tree:六种脏数据 + 深链 + 空输入,全部按名成立')
