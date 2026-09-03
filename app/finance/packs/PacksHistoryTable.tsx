'use client'

// app/finance/packs/PacksHistoryTable.tsx
// CONV-4 · 已存档管理报表包的登记簿(报告体本身 PackBody 不动 —— 见 page.tsx 顶注)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type PackRow = {
    id: string
    code: string
    periodMonth: string
    producedAt: string
    lockedBeforeAt: string
    supersededAt: string | null
    supersededReason: string | null
}

export default function PacksHistoryTable({ rows, empty }: { rows: PackRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【状态】—— 单号是身份,状态(在用/已被取代)是
    //   这张登记簿存在的理由。
    const columns: Column<PackRow>[] = [
        {
            key: 'code', header: t('pack.colCode'), priority: true, className: 'font-mono',
            render: (r) => (
                <Link href={`/finance/packs/${r.id}`} className="text-blue-600 hover:underline font-mono">
                    {r.code}
                </Link>
            ),
        },
        { key: 'month', header: t('pack.colMonth'), className: 'font-mono', render: (r) => r.periodMonth },
        { key: 'produced', header: t('pack.colProduced'), className: 'text-xs font-mono', render: (r) => r.producedAt },
        { key: 'lockedBefore', header: t('pack.colLockedBefore'), className: 'text-xs font-mono', render: (r) => r.lockedBeforeAt },
        {
            key: 'status', header: t('pack.colStatus'), priority: true, className: 'text-xs',
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
        />
    )
}
