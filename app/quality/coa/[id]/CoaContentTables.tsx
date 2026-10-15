'use client'

// app/quality/coa/[id]/CoaContentTables.tsx
// MES-6b-2 · 证书页上"证书说了什么"的两张表 —— 成分(惩罚元素旁边是 ppm)与点了单时合同的验收限和判定。全部读快照(签发那一刻冻住的),
//   不读活数据。手机上留物质与含量、参数与判定。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type CompositionRow = { substance: string; label: string; content: string; ppm: string }
export type LimitRow = { parameter: string; label: string; min: string; max: string; measured: string; judgement: string }

export function CoaCompositionTable({ rows }: { rows: CompositionRow[] }) {
    const t = useTranslations()
    const columns: Column<CompositionRow>[] = [
        { key: 'substance', header: t('coa.detail.substance'), priority: true, render: (r) => r.label },
        { key: 'content', header: t('coa.detail.contentPct'), priority: true, align: 'right', render: (r) => r.content },
        { key: 'ppm', header: 'ppm', render: (r) => r.ppm },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.substance} phone={{ mode: 'columns' }} empty="—" />
}

export function CoaLimitsTable({ rows }: { rows: LimitRow[] }) {
    const t = useTranslations()
    const columns: Column<LimitRow>[] = [
        { key: 'parameter', header: t('coa.detail.parameter'), priority: true, render: (r) => r.label },
        { key: 'min', header: t('coa.detail.min'), render: (r) => r.min },
        { key: 'max', header: t('coa.detail.max'), render: (r) => r.max },
        { key: 'measured', header: t('coa.detail.measured'), render: (r) => r.measured },
        { key: 'judgement', header: t('coa.detail.judgement'), priority: true, render: (r) => r.judgement },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.parameter} phone={{ mode: 'columns' }} empty="—" />
}
