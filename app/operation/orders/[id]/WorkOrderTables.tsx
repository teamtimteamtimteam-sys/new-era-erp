'use client'

// app/operation/orders/[id]/WorkOrderTables.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-10(2026-09-04)· 一张工单的三张子表
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【转换当场照出一个【看得见的】缺陷:两张表的列【错位】,而且是一对镜像】★★
//   转换前:
//     投入侧  4 个 <th> 对 **5** 个 <td> —— 「出处」那一格【没有表头】
//     产出侧  **5** 个 <th> 对 4 个 <td> —— 声明了 colBasis 表头,【却没有那一格】
//   两张表逐字互为镜像,是同一次复制粘贴把「出处」列留在了错的一侧。
//   **后果不是难看,是读错数**:产出侧的「实产」落在「出处」表头底下,
//   「差异」落在「实产」底下 —— 整张表右移一格,而每一格里都还是一个像样的数字,
//   所以它不会像坏掉,只会像在说别的话。
//   `processing.wo.colBasis` 这个键【一直存在】,只是投入侧从没用过它。
//
//   ☞ 这是 CONV-9 §⑫-10 第 1 条(MaintenancePanel 5 th 对 6 td)的**第二次**。
//     两次都不是被人眼看出来的,都是【DataTable 的契约要求每列都有 header】
//     逼出来的 —— 一个"每列必须有名字"的契约,顺手把列错位变成了不可能。
//
// ★【手机:元凶【在】表里 —— CONV-9 §⑫-5a 的又一例】★
//   探针给这一页的判词是 +65px / 1 张表被裁,culprit `span.text-amber-700`。
//   那枚琥珀字住在投入表的「计划外」标记与两张表的负差异里 —— 全都在 <td> 中。
//   **所以这一页正是 DataTable 够得着的那一种。**
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

/** 计划 vs 实际的一行,投入侧与产出侧共用同一个形状。 */
export type FulfilmentRow = {
    id: string
    label: string
    hasPlan: boolean
    plannedText: string | null
    actualText: string
    varianceText: string | null
    varianceNegative: boolean
    /** 投入侧才有:这个计划数【是谁说的】。产出侧为 null。 */
    basis: { tone: string; label: string; reference: string | null } | null
    basisUnstated: boolean
}

export type LinkedRunRow = {
    id: string
    code: string
    href: string
    processDate: string
    totalInput: string
    totalOutput: string
    reversed: boolean
    statusLabel: string
}

function varianceCell(r: FulfilmentRow) {
    // 【差异为空就留空 —— 绝不写 0】没有被减数,差就说不出来。
    return r.varianceText == null
        ? <span className="text-gray-400">—</span>
        : <span className={r.varianceNegative ? 'text-amber-700' : ''}>{r.varianceText}</span>
}

export function InputSideTable({ rows }: { rows: readonly FulfilmentRow[] }) {
    const t = useTranslations()
    const columns: Column<FulfilmentRow>[] = [
        {
            key: 'material',
            header: t('processing.wo.colMaterial'),
            // 身份列:一行差异的主语是那一种料。
            priority: true,
            render: (r) => (
                <>
                    {r.label}
                    {/* 【吃了没人计划过的料】自己一行,并说出它是什么 */}
                    {!r.hasPlan && (
                        <span className="ml-2 text-xs text-amber-700">{t('processing.wo.unplannedMaterial')}</span>
                    )}
                </>
            ),
        },
        {
            key: 'planned', header: t('processing.wo.colPlanned'), align: 'right', className: 'font-mono',
            render: (r) => r.plannedText ?? <span className="text-gray-400">—</span>,
        },
        {
            // ★【这一列转换前【没有表头】—— 补上的是它一直缺的那个名字,不是新列】★
            //   出处必须在屏幕上分得开,不只是在数据里分得开:播种的猜测标琥珀并带
            //   「低置信」,校准过的标绿;**没人说过的那一格写着「还没有人说过」,
            //   不是一个空白格** —— 空白读起来像"这一栏不重要",而这一栏正是
            //   六个月后唯一能回答"这个数可不可信"的东西。
            key: 'basis',
            header: t('processing.wo.colBasis'),
            className: 'text-xs',
            render: (r) =>
                !r.hasPlan ? <span className="text-gray-400">—</span>
                    : r.basisUnstated ? <span className="text-gray-500 italic">{t('processing.wo.basis.unstated')}</span>
                    : r.basis ? (
                        <>
                            <span className={`inline-block px-2 py-0.5 rounded ${r.basis.tone}`}>{r.basis.label}</span>
                            {r.basis.reference && <span className="block text-gray-500 mt-1">{r.basis.reference}</span>}
                        </>
                    ) : null,
        },
        { key: 'actual', header: t('processing.wo.colConsumed'), align: 'right', className: 'font-mono', render: (r) => r.actualText },
        {
            key: 'variance',
            header: t('processing.wo.colVariance'),
            align: 'right',
            // ★ 计划对实际的表,存在的理由就是这一列。
            priority: true,
            className: 'font-mono',
            render: varianceCell,
        },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }}
                   // 计划外的料整行琥珀底 —— rowClassName 是 CONV-4 建的槽。
                   rowClassName={(r) => (r.hasPlan ? undefined : 'bg-amber-50')}
                   empty={t('processing.wo.noLines')} />
    )
}

export function OutputSideTable({ rows }: { rows: readonly FulfilmentRow[] }) {
    const t = useTranslations()
    // ★ 产出侧【没有】出处列 —— 转换前它声明了那个表头却没有那一格,
    //   于是整张表右移一格。这里按【表体实际有什么】定列,而不是按旧表头。
    const columns: Column<FulfilmentRow>[] = [
        { key: 'material', header: t('processing.wo.colMaterial'), priority: true, render: (r) => r.label },
        {
            key: 'expected', header: t('processing.wo.colExpected'), align: 'right', className: 'font-mono',
            // 【没估过 ≠ 估了零 —— 屏幕上把它说出来】
            render: (r) => r.hasPlan
                ? r.plannedText
                : <span className="text-gray-500 italic text-xs">{t('processing.wo.noExpectation')}</span>,
        },
        { key: 'produced', header: t('processing.wo.colProduced'), align: 'right', className: 'font-mono', render: (r) => r.actualText },
        { key: 'variance', header: t('processing.wo.colVariance'), align: 'right', priority: true, className: 'font-mono', render: varianceCell },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }} empty={t('processing.wo.noOutputsYet')} />
    )
}

export function LinkedRunsTable({ rows }: { rows: readonly LinkedRunRow[] }) {
    const t = useTranslations()
    const columns: Column<LinkedRunRow>[] = [
        {
            key: 'code',
            header: t('processing.colCode'),
            // 身份列。
            priority: true,
            className: 'font-mono',
            render: (r) => <Link href={r.href} className="text-blue-600 hover:underline">{r.code}</Link>,
        },
        { key: 'date', header: t('processing.colProcessDate'), render: (r) => r.processDate },
        { key: 'in', header: t('processing.colTotalInput'), align: 'right', className: 'font-mono', render: (r) => r.totalInput },
        { key: 'out', header: t('processing.colTotalOutput'), align: 'right', className: 'font-mono', render: (r) => r.totalOutput },
        {
            key: 'status',
            header: t('processing.colStatus'),
            // ★ 留状态而不是留数量:一张【已冲销】的加工单仍然列在这里
            //   (它确实照这张工单干过活),但它的消耗【哪儿都不算】——
            //   不算进上面的差异、不算进改单下限、不算进取消保护。
            //   所以「这一行算不算数」比「这一行有多少」更要紧。
            priority: true,
            render: (r) => <span className="text-xs px-2 py-1 bg-gray-200 rounded">{r.statusLabel}</span>,
        },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }}
                   rowClassName={(r) => (r.reversed ? 'text-gray-400' : undefined)}
                   empty={t('processing.wo.noRuns')} />
    )
}
