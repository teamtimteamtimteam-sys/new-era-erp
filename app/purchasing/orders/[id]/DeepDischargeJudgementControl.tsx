'use client'

// app/purchasing/orders/[id]/DeepDischargeJudgementControl.tsx
// PROC-1B-iii(R1):在【采购行】上下那个判断 —— 这批料能不能深度放电。
//
// ★【为什么这个控件在【采购单】上,而不是在进料批上】★
//   因为这个判断是在【买的时候】做出的,在货到之前 —— 那一刻进料批还不存在。
//   把它放在收货页上,等于要求一个已经做完的判断等着货到才能被记下来。
//
// ★【三个取值,三种下一步 —— 所以它不是一个勾选框】★
//   可深度放电   → 走深度放电线
//   不可深度放电 → 走整电池粉料线(旁路)
//   未评估       → **不可路由**,因为你不许照着一个猜测去路由
//   而"没选"(空)是第四种情况:**这一行比这条轴还老**。
//   ★ 一个没设的判断【永远不许被读成"不能"】★ —— 所以空选项的字面写的是
//   "未填写",不是"否",而 not_assessed 是一个要【主动选】的、记下来的事实。
import { useState, useTransition } from 'react'
import { setDeepDischargeJudgement } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeepDischargeJudgementControl({
    poId, lineId, current, options, canEdit,
}: {
    poId: string
    lineId: string
    current: string | null
    options: { code: string; label: string }[]
    canEdit: boolean
}) {
    const t = useTranslations()
    const [value, setValue] = useState(current ?? '')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    const label = options.find((o) => o.code === value)?.label

    return (
        <span className="block text-xs mt-0.5">
            <span className="text-gray-500">{t('purchasing.deepDischarge.label')}: </span>
            {canEdit ? (
                <select
                    value={value}
                    disabled={pending}
                    onChange={(e) => {
                        const next = e.target.value
                        setValue(next)
                        setError(null)
                        startTransition(async () => {
                            const r = await setDeepDischargeJudgement(poId, lineId, next)
                            if (r.error) setError(r.error)
                        })
                    }}
                    className="rounded border border-gray-300 bg-white px-1 py-0.5 text-xs"
                >
                    {/* 【空 = 没填过,不是"否"】文案必须说出这一点 */}
                    <option value="">{t('purchasing.deepDischarge.unset')}</option>
                    {options.map((o) => (
                        <option key={o.code} value={o.code}>{o.label}</option>
                    ))}
                </select>
            ) : (
                <span className={value ? 'text-gray-800' : 'text-gray-400'}>
                    {label ?? t('purchasing.deepDischarge.unset')}
                </span>
            )}
            {error && <span className="block text-[11px] text-red-700">{error}</span>}
        </span>
    )
}
