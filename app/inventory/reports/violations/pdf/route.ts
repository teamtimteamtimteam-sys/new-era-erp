import { renderReport, pdfFailed } from '../../pdfShared'
import { getTranslations } from '@/lib/i18n/server'
import { fetchViolations } from '../violationsQuery'

export async function GET() {
    try {
        const t = await getTranslations()
        const { violations, unconfigured, unclassified } = await fetchViolations()
        return await renderReport({
            name: 'class-violations',
            titleKey: 'reports.violations.title',
            filters: t('reports.violations.count', { n: String(violations.length) }),
            columns: [
                { header: t('reports.colSection'), width: 150 },
                { header: t('reports.colLocation'), width: 150 },
                { header: t('reports.colMaterial'), width: 180 },
                { header: t('reports.colClass'), width: 110 },
                { header: t('reports.colQty'), width: 80, align: 'right' },
            ],
            rows: [
                ...violations.map((v) => [t('reports.violations.sectionViolations'), v.location_code, v.material_code, v.class_code, String(v.qty)]),
                ...unconfigured.map((r) => [t('reports.violations.sectionUnconfigured'), r.code, r.other, '', `${r.qty} ${r.unit}`]),
                ...unclassified.map((r) => [t('reports.violations.sectionUnclassified'), r.other, r.code, '', `${r.qty} ${r.unit}`]),
            ],
        })
    } catch (e) { return pdfFailed(e) }
}
