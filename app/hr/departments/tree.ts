// app/hr/departments/tree.ts
// 上级下拉的候选计算:把【自己】与【自己的所有下级】剔掉 —— 选了会成环的项
// 根本不出现在列表里。DB 的 DEPARTMENT_CYCLE 触发器是后墙,不是第一道防线。
// 普通模块(非 server action),由服务端页面调用。

export type DeptNode = { id: string; code: string; name_en: string; parent_department_id: string | null }

export function descendantIds(all: DeptNode[], rootId: string): Set<string> {
    const childrenOf = new Map<string, string[]>()
    for (const d of all) {
        if (!d.parent_department_id) continue
        const arr = childrenOf.get(d.parent_department_id) ?? []
        arr.push(d.id)
        childrenOf.set(d.parent_department_id, arr)
    }
    const out = new Set<string>()
    const stack = [rootId]
    while (stack.length) {
        const cur = stack.pop()!
        for (const child of childrenOf.get(cur) ?? []) {
            if (out.has(child)) continue // 数据万一已成环也不会打转
            out.add(child)
            stack.push(child)
        }
    }
    return out
}

export function parentOptionsFor(all: DeptNode[], selfId?: string) {
    const excluded = selfId ? descendantIds(all, selfId) : new Set<string>()
    if (selfId) excluded.add(selfId)
    return all
        .filter((d) => !excluded.has(d.id))
        .map((d) => ({ id: d.id, label: `${d.code} — ${d.name_en}` }))
}
