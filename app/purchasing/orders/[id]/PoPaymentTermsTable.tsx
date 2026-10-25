'use client'

// app/purchasing/orders/[id]/PoPaymentTermsTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-8(2026-09-04)· 付款计划 —— 第二处「只读表里住着一个写库控件」
// ════════════════════════════════════════════════════════════════════════════
//
// 与 PoLinesTable 的 ③ 是同一件事的第二次:最后一列是 `ExpectedDateControl`
// (给一期分期填【预计付款日】,一个日期框直接写库 —— DATE-PICK-1 起是共用的 DatePicker)。
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
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { MaskedValue } from '@/app/components/MaskedValue'
import { useTranslations } from '@/lib/i18n/client'
import { xDate, xInt, xMoney, xNum, xRestricted, xText } from '@/lib/export/cells'
import ExpectedDateControl from './ExpectedDateControl'

export type PoTermRow = {
    id: string
    seqText: string
    label: string
    /** 「几成」或一个固定金额 —— 服务端已经选好印哪一个。 */
    /** TABLE-EXPORT-2b-2:null = 受限(固定额 / 估算总额被遮)—— 画「受限」,不画「—」也不画「0.00」 */
    shareText: string | null
    amountText: string | null
    triggerText: string
    dueDateText: string
    /** 下面几项是 ExpectedDateControl 要的纯数据。 */
    triggerEvent: string
    /** YYYY-MM-DD 原值(控件与导出都用它) */
    expectedDate: string | null
    ownerName: string | null
    // ── TABLE-EXPORT-3b:导出读的原始值 ──
    seq: number
    /** 按比例的一期:几成(30 = 30%);固定额的一期为 null */
    percentage: number | null
    /** 固定额(单据币种);遮蔽时为 null —— 是否「受限」看 shareText === null */
    fixedAmount: number | null
    /** 这一期的金额(单据币种);是否「受限」看 amountText === null */
    amount: number | null
    currency: string
    dueDate: string | null
}

export default function PoPaymentTermsTable({
    rows,
    poId,
    canEditPurchasing,
    poCode,
}: {
    rows: readonly PoTermRow[]
    poId: string
    canEditPurchasing: boolean
    /** TABLE-EXPORT-3b:导出的 About 表说明这份文件出自哪张单 */
    poCode: string
}) {
    const t = useTranslations()

    const columns: ExportableColumn<PoTermRow>[] = [
        {
            key: 'seq',
            header: t('purchasing.colSeq'),
            className: 'text-sm text-gray-500',
            render: (r) => r.seqText,
            exportAs: (r) => xInt(r.seq),
        },
        {
            key: 'label',
            header: t('purchasing.colLabel'),
            // 身份列:这一期是什么(「预付 30%」「到货后付清」)。
            priority: true,
            render: (r) => r.label,
            exportAs: (r) => xText(r.label),
        },
        {
            key: 'share',
            header: t('purchasing.colShare'),
            align: 'right',
            className: 'text-sm',
            render: (r) => r.shareText ?? <MaskedValue value={null} canView={false} />,
            // 屏幕上这一格是「30%」或一个带币种的固定额 —— 导出照它的意思:百分数,或金额带币种。shareText 为 null = 「受限」。
            exportAs: (r) =>
                r.shareText === null ? xRestricted
                : r.percentage !== null ? xNum(r.percentage, 'pct')
                : xMoney(r.fixedAmount, r.currency),
        },
        {
            key: 'amount',
            header: t('purchasing.colAmount'),
            align: 'right',
            // 这张计划表存在的理由:这一期要付多少。
            priority: true,
            className: 'text-sm',
            render: (r) => r.amountText ?? <MaskedValue value={null} canView={false} />,
            // 屏幕是光秃秃的数(币种在头卡上);文件里没有头卡,金额格自己带着单据币种
            exportAs: (r) => (r.amountText === null ? xRestricted : xMoney(r.amount, r.currency)),
        },
        {
            key: 'trigger',
            header: t('purchasing.colTrigger'),
            render: (r) => r.triggerText,
            exportAs: (r) => xText(r.triggerText),
        },
        {
            key: 'dueDate',
            header: t('purchasing.colDueDate'),
            render: (r) => r.dueDateText,
            exportAs: (r) => xDate(r.dueDate),
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
            // 格子是一个写库的日期控件;导出它此刻的值(没有估计日 / 这一期不适用估计日 → 空格)
            exportAs: (r) => xDate(r.expectedDate),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('purchasing.noPaymentTerms')}
            exportSpec={{ name: 'purchasing-order-payment-terms', title: t('purchasing.form.paymentTerms'),
                          aboutExtra: [[t('purchasing.orderDetailTitle'), poCode]] }}
        />
    )
}
