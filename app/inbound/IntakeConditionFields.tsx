'use client'

// PROC-2c(D5):PROC-2b 那两块控件的【唯一一份实现】。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么把它抽出来,而不是在收货表单里再写一遍】
//
// PROC-2b 把这两块做在批次页面上,PROC-2c 要它们【在门口也出现一次】。
// 照抄一份是最快的写法,而它会立刻产生本仓库反复付过账的那件事:**两份实现,
// 在写下的那天一致,之后各自漂开。** 屏幕上的字尤其如此 —— 「一条都没勾 ≠ 安全」
// 与「已知混合 ≠ 分不出来」这两句话是本刀真正在防的东西,而它们只要有一份
// 没跟上,那一块屏幕就在说另一件事。
//
// 【两个宿主,一个区别】
//   * 批次页面(IntakeConditionPanel):受控 state + 一个"保存"按钮,走 RPC;
//   * 建批次表单(NewInboundForm / ReceiveForm):同样的控件带 name,
//     跟着整张表单一次提交 —— 建批次与记状态因此是【同一笔】。
// 所以这里【不带保存按钮、也不带标题】:那两样是宿主的事。
//
// 【P4:没有默认】复选框一个都不预勾;确定度以【还没选】开局。两个宿主都是。
// ════════════════════════════════════════════════════════════════════════════
import { useTranslations } from '@/lib/i18n/client'

export type SafetyState = { code: string; name_en: string; name_zh: string; may_be_fed: boolean }
export type Certainty = { code: string; name_en: string; name_zh: string; may_be_fed: boolean }

// 【哨兵,不是取值】"还没选"必须与字典里任何一行都分得开 —— 空串在 FormData 里
// 与"没提交这个字段"分不开,所以用一个不可能是字典码的串。
export const CERTAINTY_UNCHOSEN = '__unchosen__'

// 【表单字段名:一份,两个表单共用】手抄到两处就是两份会漂开的清单。
export const FIELD_SAFETY_STATES = 'safety_states'
export const FIELD_CERTAINTY = 'chemistry_certainty'

export default function IntakeConditionFields({
    states, certainties, picked, certainty, onToggle, onCertainty,
    disabled, locale, asFormFields = false, everRecordedCertainty = false,
}: {
    states: SafetyState[]
    certainties: Certainty[]
    picked: string[]
    certainty: string
    onToggle: (code: string) => void
    onCertainty: (code: string) => void
    disabled: boolean
    locale: string
    /** true = 带 name,跟着宿主表单一起提交(建批次那条路) */
    asFormFields?: boolean
    /** 这批货此前记过确定度吗 —— 只影响"还没有人记过"那句提示要不要出现 */
    everRecordedCertainty?: boolean
}) {
    const t = useTranslations()
    const label = (r: { name_en: string; name_zh: string }) => (locale === 'zh' ? r.name_zh : r.name_en)

    return (
        <div className="space-y-4">
            {/* ── 安全状态:多值 ─────────────────────────────────────────────── */}
            <div>
                <p className="text-sm font-medium mb-1">{t('inbound.condition.safety')}</p>
                <p className="text-xs text-gray-600 mb-2">{t('inbound.condition.safetyHint')}</p>
                <div className="space-y-1">
                    {states.map((s) => (
                        <label key={s.code} className="flex items-start gap-2 text-sm">
                            <input type="checkbox" className="mt-1" disabled={disabled}
                                   {...(asFormFields ? { name: FIELD_SAFETY_STATES, value: s.code } : {})}
                                   checked={picked.includes(s.code)} onChange={() => onToggle(s.code)} />
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

            {/* ── 化学体系确定度 ────────────────────────────────────────────── */}
            <div className="border-t border-gray-200 pt-3">
                <p className="text-sm font-medium mb-1">{t('inbound.condition.certainty')}</p>
                <select value={certainty} onChange={(e) => onCertainty(e.target.value)} disabled={disabled}
                        {...(asFormFields ? { name: FIELD_CERTAINTY } : {})}
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
                {certainty === CERTAINTY_UNCHOSEN && !everRecordedCertainty && (
                    <p className="text-xs text-amber-700 mt-1">{t('inbound.condition.certaintyNotRecorded')}</p>
                )}
            </div>
        </div>
    )
}
