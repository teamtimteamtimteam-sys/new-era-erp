'use client'

// LOG-4b:运费单冲销控件。
// ★ BTN-4:AUDEL-2 的形状折进了 <ConfirmButton reason> —— 后果仍然写在按下
//   【之前】(body)、理由为空时确认钮不可按、服务端仍是权威。变的只是画它的
//   那一份实现从 ReasonPrompt 换成了对话框,而对话框【探针点得到】。
//   ☞ 主语是运费单号(code),由父组件传进来:原来这个控件只拿到 id。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { reverseFreight } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function ReverseFreightControl({ id, code }: { id: string; code: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    return (
        <div className="inline-flex flex-col items-end">
            <ConfirmButton
                subject={code}
                title={t('finance.freight.reverseTitle')}
                // 【三件后果都在按下之前说清】分录镜像回零、离开应付账龄、不可撤销;
                // 外加"已被付过款的冲不了"—— 那一条与其让人按下去撞
                // FREIGHT_HAS_SETTLEMENT,不如先说。
                body={t('finance.freight.reverseConsequence')}
                confirmLabel={t('finance.freight.reverseButton')}
                tier="destructive"
                reason={{ placeholder: t('finance.freight.reverseReason') }}
                triggerVariant="destructive"
                triggerSize="sm"
                disabled={isPending}
                onConfirm={(reason) => {
                    setError('')
                    startTransition(async () => {
                        const res = await reverseFreight(id, reason)
                        if (res && 'error' in res && res.error) setError(res.error)
                        else router.refresh()
                    })
                }}
            >
                {isPending ? t('common.saving') : t('finance.freight.reverseButton')}
            </ConfirmButton>
            {error && <p className="mt-1 max-w-md text-xs text-destructive-text">{error}</p>}
        </div>
    )
}
