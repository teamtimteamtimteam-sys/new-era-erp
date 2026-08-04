'use client'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { runRevaluation } from '../month-end/actions'

export default function RevalueButton({ periodEnd, disabled }: { periodEnd: string; disabled: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState<string | null>(null)
    return (
        <div>
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}
            {done && <p className="mb-3 text-sm text-green-700">{t('finance.reval.done', { 0: done })}</p>}
            <button type="button" disabled={pending || disabled}
                onClick={() => { setError(null); start(async () => {
                    const r = await runRevaluation(periodEnd)
                    if (r.error) setError(r.error)
                    else { setDone(JSON.parse(r.result ?? '{}').journal_code ?? '—'); router.refresh() }
                }) }}
                className="bg-gray-900 text-white px-4 py-2 rounded text-sm disabled:opacity-50">
                {t('finance.reval.run', { 0: periodEnd })}
            </button>
        </div>
    )
}
