import { renderReport, pdfFailed } from '../../pdfShared'
import { getTranslations } from '@/lib/i18n/server'
import { fetchSafety } from '../safetyQuery'

export async function GET() {
    try {
        const t = await getTranslations()
        const { rows, monitored, below } = await fetchSafety()
        return await renderReport({
            name: 'safety-stock',
            titleKey: 'reports.safety.title',
            filters: monitored === 0
                ? t('reports.safety.noneMonitored')
                : t('reports.safety.someBelow', { below: String(below), n: String(monitored) }),
            columns: [
                { header: t('reports.colMaterial'), width: 260 },
                { header: t('reports.colAvailable'), width: 110, align: 'right' },
                { header: t('reports.colThreshold'), width: 110, align: 'right' },
                { header: t('reports.colShortfall'), width: 110, align: 'right' },
            ],
            rows: rows.map((r) => {
                const short = (r.safety_stock_qty ?? 0) - r.available_qty
                return [`${r.code} ${r.name}`, `${r.available_qty} ${r.unit}`,
                        `${r.safety_stock_qty} ${r.unit}`, short > 0 ? `${short} ${r.unit}` : '—']
            }),
        })
    } catch (e) { return pdfFailed(e) }
}
