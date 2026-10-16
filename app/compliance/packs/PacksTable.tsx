'use client'

// MES-8b-1:冻下来的合规包清单 —— 一份一行。被取代的那一份灰掉、说出被哪一份取代与理由。手机上留【号】【月】【PDF】。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type PackRow = { id: string; code: string; month: string; frozen: string; superseded: string | null; latestVersion: string }

export default function PacksTable({ rows, empty }: { rows: PackRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<PackRow>[] = [
        { key: 'code', header: t('compliancePacks.colCode'), priority: true,
          render: (r) => <Link href={`/compliance/packs/${r.id}`} className="hover:underline app-link">{r.code}</Link> },
        { key: 'month', header: t('compliancePacks.colMonth'), priority: true, render: (r) => r.month },
        { key: 'frozen', header: t('compliancePacks.colFrozen'), render: (r) => r.frozen },
        { key: 'pdf', header: t('compliancePacks.colPdf'), priority: true, render: (r) => r.latestVersion },
        { key: 'superseded', header: t('compliancePacks.colSuperseded'), render: (r) => r.superseded ?? '—' },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        rowClassName={(r) => (r.superseded ? 'text-gray-400' : undefined)} />
}
