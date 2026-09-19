// app/related/[subject]/[id]/[target]/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-5 · 【有主语】的那一页 ——「NMC Cathode Foil 的产出批」
// ════════════════════════════════════════════════════════════════════════════
//
// 【这一页只做一件事:把地址解析出来。】其余全部在
// `app/components/related/related-records.tsx` 里,而那个组件同时供着
// `/documents/<key>`(无主语那一形状)。**两条地址,一个组件。**
//
// ★【为什么地址是三段路径,而不是 `?subject=…&type=…&target=…`】
//   `scripts/check-nav-routes.mjs` 的判据 ② 按【路由】登记例外,一条路径
//   写得出一条例外;查询串形式会让一条例外覆盖无穷多种组合,
//   **而那正是 SEARCH-1 · S6 收紧掉的那张通行证**。
//
// ★【主语用 uuid,不用单据号】uuid 不透明,URL 本身不披露任何业务内容。
//   22 种 `link_mode='detail'` 的单据今天就是这么链详情的(`${route}/${row.id}`),
//   所以这是主流写法,不是本刀发明的。`/me/avatar` 的例外理由逐字写着
//   「地址里不再出现任何 uid —— 服务谁由会话说了算」;这里主语必须写进地址
//   (这一页就是关于它的),而**写成 uuid 是那条规矩允许的最小披露**。
//
// ★【入口只有搜索面板】它不是一个菜单去处,所以它在 check-nav-routes 的
//   EXCEPTIONS 里带着这句理由。
import RelatedRecords from '@/app/components/related/related-records'

export default async function RelatedSubjectPage({
    params, searchParams,
}: {
    params: Promise<{ subject: string; id: string; target: string }>
    searchParams: Promise<{ after?: string }>
}) {
    const { subject, id, target } = await params
    const { after } = await searchParams
    return (
        <RelatedRecords
            subjectKey={subject}
            subjectId={id}
            targetKey={target}
            after={after}
        />
    )
}
