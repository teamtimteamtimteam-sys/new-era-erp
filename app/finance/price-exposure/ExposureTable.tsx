'use client'

// MES-8b-1:每一个可计价金属一行 —— 状态、批数、料的 kg、金属的 kg、价(美元 / 吨)与它的日子、值(美元)、价比含量还旧的批数、对它「not measured」的 kg。
//   没有价 / 同一天几条价的那一行,值那一格说出原因,不写 0。
import { formatMoneyBare } from '@/lib/format'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xDate, xInt, xNum, xText } from '@/lib/export/cells'

export type ExposureLine = {
    metal: string; state: 'priced' | 'no_price' | 'price_ambiguous'; price_date: string | null; price_usd_per_tonne: number | null
    price_index: string | null; prices_on_that_date: number; batches: number; material_kg: number; metal_kg: number
    value_usd: number | null; price_older_than_content: number; not_measured_kg: number
}

const kg = (n: number) => new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 }).format(Number(n))
// 两位小数 + 千分位,不带币种 —— 列头写着 USD(金属价按市场惯例以美元报)
const usd = (n: number) => formatMoneyBare(Number(n), 'the column header names USD')

export default function ExposureTable({ lines }: { lines: ExposureLine[] }) {
    const t = useTranslations()
    const state: Record<ExposureLine['state'], string> = {
        priced: t('inventoryExposure.priced'), no_price: t('inventoryExposure.noPrice'), price_ambiguous: t('inventoryExposure.priceAmbiguous'),
    }
    // TABLE-EXPORT-3a(Tim 2026-10-23,Q7 的报表体之一):照屏幕导出。列头已写着 USD 与 kg,格子是光秃秃的数;
    //   没有价 / 同一天几条价的那一行,值那一格与屏幕一样写原因(一句话,不是 0)。整节仍由 FN.margin 把门(InventoryExposureSection)。
    const cols: ExportableColumn<ExposureLine>[] = [
        { key: 'metal', header: t('inventoryExposure.colMetal'), priority: true, render: (r) => r.metal.toUpperCase(), exportAs: (r) => xText(r.metal.toUpperCase()) },
        { key: 'kg', header: t('inventoryExposure.colMaterialKg'), align: 'right', render: (r) => kg(r.material_kg), exportAs: (r) => xNum(r.material_kg) },
        { key: 'metalKg', header: t('inventoryExposure.colMetalKg'), align: 'right', priority: true, render: (r) => kg(r.metal_kg), exportAs: (r) => xNum(r.metal_kg) },
        { key: 'price', header: t('inventoryExposure.colPrice'), align: 'right',
          render: (r) => (r.state === 'priced' && r.price_usd_per_tonne !== null ? usd(r.price_usd_per_tonne) : '—'),
          exportAs: (r) => (r.state === 'priced' && r.price_usd_per_tonne !== null ? xNum(r.price_usd_per_tonne, 'money') : xText('—')) },
        { key: 'date', header: t('inventoryExposure.colPriceDate'), render: (r) => r.price_date ?? '—', exportAs: (r) => (r.price_date ? xDate(r.price_date) : xText('—')) },
        { key: 'value', header: t('inventoryExposure.colValue'), align: 'right', priority: true,
          render: (r) => <span data-value={`exposure-${r.metal}-${r.state}`}>{r.state === 'priced' && r.value_usd !== null ? usd(r.value_usd) : state[r.state]}</span>,
          exportAs: (r) => (r.state === 'priced' && r.value_usd !== null ? xNum(r.value_usd, 'money') : xText(state[r.state])) },
        { key: 'older', header: t('inventoryExposure.colOlder'), align: 'right', render: (r) => String(r.price_older_than_content), exportAs: (r) => xInt(r.price_older_than_content) },
        { key: 'nm', header: t('inventoryExposure.colNotMeasured'), align: 'right', render: (r) => kg(r.not_measured_kg), exportAs: (r) => xNum(r.not_measured_kg) },
    ]
    return <DataTable rows={lines} columns={cols} rowKey={(r) => r.metal} phone={{ mode: 'columns' }} empty={t('inventoryExposure.noMetals')}
        exportSpec={{ name: 'finance-inventory-metal-exposure', title: t('inventoryExposure.title') }} />
}
