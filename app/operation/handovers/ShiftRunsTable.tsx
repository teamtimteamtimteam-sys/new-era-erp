'use client'

// app/operation/handovers/ShiftRunsTable.tsx
// SYSTEM-MAP-4(Tim 2026-10-29 第 7 条 · 2026-10-30 Q5):交接班页与新建交接班那一屏共用的【只读】一段 ——
// 这个班 · 这一天的加工单。怎么配、为什么这样配,写在 ./shiftRuns.ts 的抬头。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import CellsTable, { type CellRow } from '../equipment/CellsTable'
import { xText, xNum, xTime } from '@/lib/export/cells'
import { processingStatusLabelKey } from '../status'
import type { ShiftRuns } from './shiftRuns'

export default function ShiftRunsTable({ data }: { data: ShiftRuns }) {
    const t = useTranslations()
    const status = (v: string) => { const k = processingStatusLabelKey(v); return k ? t(k) : v }
    const notRecorded = t('processing.rec.predatesField')
    const qty = (v: number | null) => (v === null ? '—' : String(v))
    const rows: CellRow[] = data.runs.map((r) => ({
        id: r.id,
        cells: {
            code: <Link href={`/operation/processing/${r.id}`} className="app-link hover:underline">{r.code}</Link>,
            operation: r.operation,
            start: r.startedAt ?? notRecorded,
            end: r.endedAt ?? notRecorded,
            input: qty(r.input),
            output: qty(r.output),
            loss: qty(r.loss),
            status: status(r.status),
        },
        exports: {
            code: xText(r.code), operation: xText(r.operation),
            start: r.startedAtRaw ? xTime(r.startedAtRaw) : xText(notRecorded),
            end: r.endedAtRaw ? xTime(r.endedAtRaw) : xText(notRecorded),
            input: xNum(r.input, 'qty'), output: xNum(r.output, 'qty'), loss: xNum(r.loss, 'qty'),
            status: xText(status(r.status)),
        },
    }))
    return (
        <div data-section="handover-runs">
            <CellsTable
                columns={[
                    { key: 'code', header: t('processing.colCode'), priority: true },
                    { key: 'operation', header: t('processing.rec.operation') },
                    { key: 'start', header: t('processing.rec.startedAt'), priority: true },
                    { key: 'end', header: t('processing.rec.endedAt') },
                    { key: 'input', header: t('processing.colTotalInput'), align: 'right' },
                    { key: 'output', header: t('processing.colTotalOutput'), align: 'right' },
                    { key: 'loss', header: t('processing.colLoss'), align: 'right', priority: true },
                    { key: 'status', header: t('processing.colStatus') },
                ]}
                rows={rows}
                empty={t('processing.handover.runsNone')}
                sorting="client"
                exportSpec={{ name: 'operation-handover-runs', title: t('processing.handover.runsTitle') }}
            />
            {data.unattributed > 0 && (
                <p className="text-sm text-amber-800 mt-2" data-runs-unattributed={data.unattributed}>
                    {t('processing.handover.runsUnattributed', { n: data.unattributed })}
                </p>
            )}
        </div>
    )
}
