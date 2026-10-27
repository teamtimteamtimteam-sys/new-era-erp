// app/operation/spare-parts/page.tsx
// SYSTEM-MAP-1(Tim D4,2026-10-27):备件清单 —— 设备底下,只读。一张备件(spare_part)物料的一批进料一行。
//   【源】spare_part_stock:与机器页「出备件」那张表单读的是同一张视图,判据与 issue_spare_parts 逐字同源(可用数量、有没有价、在不在暂扣)。
//     它【不带钱】—— "已定价"是一个布尔,不是价格(那张视图抬头写着为什么)。所以这一页没有要遮的值。
//   【门】requireFunction(FN.spareParts) = module.inventory.view,与视图体里那句 has_permission 同一个码。
//   【去处】批次 → 那一批的页面;出备件在那台机器的设备页上做(这里不出)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { formatDate } from '@/lib/dates'
import SparePartsTable, { type SparePartRow } from './SparePartsTable'

type Row = {
    inbound_batch_id: string; batch_code: string; material_id: string; material_code: string; material_name: string; unit: string
    available_qty: number | string; remaining_qty: number | string | null; priced: boolean; hold_ncr_code: string | null; arrival_date: string | null
}

export default async function SparePartsPage() {
    const denied = await requireFunction(FN.spareParts)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const stock = mustRows(await supabase.from('spare_part_stock')
        .select('inbound_batch_id, batch_code, material_id, material_code, material_name, unit, available_qty, remaining_qty, priced, hold_ncr_code, arrival_date')
        .order('material_code', { ascending: true }).order('batch_code', { ascending: true }), 'spare_part_stock') as Row[]

    const rows: SparePartRow[] = stock.map((r) => ({
        batchId: r.inbound_batch_id,
        batchCode: r.batch_code,
        part: `${r.material_code} — ${r.material_name}`,
        unit: r.unit,
        available: Number(r.available_qty),
        remaining: r.remaining_qty === null ? null : Number(r.remaining_qty),
        priced: r.priced,
        hold: r.hold_ncr_code,
        arrival: r.arrival_date ? formatDate(r.arrival_date, locale) : '—',
        arrivalRaw: r.arrival_date,
    }))

    return (
        <ListPage title={t('spareParts.title')} intro={t('spareParts.intro')} state={{ kind: 'ok' }}>
            <SparePartsTable rows={rows} empty={t('spareParts.empty')} />
        </ListPage>
    )
}
