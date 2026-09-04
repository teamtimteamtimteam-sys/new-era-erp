'use client'

// app/hr/employees/[id]/EmployeeTables.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 一名员工页上的三张表:培训 · 绩效评估 · 薪资历史
// ════════════════════════════════════════════════════════════════════════════
//
// 【一个文件三个表组件】与 CONV-5 的 ContractsTables(一个文件五张表)同形。
// 闸数的是【调用点】,所以这里是 3 个。
//
// 【任职履历那一节【没有】进来 —— 它不是表】它转换前就是一条 <ol> 时间线
// (左边一根竖线、每条一个日期加一枚变动类型徽章)。把一条时间线塞进
// 「一行 = 一条记录」的表格契约里,就是 CONV-3 §⑧-3 拒绝对透视表做的那件事:
// **没有形状匹配不硬套。**
//
// ★【三张表的手机两列,各自的理由】★
//   培训   名称 · 到期日 —— CONV-5 §⑩-13 给 /hr/training 挑的正是「到期日」:
//                          「证书过期 = 这个人暂时不能上那道工序」。
//   评估   类型 · 状态   —— CONV-5 给 /hr/reviews 挑的是「状态」:
//                          「在 submitted 里躺三周的评估就是一件待办」。
//   薪资   期间 · 实发   —— 与 /hr/payroll/[id] 的明细行同一条:那个月实际拿到多少。
// 三条都是把【列表页已经拍过板的那一列】搬到这一个人身上,不是重新拍板。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'
import { statusPillClass } from '../../reviews/reviewShared'

// ── 培训 ────────────────────────────────────────────────────────────────────
export type TrainingRow = {
    id: string
    name: string
    href: string
    categoryText: string
    completedDate: string
    expiryDate: string
    /** 已过期 —— 徽章挂在【到期日】那一格里,也就是手机上留下的那一列。 */
    expired: boolean
    provider: string
}

export function EmployeeTrainingTable({ rows }: { rows: readonly TrainingRow[] }) {
    const t = useTranslations()
    const columns: Column<TrainingRow>[] = [
        {
            key: 'name',
            header: t('hr.colTrainingName'),
            priority: true,
            render: (r) => (
                <Link href={r.href} className="text-blue-600 hover:underline">
                    {r.name}
                </Link>
            ),
        },
        { key: 'category', header: t('hr.colCategory'), render: (r) => r.categoryText },
        { key: 'completed', header: t('hr.colCompletedDate'), render: (r) => r.completedDate },
        {
            key: 'expiry',
            header: t('hr.colExpiryDate'),
            // ★ 见抬头:证书过期是这张表存在的理由,徽章跟着它留在小屏上。
            priority: true,
            render: (r) => (
                <>
                    {r.expiryDate}
                    {r.expired && (
                        <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-red-100 text-red-800">
                            {t('hr.severity.expired')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'provider', header: t('hr.colProvider'), render: (r) => r.provider },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('hr.trainingEmpty')}
        />
    )
}

// ── 绩效评估 ────────────────────────────────────────────────────────────────
export type EmployeeReviewRow = {
    id: string
    typeText: string
    href: string
    cycleName: string
    periodText: string
    status: string
    statusText: string
    ratingText: string
}

export function EmployeeReviewsTable({ rows }: { rows: readonly EmployeeReviewRow[] }) {
    const t = useTranslations()
    const columns: Column<EmployeeReviewRow>[] = [
        {
            key: 'type',
            header: t('reviews.type'),
            priority: true,
            render: (r) => (
                <Link href={r.href} className="text-blue-600 hover:underline">
                    {r.typeText}
                </Link>
            ),
        },
        { key: 'cycle', header: t('reviews.cycle'), render: (r) => r.cycleName },
        {
            key: 'period',
            header: t('reviews.period'),
            className: 'whitespace-nowrap font-mono text-xs',
            render: (r) => r.periodText,
        },
        {
            key: 'status',
            header: t('reviews.status'),
            // ★ 见抬头:一份卡在某个状态里的评估就是一件待办。
            priority: true,
            render: (r) => (
                <span className={'inline-block rounded px-2 py-0.5 text-xs ' + statusPillClass(r.status)}>
                    {r.statusText}
                </span>
            ),
        },
        { key: 'rating', header: t('reviews.rating'), render: (r) => r.ratingText },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('reviews.noneForEmployee')}
        />
    )
}

// ── 薪资历史(受限) ────────────────────────────────────────────────────────
export type EmployeePayRow = {
    id: string
    periodLabel: string
    periodHref: string | null
    currency: string
    grossText: string
    employerCpfText: string
    employeeCpfText: string
    deductionsText: string
    netText: string
    posted: boolean
    statusText: string
}

export function EmployeePayrollTable({ rows }: { rows: readonly EmployeePayRow[] }) {
    const t = useTranslations()
    const columns: Column<EmployeePayRow>[] = [
        {
            key: 'period',
            header: t('hr.colPeriod'),
            priority: true,
            render: (r) => (
                <>
                    {r.periodHref ? (
                        <Link href={r.periodHref} className="text-blue-600 hover:underline">
                            {r.periodLabel}
                        </Link>
                    ) : (
                        '—'
                    )}
                    <span className="text-gray-400 ml-2">{r.currency}</span>
                </>
            ),
        },
        { key: 'gross', header: t('hr.colGross'), align: 'right', className: 'font-mono', render: (r) => r.grossText },
        { key: 'employerCpf', header: t('hr.colEmployerCpf'), align: 'right', className: 'font-mono', render: (r) => r.employerCpfText },
        { key: 'employeeCpf', header: t('hr.colEmployeeCpf'), align: 'right', className: 'font-mono', render: (r) => r.employeeCpfText },
        { key: 'deductions', header: t('hr.colDeductions'), align: 'right', className: 'font-mono', render: (r) => r.deductionsText },
        {
            key: 'net',
            header: t('hr.colNet'),
            align: 'right',
            // ★ 见抬头:那个月实际拿到多少。
            priority: true,
            className: 'font-mono font-medium',
            render: (r) => r.netText,
        },
        {
            key: 'status',
            header: t('hr.colStatus'),
            render: (r) => (
                <span
                    className={
                        'px-2 py-0.5 rounded text-xs ' +
                        (r.posted ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800')
                    }
                >
                    {r.statusText}
                </span>
            ),
        },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('hr.payrollEmpty')}
        />
    )
}
