'use client'

// MES-8a(2026-10-16,MES-0 Q77 · MES-8 Step 0 Q5,Tim):采购单表单上的等级建议 —— 两种摆法,同一个来源(adviseSupplierGrade → supplier_grade_advice):
//   'grade'    供应商下拉旁边:这家最近一次没被取代的评审的等级(或"Not reviewed" / "Not graded — V23 not set"),只是建议;
//   'warning'  付款计划下面:"下单时"那几期超过这一等级的预付上限时,一条 PREPAYMENT_ABOVE_GRADE_CAP 警告 —— 【不挡提交】。
//   每次供应商、付款计划或预估总额变了就重新问一次库(不在浏览器里比任何数)。
import { useEffect, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { adviseSupplierGrade, type OrderTermInput } from './actions'
import type { GradeAdvice } from '@/app/suppliers/scorecardTypes'

export default function SupplierGradeAdvice({ mode, supplierId, terms, estimatedTotal }: {
    mode: 'grade' | 'warning'
    supplierId: string
    terms: OrderTermInput[]
    estimatedTotal: number
}) {
    const t = useTranslations()
    const [advice, setAdvice] = useState<GradeAdvice | null>(null)
    const [restricted, setRestricted] = useState(false)
    const [error, setError] = useState('')
    const termsKey = JSON.stringify(terms)
    useEffect(() => {
        let live = true
        // 没选供应商时什么都不问 —— 下面的渲染在 supplierId 为空时直接返回 null,所以不必在这里清状态
        if (!supplierId) return
        const handle = setTimeout(async () => {
            const res = await adviseSupplierGrade({ supplierId, terms: JSON.parse(termsKey) as OrderTermInput[], estimatedTotal })
            if (!live) return
            setError(res.error ?? ''); setRestricted(!!res.restricted); setAdvice(res.advice ?? null)
        }, 300)
        return () => { live = false; clearTimeout(handle) }
    }, [supplierId, termsKey, estimatedTotal])

    if (!supplierId) return null
    if (error) return <p className="text-xs text-red-600 mt-1" data-error="grade-advice">{error}</p>
    if (mode === 'grade') {
        if (restricted) return <p className="text-xs text-[color:var(--brand-muted-text)] mt-1" data-value="supplier-grade">{t('scorecards.po.gradeRestricted')}</p>
        if (!advice) return null
        return (
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1" data-value="supplier-grade">
                {!advice.reviewed ? t('scorecards.po.notReviewed')
                    : !advice.graded ? t('scorecards.po.notGraded')
                    : t('scorecards.po.grade', { grade: advice.grade ?? '' })}
            </p>
        )
    }
    const w = advice?.warnings?.[0]
    if (!w) return null
    return (
        <div className="bg-amber-50 border border-amber-300 px-3 py-2 rounded text-sm" data-warning="PREPAYMENT_ABOVE_GRADE_CAP" role="status">
            {t('scorecards.po.prepaymentAboveCap', { grade: w.grade, cap: String(w.cap_pct), pct: String(w.on_order_pct) })}
        </div>
    )
}
