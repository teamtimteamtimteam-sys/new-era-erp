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
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { formatDate } from '@/lib/dates'
import { ListPage } from '@/app/components/ui/list-page'
import ContaminationGrid, { type GridRow } from './ContaminationGrid'
import ContaminationChecksList from './ContaminationChecksList'
import { CHECK_ROW_COLUMNS, labelsFor, toCheckListRows } from './checkRows'

export default async function ContaminationPage() {
    const denied = await requireFunction(FN.contamination)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [gridRes, checkRes, streamRes, labels, canOpenRuns] = await Promise.all([
        supabase.from('contamination_shift_status')
            .select('process_date, shift_code, stream_code, first_run_id, first_run_code, run_codes, max_rate_pct, any_above_warning, check_state')
            .order('process_date', { ascending: false }).order('shift_code').order('stream_code').limit(300),
        supabase.from('contamination_check_rows').select(CHECK_ROW_COLUMNS).eq('is_current', true).order('id', { ascending: false }).limit(50),
        supabase.from('contamination_streams').select('code, name_en, name_zh, warning_pct').eq('is_active', true).order('sort_order'),
        labelsFor(supabase, locale),
        can('module.processing.view'),
    ])
    const grid = mustRows(gridRes, 'contamination_shift_status') as unknown as {
        process_date: string; shift_code: string; stream_code: string; first_run_id: string; first_run_code: string; run_codes: string[]
        max_rate_pct: number | null; any_above_warning: boolean | null; check_state: string
    }[]
    const rows: GridRow[] = grid.map((g) => ({
        key: `${g.process_date}|${g.shift_code}|${g.stream_code}`,
        date: formatDate(g.process_date, locale), shift: labels.shift(g.shift_code), stream: labels.stream(g.stream_code),
        state: g.check_state === 'checked' ? 'checked' : g.check_state === 'not_sampled' ? 'not_sampled' : 'missing',
        maxRate: g.max_rate_pct === null ? null : Number(g.max_rate_pct), anyAbove: g.any_above_warning,
        runCode: g.first_run_code, runHref: canOpenRuns ? `/operation/processing/${g.first_run_id}` : null,
        runCount: (g.run_codes ?? []).length,
    }))
    const checks = toCheckListRows(mustRows(checkRes, 'contamination_check_rows'), labels, locale, canOpenRuns)
    const streams = mustRows(streamRes, 'contamination_streams')
    const missing = rows.filter((r) => r.state === 'missing').length

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
            <ContaminationGrid rows={rows} />
            <h2 className="mt-8 mb-2">{t('contamination.recentTitle')}</h2>
            <ContaminationChecksList rows={checks} emptyKey="contamination.emptyRecent" />
        </ListPage>
    )
}
