// NTF-1:通知在应用这一侧的形状。
//
// 【门牌的判据与 LINKS-1 逐字相同】:指向【补救动作所在的那张页面】。
// 库位没配置 / 库位排除了这一类 → 库位编辑页(许可分类就在那里改);
// 物料没分类 / 物料被重新分类 → 物料编辑页(分类就在那里改)。

export type NotificationRow = {
    id: string
    occurred_at: string
    event_type: string
    subject_type: string
    subject_id: string | null
    subject_code: string | null
    payload: Record<string, unknown> | null
}

// 主体 → 那件事自己的页面。【未知主体返回 null】—— 不猜一个 URL 出来:
// 一条点开是 404 的通知比一条不能点的通知更坏。
export function subjectHref(row: NotificationRow): string | null {
    if (!row.subject_id) return null
    switch (row.subject_type) {
        case 'material':
            return `/materials/${row.subject_id}/edit`
        case 'storage_location':
            return `/inventory/locations/${row.subject_id}/edit`
        default:
            return null
    }
}

// 渲染用的参数。【全部来自 payload】—— 事件记的是【当时】的事实,
// 回连主体去取名字会让一条三天前的通知说出今天的名字。
export function eventParams(row: NotificationRow): Record<string, string> {
    const p = (row.payload ?? {}) as Record<string, unknown>
    const s = (k: string) => (p[k] === null || p[k] === undefined ? '—' : String(p[k]))
    return {
        material: s('material_code'),
        location: s('location_code'),
        qty: s('qty'),
        class: s('class'),
    }
}
