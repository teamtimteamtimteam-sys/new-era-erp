// app/operation/contamination/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q21–Q25,Tim)· 交叉污染抽检
// ════════════════════════════════════════════════════════════════════════════
// 【这一页是什么】每一个(加工日, 班次, 流)一行:那一天那一班有一张 MES-4a 起记的单产出了这条流的极片 —— 抽过没有、
//   最高的污染率对着警戒线(V11)。下面是最近的抽检逐次。【只读】—— 抽检记在那一炉的加工单页上(action.processing_aftercare)。
// 【门】requireFunction(FN.contamination) = 加工或产出查看码任一;读的两张视图(contamination_shift_status · contamination_check_rows)
//   是带同一对码的属主视图(只持产出码的人读不到 processing_runs —— 单号由视图借过来,但链接只给进得去加工单页的人)。
// 【与物料平衡无关】污染不改质量,结平不等它(规格 §3.4)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import ContaminationGrid from './ContaminationGrid'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import {
    GRID_SHOWN, RECENT_CHECKS_SHOWN, checksCount, checksPage, gridCount, gridPage, missingCount, shapeGridRows,
    GRID_SORT, CHECKS_SORT, CHECKS_SORT_PREFIX, parseGridSort, parseChecksSort, gridExportHref, checksExportHref,
} from './contaminationRows'
import ContaminationChecksList from './ContaminationChecksList'
import { CHECK_ROW_COLUMNS, labelsFor, toCheckListRows } from './checkRows'

export default async function ContaminationPage({
    searchParams,
}: {
    searchParams: Promise<Record<string, string | string[] | undefined>>
}) {
    const denied = await requireFunction(FN.contamination)
    if (denied) return denied

    // TABLE-FEATURES-1 Q9:两张表各自在数据库里排;第二张带前缀 checks_(contaminationRows.ts)
    const sp = await searchParams
    const gridSort = parseGridSort(sp)
    const checksSort = parseChecksSort(sp)

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    // ★ TABLE-EXPORT-2b-2(Tim TABLE-EXPORT-2 Q2 · 2b Q1 · 2b Q6):两张表的读取与映射搬进 contaminationRows.ts,与导出路由共用;
    //   各画前 N 行(网格 300 格 · 抽检 50 次),而且说出来;「缺几格」是一次 count(exact),不再数截下来的那 300 格。
    const [gridRes, gridTotalRes, missingRes, checkRes, checkTotalRes, streamRes, labels, canOpenRuns] = await Promise.all([
        gridPage(supabase, gridSort, 0, GRID_SHOWN - 1),
        gridCount(supabase),
        missingCount(supabase),
        checksPage(supabase, CHECK_ROW_COLUMNS, checksSort, 0, RECENT_CHECKS_SHOWN - 1),
        checksCount(supabase),
        supabase.from('contamination_streams').select('code, name_en, name_zh, warning_pct').eq('is_active', true).order('sort_order'),
        labelsFor(supabase, locale),
        can('module.processing.view'),
    ])
    const rows = shapeGridRows(mustRows(gridRes, 'contamination_shift_status'), labels, locale, canOpenRuns)
    const gridTotal = mustCount(gridTotalRes, 'contamination_shift_status count')
    const missing = mustCount(missingRes, 'contamination_shift_status missing')
    const checks = toCheckListRows(mustRows(checkRes, 'contamination_check_rows'), labels, locale, canOpenRuns)
    const checkTotal = mustCount(checkTotalRes, 'contamination_check_rows count')
    const streams = mustRows(streamRes, 'contamination_streams')

    return (
        <ListPage
            title={t('contamination.title')}
            intro={t('contamination.intro')}
            maxWidth="max-w-6xl"
            state={{ kind: 'ok' }}
        >
            <p className="text-sm mb-2" data-summary="contamination">
                {streams.map((s) => (
                    <span key={s.code} className="mr-4">
                        {locale === 'zh' ? s.name_zh : s.name_en}: {s.warning_pct === null
                            ? <span className="text-amber-700" data-not-set="warning">{t('contamination.warningNotSet')}</span>
                            : t('contamination.warningAt', { pct: Number(s.warning_pct) })}
                    </span>
                ))}
                <Link href="/settings/dictionaries" className="hover:underline app-link">{t('contamination.setWarning')}</Link>
            </p>
            <p className="text-sm mb-4">{missing === 0 ? t('contamination.noneMissing') : t('contamination.missingCount', { n: missing })}</p>
            <RowCapNotice shown={rows.length} total={gridTotal} />
            <ContaminationGrid rows={rows} exportUrl={gridExportHref(gridSort)}
                sorting={{ mode: 'server', active: gridSort, shown: rows.length, total: gridTotal, sortable: Object.keys(GRID_SORT) }} />
            <h2 className="mt-8 mb-2">{t('contamination.recentTitle')}</h2>
            <RowCapNotice shown={checks.length} total={checkTotal} />
            <ContaminationChecksList rows={checks} emptyKey="contamination.emptyRecent"
                exportSpec={{ name: 'operation-contamination-checks-recent', title: t('contamination.recentTitle'),
                              serverRows: checksExportHref(checksSort) }}
                sorting={{ mode: 'server', active: checksSort, shown: checks.length, total: checkTotal,
                           sortable: Object.keys(CHECKS_SORT), prefix: CHECKS_SORT_PREFIX }} />
        </ListPage>
    )
}
