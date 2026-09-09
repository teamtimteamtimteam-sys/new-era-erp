'use client'

// 评级 + 书面结论。两者都要:只有档位的评估没法向员工交代,只有文字的没法横向看。
// 档位目录人人可读(HR-3d 的策略),但【谁能写】仍由 set_review_conclusion 把关。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useLocale, useTranslations } from '@/lib/i18n/client'
import { setConclusion } from './actions'
import { Button } from '@/app/components/ui/button'

export type RatingOption = {
    code: string
    name_en: string
    name_zh: string
    is_active: boolean
}

type Props = {
    reviewId: string
    ratings: RatingOption[]
    ratingCode: string | null
    summaryText: string | null
    /**
     * ★ ALERT-2d:这个 prop 现在【只装记录状态】,不装权限。
     * 改之前 /hr/reviews/[id] 传的是 `canWrite && (status==='draft'||status==='self_review')`
     * —— 为假有两个不同的原因,而屏幕上一句都不说。权限那一半移到页面上的
     * `<PermissionGate>`(看得见、按不动、点名权限码 + 另一条路)。
     */
    editable: boolean
    /** 记录状态那一半的一句话:这份考核现在是什么状态、于是结论改不动。 */
    stateNote?: string | null
}

export default function ConclusionForm({ reviewId, ratings, ratingCode, summaryText, editable, stateNote }: Props) {
    const t = useTranslations()
    const locale = useLocale()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [rating, setRating] = useState(ratingCode ?? '')
    const [summary, setSummary] = useState(summaryText ?? '')

    const ratingName = (code: string | null) => {
        if (!code) return '—'
        const r = ratings.find((x) => x.code === code)
        return r ? (locale === 'zh' ? r.name_zh : r.name_en) : code
    }

    if (!editable) {
        return (
            <div className="mb-6">
                <div className="text-sm mb-2">
                    <span className="text-gray-600 mr-1">{t('reviews.rating')}:</span>
                    <span className="font-medium">{ratingName(ratingCode)}</span>
                </div>
                <div className="text-sm">
                    <span className="text-gray-600 mr-1">{t('reviews.summary')}:</span>
                    <span className="whitespace-pre-wrap">{summaryText ?? '—'}</span>
                </div>
                {/* ★ ALERT-2d:只读【本身】没有问题,没有解释才有。 */}
                {stateNote && (
                    <p className="mt-2 text-sm text-gray-600" data-state-note="conclusion">{stateNote}</p>
                )}
            </div>
        )
    }

    function save() {
        setError(null)
        startTransition(async () => {
            const r = await setConclusion(reviewId, rating || null, summary || null)
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    return (
        <div className="mb-6 rounded border border-gray-200 p-4">
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <div className="flex gap-3 flex-wrap items-end">
                <label className="text-xs text-gray-600">
                    {t('reviews.rating')}
                    <select
                        value={rating}
                        onChange={(e) => setRating(e.target.value)}
                        className="block border border-gray-300 rounded px-2 py-1 text-sm"
                    >
                        <option value="">—</option>
                        {ratings
                            .filter((r) => r.is_active || r.code === ratingCode)
                            .map((r) => (
                                <option key={r.code} value={r.code}>
                                    {locale === 'zh' ? r.name_zh : r.name_en}
                                </option>
                            ))}
                    </select>
                </label>
                <label className="text-xs text-gray-600 grow min-w-64">
                    {t('reviews.summary')}
                    <textarea
                        value={summary}
                        onChange={(e) => setSummary(e.target.value)}
                        className="block w-full border border-gray-300 rounded px-2 py-1 text-sm min-h-20"
                    />
                </label>
                <Button
                    type="button"
                    onClick={save}
                    disabled={pending}
                >
                    {pending ? t('common.saving') : t('common.save')}
                </Button>
            </div>
        </div>
    )
}
