'use client'

// app/hr/leave/[id]/LeaveDetailTables.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 一张请假单下面的两张表
// ════════════════════════════════════════════════════════════════════════════
//
// 【一个文件两个表组件】与 CONV-5 的 ContractsTables / OverlapTables 同形 ——
// 两张表属于同一页、同一个问题(这几天从哪儿来、扣到哪儿去)。闸数的是调用点,
// 所以这里是 2 个。
//
// ★★【授予表在手机上留【三列】,不是两列 —— 而这是一个有先例的判断】★★
// 一笔授予的身份是「哪一年 · 哪一种」**合起来**:同一年可以既有当年计提又有
// 上年结转,而「2026」与「结转」各自都不足以指认某一笔。
// 这正是 CONV-5 §⑩-13 给 `/inventory/reports/violations` 写下的同一句话 ——
// 「身份是两者【合起来】,少一个这一行读不成话」。第三列是【剩余】,
// 因为审批人打开这一段就是为了那个数(与 CONV-5 给 /hr/leave/balances 挑的
// 「可用天数」是同一个理由,只是这里是逐笔的版本)。
//
// 【消耗表两列就够】它的主语是"这是哪一种账目变动",而它存在的理由是"扣了几天"。
//
// ★ TABLE-EXPORT-3b:两张表各一对导出(About 表上写明是哪一张请假单、哪一名员工)。屏幕上的天数全是字符串 ——
//   导出读加在行上的原始数(xNum),到期日读原始日期(xDate),不写格式化过的那串字。
import * as React from 'react'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xDate, xNum, xText } from '@/lib/export/cells'
import { useTranslations } from '@/lib/i18n/client'

export type GrantBreakdownRow = {
    id: string
    leaveYear: string
    grantTypeText: string
    days: string
    consumed: string
    remaining: string
    expiresOn: string
    statusText: string
    /** TABLE-EXPORT-3b:导出用的原始值 */
    daysRaw: number
    consumedRaw: number
    remainingRaw: number
    expiresYmd: string | null
}

export function GrantBreakdownTable({ rows, about }: { rows: readonly GrantBreakdownRow[]; about: ReadonlyArray<[string, string]> }) {
    const t = useTranslations()

    const columns: ExportableColumn<GrantBreakdownRow>[] = [
        {
            key: 'year',
            header: t('leave.grantYear'),
            // ★ 身份的前一半 —— 见抬头。
            priority: true,
            render: (r) => r.leaveYear,
            // 年份是一个标识,不是一个量 —— 写成文字(数字格式 #,##0 会把它印成「2,026」)
            exportAs: (r) => xText(r.leaveYear),
        },
        {
            key: 'grantType',
            header: t('leave.grantType'),
            // ★ 身份的后一半 —— 少了它,同一年的两笔授予读起来是同一笔。
            priority: true,
            render: (r) => r.grantTypeText,
            exportAs: (r) => xText(r.grantTypeText),
        },
        { key: 'days', header: t('leave.days'), align: 'right', render: (r) => r.days, exportAs: (r) => xNum(r.daysRaw, 'qty') },
        { key: 'taken', header: t('leave.taken'), align: 'right', render: (r) => r.consumed, exportAs: (r) => xNum(r.consumedRaw, 'qty') },
        {
            key: 'remaining',
            header: t('leave.remaining'),
            align: 'right',
            // ★ 审批人打开这一段就是为了这个数。
            priority: true,
            render: (r) => r.remaining,
            exportAs: (r) => xNum(r.remainingRaw, 'qty'),
        },
        { key: 'expires', header: t('leave.expires'), render: (r) => r.expiresOn, exportAs: (r) => xDate(r.expiresYmd) },
        { key: 'status', header: t('leave.grantStatus'), render: (r) => r.statusText, exportAs: (r) => xText(r.statusText) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('leave.noGrants')}
            exportSpec={{ name: 'hr-leave-grant-breakdown', title: t('leave.balanceNow'), aboutExtra: about }}
        />
    )
}

export type ConsumptionRow = {
    id: string
    entryTypeText: string
    days: string
    grantIdShort: string
    notes: string
    /** TABLE-EXPORT-3b:导出用的原始值 */
    daysRaw: number
    grantIdShortRaw: string | null
    notesRaw: string | null
}

export function ConsumptionTable({ rows, about }: { rows: readonly ConsumptionRow[]; about: ReadonlyArray<[string, string]> }) {
    const t = useTranslations()

    const columns: ExportableColumn<ConsumptionRow>[] = [
        {
            key: 'entryType',
            header: t('leave.entryType'),
            // 身份列 —— 这是哪一种账目变动。
            priority: true,
            render: (r) => r.entryTypeText,
            exportAs: (r) => xText(r.entryTypeText),
        },
        {
            key: 'days',
            header: t('leave.days'),
            align: 'right',
            // ★ 这张表存在的理由:这几天到底从哪几笔授予里扣的、扣了几天。
            priority: true,
            render: (r) => r.days,
            exportAs: (r) => xNum(r.daysRaw, 'qty'),
        },
        { key: 'grantId', header: t('leave.grantId'), render: (r) => r.grantIdShort, exportAs: (r) => xText(r.grantIdShortRaw) },
        { key: 'notes', header: t('leave.notes'), render: (r) => r.notes, exportAs: (r) => xText(r.notesRaw) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('leave.noConsumption')}
            exportSpec={{ name: 'hr-leave-consumption', title: t('leave.consumption'), aboutExtra: about }}
        />
    )
}
