// RPT-1:快照 PDF。与页面共用 snapshotQuery。
// 【受限的金额印「受限」,不是空格子】理由同 CSV。
import { renderReport, pdfFailed } from '../../pdfShared'
import { getTranslations } from '@/lib/i18n/server'
import { fetchValuation, statusKey } from '../snapshotQuery'

export async function GET() {
    try {
        const t = await getTranslations()
        const v = await fetchValuation()
        const money = (n: number | null) => (n === null ? t('valuation.priceRestricted') : String(n))
        return await renderReport({
            name: 'stock-snapshot',
            titleKey: 'reports.snapshot.title',
            filters: '',
            columns: [
                { header: t('reports.colMaterial'), width: 160 },
                { header: t('reports.colLocation'), width: 140 },
                { header: t('reports.colStatus'), width: 70 },
                { header: t('reports.colQty'), width: 70, align: 'right' },
                { header: t('reports.colValue'), width: 80, align: 'right' },
            ],
            rows: v.rows.map((r) => [
                `${r.material_code} ${r.material_name}`,
                // 【未指定库位在 PDF 里也有名字】,不是一个空格子
                r.location_code ? `${r.location_code} ${r.location_name ?? ''}` : t('reports.unspecifiedLocation'),
                t(statusKey(r.stock_status)),
                `${r.qty} ${r.unit}`,
                money(r.value_base),
            ]),
        })
    } catch (e) {
        return pdfFailed(e)
    }
}
