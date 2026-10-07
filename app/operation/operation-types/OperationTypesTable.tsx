'use client'

// MES-4a:工序清单。行在服务端压平成字符串与数(Column.render 是函数,过不了 RSC 边界 —— CONV-1 §①)。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type OpTypeRow = {
    code: string; name: string; href: string; active: boolean; kindText: string
    /** 'na' = 状态改变型,没有平衡;'unset' = 还没有人给(V1);否则是带 % 的数 */
    tolerance: string
    fields: number; machines: number; recipes: number
}

export default function OperationTypesTable({ rows }: { rows: OpTypeRow[] }) {
    const t = useTranslations()
    const columns: Column<OpTypeRow>[] = [
        {
            key: 'name', header: t('processing.opType.colName'), priority: true,
            render: (r) => (
                <>
                    <Link href={r.href} className="hover:underline app-link app-link-inline">{r.name}</Link>
                    <span className="block text-xs text-[color:var(--brand-muted-text)]">{r.code}</span>
                    {!r.active && <span className="text-xs text-amber-700">{t('processing.opType.inactive')}</span>}
                </>
            ),
        },
        { key: 'kind', header: t('processing.opType.colKind'), render: (r) => r.kindText },
        {
            key: 'tolerance', header: t('processing.opType.colTolerance'), align: 'right', priority: true,
            render: (r) => r.tolerance === 'na' ? <span className="text-[color:var(--brand-muted-text)]">{t('processing.opType.notApplicable')}</span>
                : r.tolerance === 'unset' ? <span className="text-amber-700" data-not-set="tolerance">{t('dict.notYetSet')}</span>
                    : r.tolerance,
        },
        { key: 'fields', header: t('processing.opType.colFields'), align: 'right', render: (r) => r.fields },
        { key: 'machines', header: t('processing.opType.colMachines'), align: 'right', render: (r) => r.machines },
        { key: 'recipes', header: t('processing.opType.colRecipes'), align: 'right', render: (r) => r.recipes },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.code} phone={{ mode: 'columns' }} empty={t('processing.opType.empty')} />
}
