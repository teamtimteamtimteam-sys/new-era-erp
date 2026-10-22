'use client'

// app/output/OutputTable.tsx
// CONV-5 · 产出批次那张表。
// ★ Q7:排序仍是服务端的(sorting.mode='server')。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xDate, xTime } from '@/lib/export/cells'
import DeleteButton from './DeleteButton'
import { Button } from '@/app/components/ui/button'

export type OutputTableRow = {
    id: string
    code: string
    materialName: string
    customerName: string
    quantity: string
    remaining: string
    /** TABLE-EXPORT-1:导出用的原始数量 / 余量(Excel 里是一个数,不是「12 kg」这串字)。 */
    quantityQty: number
    remainingQty: number
    /** TABLE-EXPORT-1:屏幕上跟在数量后面的单位(原样的码,如 kg)—— 导出时写进格式。 */
    unit: string
    /** APR-7:注销要经 CFO(还有料) */
    needsWriteOffRequest: boolean
    /** APR-7:碰到这一批的那一张在等的仓库申请 */
    openWarehouseRequest: string | null
    outputDate: string
    /** TABLE-EXPORT-1:导出用的原始日历日 `YYYY-MM-DD`(没有 = null,屏幕上是「—」)。 */
    outputDateRaw: string | null
    stateLabel: string
    /**
     * PROC-WIRE-1A:被指定为下游工序投料的批次【不是可售库存】。
     * 它与销售状态是两条轴,所以是【另一个】角标,不是同一个角标的第四种颜色 ——
     * 一批货可以既"库存中"又"已许给产线"。null = 没有这条轴上的标记。
     */
    purposeTag: string | null
    status: string
    createdLabel: string
    /** TABLE-EXPORT-1:导出用的原始时刻(Excel 里是真日期,按新加坡时间)。 */
    createdAt: string
}

export default function OutputTable({
    rows, empty, sort, dir, filterQuery, shown, total, canWriteOff, exportHref,
}: {
    rows: OutputTableRow[]
    empty: React.ReactNode
    sort: string
    dir: 'asc' | 'desc'
    filterQuery: Record<string, string>
    shown: number
    total: number
    /** ROLE-1 Batch 3b:can('action.batch_write_off'),页面算好传进来。 */
    canWriteOff: boolean
    /** TABLE-EXPORT-1:服务端翻页取全的那条路由(带当前筛选与排序)。 */
    exportHref: string
}) {
    const t = useTranslations()

    const href = (key: string, nextDir: 'asc' | 'desc') => {
        const params = new URLSearchParams(filterQuery)
        params.set('sort', key)
        params.set('dir', nextDir)
        return `/output?${params.toString()}`
    }

    // ★ 手机上留【批次号】与【可用余量】—— 批次号是身份,而余量是这张登记簿
    //   被打开的理由(还能卖/还能投多少)。总量是余量的来源,进展开区。
    const columns: ExportableColumn<OutputTableRow>[] = [
        {
            key: 'code', header: t('output.colCode'), priority: true, sortable: true, className: 'text-sm',
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/output/${r.id}/edit`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'material', header: t('output.colMaterial'), render: (r) => r.materialName, exportAs: (r) => xText(r.materialName) },
        { key: 'customer', header: t('output.colCustomer'), render: (r) => r.customerName, exportAs: (r) => xText(r.customerName) },
        { key: 'quantity', header: t('output.colQuantity'), sortable: true, render: (r) => r.quantity, exportAs: (r) => xNum(r.quantityQty, 'qty', r.unit) },
        { key: 'remaining_qty', header: t('output.colRemaining'), priority: true, sortable: true, render: (r) => r.remaining, exportAs: (r) => xNum(r.remainingQty, 'qty', r.unit) },
        { key: 'output_date', header: t('output.colOutputDate'), sortable: true, render: (r) => r.outputDate, exportAs: (r) => xDate(r.outputDateRaw) },
        {
            // 两个角标是两条轴(销售状态 · 用途),导出成一格里的两段,与 materials 的「UN · HS」同一个写法
            key: 'state', header: t('output.colState'),
            exportAs: (r) => xText(r.purposeTag ? `${r.stateLabel} · ${r.purposeTag}` : r.stateLabel),
            render: (r) => (
                <>
                    <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.stateLabel}</span>
                    {r.purposeTag && (
                        <span className="ml-1 px-2 py-1 bg-amber-100 text-amber-800 border border-amber-300 rounded text-xs">
                            {r.purposeTag}
                        </span>
                    )}
                </>
            ),
        },
        {
            key: 'status', header: t('output.colStatus'), exportAs: (r) => xText(r.status),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.status}</span>,
        },
        {
            key: 'created_at', header: t('output.colCreated'), sortable: true,
            className: 'text-sm text-gray-600', render: (r) => r.createdLabel,
            exportAs: (r) => xTime(r.createdAt),
        },
        { key: 'actions', header: t('output.colActions'), exportAs: false, render: (r) => <DeleteButton id={r.id} code={r.code} canWriteOff={canWriteOff}
            needsRequest={r.needsWriteOffRequest} openRequestLabel={r.openWarehouseRequest} /> },
        {
            key: 'label', header: t('batchLabel.col'), exportAs: false,
            render: (r) => (
                <Button asChild variant="link" size="inline">
                    <a href={`/output/${r.id}/label`} target="_blank" rel="noopener noreferrer">
                        {t('batchLabel.col')}
                    </a>
                </Button>
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
            sorting={{ mode: 'server', coverage: { shown, total }, active: { key: sort, dir }, href }}
            exportSpec={{ name: 'output', title: t('output.listTitle'), serverRows: exportHref }}
        />
    )
}
