'use client'

// app/finance/wht/WhtControls.tsx
// WHT-1:汇缴控件。**禁用一律说出为什么**(CMP-2 的规矩);拒绝就地显示。
// ★ PAY-REQ-1 · Batch B:它提的是一张【缴纳申请】(CFO 批准后由财务在申请页上执行,
//   执行时给实际缴纳日);成功由 action 跳到那张申请。日期因此是【计划】缴纳日。
import { CONTROL_SELECT, CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { submitWhtRemittanceRequest, requestWhtReversal } from './actions'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

type Month = { month: string; label: string; amount: string }

export function RemitControl({ months ,
canEdit
}: { months: Month[] 
canEdit: boolean
}) {
    const t = useTranslations()
    const [month, setMonth] = useState('')
    const [on, setOn] = useState('')
    const [ref, setRef] = useState('')
    const [bank, setBank] = useState('')
    const [notes, setNotes] = useState('')
    const [err, setErr] = useState('')
    const [busy, start] = useTransition()

    // 【没有欠款时不给按钮,而是说出为什么】一个点下去只会得到
    // WHT_NOTHING_TO_REMIT 的按钮,是本仓库记过的那条
    // "页面不该 offer 一个服务端一定会拒的动作"。
    if (months.length === 0) {
        return (
            <p className="text-sm text-[color:var(--brand-muted-text)]">{t('wht.noneTitle')}</p>
        )
    }

    // 【日期不预填今天】它决定这笔汇缴进哪个会计期间,而一个默认成今天的日期
    // 永远撞不上 PERIOD_LOCKED —— 于是留空反而比填对更容易过关(FIN-10)。
    const incomplete = !month || !on || !ref.trim()

    return (
        <div className="border border-gray-300 rounded p-4">
            <div className="flex flex-wrap items-end gap-3">
                <div>
                    <label className="block mb-1">{t('wht.remitMonth')}</label>
                    <select value={month} onChange={(e) => setMonth(e.target.value)}
                            name="period_month"
                            className={CONTROL_SELECT}>
                        <option value="">—</option>
                        {months.map((m) => (
                            <option key={m.month} value={m.month}>{m.label} · {m.amount}</option>
                        ))}
                    </select>
                </div>
                <div>
                    <label className="block mb-1">{t('wht.remitPlannedOn')}</label>
                    <input type="date" value={on} onChange={(e) => setOn(e.target.value)}
                           className={CONTROL_INPUT} />
                </div>
                <div>
                    <label className="block mb-1">{t('wht.remitReference')}</label>
                    <input value={ref} onChange={(e) => setRef(e.target.value)}
                           placeholder={t('wht.remitReferenceHint')}
                           className={CONTROL_INPUT} />
                </div>
                <div>
                    <label className="block mb-1">{t('wht.remitBank')}</label>
                    {/* 【币种是数据,不是这里的字面量】账户码本身是科目码,不是币种;
                        本位币户之外的账户由服务端按名拒(WHT_REMIT_BANK_NOT_BASE)。 */}
                    <input value={bank} onChange={(e) => setBank(e.target.value)}
                           placeholder="1000"
                           className={`${CONTROL_INPUT} w-24`} />
                </div>
                <div className="grow">
                    <label className="block mb-1">{t('wht.remitNotes')}</label>
                    <input value={notes} onChange={(e) => setNotes(e.target.value)}
                           className={`${CONTROL_INPUT} w-full`} />
                </div>
            </div>

            <div className="mt-3 flex items-center gap-3">
                <PermissionGate code="module.finance.edit" allowed={canEdit}>
                <Button type="button" disabled={incomplete || busy}
                        onClick={() => start(async () => {
                            const r = await submitWhtRemittanceRequest(month, on, ref, bank, notes)
                            if (r?.error) setErr(r.error)
                        })}>
                    {busy ? t('common.saving') : t('wht.remitSubmitRequest')}
                </Button>
                </PermissionGate>
                {/* 【禁用要说出理由,而不是把控件藏起来】 */}
                {incomplete && (
                    <span className="text-sm text-amber-700">
                        {t('wht.remitReferenceHint')}
                    </span>
                )}
            </div>
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('wht.remitRequestNotice')}</p>
            {err && <p className="text-sm text-red-700 mt-2">{err}</p>}
        </div>
    )
}

// ★ PAY-REQ-1 · Batch B(Tim 的 Q3):更正一笔缴纳 —— 提一张冲销申请(理由必填);
//   CFO 批准后由财务在申请页上执行并给出冲销日。通用冲销口对它关了门。
export function RequestWhtReversalButton({ remittanceId, code, canEdit }: {
    remittanceId: string; code: string; canEdit: boolean
}) {
    const t = useTranslations()
    const [pending, start] = useTransition()
    return (
        <PermissionGate code="module.finance.edit" allowed={canEdit}>
            <ConfirmButton
                subject={code}
                title={t('wht.requestReversalConfirm')}
                body={t('wht.requestReversalBody')}
                confirmLabel={t('finance.requestReversal')}
                tier="reversal"
                reason={{ placeholder: t('finance.requestReversalPlaceholder') }}
                triggerVariant="reversal"
                disabled={pending}
                onConfirm={(reason) => start(async () => {
                    const r = await requestWhtReversal(remittanceId, reason)
                    if (r?.error) {
                        showActionMessage({
                            subject: code,
                            headline: t('common.actionMessage.headline.notReversalRequested'),
                            body: r.error,
                            detail: r.detail,
                        })
                    }
                })}
            >
                {pending ? t('common.saving') : t('finance.requestReversal')}
            </ConfirmButton>
        </PermissionGate>
    )
}
