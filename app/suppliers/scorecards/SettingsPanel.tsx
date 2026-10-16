'use client'

// MES-8a(2026-10-16,MES-0 §5.1 V23 · V24 · Q93;MES-8 Step 0 Q4 · Q5,Tim):评分的设定 —— V23(每一项计分的权重、等级线、评审周期)与
//   V24(每一个等级的预付上限 % 与抽样级别)。【空着就是 Not yet set】—— 表单不预填任何一个数(Q4:什么都不猜)。
//   权重与等级线同进同出(只给一半没法评级,库按名拒);等级线按分从小到大,最后一条没有上限(它接住比所有线都高的分)。
//   存的是整份(库里 set_supplier_score_settings 整行替换);改它不改写任何一次过去的评审(每一次评审都抄走了它当时的那一份)。
//   缺 action.supplier_review 时整张表单在 PermissionGate 里。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { saveScoreSettings } from '../scorecardActions'
import { SCORED_MEASURES, type ScoreSettings, type ScoredMeasure } from '../scorecardTypes'

type LineIn = { grade: string; max: string; cap: string; sampling: string }
const s = (v: number | null | undefined) => (v == null ? '' : String(v))

export default function SettingsPanel({ settings, canEdit }: { settings: ScoreSettings; canEdit: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [saved, setSaved] = useState(false)
    const [weights, setWeights] = useState<Record<ScoredMeasure, string>>(
        Object.fromEntries(SCORED_MEASURES.map((k) => [k, s(settings.weights?.[k])])) as Record<ScoredMeasure, string>)
    const [lines, setLines] = useState<LineIn[]>((settings.grade_lines ?? []).map((l) => ({
        grade: l.grade, max: s(l.max_score),
        cap: s(settings.grade_caps?.[l.grade]?.prepayment_cap_pct), sampling: settings.grade_caps?.[l.grade]?.sampling_level ?? '' })))
    const [windowDays, setWindowDays] = useState(s(settings.review_window_days))

    const num = (v: string) => (v.trim() === '' ? null : Number(v))
    const weightsGiven = SCORED_MEASURES.some((k) => weights[k].trim() !== '')
    function save() {
        setError(''); setSaved(false)
        const payload: ScoreSettings = {
            weights: weightsGiven ? Object.fromEntries(SCORED_MEASURES.map((k) => [k, num(weights[k]) as number])) as Record<ScoredMeasure, number> : null,
            grade_lines: lines.length ? lines.map((l, i) => ({ grade: l.grade.trim(), max_score: i === lines.length - 1 ? null : num(l.max) })) : null,
            review_window_days: windowDays.trim() === '' ? null : Number(windowDays),
            grade_caps: lines.some((l) => l.cap.trim() !== '' || l.sampling.trim() !== '')
                ? Object.fromEntries(lines.filter((l) => l.grade.trim() !== '').map((l) => [l.grade.trim(),
                    { prepayment_cap_pct: num(l.cap), sampling_level: l.sampling.trim() === '' ? null : l.sampling.trim() }]))
                : null,
        }
        startTransition(async () => {
            const res = await saveScoreSettings(payload)
            if (res.error) { setError(res.error); return }
            setSaved(true)
            router.refresh()
        })
    }
    const setLine = (i: number, patch: Partial<LineIn>) => { setSaved(false); setLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...patch } : l))) }

    return (
        <PermissionGate code="action.supplier_review" allowed={canEdit}>
            <div className="space-y-4 max-w-3xl" data-form="score-settings">
                {error && <p className="text-sm text-red-600" data-error="score-settings">{error}</p>}
                {saved && <p className="text-sm text-green-700" data-saved="score-settings">{t('scorecards.settings.saved')}</p>}
                <fieldset className="border border-gray-300 rounded px-3 py-2 text-sm space-y-2" data-section="weights">
                    <legend className="px-1">{t('scorecards.settings.weights')}</legend>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('scorecards.settings.weightsHint')}</p>
                    <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                        {SCORED_MEASURES.map((k) => (
                            <label key={k} className="flex flex-wrap items-center gap-2 min-w-0">
                                <span className="min-w-0 flex-1">{t('scorecards.measure.' + k)}</span>
                                <input type="text" inputMode="decimal" value={weights[k]} className={`${CONTROL_INPUT} w-24`} data-field={`weight-${k}`}
                                       onChange={(e) => { setSaved(false); setWeights((w) => ({ ...w, [k]: e.target.value })) }} />
                            </label>
                        ))}
                    </div>
                </fieldset>
                <fieldset className="border border-gray-300 rounded px-3 py-2 text-sm space-y-2" data-section="grade-lines">
                    <legend className="px-1">{t('scorecards.settings.gradeLines')}</legend>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('scorecards.settings.gradeLinesHint')}</p>
                    {lines.map((l, i) => (
                        <div key={i} className="flex flex-wrap items-end gap-2 border-t border-gray-100 pt-2" data-grade-line={i + 1}>
                            <label className="block min-w-0">
                                <span className="block text-xs">{t('scorecards.settings.grade')}</span>
                                <input type="text" value={l.grade} onChange={(e) => setLine(i, { grade: e.target.value })} className={`${CONTROL_INPUT} w-24`} />
                            </label>
                            <label className="block min-w-0">
                                <span className="block text-xs">{t('scorecards.settings.maxScore')}</span>
                                {i === lines.length - 1
                                    ? <span className="block py-1 text-xs text-[color:var(--brand-muted-text)]">{t('scorecards.settings.lastLineOpen')}</span>
                                    : <input type="text" inputMode="decimal" value={l.max} onChange={(e) => setLine(i, { max: e.target.value })} className={`${CONTROL_INPUT} w-24`} />}
                            </label>
                            <label className="block min-w-0">
                                <span className="block text-xs">{t('scorecards.settings.capPct')}</span>
                                <input type="text" inputMode="decimal" value={l.cap} onChange={(e) => setLine(i, { cap: e.target.value })} className={`${CONTROL_INPUT} w-24`} />
                            </label>
                            <label className="block min-w-0 flex-1">
                                <span className="block text-xs">{t('scorecards.settings.samplingLevel')}</span>
                                <input type="text" value={l.sampling} onChange={(e) => setLine(i, { sampling: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                            </label>
                            <Button type="button" variant="ghost" onClick={() => { setSaved(false); setLines((ls) => ls.filter((_, j) => j !== i)) }}>{t('scorecards.settings.removeLine')}</Button>
                        </div>
                    ))}
                    <Button type="button" variant="secondary" onClick={() => { setSaved(false); setLines((ls) => [...ls, { grade: '', max: '', cap: '', sampling: '' }]) }}>
                        {t('scorecards.settings.addLine')}
                    </Button>
                </fieldset>
                <label className="block text-sm">
                    <span className="block mb-1">{t('scorecards.settings.windowDays')}</span>
                    <input type="text" inputMode="numeric" value={windowDays} onChange={(e) => { setSaved(false); setWindowDays(e.target.value) }} className={`${CONTROL_INPUT} w-24`} data-field="review_window_days" />
                    <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('scorecards.settings.windowDaysHint')}</span>
                </label>
                <Button type="button" disabled={isPending} onClick={save}>{isPending ? t('common.saving') : t('scorecards.settings.save')}</Button>
            </div>
        </PermissionGate>
    )
}
