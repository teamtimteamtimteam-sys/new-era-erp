'use client'

// MES-8b-1:冻下来的合规包清单 —— 一份一行。被取代的那一份灰掉、说出被哪一份取代与理由。手机上留【号】【月】【PDF】。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xTime } from '@/lib/export/cells'

export type PackRow = {
    id: string; code: string; month: string; frozen: string
    /** TABLE-EXPORT-2b-1:冻结时刻的原始 ISO */
    frozenAt: string
    superseded: string | null; latestVersion: string
}

export default function PacksTable({ rows, empty }: { rows: PackRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: ExportableColumn<PackRow>[] = [
        { key: 'code', header: t('compliancePacks.colCode'), priority: true,
          // 被取代的那一份屏幕上整行灰掉 —— 导出把这个状态写进号格
          exportAs: (r) => xText(r.superseded ? `${r.code} (${t('table.export.rowSuperseded')})` : r.code),
          render: (r) => <Link href={`/compliance/packs/${r.id}`} className="hover:underline app-link">{r.code}</Link> },
        { key: 'month', header: t('compliancePacks.colMonth'), priority: true, render: (r) => r.month, exportAs: (r) => xText(r.month) },
        { key: 'frozen', header: t('compliancePacks.colFrozen'), render: (r) => r.frozen, exportAs: (r) => xTime(r.frozenAt) },
        { key: 'pdf', header: t('compliancePacks.colPdf'), priority: true, render: (r) => r.latestVersion, exportAs: (r) => xText(r.latestVersion) },
        { key: 'superseded', header: t('compliancePacks.colSuperseded'), render: (r) => r.superseded ?? '—', exportAs: (r) => xText(r.superseded) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        rowClassName={(r) => (r.superseded ? 'text-gray-400' : undefined)}
        exportSpec={{ name: 'compliance-packs', title: t('compliancePacks.listTitle'), serverRows: '/compliance/packs/export' }} />
}
