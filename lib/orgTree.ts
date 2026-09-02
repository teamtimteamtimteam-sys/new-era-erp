// lib/orgTree.ts — 汇报关系:从【行】推出【树】,以及推不出树的那些情况。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么这段逻辑住在 lib/ 而不住在那个页面里】
// 它要能被【断言】。CHART-1 ③ 点名要求六种脏数据各自渲染成什么,而其中五种
// **线上一行都没有**(实测 2026-09-03:9 个未删员工,manager_id 非空 0 个)。
// 一个只在页面里存在的算法,只能靠"打开页面看一眼"来验证 —— 而线上打开页面
// 恰好【永远走不到】那五个分支。所以判据必须离开 React,住在一个纯函数里,
// 由 scripts/check-org-tree.mjs 逐个喂给它。
//
// 【本模块不读数据库、不认识 React】输入是行,输出是树。这是它可测的全部原因。
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【一条环必须【看得见】,不能被静默丢掉】★★
// A 汇报给 B、B 汇报给 A —— 这在树里放不下。最省事的写法是把环上的人丢掉
// (或者更糟:递归到爆栈)。两种都错:**一条汇报环是一处数据错误,有人得去改它**,
// 而一个把它藏起来的页面会让那个人永远不知道。所以环在这里是一个【一等公民的
// 返回值】(OrgTree.cycles),页面据此画出一块显眼的告示。
//
// 【本模块【不】读任何遮蔽列】(CHART-1 ③)
// OrgEmployee 上的字段就是本页读的全部字段。employees 上被从 authenticated
// 收回的五列是 work_email / work_phone / identity_no / work_pass_no /
// monthly_salary(实测 has_column_privilege,2026-09-03)—— **一个都不在下面。**
// 加字段的人:先去查那张表的列权限,再决定加不加。

/** 本页读的员工字段 —— **就是这些,没有别的**。任何一个遮蔽列都不在其中。 */
export type OrgEmployee = {
    id: string
    code: string
    /** preferred_name ?? legal_name,取好了再传进来 */
    name: string
    manager_id: string | null
    department_id: string | null
    employment_status: string
}

export type OrgDepartment = {
    id: string
    code: string
    name: string
}

/** 一个人身上【单独标出来】的毛病。null = 这个人没毛病。 */
export type OrgNodeIssue =
    /** 他的 manager_id 指着一个本页看不见的人(已软删 / 被 RLS 挡住 / 行不存在)。
     *  **这不等于"他没有上级"** —— 两者在屏幕上必须说成两句话。 */
    | { kind: 'manager_not_visible'; managerId: string }

export type OrgNode = {
    emp: OrgEmployee
    children: OrgNode[]
    depth: number
    issue: OrgNodeIssue | null
}

/** 一条汇报环:环上的人(按汇报方向排好),各自带着挂在他下面的非环子树。 */
export type OrgCycle = {
    /** 环上成员,order[i] 汇报给 order[i+1],最后一个汇报给 order[0] */
    members: OrgNode[]
}

export type OrgTree = {
    /** 顶层的人:没有上级,或者上级本页看不见。**不含环上的人。** */
    roots: OrgNode[]
    /** 放不进树的那些 —— 每一条都要在屏幕上被点名 */
    cycles: OrgCycle[]
    /** 一个成员都没有的部门(未删部门 − 有人挂着的部门) */
    emptyDepartments: OrgDepartment[]
    /** 传进来多少人(= 树上 + 环上,两者互斥且穷尽) */
    total: number
    /** 有多少人是【顶层】—— 多根本身不是错误,但"全是根"是一句要说的话 */
    rootCount: number
    /** 最深几层(根 = 1)。全是根时 = 1;没有人时 = 0。 */
    maxDepth: number
    /** 有几条汇报边真的连上了(= total − rootCount − 环上人数) */
    linkedCount: number
}

/**
 * 【已离岗】—— 而这个判据要窄,窄是有理由的。
 *
 * employees.employment_status 的取值实测是四个(表上的 CHECK):
 *     probation · active · notice · separated
 * 只有 `separated` 是"人已经走了、行还留着"。**`notice` 是在服通知期,人还在上班**,
 * 把他标成"已停用"是一句假话 —— 而组织架构图正是那种"上面写什么就被信什么"的屏幕。
 * 所以这里【不】用"非 active 即停用"那种宽判据。
 *
 * 屏幕上仍然把 `notice` 显示出来(任何非 active 的状态都显示),
 * 只是它不触发"这个人的上级已经不在了"那句话。
 */
export function isDeparted(e: OrgEmployee): boolean {
    return e.employment_status === 'separated'
}

/** 状态值要不要在名字旁边显示出来 —— active 是常态,不必标。 */
export function showsStatus(e: OrgEmployee): boolean {
    return e.employment_status !== 'active'
}

/**
 * 找出全部汇报环。
 *
 * 【为什么是这个走法】每个人最多一个上级,所以这张图是一片"功能图"
 * (每个点出度 ≤ 1)—— 它的环一定互不相交,而且从任何一点往上走
 * 要么走到头、要么撞进【唯一】一条环。于是不需要 Tarjan:
 * 沿着上级链走,遇到本次路径里已经出现过的点,那一段就是环。
 *
 * 【为什么带 state】不带的话,n 个人挂在同一条链上会走 O(n²)。
 * 走过即标记 done,总代价 O(n)。
 */
function findCycles(
    emps: OrgEmployee[],
    byId: Map<string, OrgEmployee>,
): { cycles: string[][]; cycleMembers: Set<string> } {
    const done = new Set<string>()
    const cycles: string[][] = []
    const cycleMembers = new Set<string>()

    for (const start of emps) {
        if (done.has(start.id)) continue
        const path: string[] = []
        const posInPath = new Map<string, number>()
        let cur: string | null = start.id

        while (cur !== null) {
            if (posInPath.has(cur)) {
                // 撞回本次路径 —— 从那一点到路径末尾就是环
                const cyc = path.slice(posInPath.get(cur)!)
                cycles.push(cyc)
                for (const id of cyc) cycleMembers.add(id)
                break
            }
            if (done.has(cur)) break // 撞进上一轮已经走完的部分,不会有新环
            posInPath.set(cur, path.length)
            path.push(cur)
            const node = byId.get(cur)
            const mgr = node?.manager_id ?? null
            // 【指着一个看不见的人 = 到头了】,不是继续走
            cur = mgr !== null && byId.has(mgr) ? mgr : null
        }
        for (const id of path) done.add(id)
    }
    return { cycles, cycleMembers }
}

/**
 * 把员工行与部门行推成一棵(或几棵)树。
 *
 * **不抛异常。** 任何一种脏数据都推得出一个能画的结果 —— 那正是本函数存在的理由。
 */
export function buildOrgTree(
    employees: OrgEmployee[],
    departments: OrgDepartment[] = [],
): OrgTree {
    const byId = new Map(employees.map((e) => [e.id, e]))
    const { cycles: cycleIdGroups, cycleMembers } = findCycles(employees, byId)

    const mkNode = (e: OrgEmployee): OrgNode => {
        const mgr = e.manager_id
        const issue: OrgNodeIssue | null =
            mgr !== null && !byId.has(mgr) ? { kind: 'manager_not_visible', managerId: mgr } : null
        return { emp: e, children: [], depth: 0, issue }
    }

    const nodes = new Map<string, OrgNode>()
    for (const e of employees) nodes.set(e.id, mkNode(e))

    // 把非环成员挂到各自上级下面
    const roots: OrgNode[] = []
    for (const e of employees) {
        if (cycleMembers.has(e.id)) continue // 环上的人由下面单独处理
        const node = nodes.get(e.id)!
        const mgr = e.manager_id
        // 【上级看不见】与【没有上级】都落到顶层,但前者带着 issue,
        // 于是屏幕上它们是两句不同的话。
        if (mgr === null || !byId.has(mgr)) { roots.push(node); continue }
        // 上级在环上:这个人挂在那个环成员下面(环那一块自己会画他)
        nodes.get(mgr)!.children.push(node)
    }

    const cycles: OrgCycle[] = cycleIdGroups.map((ids) => ({
        members: ids.map((id) => nodes.get(id)!),
    }))

    // 深度:从每个根往下压。环上的人不参与 —— 他们没有"层数"这个概念。
    let maxDepth = 0
    const assign = (n: OrgNode, d: number) => {
        n.depth = d
        if (d > maxDepth) maxDepth = d
        for (const c of n.children) assign(c, d + 1)
    }
    for (const r of roots) assign(r, 1)
    // 环成员的子树也要有 depth(画列表缩进要用),从 1 起算
    for (const c of cycles) for (const m of c.members) assign(m, 1)

    // 名字排序,让两次渲染稳定(否则 PostgREST 顺序一变,页面就抖)
    const sortRec = (ns: OrgNode[]) => {
        ns.sort((a, b) => a.emp.name.localeCompare(b.emp.name) || a.emp.code.localeCompare(b.emp.code))
        for (const n of ns) sortRec(n.children)
    }
    sortRec(roots)
    for (const c of cycles) sortRec(c.members.flatMap((m) => m.children))

    // 【空部门】= 未删部门里,没有任何一个本页看得见的人挂着的
    const occupied = new Set(employees.map((e) => e.department_id).filter(Boolean) as string[])
    const emptyDepartments = departments
        .filter((d) => !occupied.has(d.id))
        .sort((a, b) => a.code.localeCompare(b.code))

    const cycleMemberCount = cycleMembers.size
    return {
        roots,
        cycles,
        emptyDepartments,
        total: employees.length,
        rootCount: roots.length,
        maxDepth: employees.length === 0 ? 0 : maxDepth,
        linkedCount: employees.length - roots.length - cycleMemberCount,
    }
}

/** 扁平化成【缩进列表】用的序列(窄屏渲染 + 断言都用它)。 */
export function flattenForList(nodes: OrgNode[]): OrgNode[] {
    const out: OrgNode[] = []
    const walk = (ns: OrgNode[]) => {
        for (const n of ns) { out.push(n); walk(n.children) }
    }
    walk(nodes)
    return out
}
