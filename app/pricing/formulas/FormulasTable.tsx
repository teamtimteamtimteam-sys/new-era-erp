'use client'

// app/pricing/formulas/FormulasTable.tsx
// CONV-5 · 计价公式那张表。
// 【注意】同目录下的 FormulaForm 只挂在 /new 与 /[id]/edit —— 不在这一页上。
// CONV-3 §⑧-10 点名要核实的四张之一,本刀按 import 核实后更正。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type FormulaRow = {
    id: string
    code: string
    name: string
    direction: string
    basisLabel: string
    treatmentChargeUsdPerTonne: number
    flatDiscountPct: number
    /** null = 通用公式(不挂任何往来对象)。 */
    counterpartyName: string | null
    isActive: boolean
}

export default function FormulasTable({ rows, empty }: { rows: FormulaRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【公式号】与【计价基准】—— 公式号是身份,而基准是这条公式
    //   【算的是什么】。加工费与折扣是基准之下的两个参数,进展开区。
    const columns: Column<FormulaRow>[] = [
        {
            key: 'code', header: t('pricing.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/pricing/formulas/${r.id}/edit`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'name', header: t('pricing.colName'), render: (r) => r.name },
        {
            key: 'direction', header: t('pricing.colDirection'),
            render: (r) => (
                <span className="px-2 py-1 rounded text-xs bg-gray-200 text-gray-700">
                    {t('pricing.direction.' + r.direction)}
                </span>
            ),
        },
        { key: 'basis', header: t('pricing.colBasis'), priority: true, className: 'text-sm', render: (r) => r.basisLabel },
        {
            key: 'treatment', header: t('pricing.colTreatment'), align: 'right', className: 'font-mono text-sm',
            render: (r) => formatMoneyBare(r.treatmentChargeUsdPerTonne, '列头 pricing.colTreatment「加工费 (USD/吨)」'),
        },
        { key: 'discount', header: t('pricing.colDiscount'), align: 'right', className: 'font-mono text-sm', render: (r) => r.flatDiscountPct },
        {
            key: 'counterparty', header: t('pricing.colCounterparty'), className: 'text-sm',
            render: (r) => r.counterpartyName ?? <span className="text-gray-500">{t('pricing.generic')}</span>,
        },
        {
            key: 'active', header: t('pricing.colActive'),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.isActive ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600')}>
                    {r.isActive ? t('pricing.form.active') : t('finance.inactive')}
                </span>
            ),
        },
        {
            key: 'actions', header: t('metalPrices.colActions'),
            render: (r) => (
                <Link href={`/pricing/formulas/${r.id}/edit`} className="text-blue-600 hover:underline text-sm">
                    {t('metalPrices.editAction')}
                </Link>
            ),
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
