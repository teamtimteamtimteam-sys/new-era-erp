'use client'

// 采购单取消控件。能否取消由服务端判定后经 props 传入;不能取消时父组件直接
// 渲染原因说明,本组件只在"可取消"时出现。
// AUDEL-2:改用共用的理由控件 —— 此前理由是一个【可以留空】的输入框,
// 而 AUDEL-1b 起服务端必填。空着提交只会换来一次拒绝,所以确认钮直接禁用。
// ★ BTN-4:那份共用实现从 ReasonPrompt 折进了 <ConfirmButton reason>。
//   ☞ 主语是采购单号(code),由父组件传进来 —— 同一页的 ApprovalControls
//     早就在这么做(它的主语取的是 po 的编号),这里只是补上同一件事。
//   ★ 上一版这句注释里写着那个属性的字面写法,于是 check-confirm-subject 的
//     解析器把【一句散文】数成了第 53 处主语(它按整份源码跑正则,不跳注释)。
//     AGENTS.md 那条「一句注释可以污染将来对它自己的计数」——
//     在一把以它为主题的刀里,又犯了一次。所以这里只描述,不写那个 token。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { cancelOrder } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

// FIX-2(B1):**禁用并把理由摆在旁边,不是把控件拿掉。**
// 本仓库的规矩:问题【不适用】就藏起来,问题适用但【被挡住】就变灰加一句话。
// "能不能取消这张单"是一个适用的问题 —— 答案只是"这一张不行,因为…"。
// 此前父组件在挡住时直接渲染一句灰字、连按钮都没有,于是人看不出"这里本来有个动作"。
export default function CancelOrderControl({ poId, code, blockedWhy }: {
    poId: string
    code: string
    // 空串 = 没挡住。非空 = 挡住了,而这句话【就是那个具体理由】(不是析取式)。
    blockedWhy: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    if (blockedWhy) {
        // FIX-3(B):`items-start` —— 列方向 flex 的 align-items 默认是 stretch,
        // 于是按钮被下面那句长理由撑到同宽,读起来像个输入框而不是按钮。
        // 加上它,按钮保持自然宽度,理由自己占一行。
        return (
            <div className="inline-flex flex-col items-start">
                <Button variant="destructive" size="sm" type="button" disabled>
                    {t('purchasing.cancelOrder')}
                </Button>
                <span className="text-xs text-amber-700 mt-1">{blockedWhy}</span>
            </div>
        )
    }
    return (
        <div className="inline-flex flex-col items-start">
            <ConfirmButton
                subject={code}
                title={t('purchasing.cancelConfirm')}
                body={t('purchasing.cancelConsequence')}
                confirmLabel={t('purchasing.cancelOrder')}
                tier="destructive"
                reason={{ placeholder: t('purchasing.cancelReason') }}
                triggerVariant="destructive"
                triggerSize="sm"
                disabled={isPending}
                onConfirm={(reason) => {
                    setError('')
                    startTransition(async () => {
                        const res = await cancelOrder(poId, reason)
                        if (res?.error) setError(res.error)
                        else router.refresh()
                    })
                }}
            >
                {isPending ? t('common.saving') : t('purchasing.cancelOrder')}
            </ConfirmButton>
            {error && <span className="mt-1 text-xs text-destructive-text">{error}</span>}
        </div>
    )
}
