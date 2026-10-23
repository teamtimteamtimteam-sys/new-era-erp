'use client'

// app/tools/pricing/formulas/FormulasTable.tsx
// CONV-5 · 计价公式那张表。
// 【注意】同目录下的 FormulaForm 只挂在 /new 与 /[id]/edit —— 不在这一页上。
// CONV-3 §⑧-10 点名要核实的四张之一,本刀按 import 核实后更正。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'
import { MaskedValue } from '@/app/components/MaskedValue'
import { xText, xNum, xMasked } from '@/lib/export/cells'

export type FormulaRow = {
    id: string
    code: string
    name: string
    direction: string
    basisLabel: string
    /** null = 这个人看不见这张公式的条款(pricing_formulas_masked 按行的方向遮;这一列 NOT NULL,所以 null 只有这一个意思) */
    treatmentChargeUsdPerTonne: number | null
    flatDiscountPct: number | null
    /** null = 通用公式(不挂任何往来对象)。 */
    counterpartyName: string | null
    isActive: boolean
}

export default function FormulasTable({ rows, empty }: { rows: FormulaRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【公式号】与【计价基准】—— 公式号是身份,而基准是这条公式
    //   【算的是什么】。加工费与折扣是基准之下的两个参数,进展开区。
    // ★ TABLE-EXPORT-2b-1(Tim 2026-10-22 Q8 · 2026-10-23 Q4):看不见条款时加工费与折扣画「受限」、导出「Restricted」——
    //   从前是一格空白(formatMoneyBare(null) / 原样的 null)。判据按行:加工费 NOT NULL,读成 null 就是被遮。
    const termsSeen = (r: FormulaRow) => r.treatmentChargeUsdPerTonne !== null
    const columns: ExportableColumn<FormulaRow>[] = [
        {
            key: 'code', header: t('pricing.colCode'), priority: true, className: 'text-sm',
            exportAs: (r) => xText(r.isActive ? r.code : `${r.code} (${t('table.export.rowInactive')})`),
            render: (r) => (
                <Link href={`/tools/pricing/formulas/${r.id}/edit`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'name', header: t('pricing.colName'), render: (r) => r.name, exportAs: (r) => xText(r.name) },
        {
            key: 'direction', header: t('pricing.colDirection'),
            exportAs: (r) => xText(t('pricing.direction.' + r.direction)),
            render: (r) => (
                <span className="px-2 py-1 rounded text-xs bg-gray-200 text-gray-700">
                    {t('pricing.direction.' + r.direction)}
                </span>
            ),
        },
        { key: 'basis', header: t('pricing.colBasis'), priority: true, className: 'text-sm', render: (r) => r.basisLabel, exportAs: (r) => xText(r.basisLabel) },
        {
            key: 'treatment', header: t('pricing.colTreatment'), align: 'right', className: 'text-sm',
            render: (r) => (
                <MaskedValue value={r.treatmentChargeUsdPerTonne} canView={termsSeen(r)}
                    format={(v: number) => formatMoneyBare(v, '列头 pricing.colTreatment「加工费 (USD/吨)」')} />
            ),
            // 列头已写明 USD/吨,与屏幕一样只给数
            exportAs: (r) => xMasked(r.treatmentChargeUsdPerTonne, termsSeen(r), (v) => xNum(v, 'money')),
        },
        {
            key: 'discount', header: t('pricing.colDiscount'), align: 'right', className: 'text-sm',
            render: (r) => <MaskedValue value={r.flatDiscountPct} canView={termsSeen(r)} />,
            exportAs: (r) => xMasked(r.flatDiscountPct, termsSeen(r), (v) => xNum(v, 'pct')),
        },
        {
            key: 'counterparty', header: t('pricing.colCounterparty'), className: 'text-sm',
            render: (r) => r.counterpartyName ?? <span className="text-gray-500">{t('pricing.generic')}</span>,
            exportAs: (r) => xText(r.counterpartyName ?? t('pricing.generic')),
        },
        {
            key: 'active', header: t('pricing.colActive'),
            exportAs: (r) => xText(r.isActive ? t('pricing.form.active') : t('finance.inactive')),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.isActive ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600')}>
                    {r.isActive ? t('pricing.form.active') : t('finance.inactive')}
                </span>
            ),
        },
        {
            key: 'actions', header: t('metalPrices.colActions'), exportAs: false,
            render: (r) => (
                <Button asChild variant="link" size="inline">
                    <Link href={`/tools/pricing/formulas/${r.id}/edit`}>
                        {t('metalPrices.editAction')}
                    </Link>
                </Button>
            ),
        },
    ]

    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
            exportSpec={{ name: 'pricing-formulas', title: t('pricing.listTitle') }} />
    )
}
