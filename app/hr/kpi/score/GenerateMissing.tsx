'use client'

// app/hr/kpi/score/GenerateMissing.tsx
// C-2:这个月里【还没有条目】的人 —— 一人一个显式的生成钮。
//
// ★【为什么它必须存在,而不是"没有行就画一句空话"】★
//   survey-hidden-exits 的那条判据:一个只在有数据时才渲染的动作,
//   会让空态变成死路。这一屏的空态恰恰是【最需要一个出口】的时候 ——
//   九月那一批在迁移里生成过了,后面五个月一开始【每个人都是空的】。
//
// ★【生成是一次复制,所以它是一个人按下的动作,不是打开页面的副作用】★
//   assign_position_kpis 会把那一刻的模板抄下来冻住(§8.3)。
//   自动生成意味着"谁被考核什么"由一次页面访问决定,而那是一件该留痕的事。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { generateKpiEntries } from './actions'

export type MissingPerson = { employeeId: string; name: string; positionCode: string | null }

export default function GenerateMissing({
    people,
    cycleId,
    disabled,
}: {
    people: MissingPerson[]
    cycleId: string
    disabled: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [busy, setBusy] = useState<string | null>(null)
    const [errors, setErrors] = useState<Record<string, string>>({})
    const [, startTransition] = useTransition()

    if (people.length === 0) return null

    return (
        <div className="border-l-4 border-amber-500 bg-amber-50 p-3 mb-6 max-w-4xl">
            <p className="text-sm mb-2">{t('kpi.generateWhat')}</p>
            <ul className="space-y-2">
                {people.map((p) => (
                    <li key={p.employeeId} className="text-sm">
                        <span>{p.name}</span>
                        {p.positionCode
                            ? <span className="text-gray-600 ml-1 font-mono text-xs">{p.positionCode}</span>
                            /* ★ 没有职位就没有模板可抄 —— 说出这一句,而不是给一个会失败的钮 */
                            : <span className="text-gray-700 ml-2 text-xs">{t('kpi.generateNoPosition')}</span>}
                        {p.positionCode && (
                            <button
                                type="button"
                                className="ml-3 border border-gray-400 rounded px-2 py-0.5 text-xs bg-white disabled:opacity-50"
                                disabled={disabled || busy === p.employeeId}
                                onClick={async () => {
                                    setBusy(p.employeeId)
                                    const r = await generateKpiEntries(p.employeeId, cycleId)
                                    setBusy(null)
                                    if (r.error) {
                                        setErrors((e) => ({ ...e, [p.employeeId]: r.error as string }))
                                        return
                                    }
                                    setErrors((e) => {
                                        const next = { ...e }
                                        delete next[p.employeeId]
                                        return next
                                    })
                                    startTransition(() => router.refresh())
                                }}
                            >
                                {busy === p.employeeId ? t('common.saving') : t('kpi.generateAction')}
                            </button>
                        )}
                        {errors[p.employeeId] && (
                            <p role="alert" className="mt-1 text-xs text-red-700">{errors[p.employeeId]}</p>
                        )}
                    </li>
                ))}
            </ul>
        </div>
    )
}
