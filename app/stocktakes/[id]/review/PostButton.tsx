'use client'

// app/stocktakes/[id]/review/PostButton.tsx
// 确认过账:确认对话框后调 post_stocktake;错误内联展示(已本地化),
// 成功由 action 重定向回详情页(只读 posted 视图)。
import { useState, useTransition } from 'react'
import { postStocktake } from '../../actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Refusal } from '@/app/components/ui/refusal'

// ROLE-1 Batch 3a:过账归 action.stocktake_post(财务);开单人与录过数的人永远不能过账。
// 两种"按不动"分开说:缺码 → PermissionGate 点名那个码;是开单人 / 录数人 → blockedReason
// 说出是哪一条(那不是管理员给得了的)。库那一侧照样按人判 —— 这里只画按钮能不能按。
export default function PostButton({
    stocktakeId,
    subject,
    canPost,
    blockedReason,
}: {
    stocktakeId: string
    subject: string
    canPost: boolean
    blockedReason: string | null
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    function doPost() {
        setError(null)
        startTransition(async () => {
            const result = await postStocktake(stocktakeId)
            if (result?.error) {
                setError(result.error)
            }
        })
    }

    return (
        <div>
            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-3">
                    {error}
                </div>
            )}
            <PermissionGate code="action.stocktake_post" allowed={canPost}>
                <ConfirmButton
                    subject={subject}
                    title={t('stocktakes.postConfirm')}
                    confirmLabel={t('stocktakes.postButton')}
                    tier="destructive"
                    triggerVariant="default"
                    disabled={isPending || blockedReason !== null}
                    onConfirm={doPost}
                >
                    {isPending ? t('common.saving') : t('stocktakes.postButton')}
                </ConfirmButton>
            </PermissionGate>
            {canPost && blockedReason && (
                <div className="mt-2">
                    <Refusal why={blockedReason} className="whitespace-normal text-left font-normal">
                        {blockedReason}
                    </Refusal>
                </div>
            )}
        </div>
    )
}
