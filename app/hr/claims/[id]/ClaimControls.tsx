'use client'

import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { decideClaim, payClaim } from '../actions'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'

/**
 * ★★ BUGFIX-1b(2026-09-12):GST 开着时这条路【一笔费用都开不出来】——
 *    `pay_medical_claim` 不传税码,而员工这一侧永远解析不出默认值。
 *    这一屏因此多一颗税码下拉,预选 `BL`。
 *
 * ★【预选做在这里,不做在函数里】★ 一个写在数据库默认值里的 `BL`,人看不见、
 *   也确认不了 —— 那就是"替人做了一个财务判断"。写在界面上,它是一个
 *   **摆在人面前的建议**:下拉可以改,而且要按一下确认才会生成费用单。
 *   裁定与它的依据(新加坡 GST Reg 26)写在 `docs/accounting-policies.md` §9.1b。
 *
 * ★【为什么报销单那条路【不】预选】`decide_expense_claim` 覆盖的是**任意一类**
 *   支出,那里没有"绝大多数"可言。医疗报销是**一类**支出,它的税务后果在绝大多数
 *   情况下是同一个。**两条路给不同的答案是一次裁定,不是一次疏忽**(Tim 2026-09-12)。
 */
export default function ClaimControls({
    claimId, claimCode, status, alreadyLinked, canFinance, gstRegistered, taxCodes,
}: {
    claimId: string
    /** 单号 —— 确认对话框的主语必须点得出【是哪一张】(CONFIRM-1)。 */
    claimCode: string
    status: string
    alreadyLinked: boolean
    canFinance: boolean
    /** GST 关着时这颗下拉根本不画:传一个税码进去会被 record_expense 按名拒。 */
    gstRegistered: boolean
    /** ★ 与报销单那条路【同一处真源】:tax_codes 里 is_active 且 side='input' 的那些。 */
    taxCodes: { code: string; name_en: string; name_zh: string; is_claimable: boolean }[]
}) {
    const t = useTranslations()
    const locale = useLocale()
    const router = useRouter()
    const [notes, setNotes] = useState('')
    const [date, setDate] = useState(new Date().toISOString().slice(0, 10))
    // ★ 预选 BL —— 而 **BL 不在启用清单里时【不伪造它】**:留空,下面那句提示说出来。
    //   一个预选出来的、其实不存在的税码,会在服务端被 TAX_CODE_UNKNOWN 挡回来,
    //   而屏幕上看起来像是已经选好了。
    const hasBlocked = taxCodes.some((x) => x.code === 'BL')
    const [taxCode, setTaxCode] = useState(hasBlocked ? 'BL' : '')
    const [error, setError] = useState<string | null>(null)
    const [ok, setOk] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    function run(fn: () => Promise<{ error?: string; expenseCode?: string }>) {
        setError(null); setOk(null)
        startTransition(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
            else { if (r.expenseCode) setOk(r.expenseCode); router.refresh() }
        })
    }

    return (
        <div className="rounded border border-gray-200 p-4">
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}
            {ok && <p className="mb-3 text-sm text-green-700">{t('claims.expenseCreated', { 0: ok })}</p>}

            {status === 'submitted' && (
                <>
                    <label className="block mb-3">{t('leave.decisionNotes')}
                        <input value={notes} onChange={(e) => setNotes(e.target.value)}
                               className={`${CONTROL_INPUT} mt-1 w-full`} /></label>
                    <div className="flex gap-3">
                        <Button type="button" disabled={pending}
                                onClick={() => run(() => decideClaim(claimId, true, notes || null))}>
                            {t('leave.approve')}
                        </Button>
                        <Button type="button" disabled={pending}
                                onClick={() => run(() => decideClaim(claimId, false, notes || null))}
                                variant="secondary">
                            {t('leave.reject')}
                        </Button>
                    </div>
                </>
            )}

            {status === 'approved' && !alreadyLinked && (
                <div>
                    <h3 className="mb-1">{t('claims.createExpense')}</h3>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('claims.createExpenseHint')}</p>
                    {/* ★ INPUT-2b:这一行是 flex-wrap —— 一个内在尺寸由内容决定的原生
                        `<select>` 坐在不换行的容器里,就是那条已经付过两次账的危险形状。 */}
                    <div className="flex gap-2 flex-wrap items-end mb-3">
                        <label className="">{t('claims.expenseDate')}
                            <input type="date" value={date} onChange={(e) => setDate(e.target.value)}
                                   className={`${CONTROL_INPUT} block`} /></label>
                        {gstRegistered && (
                            <label className="">{t('claims.taxCode')} <span className="text-red-600">*</span>
                                <select value={taxCode} onChange={(e) => setTaxCode(e.target.value)}
                                        className={`${CONTROL_SELECT} block`}>
                                    {/* BL 不在清单里时才有空占位 —— 否则一个可选的空值等于把预选让回去了。 */}
                                    {!hasBlocked && <option value="">{t('claims.taxCodePick')}</option>}
                                    {taxCodes.map((x) => (
                                        <option key={x.code} value={x.code}>
                                            {x.code} · {locale === 'zh' ? x.name_zh : x.name_en}
                                            {x.is_claimable ? '' : ` — ${t('expense.form.taxCodeBlocked')}`}
                                        </option>
                                    ))}
                                </select></label>
                        )}
                    </div>
                    {gstRegistered && (
                        <p className="mb-3 text-xs text-[color:var(--brand-muted-text)]" data-state-note="claim-tax-code">
                            {hasBlocked ? t('claims.taxCodeHint') : t('claims.taxCodeNoDefault')}
                        </p>
                    )}
                    {/* ★★ ALERT-2d ④(b):`pending || !date` —— 两样东西:
                           · `pending`     瞬态,一秒后自己消失 → 留在 disabled 里,
                                           按钮的字已经说了「保存中…」(CMP-2 只要求
                                           **非瞬态**条件配一行常驻的解释);
                           · `!canFinance` 权限 → <PermissionGate>:点名 module.finance.edit,
                                           并说管理员在 Settings → Roles 里给。
                                           下面那句 needsFinance 【留着】—— 它说的是另一件事
                                           (HR 审、财务转应付,两步两人),是【流程】不是【补救】;
                           · `!date`       【还没填日期】—— 既不是权限也不是记录状态,
                                           它是"还没有东西可操作"那一族。给它写一句拒绝
                                           是假话:该说的是【下一步做什么】。
                           ★ BUGFIX-1b 多了一个同族的:GST 开着而税码还空着(只可能发生在
                             BL 不在启用清单里的时候)—— 同样配了一行常驻的说明,见上面那一段。 */}
                    <PermissionGate code="module.finance.edit" allowed={canFinance} inline>
                        {/* ★★ 预选不等于替人决定 —— 所以这颗钮换成 <ConfirmButton>:
                            对话框**把要用的税码与日期念出来**,人按下的那一下才是那个决定。
                            主语是单号(CONFIRM-1 的必填 subject:一句「生成费用单?」
                            在一张十行的表里答不出"哪一个")。 */}
                        <ConfirmButton
                            subject={claimCode}
                            title={t('claims.confirmRaiseTitle')}
                            body={gstRegistered
                                ? t('claims.confirmRaiseBodyGst', { date, code: taxCode })
                                : t('claims.confirmRaiseBody', { date })}
                            confirmLabel={t('claims.createExpense')}
                            triggerVariant="default"
                            disabled={pending || !date || (gstRegistered && !taxCode)}
                            onConfirm={() => run(() => payClaim(claimId, date, gstRegistered ? taxCode : null))}>
                            {pending ? t('common.saving') : t('claims.createExpense')}
                        </ConfirmButton>
                    </PermissionGate>
                    {!date && (
                        <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]" data-state-note="claim-date">
                            {t('claims.needExpenseDate')}
                        </p>
                    )}
                    {!canFinance && <p className="mt-2 text-xs text-amber-800">{t('claims.needsFinance')}</p>}
                </div>
            )}
        </div>
    )
}
