'use client'

// app/hr/leave/grants/GrantRunner.tsx
// 年末结转。【先看会发生什么,再动手】—— 结转会写进假期账,账一旦错了,
// 最后是在某个人离职那天以一个错误的补偿金额暴露出来。
// 【年度发放那一半已随 HR-2c 删除】:年假按月累积、读时派生,没有"整年发放"这个动作了。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { runCarryForward } from '../actions'
import { Button } from '@/app/components/ui/button'

export default function GrantRunner({
    year, alreadyCarried,
}: {
    year: number
    alreadyCarried: number
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [log, setLog] = useState<string[]>([])



    function carry() {
        setError(null); setLog([])
        startTransition(async () => {
            const r = await runCarryForward(year)
            if (r.error) setError(r.error)
            else {
                const d = r.detail as { employees: number; total_days: number } | undefined
                setLog([t('leave.carryDone', { 0: String(d?.employees ?? 0), 1: String(d?.total_days ?? 0) })])
                router.refresh()
            }
        })
    }

    const card = 'rounded border border-gray-200 p-4 mb-6'

    return (
        <div>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            {log.length > 0 && (
                <div className="mb-4 rounded border border-gray-200 bg-gray-50 px-3 py-2 text-sm">
                    {log.map((l, i) => <div key={i} className="font-mono text-xs">{l}</div>)}
                </div>
            )}

            <section className={card}>
                <h2 className="font-bold mb-1">{t('leave.carryTitle', { 0: String(year), 1: String(year + 1) })}</h2>
                <p className="text-sm text-gray-600 mb-3">{t('leave.carryHint')}</p>
                <p className="text-sm mb-3">{t('leave.alreadyCarried', { 0: String(alreadyCarried) })}</p>
                <Button size="sm" type="button" onClick={carry} disabled={pending}>
                    {pending ? t('common.saving') : t('leave.runCarry')}
                </Button>
                <p className="mt-2 text-xs text-gray-500">{t('leave.carryIdempotentHint')}</p>
            </section>
        </div>
    )
}
