'use client'

// app/components/related/RelatedTable.tsx
// SEARCH-5 · 关联页那张表 —— **两列,句号**
//
// ★【为什么不按单据种类各写一份列定义】那就是 39 份清单,而"教 39 个列表页
//   各加一个筛子"正是 Tim 否掉的那条路。两列对 40 个种类全都成立:
//   单据号(39 张表全有,是登记表的存在前提)+ 标签(31/40 有)。
//
// ★【9 个种类没有 label_column,对它们只画一列】实测:cash_forecast ·
//   collection_chase · customer_statement · traceability_report · contract ·
//   management_pack · attendance_period · gst_period · wht_remittance。
//   **不拿别的东西顶上** —— `records.ts` 的 `toHit` 已经是这条规矩
//   (「没有标签就不给标签」)。画一列空的「标签」表头,是把一处缺席
//   画成一个答案。
//
// ★【手机上留哪一列】单据号 `priority: true`。它是身份,而标签是补充说明 ——
//   `<DataTable>` 按构造【当场按名拒绝】一张没有声明 priority 列的表
//   (DATATABLE_NO_PHONE_COLUMNS),所以这句声明是必须的,不是可选的。
//
// ★★【排序 / 筛选 / 导出:一样都不给(第一刀)】★★
//   `<DataTable>` 的四个开关默认全关,而打开任何一个都要这一页先回答
//   「排的是不是全体」—— 这一页是 keyset 分页的,它手上只有这一屏。
//   给一个只排得了这一屏的排序控件,正是 `data-table.tsx` 抬头点名的
//   那个静默失败(A1 的类型约束就是为它立的)。
//   ☞ 失去的东西**照直报**:/inbound 有 8 个筛子 + 两种排序 + 分页 + 导出,
//     /output 有 7 + 两种 + 分页 + 导出,而它们恰好是关联最密的两张表。
//     从关联页跳过去的人拿到的是一张没有这些的表。**这是 Tim 接受过的代价。**
//
// ★★【任务也画成表,而 /tools/tasks 是一块看板】★★(Tim 的 W3)
//   裁定的理由:这一页答的是「这个人手上有哪几件事」,不是「哪一件在哪一列」,
//   而一个只读的、按主语筛过的子集里没有"列与列之间的移动"这回事。
//   ⚠ **代价:任务是唯一一种「共享页的画法与它自己那一页不是同一种画法」的单据。**

import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type RelatedRow = {
    id: string
    code: string
    label: string
    /**
     * ★ `null` = 这一种单据**没有逐张单据的落点**(`link_mode='type_list'`
     *   的那 5 种)。那时单据号是**文字**,不是链接 —— 一个链回本页的链接
     *   是一条指向自己的链接,而它读起来像"还有得看"。
     */
    href: string | null
}

export default function RelatedTable({
    rows, showLabel, codeHeader, labelHeader, empty,
}: {
    rows: RelatedRow[]
    showLabel: boolean
    codeHeader: string
    labelHeader: string
    empty?: React.ReactNode
}) {
    const columns: Column<RelatedRow>[] = [
        {
            key: 'code',
            header: codeHeader,
            // ★ 身份那一列,手机上留下来。
            priority: true,
            render: (r) =>
                r.href ? (
                    <Link href={r.href} className="hover:underline app-link" data-related-row={r.code}>
                        {r.code}
                    </Link>
                ) : (
                    <span data-related-row={r.code}>{r.code}</span>
                ),
        },
    ]
    if (showLabel) {
        columns.push({
            key: 'label',
            header: labelHeader,
            render: (r) => r.label,
        })
    }

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
