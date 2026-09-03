'use client'

// app/finance/revaluation/RevaluationPreviewTable.tsx
// CONV-4 · 期末重估预览那张表 —— 逐个「科目 · 币种」一行,末尾一行是
// 【过账真正会发生的那一行】净额进 7110,走 rowClassName 加粗,复用
// assets/close 两页已经建立的"合计行是数据、不是表尾"的处理。

import { useTranslations } from '@/lib/i18n/client'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type RevaluationRow = {
    key: string
    account: string | null
    currency: string | null
    native: number | null
    carryBase: number | null
    rate: number | null
    rateAsOf: string | null
    periodEnd: string | null
    adjustment: number | null
    baseCurrency: string
    isTotal?: boolean
    totalUnknown?: boolean
}

export default function RevaluationPreviewTable({ rows }: { rows: RevaluationRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【科目】与【调整额】—— 科目是身份,调整额是这张预览表
    //   存在的理由(过账会动哪几笔、动多少)。
    const columns: Column<RevaluationRow>[] = [
        {
            key: 'account', header: t('finance.reval.account'), priority: true, className: 'font-mono',
            render: (r) => (r.isTotal ? t('finance.reval.netTo7110') : `${r.account} · ${r.currency}`),
        },
        {
            key: 'native', header: t('finance.reval.native'), align: 'right', className: 'font-mono',
            render: (r) => (r.isTotal || r.native === null ? '' : formatMoneyBare(r.native, '行标签「科目 · 币种」已写明这格的外币')),
        },
        {
            key: 'carry', header: t('finance.reval.carry'), align: 'right', className: 'font-mono',
            render: (r) => (r.isTotal || r.carryBase === null ? '' : formatAmount(r.carryBase, r.baseCurrency)),
        },
        {
            key: 'mid', header: t('finance.reval.mid'), align: 'right', className: 'font-mono',
            render: (r) => {
                if (r.isTotal) return ''
                return (
                    <>
                        {r.rate ?? '—'}
                        {/* FIN-19:回溯取的是哪一天的价 —— 与期末不同就标出来。 */}
                        {r.rate !== null && r.rateAsOf && r.rateAsOf !== r.periodEnd && (
                            <span className="ml-1 px-1 rounded bg-amber-100 text-amber-800 font-sans text-xs">
                                {t('finance.fxLookup.asOf', { 0: r.rateAsOf })}
                            </span>
                        )}
                    </>
                )
            },
        },
        {
            key: 'adj', header: t('finance.reval.adj'), priority: true, align: 'right', className: 'font-mono font-medium',
            render: (r) => {
                // 【缺牌价时合计不是 0,是不知道】—— 画成 0 会读作"这次重估
                // 对损益没有影响",而真相是它还算不出来。
                if (r.isTotal) return r.totalUnknown ? '—' : formatAmount(r.adjustment ?? 0, r.baseCurrency)
                return r.adjustment === null ? '—' : formatAmount(r.adjustment, r.baseCurrency)
            },
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.key}
            phone={{ mode: 'columns' }}
            rowClassName={(r) => (r.isTotal ? 'bg-gray-50 font-medium' : undefined)}
        />
    )
}
