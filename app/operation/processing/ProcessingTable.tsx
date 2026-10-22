'use client'

// app/operation/processing/ProcessingTable.tsx
// CONV-5 · 加工单列表那张表。
//
// ★【排序不在这里】★ 这一页的 sort/dir 由 ProcessingToolbar 写进 URL、
//   由服务端 applyProcessingFilters 执行。DataTable 【不】接管排序
//   (不传 sorting prop),否则同一张表会有两套排序、而它们会各说各话。
//   Q7:转换前后的行序必须一个字不差 —— 本刀用 fetch 对拍验过,不是断言。
//
// TABLE-EXPORT-1(Tim 2026-10-22 Q2):表是服务端分页的,于是导出的行不从这一页来 ——
//   exportHref 指向 ./export(processingRows.ts 同一份读取翻页取全),列仍是这里这一份定义。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xDate } from '@/lib/export/cells'

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
    /** MES-4a:物料平衡的状态(open / closed / before_closure / not_applicable / reversed);读不到就是 null */
    balanceState: string | null
    /** TABLE-EXPORT-1:导出用的原始值 —— 加工日 `YYYY-MM-DD`、投入 / 产出 / 损耗的数(屏幕上那几个是拼好的字)。 */
    processDateRaw: string | null
    totalInputQty: number | null
    totalOutputQty: number | null
    lossQty: number | null
}

export default function ProcessingTable({ rows, empty, exportHref }: {
    rows: ProcessingRunRow[]; empty: React.ReactNode
    /** TABLE-EXPORT-1:服务端翻页取全的那条路由(带当前筛选与排序,不带 page)。 */
    exportHref: string
}) {
    const t = useTranslations()

    // ★ 手机上留【加工单号】与【损耗】—— 单号是身份;而损耗是这张登记簿被
    //   扫读的理由:一炉料进去出来少了多少,是这一页唯一需要当场判断的数
    //   (docs/proc-loss-and-saleability.md 整篇讲的就是它)。状态是个多数时候
    //   相同的徽章,进展开区。
    const columns: ExportableColumn<ProcessingRunRow>[] = [
        {
            key: 'code', header: t('processing.colCode'), priority: true, className: 'text-sm', exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/operation/processing/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'processDate', header: t('processing.colProcessDate'), render: (r) => r.processDate, exportAs: (r) => xDate(r.processDateRaw) },
        { key: 'totalInput', header: t('processing.colTotalInput'), render: (r) => r.totalInput, exportAs: (r) => xNum(r.totalInputQty, 'qty') },
        { key: 'totalOutput', header: t('processing.colTotalOutput'), render: (r) => r.totalOutput, exportAs: (r) => xNum(r.totalOutputQty, 'qty') },
        // 屏幕上括号里那个百分数由投入与损耗两列算得出,导出只写损耗量本身(一个数)
        { key: 'loss', header: t('processing.colLoss'), priority: true, render: (r) => r.lossLabel, exportAs: (r) => xNum(r.lossQty, 'qty') },
        {
            key: 'status', header: t('processing.colStatus'), exportAs: (r) => xText(r.statusLabel),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.statusLabel}</span>,
        },
        {
            // MES-4a(Q19):平衡结了没有 —— "待结算"是要人去做的事,其余几种是一句状态。
            key: 'balance', header: t('processing.rec.colBalance'),
            exportAs: (r) => xText(r.balanceState === null ? null : t('processing.rec.balanceState.' + r.balanceState)),
            render: (r) => r.balanceState === null ? '—' : (
                <span className={r.balanceState === 'open' ? 'text-amber-700' : 'text-[color:var(--brand-muted-text)]'} data-balance={r.balanceState}>
                    {t('processing.rec.balanceState.' + r.balanceState)}
                </span>
            ),
        },
        {
            // WO-1c:这次加工算在哪张计划上 —— 【没有就说"无计划",不留空】
            // 空白读起来是"数据缺了",而真相是一个正当的类别。
            key: 'workOrder', header: t('processing.colWorkOrder'), className: 'text-sm',
            exportAs: (r) => xText(r.workOrderId ? r.workOrderCode : t('processing.noWorkOrder')),
            render: (r) =>
                r.workOrderId ? (
                    <Link href={`/operation/orders/${r.workOrderId}`} className="hover:underline app-link">
                        {r.workOrderCode}
                    </Link>
                ) : (
                    <span className="text-gray-500 italic">{t('processing.noWorkOrder')}</span>
                ),
        },
    ]

    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
                   exportSpec={{ name: 'operation-processing-runs', title: t('processing.listTitle'), serverRows: exportHref }} />
    )
}
