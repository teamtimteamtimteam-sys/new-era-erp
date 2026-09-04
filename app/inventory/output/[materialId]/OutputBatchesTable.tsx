'use client'

// app/inventory/output/[materialId]/OutputBatchesTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 一种物料下面还在库的产出批次 —— **全仓最宽的一张,11 列**
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【CONV-8 实测这一页溢出 +664px,是 37 张详情页里最坏的一张】★★
// 探针点名的元凶是 `span.px-2 py-1 bg-gray-200 rounded text-xs` ——
// **那枚徽章住在这张表的一个 `<td>` 里**(状态那一列),
// 与姊妹页 /inventory/inbound/[materialId] 逐字同形。
// 所以 CONV-8 §⑥ 那句「元凶不是表」在这两页上要读细一点:
// **元凶【是一枚徽章】,而那枚徽章【在表里】** —— 两件事同时为真,
// 而 DataTable 够得着它(状态列不是 priority,390px 上整格进展开区)。
//
// ★【手机上留【批次号】与【剩余】,不留任何一列价值】★
// 这一页有【三】列钱(单位成本 / 成本价值 / 市价价值),而 CONV-5 §⑩-13 给
// /inventory/reports/snapshot 拍的板是「不留价值:主要读者看不到价」。
// 这里更强:三列钱里挑一列留下,等于替读者决定他关心成本还是市价 ——
// 而那两个数在这套系统里是【刻意分开】的两件事(一个是我们花了多少,
// 一个是今天卖得了多少)。**挑一个会说一句这一页没在说的话。**
// 所以两列都不留,三列钱一起进展开区,与 CONV-5 的判据同向而更彻底。
//
// 【行数据在服务端压平】状态标签、金属市价折算、工单反查、库龄色调 ——
// 全部在服务端算完;一个 Map、一个判据都不过界(CONV-1 §①)。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type OutputBatchRow = {
    id: string
    code: string
    href: string
    customer: string
    quantityText: string
    remainingText: string
    stateLabel: string
    outputDate: string
    unitCostText: string
    costValueText: string
    marketValueText: string
    ageDays: string | null
    ageToneClass: string
    /** WO-1c:有工单就点得进去。 */
    workOrderCode: string | null
    workOrderHref: string | null
}

export default function OutputBatchesTable({ rows }: { rows: readonly OutputBatchRow[] }) {
    const t = useTranslations()

    const columns: Column<OutputBatchRow>[] = [
        {
            key: 'code',
            header: t('output.colCode'),
            // 身份列 —— 一行在库产出的主语是它的批次号。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => (
                <Link href={r.href} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'customer', header: t('output.colCustomer'), render: (r) => r.customer },
        { key: 'quantity', header: t('output.colQuantity'), render: (r) => r.quantityText },
        {
            key: 'remaining',
            header: t('output.colRemaining'),
            // ★ 这张表存在的理由:这一批还剩多少可卖 / 可投。
            priority: true,
            render: (r) => r.remainingText,
        },
        {
            // ★ 这一列就是 CONV-8 的探针点名的那枚徽章所在处 —— 见文件抬头。
            key: 'state',
            header: t('output.colState'),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.stateLabel}</span>,
        },
        { key: 'outputDate', header: t('output.colOutputDate'), render: (r) => r.outputDate },
        { key: 'unitCost', header: t('valuation.colUnitCost'), render: (r) => r.unitCostText },
        { key: 'costValue', header: t('valuation.colCostValue'), render: (r) => r.costValueText },
        { key: 'marketValue', header: t('valuation.colMarketValue'), render: (r) => r.marketValueText },
        {
            key: 'age',
            header: t('valuation.colAge'),
            render: (r) =>
                r.ageDays !== null ? (
                    <span className={'px-2 py-1 rounded text-xs ' + r.ageToneClass}>{r.ageDays}</span>
                ) : (
                    '—'
                ),
        },
        {
            // WO-1c:这批货是照哪张计划做出来的 —— 出处是这套系统存在的理由,
            // 而【没有计划】是一个正当的答案,所以它有名字,不是空白。
            key: 'workOrder',
            header: t('processing.colWorkOrder'),
            className: 'font-mono text-sm',
            render: (r) =>
                r.workOrderHref ? (
                    <Link href={r.workOrderHref} className="text-blue-600 hover:underline">
                        {r.workOrderCode ?? '—'}
                    </Link>
                ) : (
                    <span className="text-gray-500 italic">{t('processing.noWorkOrder')}</span>
                ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('inventory.emptyState')}
        />
    )
}
