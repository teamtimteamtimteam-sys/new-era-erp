// TABLE-EXPORT-2b-2:流水 → 表的行,页面与导出路由共用这一份映射(列只有表上那一份定义)。
import { flatten, type LedgerRow } from './ledgerQuery'
import { statusKey } from '../snapshot/snapshotQuery'
import type { LedgerTableRow } from './LedgerTable'

export function shapeLedgerRows(rows: LedgerRow[], t: (k: string) => string): LedgerTableRow[] {
    return rows.map((r) => {
        const f = flatten(r)
        return {
            id: r.id,
            date: f.date,
            batch: f.batch,
            material: f.material,
            location: f.location,
            hasLocation: Boolean(f.location),
            type: f.type,
            status: t(statusKey(f.status)),
            qty: String(f.qty),
            qtyDelta: f.qty,
        }
    })
}
