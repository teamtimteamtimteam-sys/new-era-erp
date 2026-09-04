'use client'

// app/hr/payroll/[id]/PayrollLinesTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 一个工资期间的明细行
// ════════════════════════════════════════════════════════════════════════════
//
// ★【这一页是 CONV-8 实测溢出 +204px 的三张之一,而元凶【是表】】★
// CONV-8 §⑥ 那张表里,9 张溢出页有 6 张的元凶不是表;这一页是剩下 3 张里的一张
// (元凶 `th.…text-right`)—— 六个右对齐的金额列,在 390px 上必然顶宽。
// 所以这一张是 DataTable 真正修得了的那一种。
//
// ★【手机上留【员工】与【实发】】★
// 身份是那个人;而一个工资期间被打开的理由是「这个月到底付出去多少」——
// 那正是 CONV-5 §⑩-13 给 /hr/payroll 列表页挑的第二列(期间 · 实发合计),
// 这里是它逐行的版本。四个中间量(应发 / 个人公积金 / 公司公积金 / 其他扣款)
// 进展开区 —— 它们回答的是"这个数怎么来的",而那是第二个问题。
//
// 【行数据在服务端压平】金额一律 formatMoneyBare + 抬头那句币种说明(CCY-1),
// 员工链接过界的是 code / name / href 三个字符串。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type PayrollLineRow = {
    id: string
    employeeCode: string
    employeeName: string
    employeeHref: string | null
    grossText: string
    employeeCpfText: string
    employerCpfText: string
    deductionsText: string
    netText: string
    /** 合计行。见 CONV-4 §⑨-3 / CONV-8 §⑧。 */
    isTotal?: boolean
    /** 合计行右边那句「共 N 行」。 */
    totalNote?: string
}

export default function PayrollLinesTable({ rows }: { rows: readonly PayrollLineRow[] }) {
    const t = useTranslations()

    const columns: Column<PayrollLineRow>[] = [
        {
            key: 'employee',
            header: t('hr.colEmployee'),
            // 身份列 —— 一行工资的主语是那个人。
            priority: true,
            render: (r) =>
                r.isTotal ? (
                    <>
                        {r.employeeName}
                        {r.totalNote && <span className="ml-2 font-normal text-gray-500">{r.totalNote}</span>}
                    </>
                ) : r.employeeHref ? (
                    <Link href={r.employeeHref} className="text-blue-600 hover:underline">
                        <span className="font-mono text-xs text-gray-500 mr-2">{r.employeeCode}</span>
                        {r.employeeName}
                    </Link>
                ) : (
                    '—'
                ),
        },
        { key: 'gross', header: t('hr.colGross'), align: 'right', className: 'font-mono', render: (r) => r.grossText },
        { key: 'employeeCpf', header: t('hr.colEmployeeCpf'), align: 'right', className: 'font-mono', render: (r) => r.employeeCpfText },
        { key: 'employerCpf', header: t('hr.colEmployerCpf'), align: 'right', className: 'font-mono', render: (r) => r.employerCpfText },
        { key: 'deductions', header: t('hr.colDeductions'), align: 'right', className: 'font-mono', render: (r) => r.deductionsText },
        {
            key: 'net',
            header: t('hr.colNet'),
            align: 'right',
            // ★ 这张表存在的理由:这个人这个月实际拿到多少。
            priority: true,
            className: 'font-mono font-medium',
            render: (r) => r.netText,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            rowClassName={(r) => (r.isTotal ? 'font-bold bg-[color:var(--brand-muted)]' : undefined)}
            empty={t('hr.errors.NO_LINES')}
        />
    )
}
