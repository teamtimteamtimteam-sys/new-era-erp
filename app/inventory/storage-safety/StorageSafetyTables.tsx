'use client'

// app/inventory/storage-safety/StorageSafetyTables.tsx
// MES-3a(2026-10-06,MES-3a Step 0 Q1 · Q13 · Q15 · Q20):/inventory/storage-safety 的三张表。
//   ① 上限:今天在效执照下每一类 NEA 废物的存量对着上限(超了整行琥珀;上限没给照直说"没给",不说"没超")。
//   ② 滞留:还在厂里的批身上每一条开着的安全状态,记下几天、提醒天数(没给 → "not yet set",V3);过了整行琥珀。
//   ③ 隔离:身上开着要隔离的状态、却还有货放在非隔离库位的批(Q20:记录不拒,在这里说出来)。
//   行都由服务端组好(page.tsx),这里只排版。手机上留身份与那一格判词(TABLE-STYLE-1)。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xInt, xDate } from '@/lib/export/cells'

// TABLE-EXPORT-1:每一种行多带几样【原始值】(吨数 · 天数 · 日历日 · 数量)—— 导出读它们,不读屏幕上那几串字。
//   上限没给(limitT = null)与提醒天数没给(periodDays = null)在导出里同样是那句话,不是空格。
export type CeilingRow = {
    key: string; category: string; onHand: string; limit: string; status: string; statusText: string; batches: string
    onHandT: number; limitT: number | null; batchCount: number
}
export type DwellRow = {
    key: string; href: string; batch: string; state: string; recorded: string; days: string; period: string; past: boolean; status: string
    recordedOn: string; daysRecorded: number; periodDays: number | null
}
export type ExposureRow = {
    key: string; href: string; batch: string; state: string; location: string; qty: string; recorded: string
    qtyRaw: number; recordedOn: string
}

export function CeilingTable({ rows, empty }: { rows: CeilingRow[]; empty: string }) {
    const t = useTranslations()
    const columns: ExportableColumn<CeilingRow>[] = [
        { key: 'category', header: t('storageSafety.page.colCategory'), priority: true, render: (r) => r.category, exportAs: (r) => xText(r.category) },
        { key: 'onHand', header: t('storageSafety.page.colOnHand'), align: 'right', render: (r) => r.onHand, exportAs: (r) => xNum(r.onHandT, 'qty') },
        { key: 'limit', header: t('storageSafety.page.colLimit'), align: 'right', render: (r) => r.limit,
          exportAs: (r) => (r.limitT === null ? xText(r.limit) : xNum(r.limitT, 'qty')) },
        { key: 'batches', header: t('storageSafety.page.colBatches'), align: 'right', render: (r) => r.batches, exportAs: (r) => xInt(r.batchCount) },
        {
            key: 'status', header: t('storageSafety.page.colStatus'), priority: true,
            render: (r) => <span data-ceiling-status={r.status}>{r.statusText}</span>,
            exportAs: (r) => xText(r.statusText),
        },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={empty}
                      exportSpec={{ name: 'storage-ceilings', title: t('storageSafety.page.ceilingsTitle') }}
                      rowClassName={(r) => (r.status === 'exceeded' ? 'bg-amber-50' : undefined)} />
}

export function DwellTable({ rows, empty }: { rows: DwellRow[]; empty: string }) {
    const t = useTranslations()
    const columns: ExportableColumn<DwellRow>[] = [
        { key: 'batch', header: t('storageSafety.page.colBatch'), priority: true, render: (r) => <Link href={r.href} className="underline">{r.batch}</Link>, exportAs: (r) => xText(r.batch) },
        { key: 'state', header: t('storageSafety.page.colState'), priority: true, render: (r) => r.state, exportAs: (r) => xText(r.state) },
        { key: 'recorded', header: t('storageSafety.page.colRecorded'), render: (r) => r.recorded, exportAs: (r) => xDate(r.recordedOn) },
        { key: 'days', header: t('storageSafety.page.colDays'), align: 'right', render: (r) => <span data-dwell-status={r.status}>{r.days}</span>, exportAs: (r) => xInt(r.daysRecorded) },
        { key: 'period', header: t('storageSafety.page.colPeriod'), render: (r) => r.period,
          exportAs: (r) => (r.periodDays === null ? xText(r.period) : xInt(r.periodDays)) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={empty}
                      exportSpec={{ name: 'safety-state-dwell', title: t('storageSafety.page.dwellTitle') }}
                      rowClassName={(r) => (r.past ? 'bg-amber-50' : undefined)} />
}

export function ExposureTable({ rows, empty }: { rows: ExposureRow[]; empty: string }) {
    const t = useTranslations()
    const columns: ExportableColumn<ExposureRow>[] = [
        { key: 'batch', header: t('storageSafety.page.colBatch'), priority: true, render: (r) => <Link href={r.href} className="underline">{r.batch}</Link>, exportAs: (r) => xText(r.batch) },
        { key: 'state', header: t('storageSafety.page.colState'), render: (r) => r.state, exportAs: (r) => xText(r.state) },
        { key: 'location', header: t('storageSafety.page.colLocation'), priority: true, render: (r) => r.location, exportAs: (r) => xText(r.location) },
        { key: 'qty', header: t('storageSafety.page.colQty'), align: 'right', render: (r) => r.qty, exportAs: (r) => xNum(r.qtyRaw, 'qty') },
        { key: 'recorded', header: t('storageSafety.page.colRecorded'), render: (r) => r.recorded, exportAs: (r) => xDate(r.recordedOn) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={empty}
                      exportSpec={{ name: 'quarantine-exposure', title: t('storageSafety.page.quarantineTitle') }}
                      rowClassName={() => 'bg-amber-50'} />
}
