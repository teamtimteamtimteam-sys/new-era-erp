'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { decideClaim, payClaim } from '../actions'
import { Button } from '@/app/components/ui/button'

export default function ClaimControls({
    claimId, status, alreadyLinked, canFinance,
}: {
    claimId: string
    status: string
    alreadyLinked: boolean
    canFinance: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [notes, setNotes] = useState('')
    const [date, setDate] = useState(new Date().toISOString().slice(0, 10))
    const [error, setError] = useState<string | null>(null)
    const [ok, setOk] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    function run(fn: () => Promise<{ error?: string; expenseCode?: string }>) {
        setError(null); setOk(null)
        startTransition(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
            else { if (r.expenseCode) setOk(r.expenseCode); router.refresh() }
        })
    }

    return (
        <div className="rounded border border-gray-200 p-4">
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}
            {ok && <p className="mb-3 text-sm text-green-700">{t('claims.expenseCreated', { 0: ok })}</p>}

            {status === 'submitted' && (
                <>
                    <label className="block text-sm mb-3">{t('leave.decisionNotes')}
                        <input value={notes} onChange={(e) => setNotes(e.target.value)}
                               className="mt-1 w-full border border-gray-300 rounded px-2 py-1 text-sm" /></label>
                    <div className="flex gap-3">
                        <Button size="sm" type="button" disabled={pending}
                                onClick={() => run(() => decideClaim(claimId, true, notes || null))}>
                            {t('leave.approve')}
                        </Button>
                        <button type="button" disabled={pending}
                                onClick={() => run(() => decideClaim(claimId, false, notes || null))}
                                className="border border-gray-300 px-4 py-1.5 rounded text-sm disabled:opacity-50">
                            {t('leave.reject')}
                        </button>
                    </div>
                </>
            )}

            {status === 'approved' && !alreadyLinked && (
                <div>
                    <h3 className="font-bold mb-1 text-sm">{t('claims.createExpense')}</h3>
                    <p className="text-xs text-gray-600 mb-3">{t('claims.createExpenseHint')}</p>
                    <div className="flex gap-2 flex-wrap items-end mb-3">
                        <label className="text-xs">{t('claims.expenseDate')}
                            <input type="date" value={date} onChange={(e) => setDate(e.target.value)}
                                   className="block border border-gray-300 rounded px-2 py-1 text-sm" /></label>
                    </div>
                    <button
                        type="button"
                        disabled={pending || !canFinance || !date}
                        title={canFinance ? undefined : t('claims.needsFinance')}
                        onClick={() => run(() => payClaim(claimId, date))}
                        className="bg-gray-900 text-white px-4 py-1.5 rounded text-sm disabled:opacity-50"
                    >
                        {pending ? t('common.saving') : t('claims.createExpense')}
                    </button>
                    {!canFinance && <p className="mt-2 text-xs text-amber-800">{t('claims.needsFinance')}</p>}
                </div>
            )}
        </div>
    )
}
