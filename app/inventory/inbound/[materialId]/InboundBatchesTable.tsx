'use client'

// app/inventory/inbound/[materialId]/InboundBatchesTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 一种物料下面还在库的进料批次(9 列)
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【CONV-8 把这一页记成「元凶不是表」,而那句话在这一页上要更正】★★
// CONV-8 §⑥ 实测这一页溢出 **+506px**,探针点名的元凶是
// `span.px-2 py-1 bg-gray-200 rounded text-xs` —— 于是它被归进了
// 「9 张溢出页里 6 张的元凶不是表」那一栏。
// **但那枚徽章住在这张表的一个 `<td>` 里**(阶段那一列)。
// 它是表【里面】的东西,所以 DataTable 够得着它:阶段列不是 priority 列,
// 在 390px 上整格进展开区,那枚徽章跟着一起走。
// ☞ 结论不是"CONV-8 量错了" —— 探针点名的那个元素是对的;
//   错的是把「元凶是一枚徽章」直接读成「元凶不在表里」。
//   **一枚徽章可以【既是】徽章【又在】表里。**(本刀转换后重测,数写在报告里。)
//
// ★【手机上留【批次号】与【剩余】,不留【价值】】★
// 与 CONV-5 §⑩-13 给 /inventory/reports/snapshot 拍的板是同一条,理由也一样:
// 这一页最主要的读者(operations / warehouse)**看不到价** ——
// 给他们留一列印着「受限」的格子,等于把小屏上两个名额之一浪费掉。
// 而「还剩多少」正是一张在库批次表存在的理由。
//
// 【行数据在服务端压平】阶段的 i18n 标签、到岸成本的可见性判断(unpriced vs
// priceRestricted 是【两句不同的话】)、库龄档的色调 —— 全部在服务端算完。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type InboundBatchRow = {
    id: string
    code: string
    href: string
    supplier: string
    quantityText: string
    remainingText: string
    stageLabel: string
    arrivalDate: string
    /** 到岸单位成本;拿不到时 unitPriceAbsence 说出【为什么】拿不到。 */
    unitPriceText: string | null
    unitPriceAbsence: string
    batchValueText: string
    /** 库龄天数 + 它那一档的色调类名;拿不到就是 null。 */
    ageDays: string | null
    ageToneClass: string
}

export default function InboundBatchesTable({ rows }: { rows: readonly InboundBatchRow[] }) {
    const t = useTranslations()

    const columns: Column<InboundBatchRow>[] = [
        {
            key: 'code',
            header: t('inbound.colCode'),
            // 身份列 —— 一行在库批次的主语是它的批次号。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => (
                <Link href={r.href} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'supplier', header: t('inbound.colSupplier'), render: (r) => r.supplier },
        { key: 'quantity', header: t('inbound.colQuantity'), render: (r) => r.quantityText },
        {
            key: 'remaining',
            header: t('inbound.colRemaining'),
            // ★ 这张表存在的理由:这一批还剩多少可用。
            priority: true,
            render: (r) => r.remainingText,
        },
        {
            // ★ 这一列就是 CONV-8 的探针点名的那枚徽章所在处 —— 见文件抬头。
            //   它【不是】priority 列,所以 390px 上整格进展开区,徽章跟着走。
            key: 'stage',
            header: t('inbound.colStage'),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.stageLabel}</span>,
        },
        { key: 'arrival', header: t('inbound.colArrivalDate'), render: (r) => r.arrivalDate },
        {
            key: 'unitPrice',
            header: t('valuation.colUnitPrice'),
            // 【「未计价」与「你看不到价」是两句不同的话】—— 服务端已经分好,
            // 这里只负责把它画成灰字,而不是画成一个 0。
            render: (r) =>
                r.unitPriceText !== null ? r.unitPriceText : <span className="text-gray-400">{r.unitPriceAbsence}</span>,
        },
        { key: 'batchValue', header: t('valuation.colBatchValue'), render: (r) => r.batchValueText },
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
