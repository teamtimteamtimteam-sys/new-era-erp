'use client'

// PROC-2c:建批次表单里的到货状态一块 —— 两条建批次路径共用。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么门口也要问一次 —— 这不是把批次页面那块搬过来】
//
// PROC-2b 把这两轴放在批次页面上,理由是【安全状态会变】:一批货到的时候带电,
// 后来才被放电并核验,只在门口记一次就永远记不下那个转变。那条理由今天仍然成立,
// 那一块也仍然在。**这里补的是另一半:门口【已经知道】的事,在门口就记下来。**
//
// 这一半是 PROC-3 的前提:一道"没有记过安全状态就不许投料"的闸,如果记它的唯一
// 地方是一个事后才点得到的编辑页,那道闸就是不可过日子的 —— 人会绕过去,或者
// 干脆不开它。
//
// 【适用与否问的是【种类】,而"不知道"永远不是"不适用"】
// 只有带状态轴的种类(今天:电池料)有安全状态与化学体系确定度可言。一箱吨袋
// 没有。所以:
//   * 种类明说【不适用】 → 【不摆这两个控件】,并说出是哪一种种类。
//     摆一个服务端保证会拒的控件,是 AGENTS.md 明令禁止的那件事;
//     库那一侧的 guard_inbound_condition_applicable 仍然是独立的那道拒绝。
//   * 种类【没有人记过】(PROC-1 留下的诚实空白)→ **照常摆出来**,
//     因为库那一侧此时也是放行的。页面与服务端必须给出同一个答案,
//     而"不知道"倒向"不许"会把一次录入拦死在一个没人做过的判断上。
// ════════════════════════════════════════════════════════════════════════════
import { useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import IntakeConditionFields, {
    CERTAINTY_UNCHOSEN, type SafetyState, type Certainty,
} from './IntakeConditionFields'

/** 一个物料的种类【说了什么】。整条不在表里 = 没有人记过种类。 */
export type MaterialAxis = { has_axes: boolean; kind_en: string; kind_zh: string }

export default function IntakeConditionFormSection({
    states, certainties, materialAxes, materialId, locale,
}: {
    states: SafetyState[]
    certainties: Certainty[]
    materialAxes: Record<string, MaterialAxis>
    materialId: string
    locale: string
}) {
    const t = useTranslations()
    const [picked, setPicked] = useState<string[]>([])
    const [certainty, setCertainty] = useState<string>(CERTAINTY_UNCHOSEN)

    // 还没选物料 —— 不摆,因为"适不适用"此刻没有答案(而不是答案是"适用")。
    if (!materialId) return null

    const axis = materialAxes[materialId]
    if (axis && !axis.has_axes) {
        return (
            <div className="border border-gray-300 rounded p-3 bg-gray-50">
                <p className="text-sm font-medium mb-1">{t('inbound.condition.title')}</p>
                <p className="text-xs text-gray-600">
                    {t('inbound.condition.notApplicable', {
                        kind: locale === 'zh' ? axis.kind_zh : axis.kind_en,
                    })}
                </p>
            </div>
        )
    }

    return (
        <div className="border border-gray-300 rounded p-3">
            <p className="text-sm font-medium mb-1">{t('inbound.condition.title')}</p>
            <p className="text-xs text-gray-600 mb-3">{t('inbound.condition.atGateHint')}</p>
            <IntakeConditionFields
                states={states} certainties={certainties}
                picked={picked} certainty={certainty}
                onToggle={(code) =>
                    setPicked((p) => (p.includes(code) ? p.filter((c) => c !== code) : [...p, code]))}
                onCertainty={setCertainty}
                disabled={false} locale={locale} asFormFields
            />
        </div>
    )
}
