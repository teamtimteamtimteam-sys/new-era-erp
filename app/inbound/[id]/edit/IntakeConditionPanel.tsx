'use client'

// PROC-2b(P3):这一批货【到货时是什么状态】—— 安全状态(多值)与化学体系确定度。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么这一块在【批次自己的页面】上,而不是在收货表单上 —— grill 的结论】
//
// 两条理由,第二条是决定性的:
//  1. 建批次的两条路都是 RPC(create_inbound_batch / receive_inbound_batch_against_po),
//     往它们加字段要改签名 = 一支迁移,而本刀在库这一侧【没有迁移】;
//  2. **更要紧的:安全状态不是一个"收货那一刻"的事实。**
//     一批货【到的时候带电,后来才被放电并核验】。只在建批次时记一次,
//     那个【转变】就永远记不下来 —— 而 PROC-3 那道闸要拦的正是"未放电",
//     它要能被满足,靠的就是有人能把"现在已经放过电了"记上去。
//     **只在收货时记,等于让那道闸永远无法被满足。**
//
// 【建批次时也该问一次 —— 那是 PROC-2c,理由写在这里】改两个 RPC 的签名要一支
// 迁移;而且 preflight_migration.py 会拒绝签名不同的 CREATE OR REPLACE
// (那是重载,不是替换),所以要 DROP + CREATE。留给它自己的一刀。
// ════════════════════════════════════════════════════════════════════════════
//
// 【P4:没有默认】复选框一个都不预勾;确定度下拉以【还没选】开局。
// 【一条安全状态都没有 ≠ 安全】—— inbound_batch_safety_states 的表注写着这句,
// 而屏幕上必须把它按名说出来,不能留一片空白让人自己去理解。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { setIntakeCondition } from './intakeConditionActions'

export type SafetyState = { code: string; name_en: string; name_zh: string; may_be_fed: boolean }
export type Certainty = { code: string; name_en: string; name_zh: string; may_be_fed: boolean }

export const CERTAINTY_UNCHOSEN = '__unchosen__'

export default function IntakeConditionPanel({
    batchId, states, certainties, currentStates, currentCertainty, canEdit, locale,
}: {
    batchId: string
    states: SafetyState[]
    certainties: Certainty[]
    currentStates: string[]
    currentCertainty: string | null
    canEdit: boolean
    locale: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [picked, setPicked] = useState<string[]>(currentStates)
    const [certainty, setCertainty] = useState<string>(currentCertainty ?? CERTAINTY_UNCHOSEN)
    const label = (r: { name_en: string; name_zh: string }) => (locale === 'zh' ? r.name_zh : r.name_en)

    function toggle(code: string) {
        setPicked((p) => (p.includes(code) ? p.filter((c) => c !== code) : [...p, code]))
    }
    function save() {
        setError(null)
        start(async () => {
            const r = await setIntakeCondition({ batchId, safetyStates: picked, certainty })
            if (r.error) { setError(r.error); return }
            router.refresh()
        })
    }

    return (
        <div className="mb-8">
            <h2 className="text-sm font-medium text-gray-700 mb-2">{t('inbound.condition.title')}</h2>
            {!canEdit && <p className="text-xs text-gray-500 mb-2">{t('inbound.condition.needsEdit')}</p>}
            {error && <p className="text-red-600 text-xs mb-2">{error}</p>}

            <div className="border border-gray-300 rounded p-3 max-w-2xl space-y-4">
                {/* ── 安全状态:多值 ─────────────────────────────────────────── */}
                <div>
                    <p className="text-sm font-medium mb-1">{t('inbound.condition.safety')}</p>
                    <p className="text-xs text-gray-600 mb-2">{t('inbound.condition.safetyHint')}</p>
                    <div className="space-y-1">
                        {states.map((s) => (
                            <label key={s.code} className="flex items-start gap-2 text-sm">
                                <input type="checkbox" className="mt-1" disabled={!canEdit}
                                       checked={picked.includes(s.code)} onChange={() => toggle(s.code)} />
                                <span>
                                    {label(s)}
                                    {/* 【规则摆在选项旁边,但明说它今天不拦人】——
                                        may_be_fed 记的是事实,读它的闸在 PROC-3。
                                        把它画成"会被拦住"是在描述一个还不存在的行为。 */}
                                    {!s.may_be_fed && (
                                        <span className="text-xs text-amber-700 ml-2">{t('inbound.condition.notFeedable')}</span>
                                    )}
                                </span>
                            </label>
                        ))}
                    </div>
                    {/* 【一条都没勾 = 没有人记过,不是"安全"】按名说出来。 */}
                    {picked.length === 0 && (
                        <p className="text-xs text-amber-700 mt-2">{t('inbound.condition.noneRecorded')}</p>
                    )}
                </div>

                {/* ── 化学体系确定度 ────────────────────────────────────────── */}
                <div className="border-t border-gray-200 pt-3">
                    <p className="text-sm font-medium mb-1">{t('inbound.condition.certainty')}</p>
                    <select value={certainty} onChange={(e) => setCertainty(e.target.value)} disabled={!canEdit}
                            className="w-full border border-gray-300 px-3 py-2 rounded text-sm">
                        <option value={CERTAINTY_UNCHOSEN}>{t('inbound.condition.certaintyUnchosen')}</option>
                        {certainties.map((c) => (
                            <option key={c.code} value={c.code}>{label(c)}</option>
                        ))}
                    </select>
                    {/* 【把那条界摆在【选的人面前】,不只写在字典里】——
                        站在一个乱糟糟的集装箱前面的人,最容易把"我分不出来"选成"已知混合"。
                        这句话写在字典行上是给读库的人看的;这一句是给他看的。 */}
                    <p className="text-xs text-gray-600 mt-1">{t('inbound.condition.certaintyBoundary')}</p>
                    {certainty === CERTAINTY_UNCHOSEN && currentCertainty === null && (
                        <p className="text-xs text-amber-700 mt-1">{t('inbound.condition.certaintyNotRecorded')}</p>
                    )}
                </div>

                {canEdit && (
                    <div className="flex gap-2 items-center">
                        <button type="button" disabled={pending} onClick={save}
                                className="border border-gray-600 bg-gray-800 text-white px-3 py-1 rounded text-xs disabled:opacity-50">
                            {t('common.save')}
                        </button>
                        <span className="text-xs text-gray-500">{t('inbound.condition.saveHint')}</span>
                    </div>
                )}
            </div>
        </div>
    )
}
