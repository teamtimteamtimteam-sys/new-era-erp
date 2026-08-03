'use client'

// 补上/更换评估人(set_review_reviewer;module.hr.edit)。
// 评估轮管理页与评估文档页共用 —— 没有评估人的评估不该要人去待办看板里找。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { setReviewer } from './actions'

export type EmployeeOption = { id: string; code: string; legal_name: string }

type Props = {
    reviewId: string
    employees: EmployeeOption[]
    currentReviewerId: string | null
    subjectEmployeeId: string // 自己不能评自己:选项里直接不出现
}

export default function SetReviewerControl({ reviewId, employees, currentReviewerId, subjectEmployeeId }: Props) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [value, setValue] = useState(currentReviewerId ?? '')

    function save() {
        if (!value) return
        setError(null)
        startTransition(async () => {
            const r = await setReviewer(reviewId, value)
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    return (
        <span className="inline-flex items-center gap-2">
            <select
                value={value}
                onChange={(e) => setValue(e.target.value)}
                className="border border-gray-300 rounded px-2 py-1 text-sm"
            >
                <option value="">{t('reviews.pickReviewer')}</option>
                {employees
                    .filter((e) => e.id !== subjectEmployeeId)
                    .map((e) => (
                        <option key={e.id} value={e.id}>
                            {e.code} · {e.legal_name}
                        </option>
                    ))}
            </select>
            <button
                type="button"
                onClick={save}
                disabled={pending || !value || value === currentReviewerId}
                className="text-blue-600 hover:underline text-sm disabled:opacity-50"
            >
                {t('reviews.assign')}
            </button>
            {error && <span className="text-xs text-red-700">{error}</span>}
        </span>
    )
}
