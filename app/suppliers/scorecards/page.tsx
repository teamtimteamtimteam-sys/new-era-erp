// app/suppliers/scorecards/page.tsx
// MES-8a(2026-10-16,MES-0 Q77 · Q78 · Q91 · Q93;MES-8 Step 0 Q2–Q6 · Q27,Tim):供应商评分卡 —— 每一家供应商最近一次没被取代的评审
//   (等级 · 窗口 · 评过几次),与评分的设定(V23 权重 · 等级线 · 评审周期;V24 每一等级的预付上限与抽样级别)。记一次评审在那家供应商的页面上。
//   【门】requireFunction(FN.supplierScorecards) = module.suppliers.view;改设定要 action.supplier_review。
//   【这一页不算任何分】等级读 supplier_scorecard_rows(最近一次评审抄下的那一份);计数在供应商页上现算。
//   最底是两条审计记录:所有评审(集合主语 supplier_scorecard_review)与设定(supplier_score_settings)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import ScorecardsTable, { type ScorecardRow } from './ScorecardsTable'
import SettingsPanel from './SettingsPanel'
import type { ScoreSettings } from '../scorecardTypes'

type R = {
    supplier_id: string; supplier_code: string; supplier_name: string; supplier_status: string; review_id: string | null
    window_from: string | null; window_to: string | null; grade: string | null; score: number | null; not_graded_reason: string | null
    recorded_at: string | null; review_count: number
}

export default async function ScorecardsPage({ searchParams }: { searchParams: Promise<{ trail?: string | string[] }> }) {
    const denied = await requireFunction(FN.supplierScorecards)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const sp = await searchParams
    const supabase = await createClient()
    const [rowsRes, setRes, canEdit] = await Promise.all([
        supabase.from('supplier_scorecard_rows')
            .select('supplier_id, supplier_code, supplier_name, supplier_status, review_id, window_from, window_to, grade, score, not_graded_reason, recorded_at, review_count')
            .order('supplier_code'),
        supabase.from('supplier_score_settings').select('weights, grade_lines, review_window_days, grade_caps').limit(1).maybeSingle(),
        can('action.supplier_review'),
    ])
    const list = mustRows(rowsRes, 'supplier_scorecard_rows') as unknown as R[]
    const settings = (mustOne(setRes, 'supplier_score_settings') ?? { weights: null, grade_lines: null, review_window_days: null, grade_caps: null }) as unknown as ScoreSettings
    const v23Set = !!settings.weights && !!settings.grade_lines && settings.review_window_days != null
    const rows: ScorecardRow[] = list.map((r) => ({
        id: r.supplier_id, code: r.supplier_code, name: r.supplier_name, status: t('suppliers.status.' + r.supplier_status),
        grade: !r.review_id ? t('scorecards.notReviewedShort') : r.grade ?? t('scorecards.notGradedShort'),
        graded: !!r.grade,
        window: r.window_from && r.window_to ? `${formatDate(r.window_from, locale)} – ${formatDate(r.window_to, locale)}` : '—',
        recorded: r.recorded_at ? formatAuditStamp(r.recorded_at) : '—',
        reviews: Number(r.review_count),
        windowFrom: r.window_from, windowTo: r.window_to, recordedAt: r.recorded_at,
    }))

    return (
        <ListPage
            title={t('scorecards.title')}
            intro={t('scorecards.intro')}
            state={{ kind: 'ok' }}
            notices={!v23Set ? (
                <div className="bg-amber-50 border border-amber-300 px-4 py-3 rounded mb-4 text-sm" data-notice="v23-not-set">
                    {t('scorecards.v23NotSet')}
                </div>
            ) : null}
        >
            <section data-section="scorecards">
                <ScorecardsTable rows={rows} empty={t('scorecards.noSuppliers')} />
            </section>
            <section className="mt-8" data-section="score-settings">
                <h2 className="mb-1">{t('scorecards.settings.title')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-3 max-w-3xl">{t('scorecards.settings.intro')}</p>
                <SettingsPanel settings={settings} canEdit={canEdit} />
                <AuditTrail subject="supplier_score_settings" id="true" show={trailCount(sp.trail)} />
            </section>
            <section className="mt-8" data-section="reviews-trail">
                <h2 className="mb-1">{t('scorecards.reviewsTrailTitle')}</h2>
                <AuditTrail subject="supplier_scorecard_review" id="all" show={trailCount(sp.trail)} />
            </section>
        </ListPage>
    )
}
