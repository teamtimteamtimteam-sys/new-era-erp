'use client'

// SO-1:状态转换。【每个按钮都带一句后果】—— 确认会冻结什么、作废要理由,
// 都写在按钮旁边而不是等拒绝之后才说。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { transitionOrder } from '../actions'
import { Button } from '@/app/components/ui/button'

const ACTION_KEY: Record<string, string> = {
    confirmed: 'sales.action.confirmed',
    closed: 'sales.action.closed',
    cancelled: 'sales.action.cancelled',
}
const CONSEQUENCE_KEY: Record<string, string> = {
    confirmed: 'sales.consequence.confirm',
    closed: 'sales.consequence.close',
    cancelled: 'sales.consequence.cancel',
}

export default function TransitionPanel({
    orderId, status, nextStates,
}: { orderId: string; status: string; nextStates: string[] }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [reason, setReason] = useState('')

    function go(to: string) {
        setError('')
        startTransition(async () => {
            const res = await transitionOrder(orderId, to, to === 'cancelled' ? reason : '')
            if (res.error) setError(res.error)
            else { setReason(''); router.refresh() }
        })
    }

    if (nextStates.length === 0) {
        return <p className="text-sm text-gray-500">{t('sales.terminal')}</p>
    }

    return (
        <div className="border border-gray-300 rounded px-4 py-3">
            {error && <p className="text-sm text-red-600 mb-2">{error}</p>}
            {nextStates.includes('cancelled') && (
                <div className="mb-3">
                    <label className="block text-xs text-gray-600 mb-1">{t('sales.cancelReason')}</label>
                    <input type="text" value={reason} onChange={(e) => setReason(e.target.value)}
                           className="w-full border border-gray-300 px-2 py-1 rounded text-sm" />
                </div>
            )}
            <div className="flex flex-wrap gap-3">
                {nextStates.map((to) => (
                    <div key={to} className="flex-1 min-w-[14rem]">
                        <Button variant={to === 'cancelled' ? 'destructive' : 'secondary'} size="sm" className="w-full" type="button" onClick={() => go(to)}
                                disabled={isPending || (to === 'cancelled' && reason.trim() === '')}>
                            {isPending ? t('common.saving') : t(ACTION_KEY[to] ?? 'sales.action.generic')}
                        </Button>
                        <p className="text-xs text-gray-500 mt-1">{t(CONSEQUENCE_KEY[to] ?? 'sales.consequence.generic')}</p>
                    </div>
                ))}
            </div>
            <p className="text-xs text-gray-500 mt-2">{t('sales.transitionNote', { status })}</p>
        </div>
    )
}
