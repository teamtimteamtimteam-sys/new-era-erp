'use client'

// app/finance/gst/GstTaxCodesTable.tsx
// CONV-4 · 税码参照表(静态,不分页,行数固定于系统税码字典)。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText } from '@/lib/export/cells'
import { formatDate } from '@/lib/dates'
import { useLocale } from '@/lib/i18n/client'

export type TaxCodeRow = {
    code: string
    side: string
    name: string
    boxes: string
    rates: { rate_pct: number; effective_from: string; effective_to: string | null }[]
}

export default function GstTaxCodesTable({ rows }: { rows: TaxCodeRow[] }) {
    const locale = useLocale()
    const t = useTranslations()

    // ★ 手机上留【税码】与【生效税率】—— 税码是身份,税率是这张参照表存在的理由。
    const columns: ExportableColumn<TaxCodeRow>[] = [
        { key: 'code', header: t('gst.code'), priority: true, render: (r) => r.code, exportAs: (r) => xText(r.code) },
        { key: 'side', header: t('gst.side'), render: (r) => (r.side === 'output' ? t('gst.sideOutput') : t('gst.sideInput')), exportAs: (r) => xText(r.side === 'output' ? t('gst.sideOutput') : t('gst.sideInput')) },
        { key: 'name', header: t('gst.name'), render: (r) => r.name, exportAs: (r) => xText(r.name) },
        {
            key: 'boxes', header: t('gst.f5Box'),
            exportAs: (r) => xText(r.boxes || t('gst.noBox')),
            render: (r) => r.boxes || <span className="text-gray-500">{t('gst.noBox')}</span>,
        },
        {
            key: 'rates', header: t('gst.rates'), priority: true,
            // TABLE-FEATURES-1 Q9:一格是几段税率的文字 —— 按它排没有意义,不可排
            sortable: false,
            // 一个税码可以有几段税率(各自的生效区间)—— 一格装不下几个数,写成屏幕上那几行文字,以「; 」分开,日期取原始的
            exportAs: (r) => xText(r.rates.length === 0 ? t('gst.noRate')
                : r.rates.map((rt) => `${Number(rt.rate_pct)}% · ${rt.effective_from} → ${rt.effective_to ?? t('gst.current')}`).join('; ')),
            render: (r) =>
                r.rates.length === 0 ? (
                    <span className="text-amber-700">{t('gst.noRate')}</span>
                ) : (
                    r.rates.map((rt) => (
                        <div key={formatDate(rt.effective_from, locale)} className="text-xs">
                            {Number(rt.rate_pct)}% · {formatDate(rt.effective_from, locale)} → {formatDate(rt.effective_to, locale) ?? t('gst.current')}
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
            exportSpec={{ name: 'gst-tax-codes', title: t('gst.taxCodes') }}
            // TABLE-FEATURES-1 Q9:税码字典一次读全 —— 在浏览器里排
            sorting={{ mode: 'client', coverage: 'complete' }}
        />
    )
}
