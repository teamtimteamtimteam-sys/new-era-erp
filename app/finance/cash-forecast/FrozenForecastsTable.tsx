'use client'

// app/finance/cash-forecast/FrozenForecastsTable.tsx
// CONV-3 · 「已冻结的预测」登记簿。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type FrozenRow = {
    id: string; code: string; week_start: string
    frozen_at: string; superseded_at: string | null
}

export default function FrozenForecastsTable({ rows }: { rows: FrozenRow[] }) {
    const t = useTranslations()

    const columns: Column<FrozenRow>[] = [
        {
            key: 'code', header: t('cashForecast.colCode'), priority: true, className: 'font-mono',
            render: (r) => (
                <>
                    {r.code}
                    {r.superseded_at && (
                        <span className="ml-2 rounded bg-[color:var(--brand-muted)] px-1.5 py-0.5 text-[11px] text-[color:var(--brand-muted-text)]">
                            {t('cashForecast.superseded')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'weekStart', header: t('cashForecast.weekStart'), priority: true, className: 'font-mono text-xs', render: (r) => r.week_start },
        { key: 'frozenAt', header: t('cashForecast.colFrozen'), className: 'text-xs', render: (r) => r.frozen_at.slice(0, 10) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('cashForecast.noneFrozen')}
        />
    )
}
