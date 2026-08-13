import type { NextRequest } from 'next/server'
import { renderReport, pdfFailed } from '../../pdfShared'
import { getTranslations } from '@/lib/i18n/server'
import { fetchLedger, parseLedgerParams, describeFilters, flatten } from '../ledgerQuery'
import { statusKey } from '../../snapshot/snapshotQuery'

export async function GET(request: NextRequest) {
    try {
        const t = await getTranslations()
        const params = parseLedgerParams(Object.fromEntries(request.nextUrl.searchParams))
        const rows = await fetchLedger(params)
        return await renderReport({
            name: 'stock-ledger',
            titleKey: 'reports.ledger.title',
            // 【过滤条件印在表头块里】—— 一份不说自己筛过什么的报表会被当成全量
            filters: describeFilters(params),
            columns: [
                { header: t('reports.colDate'), width: 70 },
                { header: t('reports.colBatch'), width: 100 },
                { header: t('reports.colMaterial'), width: 170 },
                { header: t('reports.colLocation'), width: 100 },
                { header: t('reports.colType'), width: 90 },
                { header: t('reports.colStatus'), width: 70 },
                { header: t('reports.colQty'), width: 60, align: 'right' },
            ],
            rows: rows.map((r) => {
                const f = flatten(r)
                return [f.date || '—', f.batch, f.material,
                        f.location || t('reports.unspecifiedLocation'),
                        f.type, t(statusKey(f.status)), String(f.qty)]
            }),
        })
    } catch (e) { return pdfFailed(e) }
}
