'use client'

// app/finance/packs/PacksHistoryTable.tsx
// CONV-4 · 已存档管理报表包的登记簿(报告体本身 PackBody 不动 —— 见 page.tsx 顶注)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xDate, xTime } from '@/lib/export/cells'

export type PackRow = {
    id: string
    code: string
    periodMonth: string
    producedAt: string
    lockedBeforeAt: string
    supersededAt: string | null
    supersededReason: string | null
    // TABLE-EXPORT-2a:导出读原始值(生成时刻按 Q7 写成新加坡时间的真日期格)
    producedAtRaw: string
    lockedBeforeRaw: string | null
}

export default function PacksHistoryTable({ rows, empty }: { rows: PackRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【状态】—— 单号是身份,状态(在用/已被取代)是
    //   这张登记簿存在的理由。
    const columns: ExportableColumn<PackRow>[] = [
        {
            key: 'code', header: t('pack.colCode'), priority: true,
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/finance/packs/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'month', header: t('pack.colMonth'), render: (r) => r.periodMonth, exportAs: (r) => xText(r.periodMonth) },
        { key: 'produced', header: t('pack.colProduced'), className: 'text-xs', render: (r) => r.producedAt, exportAs: (r) => xTime(r.producedAtRaw) },
        { key: 'lockedBefore', header: t('pack.colLockedBefore'), className: 'text-xs', render: (r) => r.lockedBeforeAt, exportAs: (r) => xDate(r.lockedBeforeRaw) },
        {
            key: 'status', header: t('pack.colStatus'), priority: true, className: 'text-xs',
            exportAs: (r) => xText(r.supersededAt ? `${t('pack.statusSuperseded')} — ${r.supersededReason ?? ''}` : t('pack.statusLive')),
            render: (r) =>
                r.supersededAt ? (
                    <span className="text-gray-600">{t('pack.statusSuperseded')} — {r.supersededReason}</span>
                ) : (
                    <span className="text-green-800">{t('pack.statusLive')}</span>
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
            exportSpec={{ name: 'management-packs', title: t('pack.storedHeading') }}
        />
    )
}
