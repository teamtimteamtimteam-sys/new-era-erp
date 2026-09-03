'use client'

// app/hr/departments/DepartmentsTable.tsx
// CONV-5 · 部门登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import DeleteDepartmentButton from './DeleteDepartmentButton'

export type DepartmentRow = {
    id: string
    code: string
    nameEn: string
    nameZh: string
    parentLabel: string
    employeeCount: number
    isActive: boolean
}

export default function DepartmentsTable({ rows, empty }: { rows: DepartmentRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【编号】与【英文名】—— 编号是身份,而名字是这张登记簿
    //   被打开的理由(找哪个部门)。人数与上级是读到这一行之后才要问的东西。
    const columns: Column<DepartmentRow>[] = [
        { key: 'code', header: t('hr.colCode'), priority: true, className: 'font-mono text-sm', render: (r) => r.code },
        { key: 'nameEn', header: t('hr.colNameEn'), priority: true, render: (r) => r.nameEn },
        { key: 'nameZh', header: t('hr.colNameZh'), render: (r) => r.nameZh },
        { key: 'parent', header: t('hr.colParent'), className: 'text-sm text-gray-600', render: (r) => r.parentLabel },
        {
            key: 'count', header: t('hr.colEmployeeCount'), align: 'right', className: 'font-mono text-sm',
            render: (r) => r.employeeCount,
        },
        {
            key: 'active', header: t('hr.colActive'),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.isActive ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600')}>
                    {r.isActive ? t('pricing.form.active') : t('finance.inactive')}
                </span>
            ),
        },
        {
            key: 'actions', header: t('metalPrices.colActions'), className: 'text-sm whitespace-nowrap',
            render: (r) => (
                <>
                    <Link href={`/hr/departments/${r.id}/edit`} className="text-blue-600 hover:underline mr-3">
                        {t('purchasing.editLink')}
                    </Link>
                    <DeleteDepartmentButton id={r.id} name={r.nameEn} />
                </>
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
