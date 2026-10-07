'use client'

// app/inventory/storage-safety/StorageSafetyTables.tsx
// MES-3a(2026-10-06,MES-3a Step 0 Q1 · Q13 · Q15 · Q20):/inventory/storage-safety 的三张表。
//   ① 上限:今天在效执照下每一类 NEA 废物的存量对着上限(超了整行琥珀;上限没给照直说"没给",不说"没超")。
//   ② 滞留:还在厂里的批身上每一条开着的安全状态,记下几天、提醒天数(没给 → "not yet set",V3);过了整行琥珀。
//   ③ 隔离:身上开着要隔离的状态、却还有货放在非隔离库位的批(Q20:记录不拒,在这里说出来)。
//   行都由服务端组好(page.tsx),这里只排版。手机上留身份与那一格判词(TABLE-STYLE-1)。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type CeilingRow = { key: string; category: string; onHand: string; limit: string; status: string; statusText: string; batches: string }
export type DwellRow = { key: string; href: string; batch: string; state: string; recorded: string; days: string; period: string; past: boolean; status: string }
export type ExposureRow = { key: string; href: string; batch: string; state: string; location: string; qty: string; recorded: string }

export function CeilingTable({ rows, empty }: { rows: CeilingRow[]; empty: string }) {
    const t = useTranslations()
    const columns: Column<CeilingRow>[] = [
        { key: 'category', header: t('storageSafety.page.colCategory'), priority: true, render: (r) => r.category },
        { key: 'onHand', header: t('storageSafety.page.colOnHand'), align: 'right', render: (r) => r.onHand },
        { key: 'limit', header: t('storageSafety.page.colLimit'), align: 'right', render: (r) => r.limit },
        { key: 'batches', header: t('storageSafety.page.colBatches'), align: 'right', render: (r) => r.batches },
        {
            key: 'status', header: t('storageSafety.page.colStatus'), priority: true,
            render: (r) => <span data-ceiling-status={r.status}>{r.statusText}</span>,
        },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={empty}
                      rowClassName={(r) => (r.status === 'exceeded' ? 'bg-amber-50' : undefined)} />
}

export function DwellTable({ rows, empty }: { rows: DwellRow[]; empty: string }) {
    const t = useTranslations()
    const columns: Column<DwellRow>[] = [
        { key: 'batch', header: t('storageSafety.page.colBatch'), priority: true, render: (r) => <Link href={r.href} className="underline">{r.batch}</Link> },
        { key: 'state', header: t('storageSafety.page.colState'), priority: true, render: (r) => r.state },
        { key: 'recorded', header: t('storageSafety.page.colRecorded'), render: (r) => r.recorded },
        { key: 'days', header: t('storageSafety.page.colDays'), align: 'right', render: (r) => <span data-dwell-status={r.status}>{r.days}</span> },
        { key: 'period', header: t('storageSafety.page.colPeriod'), render: (r) => r.period },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={empty}
                      rowClassName={(r) => (r.past ? 'bg-amber-50' : undefined)} />
}

export function ExposureTable({ rows, empty }: { rows: ExposureRow[]; empty: string }) {
    const t = useTranslations()
    const columns: Column<ExposureRow>[] = [
        { key: 'batch', header: t('storageSafety.page.colBatch'), priority: true, render: (r) => <Link href={r.href} className="underline">{r.batch}</Link> },
        { key: 'state', header: t('storageSafety.page.colState'), render: (r) => r.state },
        { key: 'location', header: t('storageSafety.page.colLocation'), priority: true, render: (r) => r.location },
        { key: 'qty', header: t('storageSafety.page.colQty'), align: 'right', render: (r) => r.qty },
        { key: 'recorded', header: t('storageSafety.page.colRecorded'), render: (r) => r.recorded },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={empty}
                      rowClassName={() => 'bg-amber-50'} />
}
