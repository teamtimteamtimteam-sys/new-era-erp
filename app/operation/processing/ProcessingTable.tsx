'use client'

// app/operation/processing/ProcessingTable.tsx
// CONV-5 · 加工单列表那张表。
//
// ★【排序不在这里】★ 这一页的 sort/dir 由 ProcessingToolbar 写进 URL、
//   由服务端 applyProcessingFilters 执行。DataTable 【不】接管排序
//   (不传 sorting prop),否则同一张表会有两套排序、而它们会各说各话。
//   Q7:转换前后的行序必须一个字不差 —— 本刀用 fetch 对拍验过,不是断言。
// ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9)取代上面那条:工具栏从来没写过 sort/dir,这一页有参数没控件。
//   现在表头是链接(DataTable 的 server 模式),排序仍在服务端执行(processingQuery.ts 的 PROCESSING_SORT);
//   于是还是只有一套排序。工单编号与平衡状态是查出来的,不可排。
//
// TABLE-EXPORT-1(Tim 2026-10-22 Q2):表是服务端分页的,于是导出的行不从这一页来 ——
//   exportHref 指向 ./export(processingRows.ts 同一份读取翻页取全),列仍是这里这一份定义。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xDate, xTime } from '@/lib/export/cells'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'

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
    /** SYSTEM-MAP-4(第 7 条 · Q5):开始 / 结束(拼好的字;MES-4a 之前的单是 null)与两个原始时刻(导出用),以及班次名 */
    startedAt: string | null
    endedAt: string | null
    startedAtRaw: string | null
    endedAtRaw: string | null
    shiftLabel: string | null
}

export default function ProcessingTable({ rows, empty, exportHref, sort, shown, total }: {
    rows: ProcessingRunRow[]; empty: React.ReactNode
    /** TABLE-EXPORT-1:服务端翻页取全的那条路由(带当前筛选与排序,不带 page)。 */
    exportHref: string
    /** TABLE-FEATURES-1 Q9:在数据库里排(processingQuery.ts 的 PROCESSING_SORT) */
    sort: ListSort; shown: number; total: number
}) {
    const t = useTranslations()
    const sortHref = useSortHref()

    // ★ 手机上留【加工单号】与【损耗】—— 单号是身份;而损耗是这张登记簿被
    //   扫读的理由:一炉料进去出来少了多少,是这一页唯一需要当场判断的数
    //   (docs/proc-loss-and-saleability.md 整篇讲的就是它)。状态是个多数时候
    //   相同的徽章,进展开区。
    const columns: ExportableColumn<ProcessingRunRow>[] = [
        {
            key: 'code', sortable: true, header: t('processing.colCode'), priority: true, className: 'text-sm', exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/operation/processing/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        // TABLE-FEATURES-1:列键与排序参数同名(process_date),旧的 ?sort=process_date 地址照旧
        { key: 'process_date', sortable: true, header: t('processing.colProcessDate'), render: (r) => r.processDate, exportAs: (r) => xDate(r.processDateRaw) },
        // SYSTEM-MAP-4(Tim 2026-10-29 第 7 条 · Q5):一张单在哪一段时刻、哪一个班做的 —— 交接班页按「班次 + 加工日」把单列出来
        //   开始与结束各一列,导出才是两个真时刻(一格只能装一个数)
        {
            key: 'started_at', sortable: true, header: t('processing.rec.startedAt'),
            render: (r) => r.startedAt ?? <span className="text-[color:var(--brand-muted-text)] italic">{t('processing.rec.predatesField')}</span>,
            exportAs: (r) => (r.startedAtRaw ? xTime(r.startedAtRaw) : xText(t('processing.rec.predatesField'))),
        },
        {
            key: 'ended_at', sortable: true, header: t('processing.rec.endedAt'),
            render: (r) => r.endedAt ?? <span className="text-[color:var(--brand-muted-text)] italic">{t('processing.rec.predatesField')}</span>,
            exportAs: (r) => (r.endedAtRaw ? xTime(r.endedAtRaw) : xText(t('processing.rec.predatesField'))),
        },
        {
            key: 'shift', sortable: true, header: t('processing.rec.shift'),
            render: (r) => r.shiftLabel ?? <span className="text-[color:var(--brand-muted-text)] italic">{t('processing.rec.predatesField')}</span>,
            exportAs: (r) => xText(r.shiftLabel ?? t('processing.rec.predatesField')),
        },
        { key: 'totalInput', sortable: true, header: t('processing.colTotalInput'), render: (r) => r.totalInput, exportAs: (r) => xNum(r.totalInputQty, 'qty') },
        { key: 'totalOutput', sortable: true, header: t('processing.colTotalOutput'), render: (r) => r.totalOutput, exportAs: (r) => xNum(r.totalOutputQty, 'qty') },
        // 屏幕上括号里那个百分数由投入与损耗两列算得出,导出只写损耗量本身(一个数)
        { key: 'loss', sortable: true, header: t('processing.colLoss'), priority: true, render: (r) => r.lossLabel, exportAs: (r) => xNum(r.lossQty, 'qty') },
        {
            key: 'status', sortable: true, header: t('processing.colStatus'), exportAs: (r) => xText(r.statusLabel),
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
                   exportSpec={{ name: 'operation-processing-runs', title: t('processing.listTitle'), serverRows: exportHref }}
                   sorting={{ mode: 'server', coverage: { shown, total }, active: sort, href: sortHref }} />
    )
}
