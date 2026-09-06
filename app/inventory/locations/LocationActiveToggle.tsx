'use client'

// LOC-1:停用 / 启用。
//
// 【永远可点,后果写在旁边】停用没有前置条件 —— 一个正被历史流水引用的库位
// 照样停得掉,那正是停用相对于删除的全部意义:历史指着的那一行继续说得出
// 自己是谁。所以这个控件【没有 disabled 分支】,它要说的是"按下去会发生什么",
// 不是"你不能按"。
//
// 【这里没有删除按钮,而且不是漏了】这张表没有硬删路径:数据库那一侧由
// guard_storage_location_no_hard_delete 具名拒绝(LOCATION_NO_HARD_DELETE),
// 界面这一侧连按钮都不给。两者说的是同一件事,而不是界面藏起了一个能用的动作。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { setLocationActive } from './actions'
import { Button } from '@/app/components/ui/button'

export default function LocationActiveToggle({ id, isActive }: { id: string; isActive: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onToggle() {
        startTransition(async () => {
            const res = await setLocationActive(id, !isActive)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="flex flex-col gap-1">
            <Button
                variant="secondary"
                size="xs"
                type="button"
                onClick={onToggle}
                disabled={isPending}
                className="w-fit"
            >
                {isPending
                    ? t('common.saving')
                    : isActive
                        ? t('locations.deactivate')
                        : t('locations.reactivate')}
            </Button>
            {/* 后果 —— 挨着按钮,不在别处 */}
            <span className="text-xs text-gray-500">
                {isActive ? t('locations.deactivateConsequence') : t('locations.reactivateConsequence')}
            </span>
            {error && <span className="text-xs text-red-600">{error}</span>}
        </div>
    )
}
