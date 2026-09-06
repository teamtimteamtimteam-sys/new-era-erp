'use client'

// 期间锁表单:日期 + 设置(确认)/ 解除(确认)。失败 alert,成功由 revalidate 刷新展示。
// CONFIRM-1:两处确认都换成 ConfirmButton。主语是【那个日期】—— 一个"要不要锁?"
// 的灰盒子答不出锁到哪一天,而锁到哪一天正是这次点击的全部内容。
import { useState, useTransition } from 'react'
import { setPeriodLock } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

export default function LockForm({ lockedBefore }: { lockedBefore: string | null }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [date, setDate] = useState(lockedBefore ?? '')

    function submit(value: string | null) {
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
            <ConfirmButton
                subject={date}
                title={t('finance.lockConfirm')}
                confirmLabel={t('finance.setLock')}
                tier="destructive"
                triggerVariant="default"
                disabled={isPending || !date}
                onConfirm={() => submit(date)}
            >
                {isPending ? t('common.saving') : t('finance.setLock')}
            </ConfirmButton>
            {lockedBefore && (
                // 解除锁的主语是【现在锁在哪一天】,不是输入框里那个可能已经被改过的值 ——
                // 解除动作传的是 null,它作用于既有的那道锁。
                <ConfirmButton
                    subject={lockedBefore}
                    title={t('finance.unlockConfirm')}
                    confirmLabel={t('finance.unlock')}
                    tier="reversal"
                    triggerVariant="reversal"
                    disabled={isPending}
                    onConfirm={() => submit(null)}
                >
                    {t('finance.unlock')}
                </ConfirmButton>
            )}
        </div>
    )
}
