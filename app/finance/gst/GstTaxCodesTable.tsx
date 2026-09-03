'use client'

// app/finance/gst/GstTaxCodesTable.tsx
// CONV-4 · 税码参照表(静态,不分页,行数固定于系统税码字典)。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type TaxCodeRow = {
    code: string
    side: string
    name: string
    boxes: string
    rates: { rate_pct: number; effective_from: string; effective_to: string | null }[]
}

export default function GstTaxCodesTable({ rows }: { rows: TaxCodeRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【税码】与【生效税率】—— 税码是身份,税率是这张参照表存在的理由。
    const columns: Column<TaxCodeRow>[] = [
        { key: 'code', header: t('gst.code'), priority: true, className: 'font-mono', render: (r) => r.code },
        { key: 'side', header: t('gst.side'), render: (r) => (r.side === 'output' ? t('gst.sideOutput') : t('gst.sideInput')) },
        { key: 'name', header: t('gst.name'), render: (r) => r.name },
        {
            key: 'boxes', header: t('gst.f5Box'),
            render: (r) => r.boxes || <span className="text-gray-500">{t('gst.noBox')}</span>,
        },
        {
            key: 'rates', header: t('gst.rates'), priority: true,
            render: (r) =>
                r.rates.length === 0 ? (
                    <span className="text-amber-700">{t('gst.noRate')}</span>
                ) : (
                    r.rates.map((rt) => (
                        <div key={rt.effective_from} className="font-mono text-xs">
                            {Number(rt.rate_pct)}% · {rt.effective_from} → {rt.effective_to ?? t('gst.current')}
                        </div>
                    ))
                ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.code}
            phone={{ mode: 'columns' }}
        />
    )
}
