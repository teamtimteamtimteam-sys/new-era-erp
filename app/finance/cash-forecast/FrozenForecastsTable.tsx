'use client'

// app/finance/cash-forecast/FrozenForecastsTable.tsx
// CONV-3 · 「已冻结的预测」登记簿。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xDate, xTime } from '@/lib/export/cells'

export type FrozenRow = {
    id: string; code: string; week_start: string
    frozen_at: string; superseded_at: string | null
}

export default function FrozenForecastsTable({ rows }: { rows: FrozenRow[] }) {
    const t = useTranslations()

    const columns: ExportableColumn<FrozenRow>[] = [
        {
            key: 'code', header: t('cashForecast.colCode'), priority: true,
            exportAs: (r) => xText(r.superseded_at ? `${r.code} (${t('cashForecast.superseded')})` : r.code),
            render: (r) => (
                <>
                    {r.code}
                    {r.superseded_at && (
                        <span className="ml-2 rounded bg-[color:var(--brand-muted)] px-1.5 py-0.5 text-xs text-[color:var(--brand-muted-text)]">
                            {t('cashForecast.superseded')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'weekStart', header: t('cashForecast.weekStart'), priority: true, className: 'text-xs', render: (r) => r.week_start, exportAs: (r) => xDate(r.week_start) },
        { key: 'frozenAt', header: t('cashForecast.colFrozen'), className: 'text-xs', render: (r) => r.frozen_at.slice(0, 10),
            // 冻结时刻是一个时刻:按 Q7 写成新加坡时间的日期格(屏幕上截了前十位 —— 那是 UTC 的日子,登记在交回里)
            exportAs: (r) => xTime(r.frozen_at) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('cashForecast.noneFrozen')}
            exportSpec={{ name: 'frozen-cash-forecasts', title: t('cashForecast.frozenTitle'), serverRows: '/finance/cash-forecast/frozen/export' }}
        />
    )
}
