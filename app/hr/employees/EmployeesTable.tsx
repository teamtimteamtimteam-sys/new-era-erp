'use client'

// app/hr/employees/EmployeesTable.tsx
// CONV-5 · 员工名录那张表。
// 【列表上不出现任何薪酬列】—— employee_directory 里有 current_gross_pay,但列表
// 是最容易被旁人瞥见的地方;薪酬属受限内容,要看去个人档案页。这条判据跟着
// 列描述符走,而不是留在 page.tsx 的抬头里。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type EmployeeRow = {
    employeeId: string
    code: string
    legalName: string
    preferredName: string | null
    departmentLabel: string
    jobTitle: string
    employmentTypeLabel: string
    workCategoryLabel: string
    employmentStatus: string
    hireDate: string
    workPassAlert: string | null
    daysToWorkPassExpiry: number | null
}

export default function EmployeesTable({ rows, empty }: { rows: EmployeeRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    const statusCls = (s: string) =>
        s === 'active'
            ? 'bg-green-100 text-green-800'
            : s === 'probation'
              ? 'bg-amber-100 text-amber-800'
              : s === 'notice'
                ? 'bg-orange-100 text-orange-800'
                : 'bg-gray-200 text-gray-600'

    // ★ 手机上留【工号】与【姓名】—— 工号是身份,姓名是这份名录被打开的理由。
    //   准证到期提醒挂在工号那一格里,所以它在手机上【不会】掉进展开区 ——
    //   那是一条"名单上就能看见、不用逐个点开"的警示,藏起来等于取消它。
    const columns: Column<EmployeeRow>[] = [
        {
            key: 'code', header: t('hr.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <>
                    <Link href={`/hr/employees/${r.employeeId}`} className="text-blue-600 hover:underline">
                        {r.code}
                    </Link>
                    {r.workPassAlert && (
                        <span
                            title={t('hr.alertType.work_pass_expiry')}
                            className={
                                'ml-2 px-1.5 py-0.5 rounded text-xs ' +
                                (r.workPassAlert === 'expired'
                                    ? 'bg-red-100 text-red-800'
                                    : r.workPassAlert === 'critical'
                                      ? 'bg-amber-100 text-amber-800'
                                      : 'bg-gray-200 text-gray-600')
                            }
                        >
                            ⚠ {r.daysToWorkPassExpiry}d
                        </span>
                    )}
                </>
            ),
        },
        {
            key: 'legalName', header: t('hr.colLegalName'), priority: true,
            render: (r) => (
                <>
                    {r.legalName}
                    {r.preferredName && <span className="text-gray-500 text-sm ml-1">({r.preferredName})</span>}
                </>
            ),
        },
        { key: 'department', header: t('hr.colDepartment'), className: 'text-sm', render: (r) => r.departmentLabel },
        { key: 'jobTitle', header: t('hr.colJobTitle'), className: 'text-sm', render: (r) => r.jobTitle },
        { key: 'employmentType', header: t('hr.colEmploymentType'), className: 'text-sm', render: (r) => r.employmentTypeLabel },
        { key: 'workCategory', header: t('hr.colWorkCategory'), className: 'text-sm', render: (r) => r.workCategoryLabel },
        {
            key: 'status', header: t('hr.colStatus'),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + statusCls(r.employmentStatus)}>
                    {t('hr.employmentStatus.' + r.employmentStatus)}
                </span>
            ),
        },
        { key: 'hireDate', header: t('hr.colHireDate'), className: 'text-sm', render: (r) => r.hireDate },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.employeeId}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
