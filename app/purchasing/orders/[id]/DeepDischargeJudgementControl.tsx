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
//
// ★【U1-B(UNBLOCK-1 Q20,2026-10-05):空只能【是】,不能【被选回去】】★
//   写入改走 set_po_line_deep_discharge,它按名拒空(DEEP_DISCHARGE_JUDGEMENT_REQUIRED)——
//   NULL 的意思是"这一行早于这条轴",不是"不知道";不知道是 not_assessed。
//   所以空选项【只在当前值为空时】才画出来,而且画成 disabled(它只是一句
//   "还没填"的说明,不是一个可选的值);一旦有了值,它就不再出现 —— 选它必然被拒。
//   ★ 编辑权限走 PermissionGate(DBLOCK-1:看得见、按不动、说出缺哪个码),
//     不再整个换成只读字;**作废的单**才换成只读字 —— 那是记录状态,不是权限,
//     两者分开传(poCancelled / canEdit),不合成一个布尔(AGENTS.md DBLOCK-1 第 2 条)。
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { setDeepDischargeJudgement } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export default function DeepDischargeJudgementControl({
    poId, lineId, current, options, canEdit, poCancelled,
}: {
    poId: string
    lineId: string
    current: string | null
    options: { code: string; label: string }[]
    /** module.purchasing.edit —— 只管权限,不掺记录状态。 */
    canEdit: boolean
    /** 这张单已作废 —— 服务端按名拒(PO_CANCELLED),所以只读显示。 */
    poCancelled: boolean
}) {
    const t = useTranslations()
    const [value, setValue] = useState(current ?? '')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    // 字典只读启用的那几条;一条已停用的旧值不在 options 里 —— 原样显示它的码,
    // 而不是把它说成"未填写"(那会是一句假话)。
    const label = value === '' ? undefined : (options.find((o) => o.code === value)?.label ?? value)
    const currentInactive = value !== '' && !options.some((o) => o.code === value)

    return (
        <span className="block text-xs mt-0.5 text-[color:var(--brand-muted-text)]">
            <span className="text-[color:var(--brand-muted-text)]">{t('purchasing.deepDischarge.label')}: </span>
            {poCancelled ? (
                <span className={value ? 'text-gray-800' : 'text-gray-400'}>
                    {label ?? t('purchasing.deepDischarge.unset')}
                </span>
            ) : (
                <PermissionGate code="module.purchasing.edit" allowed={canEdit} inline>
                    <select
                        value={value}
                        disabled={pending}
                        onChange={(e) => {
                            const next = e.target.value
                            // 空不可选(见抬头);这一行只是防住一个不该出现的事件。
                            if (next === '') return
                            const previous = value
                            setValue(next)
                            setError(null)
                            startTransition(async () => {
                                const r = await setDeepDischargeJudgement(poId, lineId, next)
                                // 乐观更新:没有确认落地就退回原值 —— 屏幕不许停在一个库里没有的值上。
                                if (r.error) {
                                    setValue(previous)
                                    setError(r.error)
                                }
                            })
                        }}
                        className={CONTROL_SELECT}
                    >
                        {/* 【空 = 没填过,不是"否"】文案必须说出这一点。只在当前为空时画,且不可选。 */}
                        {value === '' && (
                            <option value="" disabled>{t('purchasing.deepDischarge.unset')}</option>
                        )}
                        {currentInactive && (
                            <option value={value} disabled>{value}</option>
                        )}
                        {options.map((o) => (
                            <option key={o.code} value={o.code}>{o.label}</option>
                        ))}
                    </select>
                </PermissionGate>
            )}
            {error && <span className="block text-xs text-red-700">{error}</span>}
        </span>
    )
}
