'use client'

// ★ APR-8(Tim 2026-09-26,grilling Q1):停用一张在用的公式 —— cco 一步(只会让能用的变少)。
//   此后计价器、建采购单、应用化验读它按名拒 FORMULA_INACTIVE;已抄下的承诺不受影响。
//   重新启用要经 CFO(表单提交 = formula_reactivate)。形状照 DeleteFormulaButton。
import { useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { deactivateFormula } from '@/app/components/pricing/termsRequestActions'

export default function DeactivateFormulaButton({ formulaId, subject }: { formulaId: string; subject: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()

    return (
        <ConfirmButton
            subject={subject}
            title={t('termsRequest.deactivateConfirm')}
            body={t('termsRequest.deactivateBody')}
            confirmLabel={t('termsRequest.deactivate')}
            tier="reversal"
            disabled={isPending}
            triggerVariant="outline"
            onConfirm={() => {
                startTransition(async () => {
                    const result = await deactivateFormula(formulaId)
                    if (result?.error) {
                        showActionMessage({
                            subject,
                            headline: t('common.actionMessage.headline.notDecided'),
                            body: result.error,
                            detail: result.detail,
                        })
                        return
                    }
                    router.refresh()
                })
            }}
        >
            {t('termsRequest.deactivate')}
        </ConfirmButton>
    )
}
