'use client'

// app/operation/processing/ProcessingTable.tsx
// CONV-5 · 加工单列表那张表。
//
// ★【排序不在这里】★ 这一页的 sort/dir 由 ProcessingToolbar 写进 URL、
//   由服务端 applyProcessingFilters 执行。DataTable 【不】接管排序
//   (不传 sorting prop),否则同一张表会有两套排序、而它们会各说各话。
//   Q7:转换前后的行序必须一个字不差 —— 本刀用 fetch 对拍验过,不是断言。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ProcessingRunRow = {
    id: string
    code: string
    processDate: string
    totalInput: string
    totalOutput: string
    lossLabel: string
    statusLabel: string
    workOrderId: string | null
    workOrderCode: string
}

export default function ProcessingTable({ rows, empty }: { rows: ProcessingRunRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【加工单号】与【损耗】—— 单号是身份;而损耗是这张登记簿被
    //   扫读的理由:一炉料进去出来少了多少,是这一页唯一需要当场判断的数
    //   (docs/proc-loss-and-saleability.md 整篇讲的就是它)。状态是个多数时候
    //   相同的徽章,进展开区。
    const columns: Column<ProcessingRunRow>[] = [
        {
            key: 'code', header: t('processing.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/operation/processing/${r.id}`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'processDate', header: t('processing.colProcessDate'), render: (r) => r.processDate },
        { key: 'totalInput', header: t('processing.colTotalInput'), render: (r) => r.totalInput },
        { key: 'totalOutput', header: t('processing.colTotalOutput'), render: (r) => r.totalOutput },
        { key: 'loss', header: t('processing.colLoss'), priority: true, render: (r) => r.lossLabel },
        {
            key: 'status', header: t('processing.colStatus'),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.statusLabel}</span>,
        },
        {
            // WO-1c:这次加工算在哪张计划上 —— 【没有就说"无计划",不留空】
            // 空白读起来是"数据缺了",而真相是一个正当的类别。
            key: 'workOrder', header: t('processing.colWorkOrder'), className: 'font-mono text-sm',
            render: (r) =>
                r.workOrderId ? (
                    <Link href={`/operation/orders/${r.workOrderId}`} className="text-blue-600 hover:underline">
                        {r.workOrderCode}
                    </Link>
                ) : (
                    <span className="text-gray-500 italic">{t('processing.noWorkOrder')}</span>
                ),
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
