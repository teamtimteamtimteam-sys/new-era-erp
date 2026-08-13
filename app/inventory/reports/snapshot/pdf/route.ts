import { renderReport, pdfFailed } from '../../pdfShared'
import { getTranslations } from '@/lib/i18n/server'
import { fetchSnapshot, statusKey } from '../snapshotQuery'

export async function GET() {
    try {
        const t = await getTranslations()
        const rows = await fetchSnapshot()
        return await renderReport({
            name: 'stock-snapshot',
            titleKey: 'reports.snapshot.title',
            filters: '',
            columns: [
                { header: t('reports.colMaterial'), width: 200 },
                { header: t('reports.colLocation'), width: 180 },
                { header: t('reports.colStatus'), width: 90 },
                { header: t('reports.colQty'), width: 90, align: 'right' },
            ],
            rows: rows.map((r) => [
                `${r.material_code} ${r.material_name}`,
                // 【未指定库位在 PDF 里也有名字】,不是一个空格子
                r.location_code ? `${r.location_code} ${r.location_name ?? ''}` : t('reports.unspecifiedLocation'),
                t(statusKey(r.stock_status)),
                `${r.qty} ${r.unit}`,
            ]),
        })
    } catch (e) {
        return pdfFailed(e)
    }
}
