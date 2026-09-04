'use client'

// app/purchasing/orders/[id]/PoPaymentTermsTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-8(2026-09-04)· 付款计划 —— 第二处「只读表里住着一个写库控件」
// ════════════════════════════════════════════════════════════════════════════
//
// 与 PoLinesTable 的 ③ 是同一件事的第二次:最后一列是 `ExpectedDateControl`
// (给一期分期填【预计付款日】,一个 <input type="date"> 直接写库)。
// 同样走 DataTable 的 `render`,不升级成 EditableTable —— 理由见 PoLinesTable 抬头。
//
// ★【CASHFLOW-1 的那条视觉约定必须活下来】★
// 「预计日期」与「到期日」是【两列】,因为它们是两种东西:一个是估计,一个是
// 合同约定的日子。控件自己带着虚线下划线 + 琥珀色来表达"这是一个估计",
// 而那套视觉住在控件里面 —— 转换不碰它,所以它原样过来了。
//
// ☞ 手机上留【期次标签】与【金额】:标签是这一期是什么,金额是这一期要付多少。
//   预计日期【进展开区】—— 它是一个可编辑的估计值,而 CONV-2 §④ 已经定过:
//   手机上编辑发生在展开区里,不在格子里。这里正好一致,不是巧合。
import * as React from 'react'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'
import ExpectedDateControl from './ExpectedDateControl'

export type PoTermRow = {
    id: string
    seqText: string
    label: string
    /** 「几成」或一个固定金额 —— 服务端已经选好印哪一个。 */
    shareText: string
    amountText: string
    triggerText: string
    dueDateText: string
    /** 下面几项是 ExpectedDateControl 要的纯数据。 */
    triggerEvent: string
    expectedDate: string | null
    ownerName: string | null
}

export default function PoPaymentTermsTable({
    rows,
    poId,
    canEditPurchasing,
}: {
    rows: readonly PoTermRow[]
    poId: string
    canEditPurchasing: boolean
}) {
    const t = useTranslations()

    const columns: Column<PoTermRow>[] = [
        {
            key: 'seq',
            header: t('purchasing.colSeq'),
            className: 'text-sm text-gray-500',
            render: (r) => r.seqText,
        },
        {
            key: 'label',
            header: t('purchasing.colLabel'),
            // 身份列:这一期是什么(「预付 30%」「到货后付清」)。
            priority: true,
            render: (r) => r.label,
        },
        {
            key: 'share',
            header: t('purchasing.colShare'),
            align: 'right',
            className: 'font-mono text-sm',
            render: (r) => r.shareText,
        },
        {
            key: 'amount',
            header: t('purchasing.colAmount'),
            align: 'right',
            // 这张计划表存在的理由:这一期要付多少。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => r.amountText,
        },
        {
            key: 'trigger',
            header: t('purchasing.colTrigger'),
            render: (r) => r.triggerText,
        },
        {
            key: 'dueDate',
            header: t('purchasing.colDueDate'),
            render: (r) => r.dueDateText,
        },
        {
            key: 'expectedDate',
            header: t('cashForecast.expectedDate'),
            render: (r) => (
                <ExpectedDateControl
                    termId={r.id}
                    purchaseOrderId={poId}
                    triggerEvent={r.triggerEvent}
                    expectedDate={r.expectedDate}
                    ownerName={r.ownerName}
                    canEdit={canEditPurchasing}
                />
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('purchasing.noPaymentTerms')}
        />
    )
}
