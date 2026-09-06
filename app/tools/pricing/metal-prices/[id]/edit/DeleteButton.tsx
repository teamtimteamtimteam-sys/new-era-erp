'use client'

import { useTransition } from 'react'
import { softDeleteMetalPrice } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

// CONFIRM-1:原来只收一个 id —— 于是确认框只说得出「删除这条金属价格?」。
// 主语(金属 + 价格日期)在【父页】手里,所以由父页传进来,而不是在这里再查一次库。
export default function DeleteButton({ id, subject }: { id: string; subject: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    return (
        <ConfirmButton
            subject={subject}
            title={t('metalPrices.deleteConfirm')}
            confirmLabel={t('common.delete')}
            tier="destructive"
            disabled={isPending}
            className="text-sm border border-red-300 text-red-600 px-3 py-1 rounded hover:bg-red-50 disabled:opacity-50"
            onConfirm={() => {
                startTransition(async () => {
                    // 成功时服务端 redirect 接管;仅失败时才会返回带 error 的对象。
                    const result = await softDeleteMetalPrice(id)
                    if (result?.error) {
                        alert(result.error)
                    }
                })
            }}
        >
            {isPending ? t('common.deleting') : t('common.delete')}
        </ConfirmButton>
    )
}
