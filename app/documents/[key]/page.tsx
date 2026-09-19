// app/documents/[key]/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-5 · 【无主语】的那一页 ——「化验单」
// ════════════════════════════════════════════════════════════════════════════
//
// 【它是 Tim 的 W1 折进来的那一半,而它【不是】一条关联】
//   关联分组点开说的是「**NMC 的**产出批」;而一条命中点开一张化验单说的是
//   「化验单」—— **没有主语**。所以它不住在 `/related/…` 底下:
//   把一份全表列表叫作「关联」,地址本身就在说一句假话。
//
// ★★【为什么必须是第二条地址,而不是三段地址里塞一个哨兵】★★
//   ① Next 的路由**不允许**同一层上出现两个不同名字的动态段 ——
//      `app/related/[subject]` 与 `app/related/[target]` 做兄弟是一个构建期错误。
//   ② 而往三段里塞 `/related/none/none/assay_result` 之类的哨兵,会让一段
//      **读起来像 id 的东西**其实不是 id。本仓库对"机器文本流到人面前"
//      有一份专门的文档(docs/machine-text-reaching-humans.md),这是同一族。
//   ☞ **两种形状是两件事,让地址照直说;共用的那一半是组件,不是地址。**
//
// 【谁落在这里】`document_types.link_mode = 'type_list'` 的那 5 种:
//   assay_result · cod · traceability_report · collection_chase ·
//   customer_statement。它们此前是 `list_q`,而那个 `?q=` 指着**别的表**的
//   单据号,前缀一个都不重叠 ⇒ 结构上永远 0 行(SEARCH-5 实测,
//   理由整段写在 `lib/search/documentHref.ts` 的抬头)。
//
// ⚠【这条地址【收掉】了一处既存的披露】那 5 种今天把单据号放进 `?q=`;
//   改完之后地址里只剩单据种类的 key。**本刀不扩大 URL 披露,反而少了 5 种。**
//
// ⚠【而它也换掉了一件事,照直说】今天点一张化验单,落在一张**保证空**的列表上;
//   改完之后落在**全部化验单**的列表上,那张单据**真的在里面**,但要自己找
//   (按单据号降序,20 条一页;实测今天化验单一共 4 条)。
//   ☞ 这不是"精确定位",它是 Tim 在 W1 里裁的形状:一次命中点击说的是
//     「化验单」,不是「某某的化验单」。
//
// ★【入口只有搜索面板】它不是一个菜单去处 —— EXCEPTIONS 里带着这句理由。
import RelatedRecords from '@/app/components/related/related-records'

export default async function DocumentTypeListPage({
    params, searchParams,
}: {
    params: Promise<{ key: string }>
    searchParams: Promise<{ after?: string }>
}) {
    const { key } = await params
    const { after } = await searchParams
    return <RelatedRecords targetKey={key} after={after} />
}
