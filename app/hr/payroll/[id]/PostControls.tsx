'use client'

// 过账 / 撤销过账。
// 过账前的 confirm 把【合计与将要动的科目】原样摆出来 —— 过账会真的动总账,
// 点之前应该看得见自己在批准什么。撤销带内联原因,并说明分录会被冲销。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { postPayroll, unpostPayroll } from '../actions'
import { Button } from '@/app/components/ui/button'

export function PostPayrollButton({
    periodId,
    currency,
    totals,
    bankAccount,
}: {
    periodId: string
    currency: string
    totals: { gross: number; employerCpf: number; employeeCpf: number; other: number; net: number }
    bankAccount: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onPost() {
        // confirm 里逐条列出会动的科目与金额(原币)
        const lines = [
            `6100 ${t('hr.acct6100')}  +${formatAmount(totals.gross, currency)}`,
            `6110 ${t('hr.acct6110')}  +${formatAmount(totals.employerCpf, currency)}`,
            `2400 ${t('hr.acct2400')}  −${formatAmount(totals.employerCpf + totals.employeeCpf, currency)}`,
            `2200 ${t('hr.acct2200')}  −${formatAmount(totals.other, currency)}`,
            `${bankAccount} ${t('finance.bank.' + bankAccount)}  −${formatAmount(totals.net, currency)}`,
        ].join('\n')
        if (!window.confirm(`${t('hr.postConfirm')}\n\n${lines}`)) return
        setError('')
        startTransition(async () => {
            const res = await postPayroll(periodId)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-3">
            <Button
                type="button"
                onClick={onPost}
                disabled={isPending}
            >
                {isPending ? t('common.saving') : t('hr.postPayroll')}
            </Button>
            {error && <span className="text-sm text-red-600">{error}</span>}
        </div>
    )
}

export function UnpostPayrollControl({ periodId }: { periodId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [reason, setReason] = useState('')
    const [error, setError] = useState('')

    function onUnpost() {
        if (!window.confirm(t('hr.unpostConfirm'))) return
        setError('')
        startTransition(async () => {
            const res = await unpostPayroll(periodId, reason)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="space-y-2">
            <p className="text-xs text-gray-500">{t('hr.unpostNote')}</p>
            <div className="flex flex-wrap items-center gap-2">
                <input
                    type="text"
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                    placeholder={t('hr.unpostReason')}
                    className="border border-gray-300 px-3 py-1.5 rounded text-sm"
                />
                <button
                    type="button"
                    onClick={onUnpost}
                    disabled={isPending || reason.trim() === ''}
                    className="border border-red-300 text-red-600 px-3 py-1.5 rounded hover:bg-red-50 text-sm disabled:opacity-50"
                >
                    {t('hr.unpostPayroll')}
                </button>
                {error && <span className="text-sm text-red-600">{error}</span>}
            </div>
        </div>
    )
}
