// RPT-1:快照 PDF。与页面共用 snapshotQuery。
// 【受限的金额印「受限」,不是空格子】理由同 CSV。
//
// ★ IA-BUILD-1(2026-09-02):【没有成本口径的量,不许印成一个有价的 0】★
// 这一张此前只印【金额】,不印 uncosted_qty —— 于是线上六行里的
// ZZ-SMOKE-PROBE 99,970 kg 印成"价值 0.00",读的人会当它是【一堆不值钱的料】,
// 而真相是【这 99,970 kg 从来没有成本口径】;MAT-2026-0001 的产出腿印成
// 253.34,而那 2,528 kg 里有 2,433 kg(96%)根本没分摊过成本 ——
// 那个数字看上去是一个结论,实际上只覆盖了 4% 的量。
// snapshotQuery 早就把话说明白了:"进料侧没有价、产出侧从未分摊,都不是值 0"。
// 页面印了这一列,CSV 印了这一列 —— 【本刀只是把 PDF 补齐到既有的决定上】,
// 不是发明一条新规矩。
//
// 【印法跟【页面】走,不跟 CSV 走】CSV 印裸数字(机器可读,0 就是 0);
// 这一份是给人看的纸,所以 0 印成「—」、非 0 印成「量 + 单位」,
// 与页面上那一格逐字相同 —— 同一件事在屏幕上和纸上不该长成两个样子。
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
                { header: t('reports.colUncostedQty'), width: 90, align: 'right' },
            ],
            rows: v.rows.map((r) => [
                `${r.material_code} ${r.material_name}`,
                // 【未指定库位在 PDF 里也有名字】,不是一个空格子
                r.location_code ? `${r.location_code} ${r.location_name ?? ''}` : t('reports.unspecifiedLocation'),
                t(statusKey(r.stock_status)),
                `${r.qty} ${r.unit}`,
                money(r.value_base),
                // 【0 印「—」,不印 0】—— 与页面同一条:一个 0 在"没有成本口径的量"
                // 这一列里读起来像"全都有价",而「—」读起来就是"这一行没有这回事"。
                r.uncosted_qty !== 0 ? `${r.uncosted_qty} ${r.unit}` : '—',
            ]),
        })
    } catch (e) {
        return pdfFailed(e)
    }
}
