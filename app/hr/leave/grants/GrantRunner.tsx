'use client'

// app/hr/leave/grants/GrantRunner.tsx
// 【先看会发生什么,再动手】。两个操作都会写进假期账,而账一旦错了,
// 最后是在某个人离职那天以一个错误的补偿金额暴露出来 —— 所以先把清单摊开。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { runGrantAnnualLeave, runCarryForward } from '../actions'

type Missing = {
    id: string; code: string; legal_name: string
    hire_date: string; annual_leave_days: number
}

export default function GrantRunner({
    year, missing, alreadyGranted, alreadyCarried,
}: {
    year: number
    missing: Missing[]
    alreadyGranted: number
    alreadyCarried: number
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [log, setLog] = useState<string[]>([])

    // 界面上先按同一套规则预估:入职当月起算的完整月数 ÷ 12,取到 0.5。
    // 真正的数字仍由 grant_annual_leave 算 —— 这里只是让人先看一眼。
    function preview(m: Missing) {
        const hire = new Date(m.hire_date + 'T00:00:00')
        const months = hire.getFullYear() < year ? 12 : 12 - hire.getMonth()
        return Math.round((m.annual_leave_days * months) / 12 * 2) / 2
    }

    function grantAll() {
        setError(null); setLog([])
        startTransition(async () => {
            const out: string[] = []
            for (const m of missing) {
                const r = await runGrantAnnualLeave(m.id, year)
                out.push(r.error ? `${m.code}: ${r.error}` : `${m.code}: ${t('leave.granted')} ${preview(m)}`)
            }
            setLog(out)
            router.refresh()
        })
    }

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
                <h2 className="font-bold mb-1">{t('leave.grantAnnualTitle', { 0: String(year) })}</h2>
                <p className="text-sm text-gray-600 mb-3">{t('leave.grantAnnualHint')}</p>
                <p className="text-sm mb-3">
                    {t('leave.alreadyGranted', { 0: String(alreadyGranted) })} ·{' '}
                    {t('leave.missingCount', { 0: String(missing.length) })}
                </p>
                {missing.length > 0 && (
                    <table className="w-full border-collapse text-xs mb-3">
                        <thead>
                            <tr className="bg-gray-50 text-left">
                                <th className="border border-gray-300 px-2 py-1">{t('leave.employee')}</th>
                                <th className="border border-gray-300 px-2 py-1">{t('me.hireDate')}</th>
                                <th className="border border-gray-300 px-2 py-1 text-right">{t('leave.willGrant')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {missing.map((m) => (
                                <tr key={m.id}>
                                    <td className="border border-gray-300 px-2 py-1">{m.code} — {m.legal_name}</td>
                                    <td className="border border-gray-300 px-2 py-1">{m.hire_date}</td>
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono">{preview(m)}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                )}
                <button type="button" onClick={grantAll} disabled={pending || missing.length === 0}
                        className="bg-gray-900 text-white px-4 py-1.5 rounded text-sm disabled:opacity-50">
                    {pending ? t('common.saving') : t('leave.runGrant', { 0: String(missing.length) })}
                </button>
            </section>

            <section className={card}>
                <h2 className="font-bold mb-1">{t('leave.carryTitle', { 0: String(year), 1: String(year + 1) })}</h2>
                <p className="text-sm text-gray-600 mb-3">{t('leave.carryHint')}</p>
                <p className="text-sm mb-3">{t('leave.alreadyCarried', { 0: String(alreadyCarried) })}</p>
                <button type="button" onClick={carry} disabled={pending}
                        className="bg-gray-900 text-white px-4 py-1.5 rounded text-sm disabled:opacity-50">
                    {pending ? t('common.saving') : t('leave.runCarry')}
                </button>
                <p className="mt-2 text-xs text-gray-500">{t('leave.carryIdempotentHint')}</p>
            </section>
        </div>
    )
}
