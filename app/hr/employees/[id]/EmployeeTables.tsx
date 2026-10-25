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
//
// ★ TABLE-EXPORT-3b:三张表各一对导出(About 表上写明是哪一名员工)。链接格导出它的字;日期写真日期(加了原始字段);
//   到期日旁那枚「已过期」徽章不进导出(docs/table-export.md「一格放不下」:徽章不随它所概括的那个值导出 —— 到期日本身就在)。
import * as React from 'react'
import Link from 'next/link'
import { MaskedValue } from '@/app/components/MaskedValue'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xDate, xMoney, xRestricted, xText } from '@/lib/export/cells'
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
    /** TABLE-EXPORT-3b:导出用的原始值 —— 日期 YYYY-MM-DD,缺就是 null(不是屏幕上的「—」)。 */
    completedYmd: string | null
    expiryYmd: string | null
    categoryRaw: string | null
    providerRaw: string | null
}

export function EmployeeTrainingTable({ rows, employee }: { rows: readonly TrainingRow[]; employee: string }) {
    const t = useTranslations()
    const columns: ExportableColumn<TrainingRow>[] = [
        {
            key: 'name',
            header: t('hr.colTrainingName'),
            priority: true,
            render: (r) => (
                <Link href={r.href} className="hover:underline app-link">
                    {r.name}
                </Link>
            ),
            exportAs: (r) => xText(r.name),
        },
        { key: 'category', header: t('hr.colCategory'), render: (r) => r.categoryText, exportAs: (r) => xText(r.categoryRaw === null ? null : r.categoryText) },
        { key: 'completed', header: t('hr.colCompletedDate'), render: (r) => r.completedDate, exportAs: (r) => xDate(r.completedYmd) },
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
            exportAs: (r) => xDate(r.expiryYmd),
        },
        { key: 'provider', header: t('hr.colProvider'), render: (r) => r.provider, exportAs: (r) => xText(r.providerRaw) },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('hr.trainingEmpty')}
            exportSpec={{ name: 'hr-employee-training', title: t('hr.trainingTitle'), aboutExtra: [[t('hr.colEmployee'), employee]] }}
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

export function EmployeeReviewsTable({ rows, employee }: { rows: readonly EmployeeReviewRow[]; employee: string }) {
    const t = useTranslations()
    // 期间那一格本来就是由两个原始日期拼成的「起 → 止」—— 导出照写这串字(docs/table-export.md:日期区间写成文字)。
    const columns: ExportableColumn<EmployeeReviewRow>[] = [
        {
            key: 'type',
            header: t('reviews.type'),
            priority: true,
            render: (r) => (
                <Link href={r.href} className="hover:underline app-link">
                    {r.typeText}
                </Link>
            ),
            exportAs: (r) => xText(r.typeText),
        },
        { key: 'cycle', header: t('reviews.cycle'), render: (r) => r.cycleName, exportAs: (r) => xText(r.cycleName) },
        {
            key: 'period',
            header: t('reviews.period'),
            className: 'whitespace-nowrap text-xs',
            render: (r) => r.periodText,
            exportAs: (r) => xText(r.periodText),
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
            exportAs: (r) => xText(r.statusText),
        },
        { key: 'rating', header: t('reviews.rating'), render: (r) => r.ratingText, exportAs: (r) => xText(r.ratingText) },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('reviews.noneForEmployee')}
            exportSpec={{ name: 'hr-employee-reviews', title: t('reviews.sectionTitle'), aboutExtra: [[t('hr.colEmployee'), employee]] }}
        />
    )
}

// ── 薪资历史(受限) ────────────────────────────────────────────────────────
export type EmployeePayRow = {
    id: string
    periodLabel: string
    periodHref: string | null
    currency: string
    /** TABLE-EXPORT-2b-2:null = 受限(读者不持 data.view_pay、又不是本人)—— 画「受限」,不画「—」 */
    grossText: string | null
    employerCpfText: string | null
    employeeCpfText: string | null
    deductionsText: string | null
    netText: string | null
    posted: boolean
    statusText: string
    /** TABLE-EXPORT-3b:导出用的原始值。期间写 YYYY-MM(屏幕上是格式化过的月份);五个金额写原数(*Text 为 null 时导出 "Restricted")。 */
    periodMonth: string | null
    gross: number | null
    employerCpf: number | null
    employeeCpf: number | null
    deductions: number | null
    net: number | null
}

export function EmployeePayrollTable({ rows, employee }: { rows: readonly EmployeePayRow[]; employee: string }) {
    const t = useTranslations()
    const paid = (text: string | null) => (text === null ? <MaskedValue value={null} canView={false} /> : text)
    // ★ TABLE-EXPORT-3b:「受限」与屏幕同一条判据 —— *Text 为 null(页面 payText:无 data.view_pay、值为空,本人除外)→ "Restricted"。
    //   币种写在期间那一格里(每行各按各的期间币种)→ 金额 xMoney(v, 该行币种)。期间那一格装着 月份 + 币种:导出写月份(主值)。
    const paidX = (text: string | null, v: number | null, ccy: string) => (text === null ? xRestricted : xMoney(v, ccy || null))
    const columns: ExportableColumn<EmployeePayRow>[] = [
        {
            key: 'period',
            header: t('hr.colPeriod'),
            priority: true,
            render: (r) => (
                <>
                    {r.periodHref ? (
                        <Link href={r.periodHref} className="hover:underline app-link">
                            {r.periodLabel}
                        </Link>
                    ) : (
                        '—'
                    )}
                    <span className="text-gray-400 ml-2">{r.currency}</span>
                </>
            ),
            exportAs: (r) => xText(r.periodMonth ? r.periodMonth.slice(0, 7) : null),
        },
        { key: 'gross', header: t('hr.colGross'), align: 'right', render: (r) => paid(r.grossText), exportAs: (r) => paidX(r.grossText, r.gross, r.currency) },
        { key: 'employerCpf', header: t('hr.colEmployerCpf'), align: 'right', render: (r) => paid(r.employerCpfText), exportAs: (r) => paidX(r.employerCpfText, r.employerCpf, r.currency) },
        { key: 'employeeCpf', header: t('hr.colEmployeeCpf'), align: 'right', render: (r) => paid(r.employeeCpfText), exportAs: (r) => paidX(r.employeeCpfText, r.employeeCpf, r.currency) },
        { key: 'deductions', header: t('hr.colDeductions'), align: 'right', render: (r) => paid(r.deductionsText), exportAs: (r) => paidX(r.deductionsText, r.deductions, r.currency) },
        {
            key: 'net',
            header: t('hr.colNet'),
            align: 'right',
            // ★ 见抬头:那个月实际拿到多少。
            priority: true,
            className: 'font-medium',
            render: (r) => paid(r.netText),
            exportAs: (r) => paidX(r.netText, r.net, r.currency),
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
            exportAs: (r) => xText(r.statusText),
        },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('hr.payrollEmpty')}
            exportSpec={{ name: 'hr-employee-pay-history', title: t('hr.payrollTitle'), aboutExtra: [[t('hr.colEmployee'), employee]] }}
        />
    )
}
