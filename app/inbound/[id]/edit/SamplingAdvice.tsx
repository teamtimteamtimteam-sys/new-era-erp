// MES-8a(2026-10-16,MES-0 Q77 · MES-8 Step 0 Q5,Tim):收货页上的抽样建议 —— 这家供应商最近一次没被取代的评审的等级,与那一次评审抄下的
//   V24 抽样级别。【只是建议】:它不加任何一项必须的化验(必须的化验是按物料的,没有按收货的那一层 —— known-issues
//   MES8A-SAMPLING-LEVEL-ADDS-NO-ASSAY)。读 supplier_grade_advice(module.suppliers.view —— 分数跟着供应商的查看码,Q91);
//   没有那个码的读者看到「受限」,不是"没有建议"。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { Refusal } from '@/app/components/ui/refusal'
import type { GradeAdvice } from '@/app/suppliers/scorecardTypes'

export default async function SamplingAdvice({ supplierId }: { supplierId: string | null }) {
    if (!supplierId) return null
    const t = await getTranslations()
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('supplier_grade_advice', { p_supplier_id: supplierId })
    if (error) {
        if (/PERMISSION_DENIED/.test(error.message)) {
            return (
                <p className="text-sm mb-6" data-section="sampling-advice">
                    {t('scorecards.sampling.label')}: <Refusal why={t('scorecards.sampling.restrictedWhy')}>{t('common.restricted')}</Refusal>
                </p>
            )
        }
        throw new Error(`supplier_grade_advice: ${error.message}`)
    }
    const a = data as unknown as GradeAdvice
    return (
        <p className="text-sm mb-6" data-section="sampling-advice">
            <span className="font-medium">{t('scorecards.sampling.label')}:</span>{' '}
            <span data-value="sampling-advice">
                {!a.reviewed ? t('scorecards.sampling.notReviewed')
                    : !a.graded ? t('scorecards.sampling.notGraded')
                    : a.sampling_level ? t('scorecards.sampling.level', { grade: a.grade ?? '', level: a.sampling_level })
                    : t('scorecards.sampling.levelNotSet', { grade: a.grade ?? '' })}
            </span>
            <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('scorecards.sampling.adviceOnly')}</span>
        </p>
    )
}
