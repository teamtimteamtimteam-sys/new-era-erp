// RPT-1:流水台账(带过滤)。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ state 恒为 'ok' —— 日期/物料/批次筛选表单与那句 windowNote(「默认 90 天,
//   而且说出来」)都必须无条件出现。一个筛空了就把筛选栏藏起来的页面,
//   会让人再也筛不回来;而一句只在有行时才出现的"本表默认只看 90 天",
//   正好在最需要它的时候(一行都没有)消失。见 docs/list-page-template.md §⑩-3。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { createClient } from '@/lib/supabase/server'
import { fetchLedger, ledgerCount, parseLedgerParams } from './ledgerQuery'
import { shapeLedgerRows } from './ledgerRows'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { ListPage } from '@/app/components/ui/list-page'
import LedgerTable from './LedgerTable'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { setSortParams } from '@/lib/listSort'

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
    // ★ TABLE-EXPORT-2b-2(Tim Q2):只画最新 LEDGER_SHOWN(1,000)条,而且说出来;物料 / 批次筛选在库里、截断之前跑(见 ledgerQuery.ts)
    const [rows, total] = await Promise.all([fetchLedger(params), ledgerCount(await createClient(), params)])
    // 【PDF 必须与屏幕上看到的是同一份】—— movement 也要带上,
    //  否则导出的是一整张流水,而人以为导的是他正在看的那一条。
    //  (TABLE-EXPORT-1:CSV 那条路由删了 —— Excel / CSV 由表上的统一导出从表手里那一份写,天然是同一份。)
    //  TABLE-FEATURES-1 Q9:排序也带上 —— PDF 与导出按屏幕上的同一个次序。
    const qs = setSortParams(new URLSearchParams(
        Object.entries({
            from: params.from, to: params.to, material_id: params.materialId,
            batch: params.batchCode, movement: params.movementId,
        }).filter(([, v]) => v) as [string, string][]
    ), params.sort).toString()

    // TABLE-EXPORT-1:导出的 About 表写【生效的】筛选(含默认 90 天那个起点);指名一条流水时日期窗不生效,
    //   与 describeFilters 同一条判据。
    const exportFilters: Array<[string, string]> = params.movementId
        ? [['movement', params.movementId]]
        : ([
            [t('reports.ledger.from'), params.from], [t('reports.ledger.to'), params.to],
            [t('reports.ledger.material'), params.materialId], [t('reports.ledger.batch'), params.batchCode],
        ] as Array<[string, string]>).filter(([, v]) => v)

    const tableRows = shapeLedgerRows(rows, t)

    return (
        <ListPage
            title={t('reports.ledger.title')}
            intro={t('reports.ledger.desc')}
            actions={
                <div className="flex gap-2">
                    <Button asChild variant="outline">
                        <a href={`/inventory/reports/ledger/pdf?${qs}`} target="_blank" rel="noopener noreferrer">{t('reports.pdf')}</a>
                    </Button>
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
                        className="text-sm text-[color:var(--brand-text)] bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-4 max-w-3xl"
                    >
                        {t('reports.ledger.movementFilter')}{' '}
                        <a href="/inventory/reports/ledger" className="hover:underline app-link app-link-inline">
                            {t('reports.ledger.movementFilterClear')}
                        </a>
                    </p>
                ) : null
            }
        >
            {/* 【默认 90 天,而且说出来】—— 一个默认过滤了却不说的报表,
                会让人以为"就这么多流水"。 */}
            <form method="get" className="flex flex-wrap items-end gap-3 my-4">
                {/* TABLE-FEATURES-1 Q9:换筛选不丢掉选中的排序 */}
                <input type="hidden" name="sort" value={params.sort.key} />
                <input type="hidden" name="dir" value={params.sort.dir} />
                <div>
                    <label className="block mb-1">{t('reports.ledger.from')}</label>
                    <DatePicker name="from" defaultValue={params.from} />
                </div>
                <div>
                    <label className="block mb-1">{t('reports.ledger.to')}</label>
                    <DatePicker name="to" defaultValue={params.to} />
                </div>
                <div>
                    <label className="block mb-1">{t('reports.ledger.material')}</label>
                    <input type="text" name="material_id" defaultValue={params.materialId}
                           placeholder="MAT-…" className={`${CONTROL_INPUT} w-36`} />
                </div>
                <div>
                    <label className="block mb-1">{t('reports.ledger.batch')}</label>
                    <input type="text" name="batch" defaultValue={params.batchCode}
                           placeholder="IN-…" className={`${CONTROL_INPUT} w-36`} />
                </div>
                <Button type="submit" variant="secondary">
                    {t('reports.ledger.apply')}
                </Button>
            </form>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-4">{t('reports.ledger.windowNote')}</p>

            <RowCapNotice shown={tableRows.length} total={total} />
            <LedgerTable rows={tableRows} empty={t('reports.ledger.empty')} filters={exportFilters}
                sort={params.sort} shown={tableRows.length} total={total}
                exportUrl={`/inventory/reports/ledger/export${qs ? `?${qs}` : ''}`} />
        </ListPage>
    )
}
