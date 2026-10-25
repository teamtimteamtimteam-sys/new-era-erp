'use client'

// MES-4a:工序清单。行在服务端压平成字符串与数(Column.render 是函数,过不了 RSC 边界 —— CONV-1 §①)。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xInt } from '@/lib/export/cells'

export type OpTypeRow = {
    code: string; name: string; href: string; active: boolean; kindText: string
    /** 'na' = 状态改变型,没有平衡;'unset' = 还没有人给(V1);否则是带 % 的数 */
    tolerance: string
    fields: number; machines: number; recipes: number
    /** TABLE-EXPORT-1:导出用的原始容差(百分数本身);'na' / 'unset' 时是 null,导出写同一句话。 */
    tolerancePct: number | null
}

export default function OperationTypesTable({ rows }: { rows: OpTypeRow[] }) {
    const t = useTranslations()
    const columns: ExportableColumn<OpTypeRow>[] = [
        {
            key: 'name', header: t('processing.opType.colName'), priority: true,
            // 屏幕上一格三行(名字 · 编号 · 停用)—— 导出同样三样,一行
            exportAs: (r) => xText([r.name, r.code, r.active ? null : t('processing.opType.inactive')].filter(Boolean).join(' · ')),
            render: (r) => (
                <>
                    <Link href={r.href} className="hover:underline app-link app-link-inline">{r.name}</Link>
                    <span className="block text-xs text-[color:var(--brand-muted-text)]">{r.code}</span>
                    {!r.active && <span className="text-xs text-amber-700">{t('processing.opType.inactive')}</span>}
                </>
            ),
        },
        { key: 'kind', header: t('processing.opType.colKind'), render: (r) => r.kindText, exportAs: (r) => xText(r.kindText) },
        {
            key: 'tolerance', header: t('processing.opType.colTolerance'), align: 'right', priority: true,
            // 「不适用」与「还没给」是两个具名的答案,导出同样两句话;给了就是那个百分数
            exportAs: (r) => r.tolerance === 'na' ? xText(t('processing.opType.notApplicable'))
                : r.tolerance === 'unset' ? xText(t('dict.notYetSet')) : xNum(r.tolerancePct, 'pct'),
            render: (r) => r.tolerance === 'na' ? <span className="text-[color:var(--brand-muted-text)]">{t('processing.opType.notApplicable')}</span>
                : r.tolerance === 'unset' ? <span className="text-amber-700" data-not-set="tolerance">{t('dict.notYetSet')}</span>
                    : r.tolerance,
        },
        { key: 'fields', header: t('processing.opType.colFields'), align: 'right', render: (r) => r.fields, exportAs: (r) => xInt(r.fields) },
        { key: 'machines', header: t('processing.opType.colMachines'), align: 'right', render: (r) => r.machines, exportAs: (r) => xInt(r.machines) },
        { key: 'recipes', header: t('processing.opType.colRecipes'), align: 'right', render: (r) => r.recipes, exportAs: (r) => xInt(r.recipes) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.code} phone={{ mode: 'columns' }} empty={t('processing.opType.empty')}
                      exportSpec={{ name: 'operation-operation-types', title: t('processing.opType.title') }}
                      // TABLE-FEATURES-1 Q9:一次读取拿到全体 —— 在浏览器里排
                      sorting={{ mode: 'client', coverage: 'complete' }} />
}
