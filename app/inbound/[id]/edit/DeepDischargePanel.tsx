'use client'

// app/inbound/[id]/edit/DeepDischargePanel.tsx
// PROC-1B-iii(R2):【实际到的货】能不能深度放电。
//
// ★★【为什么这是【自己一块】,而不是塞进"到货状态"那一块】★★
//   到货状态(inbound_safety_states)答的是"这批料【现在】放没放电" ——
//   那是一条【状态】轴,而且是【起火闸】读的那一条。
//   本块答的是"这批料【压根能不能】放电" —— 一条【能力】轴。
//   两者必须能同时说话:带电 + 能放电 → 深度放电线;
//   带电 + 放不了电 → 整电池粉料线(而那正是粉料线受理"未放电"却不解决它的理由)。
//   ★ 把它并进那一块,等于给同一件事造第二种说法,而"一个事实两个来源"
//     是这个仓库反复付账的那一类缺陷。★
//
// 【它不拦任何东西】R3:这个判断影响的是【怎么路由】,不是收不收货。
//   所以这块界面上没有任何"被卡住了"的语气 —— 它记录,不裁决。
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { setDeepDischargeActual } from './deepDischargeActions'
import { useTranslations } from '@/lib/i18n/client'
import { Alert } from '@/app/components/ui/alert'

export default function DeepDischargePanel({
    batchId, current, judged, judgedVisible, hasPoLine, options, canEdit,
}: {
    batchId: string
    current: string | null
    /** 采购行上买的时候下的那个判断(没挂采购行、或看不见时为 null)。 */
    judged: string | null
    /**
     * 这批货挂没挂采购行。**"没有采购行"与"看不见采购行"是两句话**:
     * 前者是自采/期初这类本来就没有单的货(那时"买的时候判的"根本不存在),
     * 后者是权限问题。并成一句,操作员就不知道该去要权限还是该忽略它。
     */
    hasPoLine: boolean
    /**
     * ★【"看不见"与"没填"必须分开说】★ 采购行躲在 module.purchasing.view 后面
     * (OPS-14 的 xmodule)。一个只有进料权限的人读它会被 RLS 静默丢行,
     * 而那时屏幕若印"未填写",说的就是一句假话 —— 买的人明明判过。
     */
    judgedVisible: boolean
    options: { code: string; label: string }[]
    canEdit: boolean
}) {
    const t = useTranslations()
    const [value, setValue] = useState(current ?? '')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    const labelOf = (c: string | null) =>
        c ? (options.find((o) => o.code === c)?.label ?? c) : null

    // 【矛盾要当场看得见,但它是【告警】,不是拒绝】—— 用蓝色,与
    // material_mismatch 同一套:红在这套界面里意味着"被拒了",而它恰恰没有。
    // 【任一侧是"未评估"或没填时,不下断言】—— 一次差异要两次互相矛盾的主张。
    const bothClaims =
        hasPoLine && judgedVisible &&
        value !== '' && value !== 'not_assessed' &&
        judged !== null && judged !== '' && judged !== 'not_assessed'
    const contradicted = bothClaims && value !== judged

    return (
        <div className="mb-8">
            <h2 className="mb-2">
                {t('inbound.deepDischarge.title')}
            </h2>
            <div className="border border-gray-300 rounded p-3 max-w-2xl">
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('inbound.deepDischarge.help')}</p>

                {/* 【买的时候判的那个值,原样摆在旁边】—— 没有它,操作员看不出
                    自己正在记的东西与谈好的是不是一回事。 */}
                <p className="text-xs mb-2 text-[color:var(--brand-muted-text)]">
                    <span className="text-[color:var(--brand-muted-text)]">{t('inbound.deepDischarge.judged')}: </span>
                    {!hasPoLine ? (
                        /* 没有采购行 —— "买的时候判的"这件事根本不存在 */
                        <span className="text-gray-400">{t('inbound.deepDischarge.judgedNoLine')}</span>
                    ) : judgedVisible ? (
                        <span className={judged ? 'text-gray-800' : 'text-gray-400'}>
                            {labelOf(judged) ?? t('inbound.deepDischarge.judgedNone')}
                        </span>
                    ) : (
                        /* ★ 看不见就【按名说出来】,绝不印成"未填写" ★ */
                        <span className="text-amber-800">{t('inbound.deepDischarge.judgedHidden')}</span>
                    )}
                </p>

                <label className="block mb-1">
                    {t('inbound.deepDischarge.actual')}
                </label>
                {canEdit ? (
                    <select
                        value={value}
                        disabled={pending}
                        onChange={(e) => {
                            const next = e.target.value
                            setValue(next)
                            setError(null)
                            startTransition(async () => {
                                const r = await setDeepDischargeActual(batchId, next)
                                if (r.error) setError(r.error)
                            })
                        }}
                        className={CONTROL_SELECT}
                    >
                        {/* 【空 = 没记过,不是"不能"】文案必须说出这一点 */}
                        <option value="">{t('inbound.deepDischarge.unset')}</option>
                        {options.map((o) => (
                            <option key={o.code} value={o.code}>{o.label}</option>
                        ))}
                    </select>
                ) : (
                    <span className={'text-sm ' + (value ? 'text-gray-800' : 'text-gray-400')}>
                        {labelOf(value === '' ? null : value) ?? t('inbound.deepDischarge.unset')}
                    </span>
                )}

                {/* ★★ POLISH-1(2026-09-12,Tim 的裁定 R12)· info 横幅走库里的 <Alert> ★★
                   R12 的原话:「**只裁那 ~8 条真正的 info 横幅**,而且要在 R8 的横幅
                   形状落地【之后】—— 因为一条白底 + 1px 描边的横幅,可能**根本不需要
                   一个 info 蓝**。」☞ 量下来:**不需要。**
                   `<Alert>` 的 default 档是 `bg-card`(白)+ `text-card-foreground`
                   (`--brand-text #182B4B`,白底 **14.13:1 ✓**),描边取 `currentColor`
                   于是与字同色 —— **「这是一条通知」由那个带描边的盒子说,不由颜色说**。
                   ☞ 所以这一刀**没有**给 `alert.tsx` 新开一个 `info` 档:
                     它今天仍然只有 `default` 与 `destructive` 两档。
                     ★ 少一个没人裁过的状态色,就少一处将来会漂的定义。 */}
                {contradicted && (
                    <Alert className="mt-2">
                        {t('inbound.deepDischarge.contradicted')}
                    </Alert>
                )}
                {error && <p className="mt-2 text-xs text-red-700">{error}</p>}
            </div>
        </div>
    )
}
