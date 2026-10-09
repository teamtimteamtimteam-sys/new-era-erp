'use client'

// app/quality/disputes/[id]/MetalsTable.tsx
// MES-6a-1 · 争议页上三份结果并排:我们的 · 对手方的 · 仲裁的,以及前两份的差与是否超出立案时在案的容差。数取自 assay_dispute_metals。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type MetalRow = { metal: string; ours: string; counterparty: string; umpire: string; diff: string; beyond: boolean }

export default function MetalsTable({ rows }: { rows: MetalRow[] }) {
    const t = useTranslations()
    const columns: Column<MetalRow>[] = [
        { key: 'metal', header: t('quality.dispute.colMetal'), priority: true, render: (r) => r.metal },
        { key: 'ours', header: t('quality.party.ours'), priority: true, render: (r) => r.ours },
        { key: 'counterparty', header: t('quality.party.counterparty'), priority: true, render: (r) => r.counterparty },
        { key: 'umpire', header: t('quality.party.umpire'), render: (r) => r.umpire },
        { key: 'diff', header: t('quality.dispute.colDiff'),
          render: (r) => <span className={r.beyond ? 'text-amber-700' : undefined}>{r.diff}{r.beyond ? ` · ${t('quality.dispute.beyond')}` : ''}</span> },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.metal} phone={{ mode: 'columns' }} empty="—" />
}
