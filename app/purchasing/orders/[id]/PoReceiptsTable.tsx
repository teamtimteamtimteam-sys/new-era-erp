'use client'

// app/purchasing/orders/[id]/PoReceiptsTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-8(2026-09-04)· 这张单收到了什么
// ════════════════════════════════════════════════════════════════════════════
//
// ★【「敞口」那一列走 MaskedValue,而【不能】在服务端折成一个字符串】★
// 敞口是 finance 的数;没有 module.finance.view 的人看到的必须是「受限」,
// 不是 0、也不是空白 —— `lib/permissions.ts` 存在的全部理由就是
// 「null 已经有主了」(AGENTS.md 那条 0 冒充受限)。
// 所以这一列传的是 `openText: string | null` **加上一个 canFinance 布尔**,
// 由 MaskedValue 去画那两种情形。把它在服务端折成 '—' 会把两件事压平成一件。
//
// ☞ 手机上留【批次号】与【数量】:批次号是身份,而这张表回答的是"到了多少"。
//   单价与敞口进展开区 —— 与 CONV-5 给 /inventory/reports/snapshot 留数量
//   而不留价值是同一条理由:这一页的读者里有看不到价的人。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { MaskedValue } from '@/app/components/MaskedValue'
import { useTranslations } from '@/lib/i18n/client'
import { xDate, xMasked, xMoney, xNum, xRestricted, xText } from '@/lib/export/cells'

export type PoReceiptRow = {
    id: string
    code: string
    arrivalDateText: string
    qtyText: string
    /**
     * null = 这一批还没有定价(画成琥珀色的「未计价」,不是空白)—— 【只对看得见价的人】。
     * ★ TABLE-EXPORT-2b-2(Tim 2026-10-23 Q4):inbound_batches_masked 对不持 data.view_purchase_prices 的人把单价遮成 NULL,
     *   从前这里照样印「未计价」—— 一句假话。看不见价的人那里 null 画「受限」(canPrices,与 canFinance 同一个办法)。
     */
    unitPriceText: string | null
    /**
     * ★ FIX-2b:null = 【看不到】(prepayment_applications_masked 在财务那道门
     * 后面),'—' = 这一批【真的】没有抵扣过。此前两者都是 '—'。
     */
    appliedText: string | null
    /** 见抬头:null 与「看不到」是两件事,交给 MaskedValue 分。 */
    openText: string | null
    /** unit_price 为空时,敞口这一格印破折号 —— 没有价就没有敞口可言。 */
    openApplicable: boolean
    // ── TABLE-EXPORT-3b:导出读的原始值 ──
    arrivalDate: string | null
    quantity: number
    unit: string
    unitPrice: number | null
    /** 已抵扣额(本位币);看不到(!canFinance)或这一批没有抵扣过 → null */
    applied: number | null
    /** 敞口(本位币);看不到 → null */
    open: number | null
}

export default function PoReceiptsTable({
    rows,
    canFinance,
    canPrices,
    poCode,
    baseCurrency,
}: {
    rows: readonly PoReceiptRow[]
    canFinance: boolean
    /** TABLE-EXPORT-2b-2:读者持不持 data.view_purchase_prices —— 单价那一格的 null 是「未计价」还是「受限」 */
    canPrices: boolean
    /** TABLE-EXPORT-3b:导出的 About 表说明这份文件出自哪张单 */
    poCode: string
    /** 抵扣额与敞口是本位币(屏幕在格子里写着它) */
    baseCurrency: string
}) {
    const t = useTranslations()

    const columns: ExportableColumn<PoReceiptRow>[] = [
        {
            key: 'code',
            header: t('finance.colCode'),
            // 身份列。
            priority: true,
            className: 'text-sm',
            render: (r) => (
                <Link href={`/inbound/${r.id}/edit`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
            exportAs: (r) => xText(r.code),
        },
        {
            key: 'arrival',
            header: t('inbound.form.arrivalDate'),
            render: (r) => r.arrivalDateText,
            exportAs: (r) => xDate(r.arrivalDate),
        },
        {
            key: 'qty',
            header: t('purchasing.colQuantity'),
            align: 'right',
            // 这张表存在的理由:到了多少。
            priority: true,
            className: 'text-sm',
            render: (r) => r.qtyText,
            exportAs: (r) => xNum(r.quantity, 'qty', r.unit),
        },
        {
            key: 'unitPrice',
            header: t('purchasing.colUnitPrice'),
            align: 'right',
            className: 'text-sm',
            render: (r) =>
                r.unitPriceText !== null ? (
                    r.unitPriceText
                ) : !canPrices ? (
                    <MaskedValue value={null} canView={false} />
                ) : (
                    <span className="text-amber-700">{t('purchasing.unpriced')}</span>
                ),
            // 与屏幕同一条三分:有价 → 数;看不见价 → "Restricted";看得见而没价 → 屏幕那句「未计价」。
            // 屏幕是光秃秃的 4 位小数、列头不写币种,导出同样不加币种(不替屏幕编一个它没说的币种)。
            exportAs: (r) =>
                r.unitPrice !== null ? xMoney(r.unitPrice)
                : !canPrices ? xRestricted
                : xText(t('purchasing.unpriced')),
        },
        {
            key: 'applied',
            header: t('purchasing.appliedLabel'),
            align: 'right',
            className: 'text-sm',
            // 与右邻那一格同一种画法(MaskedValue),所以「受限」在这张表里
            // 只有一个样子 —— CONV-0 收敛出来的那一个。
            render: (r) => <MaskedValue value={r.appliedText} canView={canFinance} />,
            // 与 MaskedValue 同一条判据:!canFinance → "Restricted";这一批没有抵扣过(屏幕「—」)→ 空格
            exportAs: (r) => xMasked(r.applied, canFinance, (v) => xMoney(v, baseCurrency)),
        },
        {
            key: 'open',
            header: t('finance.colOpen'),
            align: 'right',
            className: 'text-sm',
            render: (r) =>
                !r.openApplicable ? '—' : <MaskedValue value={r.openText} canView={canFinance} />,
            // 没有价就没有敞口(屏幕「—」)→ 空格;否则与 MaskedValue 同一条判据
            exportAs: (r) =>
                !r.openApplicable ? xText(null) : xMasked(r.open, canFinance, (v) => xMoney(v, baseCurrency)),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('purchasing.noReceipts')}
            exportSpec={{ name: 'purchasing-order-receipts', title: t('purchasing.receipts'),
                          aboutExtra: [[t('purchasing.orderDetailTitle'), poCode]] }}
        />
    )
}
