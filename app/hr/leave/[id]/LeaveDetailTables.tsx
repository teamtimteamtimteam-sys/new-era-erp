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
import * as React from 'react'
import { DataTable, type Column } from '@/app/components/ui/data-table'
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
}

export function GrantBreakdownTable({ rows }: { rows: readonly GrantBreakdownRow[] }) {
    const t = useTranslations()

    const columns: Column<GrantBreakdownRow>[] = [
        {
            key: 'year',
            header: t('leave.grantYear'),
            // ★ 身份的前一半 —— 见抬头。
            priority: true,
            render: (r) => r.leaveYear,
        },
        {
            key: 'grantType',
            header: t('leave.grantType'),
            // ★ 身份的后一半 —— 少了它,同一年的两笔授予读起来是同一笔。
            priority: true,
            render: (r) => r.grantTypeText,
        },
        { key: 'days', header: t('leave.days'), align: 'right', className: 'font-mono', render: (r) => r.days },
        { key: 'taken', header: t('leave.taken'), align: 'right', className: 'font-mono', render: (r) => r.consumed },
        {
            key: 'remaining',
            header: t('leave.remaining'),
            align: 'right',
            // ★ 审批人打开这一段就是为了这个数。
            priority: true,
            className: 'font-mono',
            render: (r) => r.remaining,
        },
        { key: 'expires', header: t('leave.expires'), render: (r) => r.expiresOn },
        { key: 'status', header: t('leave.grantStatus'), render: (r) => r.statusText },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('leave.noGrants')}
        />
    )
}

export type ConsumptionRow = {
    id: string
    entryTypeText: string
    days: string
    grantIdShort: string
    notes: string
}

export function ConsumptionTable({ rows }: { rows: readonly ConsumptionRow[] }) {
    const t = useTranslations()

    const columns: Column<ConsumptionRow>[] = [
        {
            key: 'entryType',
            header: t('leave.entryType'),
            // 身份列 —— 这是哪一种账目变动。
            priority: true,
            render: (r) => r.entryTypeText,
        },
        {
            key: 'days',
            header: t('leave.days'),
            align: 'right',
            // ★ 这张表存在的理由:这几天到底从哪几笔授予里扣的、扣了几天。
            priority: true,
            className: 'font-mono',
            render: (r) => r.days,
        },
        { key: 'grantId', header: t('leave.grantId'), className: 'font-mono', render: (r) => r.grantIdShort },
        { key: 'notes', header: t('leave.notes'), render: (r) => r.notes },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('leave.noConsumption')}
        />
    )
}
