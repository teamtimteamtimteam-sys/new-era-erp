'use client'

// MES-5b-2(2026-10-09,MES-5b Step 0 Q22 · Q25,Tim):撤回一张电费单的控件 —— 运费单冲销那一个(ReverseFreightControl)的形状。
//   后果写在按下【之前】(body):费用单与分录冲掉、各炉的实际电费行撤掉、被它替掉的手敲估计放回去并重新计提、同一段时间可以再过一张;
//   已经经付款结过的拒,先冲那笔付款。理由为空时确认钮按不下去;服务端(reverse_electricity_allocation)仍是权威。
//   主语是那张费用单的单号(这张分摊的编号)。没有 module.finance.edit 的人:看得见、按不下去、说出要哪个码(DBLOCK-1)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { useTranslations } from '@/lib/i18n/client'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { reverseAllocation } from '../actions'

export default function ReverseAllocationControl({ id, code, canEdit }: { id: string; code: string; canEdit: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    return (
        <div className="inline-flex flex-col items-start" data-control="reverse-allocation">
            <PermissionGate code="module.finance.edit" allowed={canEdit}>
                <ConfirmButton
                    subject={code}
                    title={t('energy.reverseTitle')}
                    body={t('energy.reverseConsequence')}
                    confirmLabel={t('energy.reverseButton')}
                    tier="destructive"
                    reason={{ placeholder: t('energy.reverseReason') }}
                    triggerVariant="destructive"
                    disabled={isPending}
                    onConfirm={(reason) => {
                        setError('')
                        startTransition(async () => {
                            const res = await reverseAllocation(id, reason)
                            if (res && 'error' in res && res.error) setError(res.error)
                            else router.refresh()
                        })
                    }}
                >
                    {isPending ? t('common.saving') : t('energy.reverseButton')}
                </ConfirmButton>
            </PermissionGate>
            {error && <p className="mt-1 max-w-md text-xs text-destructive-text">{error}</p>}
        </div>
    )
}
