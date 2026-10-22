'use client'

// app/purchasing/orders/OrdersTable.tsx
// CONV-5 · 采购单登记簿那张表。
// ★ 已取消的单整行发灰 + 单号加删除线 —— 整行那一半走 CONV-4 建的 rowClassName;
//   删除线留在单号那一格里,因为它是【那个链接】的样子,不是整行的样子。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { MaskedValue } from '@/app/components/MaskedValue'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xMoney, xDate, xMasked } from '@/lib/export/cells'

export type PurchaseOrderRow = {
    poId: string
    code: string
    status: string
    supplierName: string
    orderDate: string
    /** TABLE-EXPORT-1:导出用的原始日历日(YYYY-MM-DD),Excel 里是真日期。 */
    orderDateRaw: string
    expectedDelivery: string
    expectedDeliveryRaw: string | null
    /** 采购单自己的币种(三个金额列的币种;预付是本位币)。 */
    currency: string
    /** 已按币种格式化好 —— formatAmount 的币种知识留在服务端。null = 遮蔽(没有 data.view_purchase_prices)。 */
    netTotal: string | null
    netTotalAmt: number | null
    /** null = carries_tax 为 false:【没有算过税】,不是"税是零";或者遮蔽(canPurchasePrices 分开两者)。 */
    taxTotal: string | null
    taxTotalAmt: number | null
    grossTotal: string | null
    grossTotalAmt: number | null
    prepaid: string | null
    prepaidAmt: number | null
    prepaidRemaining: string | null
    canFinance: boolean
    /** TABLE-EXPORT-1:已预付是本位币 —— 屏幕上那一格写着它(formatAmount(prepaid_base, base))。 */
    baseCurrency: string
    /** data.view_purchase_prices —— 三个金额列的遮蔽判据(purchase_orders_masked)。 */
    canPurchasePrices: boolean
    /** null = 没有收货口径可言。 */
    receiptPct: number | null
}

export default function OrdersTable({ rows, empty, exportHref }: {
    rows: PurchaseOrderRow[]
    empty: React.ReactNode
    /** TABLE-EXPORT-1:服务端翻页取全的那条路由(带当前筛选)。 */
    exportHref: string
}) {
    const t = useTranslations()

    const statusPill = (s: string) => {
        const cls =
            s === 'open'
                ? 'bg-green-100 text-green-800'
                : s === 'closed'
                  ? 'bg-gray-200 text-gray-700'
                  : s === 'cancelled'
                    ? 'bg-red-100 text-red-700'
                    : 'bg-amber-100 text-amber-800'
        return <span className={'px-2 py-1 rounded text-xs ' + cls}>{t('purchasing.status.' + s)}</span>
    }

    // ★ 手机上留【单号】与【应付总额】—— 单号是身份,而 PO-GST-1 之后这张清单
    //   有三个金额列,其中【应付总额】才是"这一单要付多少"的答案。
    //   净额与 GST 是它的两个来源,进展开区。
    // TABLE-EXPORT-1:金额导出成【数】(采购单自己的币种,与屏幕同一个数);三个金额列与预付按屏幕
    //   同一个 canView 写「受限」(xMasked ↔ <MaskedValue>)。「没有算过税」的「—」导出为空格 —— 它不是 0。
    const columns: ExportableColumn<PurchaseOrderRow>[] = [
        {
            key: 'code', header: t('finance.colCode'), priority: true, className: 'text-sm',
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link
                    href={`/purchasing/orders/${r.poId}`}
                    className={r.status === 'cancelled' ? 'text-gray-500 hover:underline line-through' : 'app-link hover:underline'}
                >
                    {r.code}
                </Link>
            ),
        },
        { key: 'supplier', header: t('purchasing.colSupplier'), render: (r) => r.supplierName, exportAs: (r) => xText(r.supplierName) },
        { key: 'orderDate', header: t('purchasing.colOrderDate'), render: (r) => r.orderDate, exportAs: (r) => xDate(r.orderDateRaw) },
        { key: 'expected', header: t('purchasing.colExpectedDelivery'), render: (r) => r.expectedDelivery, exportAs: (r) => xDate(r.expectedDeliveryRaw) },
        // PO-GST-1:净额 / GST / 应付总额。
        {
            key: 'net', header: t('purchasing.colNetTotal'), align: 'right', className: 'text-sm',
            render: (r) => <MaskedValue value={r.netTotal} canView={r.canPurchasePrices} fallback="—" />,
            exportAs: (r) => xMasked(r.netTotalAmt, r.canPurchasePrices, (v) => xMoney(v, r.currency)),
        },
        {
            // 【GST 那一格印「—」不印 0.00】carries_tax 为 false 的行是"没有算过税",
            // 不是"税是零" —— 一个 0.00 会把前者说成后者,而那是这张清单上唯一会撒的谎。
            key: 'tax', header: t('purchasing.colTaxTotal'), align: 'right', className: 'text-sm',
            render: (r) => <MaskedValue value={r.taxTotal} canView={r.canPurchasePrices} fallback="—" />,
            exportAs: (r) => xMasked(r.taxTotalAmt, r.canPurchasePrices, (v) => xMoney(v, r.currency)),
        },
        {
            key: 'gross', header: t('purchasing.colGrossTotal'), priority: true, align: 'right',
            className: 'text-sm font-medium',
            render: (r) => <MaskedValue value={r.grossTotal} canView={r.canPurchasePrices} fallback="—" />,
            exportAs: (r) => xMasked(r.grossTotalAmt, r.canPurchasePrices, (v) => xMoney(v, r.currency)),
        },
        {
            key: 'prepaid', header: t('purchasing.colPrepaid'), align: 'right', className: 'text-sm',
            // 未抵扣角标(⚠)是同一格里的第二个数,一格放不下两个数 —— 导出只写已预付本身。
            exportAs: (r) => xMasked(r.prepaidAmt, r.canFinance, (v) => xMoney(v, r.baseCurrency)),
            render: (r) => (
                <>
                    <MaskedValue value={r.prepaid} canView={r.canFinance} fallback="—" />
                    {/* 搁浅的定金要不点开每张单也看得见(cut 4c) */}
                    {r.canFinance && r.prepaidRemaining && (
                        <span
                            title={t('purchasing.unappliedMarker')}
                            className="ml-2 inline-block px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800 font-sans"
                        >
                            ⚠ {r.prepaidRemaining}
                        </span>
                    )}
                </>
            ),
        },
        {
            key: 'receipt', header: t('purchasing.colReceipt'),
            exportAs: (r) => xNum(r.receiptPct, 'pct'),
            render: (r) =>
                r.receiptPct === null ? (
                    '—'
                ) : (
                    <div className="flex items-center gap-2">
                        {/* 收货进度条:>100%(超收)封顶显示。CHART-1 ④:配色用品牌 token。 */}
                        <div className="w-20 h-2 rounded overflow-hidden" style={{ background: 'var(--brand-muted)' }}>
                            <div
                                className="h-full"
                                style={{ width: `${Math.min(100, r.receiptPct)}%`, background: 'var(--brand-forest-fill)' }}
                            />
                        </div>
                        <span className="text-xs text-gray-600">{r.receiptPct}%</span>
                    </div>
                ),
        },
        { key: 'status', header: t('purchasing.colStatus'), render: (r) => statusPill(r.status), exportAs: (r) => xText(t('purchasing.status.' + r.status)) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.poId}
            phone={{ mode: 'columns' }}
            empty={empty}
            rowClassName={(r) => (r.status === 'cancelled' ? 'text-gray-400' : undefined)}
            exportSpec={{ name: 'purchase-orders', title: t('purchasing.ordersTitle'), serverRows: exportHref }}
        />
    )
}
