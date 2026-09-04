// RPT-1:流水台账(带过滤)。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ state 恒为 'ok' —— 日期/物料/批次筛选表单与那句 windowNote(「默认 90 天,
//   而且说出来」)都必须无条件出现。一个筛空了就把筛选栏藏起来的页面,
//   会让人再也筛不回来;而一句只在有行时才出现的"本表默认只看 90 天",
//   正好在最需要它的时候(一行都没有)消失。见 docs/list-page-template.md §⑩-3。
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { fetchLedger, parseLedgerParams, flatten } from './ledgerQuery'
import { statusKey } from '../snapshot/snapshotQuery'
import { ListPage } from '@/app/components/ui/list-page'
import LedgerTable, { type LedgerTableRow } from './LedgerTable'

export default async function LedgerPage({
    searchParams,
}: {
    searchParams: Promise<Record<string, string | undefined>>
}) {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const t = await getTranslations()
    const sp = await searchParams
    const params = parseLedgerParams(sp)
    const rows = await fetchLedger(params)
    // 【CSV / PDF 必须与屏幕上看到的是同一份】—— movement 也要带上,
    //  否则导出的是一整张流水,而人以为导的是他正在看的那一条。
    const qs = new URLSearchParams(
        Object.entries({
            from: params.from, to: params.to, material_id: params.materialId,
            batch: params.batchCode, movement: params.movementId,
        }).filter(([, v]) => v) as [string, string][]
    ).toString()

    const tableRows: LedgerTableRow[] = rows.map((r) => {
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
        }
    })

    return (
        <ListPage
            title={t('reports.ledger.title')}
            intro={t('reports.ledger.desc')}
            actions={
                <div className="flex gap-2 shrink-0">
                    <a href={`/inventory/reports/ledger/export?${qs}`}
                       className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.csv')}</a>
                    <a href={`/inventory/reports/ledger/pdf?${qs}`} target="_blank" rel="noopener noreferrer"
                       className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.pdf')}</a>
                </div>
            }
            state={{ kind: 'ok' }}
            notices={
                /* ★【一个【看不见的】筛选必须自己说话,并且给得出退路】★
                   movement 不在下面那张表单里(它不是一个人会手打的东西),
                   所以没有这一句,人只会看到一张【只有一行】的流水台账,
                   而那与"这段时间只发生了一件事"长得一模一样。
                   旁边那条链接是【清除它】的唯一办法 —— 一个清不掉的筛选是个陷阱。 */
                params.movementId ? (
                    <p
                        data-ledger-filter="movement"
                        className="text-sm text-gray-700 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-4 max-w-3xl"
                    >
                        {t('reports.ledger.movementFilter')}{' '}
                        <a href="/inventory/reports/ledger" className="text-blue-600 hover:underline">
                            {t('reports.ledger.movementFilterClear')}
                        </a>
                    </p>
                ) : null
            }
        >
            {/* 【默认 90 天,而且说出来】—— 一个默认过滤了却不说的报表,
                会让人以为"就这么多流水"。 */}
            <form method="get" className="flex flex-wrap items-end gap-3 my-4">
                <div>
                    <label className="block text-xs text-gray-600 mb-1">{t('reports.ledger.from')}</label>
                    <input type="date" name="from" defaultValue={params.from}
                           className="border border-gray-300 px-2 py-1 rounded text-sm" />
                </div>
                <div>
                    <label className="block text-xs text-gray-600 mb-1">{t('reports.ledger.to')}</label>
                    <input type="date" name="to" defaultValue={params.to}
                           className="border border-gray-300 px-2 py-1 rounded text-sm" />
                </div>
                <div>
                    <label className="block text-xs text-gray-600 mb-1">{t('reports.ledger.material')}</label>
                    <input type="text" name="material_id" defaultValue={params.materialId}
                           placeholder="MAT-…" className="border border-gray-300 px-2 py-1 rounded text-sm w-36" />
                </div>
                <div>
                    <label className="block text-xs text-gray-600 mb-1">{t('reports.ledger.batch')}</label>
                    <input type="text" name="batch" defaultValue={params.batchCode}
                           placeholder="IN-…" className="border border-gray-300 px-2 py-1 rounded text-sm w-36" />
                </div>
                <button type="submit" className="border border-gray-300 px-3 py-1 rounded text-sm hover:bg-gray-50">
                    {t('reports.ledger.apply')}
                </button>
            </form>
            <p className="text-xs text-gray-500 mb-4">{t('reports.ledger.windowNote')}</p>

            <LedgerTable rows={tableRows} empty={t('reports.ledger.empty')} />
        </ListPage>
    )
}
