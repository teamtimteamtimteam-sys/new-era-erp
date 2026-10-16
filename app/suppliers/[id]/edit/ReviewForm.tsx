'use client'

// MES-8a(2026-10-16,MES-8 Step 0 Q2 · Q4 · Q6):记一次供应商评审。窗口由评审人输入(必填,不给默认 —— Q4);先"预览"看这一次会抄下什么
//   (计数 · 此刻的权重与等级线 · 由它们算出的等级),再"记下"。预览与记下调的是库里同一支 supplier_scorecard_preview,所以屏幕上看见的
//   就是将要抄进评审的那一份。更正一次评审:选它、写理由(Q2)。缺 action.supplier_review 时整张表单在 PermissionGate 里(看得见、按不动、说出码)。
import { CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import { previewScorecard, recordSupplierReview } from '../../scorecardActions'
import MeasuresTable from '../../MeasuresTable'
import type { ScorecardPreview } from '../../scorecardTypes'

export default function ReviewForm({ supplierId, canReview, correctable }: {
    supplierId: string
    canReview: boolean
    /** 还没被更正过的评审(只有它们可以被更正 —— 一次评审只更正一次) */
    correctable: { id: string; label: string }[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [saved, setSaved] = useState(false)
    const [from, setFrom] = useState('')
    const [to, setTo] = useState('')
    const [fromBad, setFromBad] = useState(false)
    const [toBad, setToBad] = useState(false)
    const [note, setNote] = useState('')
    const [corrects, setCorrects] = useState('')
    const [reason, setReason] = useState('')
    const [preview, setPreview] = useState<ScorecardPreview | null>(null)
    const windowOk = !!from && !!to && !fromBad && !toBad
    const canSave = windowOk && (!corrects || reason.trim() !== '') && !isPending

    function doPreview() {
        setError(''); setSaved(false)
        startTransition(async () => {
            const res = await previewScorecard(supplierId, from, to)
            if (res.error) { setError(res.error); setPreview(null); return }
            setPreview(res.preview ?? null)
        })
    }
    function doSave() {
        setError(''); setSaved(false)
        startTransition(async () => {
            const res = await recordSupplierReview({ supplierId, from, to, note, correctsReviewId: corrects, correctionReason: reason })
            if (res.error) { setError(res.error); return }
            setSaved(true); setPreview(null); setNote(''); setCorrects(''); setReason('')
            router.refresh()
        })
    }

    return (
        <PermissionGate code="action.supplier_review" allowed={canReview}>
            <div className="space-y-3 max-w-3xl" data-form="supplier-review">
                {error && <p className="text-sm text-red-600" data-error="supplier-review">{error}</p>}
                {saved && <p className="text-sm text-green-700" data-saved="supplier-review">{t('scorecards.review.saved')}</p>}
                <div className="flex flex-wrap gap-4">
                    <div className="block text-sm min-w-0">
                        <span className="block mb-1">{t('scorecards.review.windowFrom')} <span className="text-red-600">*</span></span>
                        <DatePicker kind="date" value={from} onChange={(v) => { setFrom(v); setPreview(null) }} onInvalidChange={setFromBad} />
                    </div>
                    <div className="block text-sm min-w-0">
                        <span className="block mb-1">{t('scorecards.review.windowTo')} <span className="text-red-600">*</span></span>
                        <DatePicker kind="date" value={to} onChange={(v) => { setTo(v); setPreview(null) }} onInvalidChange={setToBad} />
                    </div>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('scorecards.review.windowHint')}</p>
                {correctable.length > 0 && (
                    <div className="flex flex-wrap gap-4">
                        <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                            <span className="block mb-1">{t('scorecards.review.corrects')}</span>
                            <select value={corrects} onChange={(e) => setCorrects(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="corrects_review_id">
                                <option value="">{t('scorecards.review.correctsNone')}</option>
                                {correctable.map((r) => <option key={r.id} value={r.id}>{r.label}</option>)}
                            </select>
                        </label>
                        {corrects && (
                            <label className="block text-sm min-w-0 basis-full">
                                <span className="block mb-1">{t('scorecards.review.correctionReason')} <span className="text-red-600">*</span></span>
                                <textarea value={reason} onChange={(e) => setReason(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`} data-field="correction_reason" />
                            </label>
                        )}
                    </div>
                )}
                <label className="block text-sm">
                    <span className="block mb-1">{t('scorecards.review.note')}</span>
                    <textarea value={note} onChange={(e) => setNote(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`} data-field="note" />
                </label>
                <div className="flex flex-wrap gap-3">
                    <Button type="button" variant="secondary" disabled={!windowOk || isPending} onClick={doPreview}>{t('scorecards.review.preview')}</Button>
                    <Button type="button" disabled={!canSave} onClick={doSave}>{isPending ? t('common.saving') : t('scorecards.review.record')}</Button>
                </div>
                {preview && (
                    <div className="border border-gray-300 rounded p-3 space-y-2" data-section="review-preview">
                        <p className="text-sm font-medium" data-value="preview-grade">
                            {preview.grade
                                ? t('scorecards.gradeLine', { grade: preview.grade, score: String(preview.score) })
                                : t('scorecards.notGraded')}
                        </p>
                        <MeasuresTable measures={preview.measures} weights={preview.weights} />
                    </div>
                )}
            </div>
        </PermissionGate>
    )
}
