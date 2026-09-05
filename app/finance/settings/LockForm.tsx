'use client'

// 期间锁表单:日期 + 设置(confirm)/ 解除(confirm)。失败 alert,成功由 revalidate 刷新展示。
import { useState, useTransition } from 'react'
import { setPeriodLock } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

export default function LockForm({ lockedBefore }: { lockedBefore: string | null }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [date, setDate] = useState(lockedBefore ?? '')

    function submit(value: string | null, confirmKey: string) {
        if (!window.confirm(t(confirmKey))) return
        startTransition(async () => {
            const result = await setPeriodLock(value)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <div className="flex flex-wrap items-end gap-3">
            <div>
                <label className="block text-sm font-medium mb-1">
                    {t('finance.lockedBefore')} <span className="text-red-600">*</span>
                </label>
                {/* 【不预填今天】:锁定日是期间边界(通常是上月末),今天几乎不会是
                    答案 —— 预填只在"今天确实是最可能的值"时才对(CMP-2 的清查)。 */}
                <input
                    type="date"
                    value={date}
                    onChange={(e) => setDate(e.target.value)}
                    className="border border-gray-300 px-3 py-2 rounded"
                />
            </div>
            {/* 禁用必须说出为什么(CMP-2):每个禁钮条件都有紧邻的一行字。 */}
            {!date && (
                <p className="text-sm text-amber-700 self-center">{t('finance.blockedLockDate')}</p>
            )}
            <Button
                onClick={() => date && submit(date, 'finance.lockConfirm')}
                disabled={isPending || !date}
            >
                {isPending ? t('common.saving') : t('finance.setLock')}
            </Button>
            {lockedBefore && (
                <Button variant="reversal"
                    onClick={() => submit(null, 'finance.unlockConfirm')}
                    disabled={isPending}
                >
                    {t('finance.unlock')}
                </Button>
            )}
        </div>
    )
}
