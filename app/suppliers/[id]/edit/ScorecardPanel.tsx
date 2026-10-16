// MES-8a(2026-10-16,MES-0 Q77 · Q78 · Q91;MES-8 Step 0 Q2–Q6,Tim):供应商页上的「评分卡」一块 —— 最近一次没被取代的评审(等级、窗口、
//   那一次抄下的预付上限与抽样级别)、每一次评审的历史(抄下的计数、更正与被更正),以及记一次评审的表单。
//   读 module.suppliers.view(页面的门本来就是它,Q91);记评审 action.supplier_review(cco · admin)—— 表单看得见、按不动、说出码。
//   ★ 等级只是建议:采购单上显示、预付超过上限时警告,从不拒绝(Q5)。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { getLocale } from '@/lib/i18n/server'
import ReviewForm from './ReviewForm'
import MeasuresTable from '../../MeasuresTable'
import type { ReviewRow } from '../../scorecardTypes'

export default async function ScorecardPanel({ supplierId }: { supplierId: string }) {
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const reviews = mustRows(
        await supabase.from('supplier_scorecard_reviews')
            .select('id, seq, window_from, window_to, measures, weights, grade_lines, grade_caps, score, grade, not_graded_reason, note, corrects_review_id, correction_reason, recorded_at')
            .eq('supplier_id', supplierId).order('seq', { ascending: false }),
        'supplier_scorecard_reviews') as unknown as ReviewRow[]
    const canReview = await can('action.supplier_review')
    const correctedBy = new Map(reviews.filter((r) => r.corrects_review_id).map((r) => [r.corrects_review_id as string, r]))
    const latest = reviews.find((r) => !correctedBy.has(r.id)) ?? null
    const label = (r: ReviewRow) => t('scorecards.reviewLabel', {
        from: formatDate(r.window_from, locale), to: formatDate(r.window_to, locale), at: formatAuditStamp(r.recorded_at) })
    const cap = latest?.grade ? latest.grade_caps?.[latest.grade] ?? null : null

    return (
        <section className="mb-8" data-section="supplier-scorecard">
            <h2 className="mb-1">{t('scorecards.panelTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3 max-w-3xl">
                {t('scorecards.panelWhat')}{' '}
                <Link href="/suppliers/scorecards" className="app-link hover:underline">{t('scorecards.allScorecards')}</Link>
            </p>
            <div className="text-sm mb-4" data-value="latest-review">
                {!latest ? <p>{t('scorecards.notReviewed')}</p> : (
                    <>
                        <p className="font-medium">
                            {latest.grade ? t('scorecards.gradeLine', { grade: latest.grade, score: String(latest.score) }) : t('scorecards.notGraded')}
                        </p>
                        <p className="text-xs text-[color:var(--brand-muted-text)]">{label(latest)}</p>
                        {latest.grade && (
                            <p className="text-xs" data-value="grade-advice">
                                {t('scorecards.adviceLine', {
                                    cap: cap?.prepayment_cap_pct != null ? `${cap.prepayment_cap_pct}%` : t('scorecards.notSet'),
                                    sampling: cap?.sampling_level ?? t('scorecards.notSet') })}
                            </p>
                        )}
                    </>
                )}
            </div>

            <ReviewForm supplierId={supplierId} canReview={canReview}
                correctable={reviews.filter((r) => !correctedBy.has(r.id)).map((r) => ({ id: r.id, label: label(r) }))} />

            {reviews.length > 0 && (
                <div className="mt-6 space-y-3" data-section="review-history">
                    <h3 className="text-sm font-medium">{t('scorecards.history')}</h3>
                    {reviews.map((r) => {
                        const by = correctedBy.get(r.id)
                        const fixes = r.corrects_review_id ? reviews.find((x) => x.id === r.corrects_review_id) : null
                        return (
                            <details key={r.id} className="border border-gray-200 rounded px-3 py-2" data-review={r.id}>
                                <summary className="cursor-pointer text-sm">
                                    <span className="font-medium">{r.grade ?? t('scorecards.notGradedShort')}</span>
                                    {' · '}{label(r)}
                                    {by && <span className="ml-2 text-xs text-amber-800" data-flag="superseded">{t('scorecards.supersededBy', { label: label(by) })}</span>}
                                </summary>
                                <div className="mt-2 space-y-2 text-sm">
                                    {fixes && <p className="text-xs">{t('scorecards.correctsLine', { label: label(fixes), reason: r.correction_reason ?? '' })}</p>}
                                    {r.note && <p className="text-xs whitespace-pre-wrap">{r.note}</p>}
                                    <MeasuresTable measures={r.measures} weights={r.weights} />
                                </div>
                            </details>
                        )
                    })}
                </div>
            )}
        </section>
    )
}
