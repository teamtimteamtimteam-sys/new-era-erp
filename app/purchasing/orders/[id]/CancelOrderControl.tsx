'use client'

// 采购单取消控件。能否取消由服务端判定后经 props 传入;不能取消时父组件直接
// 渲染原因说明,本组件只在"可取消"时出现。
// AUDEL-2:改用共用的 ReasonPrompt —— 此前理由是一个【可以留空】的输入框,
// 而 AUDEL-1b 起服务端必填。空着提交只会换来一次拒绝,所以现在按钮直接禁用。
import { useRouter } from 'next/navigation'
import ReasonPrompt from '@/app/components/ReasonPrompt'
import { cancelOrder } from './actions'
import { useTranslations } from '@/lib/i18n/client'

// FIX-2(B1):**禁用并把理由摆在旁边,不是把控件拿掉。**
// 本仓库的规矩:问题【不适用】就藏起来,问题适用但【被挡住】就变灰加一句话。
// "能不能取消这张单"是一个适用的问题 —— 答案只是"这一张不行,因为…"。
// 此前父组件在挡住时直接渲染一句灰字、连按钮都没有,于是人看不出"这里本来有个动作"。
export default function CancelOrderControl({ poId, blockedWhy }: {
    poId: string
    // 空串 = 没挡住。非空 = 挡住了,而这句话【就是那个具体理由】(不是析取式)。
    blockedWhy: string
}) {
    const t = useTranslations()
    const router = useRouter()
    if (blockedWhy) {
        return (
            <div className="inline-flex flex-col">
                <button type="button" disabled
                        className="border border-gray-300 text-gray-400 px-3 py-1.5 rounded text-sm cursor-not-allowed">
                    {t('purchasing.cancelOrder')}
                </button>
                <span className="text-xs text-amber-700 mt-1">{blockedWhy}</span>
            </div>
        )
    }
    return (
        <ReasonPrompt
            triggerLabel={t('purchasing.cancelOrder')}
            title={t('purchasing.cancelConfirm')}
            consequence={t('purchasing.cancelConsequence')}
            confirmLabel={t('purchasing.cancelOrder')}
            placeholder={t('purchasing.cancelReason')}
            action={(reason) => cancelOrder(poId, reason)}
            onDone={() => router.refresh()}
        />
    )
}
