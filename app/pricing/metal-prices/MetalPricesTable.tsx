'use client'

// app/pricing/metal-prices/MetalPricesTable.tsx
// CONV-5 · 金属行情那张表。
//
// ★★【价格那一格上挂着【四种】互不相同的判词,一种都不能合并】★★
//   METAL-1 / FIN-26 的裁定,原样搬过来:
//     · outside        —— 琥珀徽标:录入那一刻超出阈值;
//     · no_reference   —— 灰色徽标:【不是"检查通过"】,是"当时没有别的报价可比";
//     · 判词为空        —— 更安静的一个:这一行录入时【还没有这项检查】。
//                          不画任何徽标会让它与"查过、没问题"一模一样。
//     · 正常             —— 什么都不挂。
//   服务端只把 verdict 与它的几个数传过来,四选一的画法留在这里。
// ★ Q7:排序仍是服务端的(sorting.mode='server')。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type MetalPriceRow = {
    id: string
    metalLabel: string
    pricePerTonne: number
    /** 未标注指数的老行按 USD 记(那条序列一直是 USD),所以回退到报价基准。 */
    quoteCurrency: string | null
    priceDate: string
    /** null = 未标注指数 —— 【空白会读成"没填",而它是一个状态】。 */
    priceIndex: string | null
    sourceLabel: string
    notes: string
    /** null = 这一行录入时还没有这项检查(见抬头第三种)。 */
    anomalyVerdict: 'outside' | 'no_reference' | 'inside' | null
    anomalyChangePct: number
    anomalyRefPrice: number
    anomalyRefDate: string
}

export default function MetalPricesTable({
    rows, empty, sort, dir, filterQuery, shown, total,
}: {
    rows: MetalPriceRow[]
    empty: React.ReactNode
    sort: string
    dir: 'asc' | 'desc'
    filterQuery: Record<string, string>
    shown: number
    total: number
}) {
    const t = useTranslations()

    const href = (key: string, nextDir: 'asc' | 'desc') => {
        const params = new URLSearchParams(filterQuery)
        params.set('sort', key)
        params.set('dir', nextDir)
        return `/pricing/metal-prices?${params.toString()}`
    }

    // ★ 手机上留【金属】与【价格】—— 金属是身份,价格是这张行情表存在的理由。
    //   ★ 那四个判词徽标挂在价格那一格里,所以它们在小屏上【不会】掉进展开区:
    //     一个"当时没查过"的标记如果只在展开后才出现,就等于取消了它。
    const columns: Column<MetalPriceRow>[] = [
        { key: 'metal', header: t('metalPrices.colMetal'), priority: true, sortable: true, render: (r) => r.metalLabel },
        {
            // METAL-3:列头不再写死 USD —— 币种跟着每一行走。
            key: 'price_usd_per_tonne', header: t('metalPrices.colPricePerTonne'), priority: true, sortable: true,
            align: 'right', className: 'font-mono text-sm',
            render: (r) => (
                <>
                    {formatMoneyBare(r.pricePerTonne, '同格内紧跟着币种,见下一段')}
                    {/* 【数字自己带币种】 */}
                    <span className="ml-1 text-xs text-gray-500">
                        {r.quoteCurrency ?? t('metalPrices.index.quoteBasisFallback')}
                    </span>
                    {r.anomalyVerdict === 'outside' && (
                        <span
                            title={t('metalPrices.anomaly.badgeTitle', {
                                change: r.anomalyChangePct,
                                refPrice: r.anomalyRefPrice,
                                refDate: r.anomalyRefDate,
                            })}
                            className="ml-2 inline-block align-middle bg-amber-100 text-amber-800 border border-amber-300 rounded px-1.5 py-0.5 text-xs font-sans"
                        >
                            {t('metalPrices.anomaly.badge')}
                        </span>
                    )}
                    {r.anomalyVerdict === null && (
                        <span
                            title={t('metalPrices.anomaly.legacyTitle')}
                            className="ml-2 inline-block align-middle bg-gray-50 text-gray-400 border border-gray-200 rounded px-1.5 py-0.5 text-xs font-sans"
                        >
                            {t('metalPrices.anomaly.legacyBadge')}
                        </span>
                    )}
                    {r.anomalyVerdict === 'no_reference' && (
                        <span
                            title={t('metalPrices.anomaly.noReferenceTitle')}
                            className="ml-2 inline-block align-middle bg-gray-100 text-gray-600 border border-gray-300 rounded px-1.5 py-0.5 text-xs font-sans"
                        >
                            {t('metalPrices.anomaly.noReferenceBadge')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'price_date', header: t('metalPrices.colPriceDate'), sortable: true, render: (r) => r.priceDate },
        {
            // 【空白会读成"没填",而它是一个状态】
            key: 'index', header: t('metalPrices.colIndex'), className: 'text-sm',
            render: (r) => r.priceIndex ?? <span className="text-gray-400">{t('metalPrices.index.unstatedShort')}</span>,
        },
        {
            // LME-1b:出处用【人话】显示 —— 老行情读作「来源未记录」,
            // 既不是空白,也不是一个看起来像答案的英文单词。
            key: 'source', header: t('metalPrices.colSource'), className: 'text-sm text-gray-600',
            render: (r) => r.sourceLabel,
        },
        { key: 'notes', header: t('metalPrices.colNotes'), className: 'text-sm', render: (r) => r.notes },
        {
            key: 'actions', header: t('metalPrices.colActions'),
            render: (r) => (
                <Link href={`/pricing/metal-prices/${r.id}/edit`} className="text-blue-600 hover:underline">
                    {t('metalPrices.editAction')}
                </Link>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            sorting={{ mode: 'server', coverage: { shown, total }, active: { key: sort, dir }, href }}
        />
    )
}
