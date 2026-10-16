'use client'

// MES-8a(2026-10-16,MES-8 Step 0 Q5):收货表单(柜台 /inbound/new 与现场 /inbound/receive)上的抽样建议 —— 选了供应商就问库一次。
//   与批次页上的那一块(app/inbound/[id]/edit/SamplingAdvice.tsx)读同一支 supplier_grade_advice、说同一组话。只是建议,不加必须的化验。
import { useEffect, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { samplingAdviceFor } from './samplingAdviceAction'
import type { GradeAdvice } from '@/app/suppliers/scorecardTypes'

export default function SamplingAdviceLive({ supplierId }: { supplierId: string }) {
    const t = useTranslations()
    const [advice, setAdvice] = useState<GradeAdvice | null>(null)
    const [restricted, setRestricted] = useState(false)
    const [error, setError] = useState('')
    useEffect(() => {
        let live = true
        // 没选供应商时什么都不问 —— 下面的渲染在 supplierId 为空时直接返回 null,所以不必在这里清状态
        if (!supplierId) return
        samplingAdviceFor(supplierId).then((res) => {
            if (!live) return
            setError(res.error ?? ''); setRestricted(!!res.restricted); setAdvice(res.advice ?? null)
        })
        return () => { live = false }
    }, [supplierId])
    if (!supplierId) return null
    if (error) return <p className="text-xs text-red-600 mt-1" data-error="sampling-advice">{error}</p>
    if (restricted) return <p className="text-xs text-[color:var(--brand-muted-text)] mt-1" data-section="sampling-advice">{t('scorecards.sampling.label')}: {t('common.restricted')}</p>
    if (!advice) return null
    return (
        <p className="text-xs mt-1" data-section="sampling-advice">
            <span className="font-medium">{t('scorecards.sampling.label')}:</span>{' '}
            {!advice.reviewed ? t('scorecards.sampling.notReviewed')
                : !advice.graded ? t('scorecards.sampling.notGraded')
                : advice.sampling_level ? t('scorecards.sampling.level', { grade: advice.grade ?? '', level: advice.sampling_level })
                : t('scorecards.sampling.levelNotSet', { grade: advice.grade ?? '' })}
            {' '}<span className="text-[color:var(--brand-muted-text)]">{t('scorecards.sampling.adviceOnly')}</span>
        </p>
    )
}
