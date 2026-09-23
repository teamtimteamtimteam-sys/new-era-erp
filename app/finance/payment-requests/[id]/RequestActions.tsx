'use client'

// app/finance/payment-requests/[id]/RequestActions.tsx
// PAY-REQ-1(Tim 2026-09-23):一张付款申请上的动作 —— 批准 / 驳回、撤回、付款。
//
// 【谁能批,这里不预判】二级审批角色、而且不是提单人 —— 两条都只有数据库知道
// (decide_payment_request → require_approver_for(2) + forbid_self_approval)。
// 与采购单的 ApprovalControls 同一条:钮亮着,拒绝由库出,就地说成人话。
// 页面对同一条规矩再写一份,是本仓库付过四次账的形状。
//
// 【权限的那一半看得见、按不动、带理由】(DBLOCK-1)—— 批/驳要 data.view_prices
// (能进这一页的人已经持有 module.finance.view,那是另一半);撤回与付款要 module.finance.edit。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { PaymentDateInput } from '@/app/components/finance/PaymentDateInput'
import { decidePaymentRequest, withdrawPaymentRequest, payPaymentRequest } from './actions'

export default function RequestActions({
    requestId,
    code,
    kind,
    status,
    canEdit,
    canDecide,
}: {
    requestId: string
    code: string
    kind: string
    status: string
    canEdit: boolean
    canDecide: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [payDate, setPayDate] = useState('')
    const [fxRate, setFxRate] = useState('')

    function run(headline: string, fn: () => Promise<{ error?: string; detail?: string }>) {
        start(async () => {
            const r = await fn()
            if (r?.error) {
                showActionMessage({ subject: code, headline, body: r.error, detail: r.detail })
                return
            }
            router.refresh()
        })
    }

    const isOut = kind === 'payment_out'
    // 出款的付款日必填 —— 空着就按不下去,并且把理由摆在旁边(CMP-2 的房规)。
    const payBlocked = isOut && payDate.trim() === ''

    return (
        <div className="space-y-4">
            {status === 'submitted' && (
                <section className="border border-amber-300 bg-amber-50 rounded p-4">
                    <h2 className="mb-1">{t('finance.paymentRequests.decideTitle')}</h2>
                    <p className="text-xs text-[color:var(--brand-text)] mb-3">{t('finance.paymentRequests.decideHint')}</p>
                    <PermissionGate code="data.view_prices" allowed={canDecide}>
                        <div className="flex flex-wrap items-start gap-3">
                            <ConfirmButton
                                subject={code}
                                title={t('finance.paymentRequests.approveConfirm')}
                                body={t('finance.paymentRequests.approveBody')}
                                confirmLabel={t('finance.paymentRequests.approve')}
                                tier="default"
                                triggerVariant="default"
                                disabled={pending}
                                onConfirm={() => run(t('common.actionMessage.headline.notDecided'),
                                    () => decidePaymentRequest(requestId, true, ''))}
                            >
                                {pending ? t('common.saving') : t('finance.paymentRequests.approve')}
                            </ConfirmButton>
                            <ConfirmButton
                                subject={code}
                                title={t('finance.paymentRequests.rejectConfirm')}
                                body={t('finance.paymentRequests.rejectBody')}
                                confirmLabel={t('finance.paymentRequests.reject')}
                                tier="destructive"
                                reason={{ placeholder: t('finance.paymentRequests.rejectPlaceholder') }}
                                triggerVariant="destructive"
                                disabled={pending}
                                onConfirm={(reason) => run(t('common.actionMessage.headline.notDecided'),
                                    () => decidePaymentRequest(requestId, false, reason))}
                            >
                                {t('finance.paymentRequests.reject')}
                            </ConfirmButton>
                        </div>
                    </PermissionGate>
                </section>
            )}

            {status === 'approved' && (
                <section className="border border-blue-300 bg-blue-50 rounded p-4">
                    <h2 className="mb-1">{t('finance.paymentRequests.payTitle')}</h2>
                    <p className="text-xs text-[color:var(--brand-text)] mb-3">
                        {isOut ? t('finance.paymentRequests.payHint') : t('finance.paymentRequests.payReversalHint')}
                    </p>
                    <PermissionGate code="module.finance.edit" allowed={canEdit}>
                        <div className="flex flex-wrap items-end gap-4">
                            {isOut && (
                                <>
                                    <div>
                                        <label className="block mb-1">
                                            {t('finance.paymentDate')} <span className="text-red-600">*</span>
                                        </label>
                                        <PaymentDateInput name="payment_date" value={payDate} onChange={setPayDate} />
                                    </div>
                                    <div>
                                        <label className="block mb-1">{t('finance.paymentRequests.dealtRate')}</label>
                                        <DecimalInput name="fx_rate" value={fxRate} onChange={setFxRate} className="w-32" />
                                    </div>
                                </>
                            )}
                            <ConfirmButton
                                subject={code}
                                title={isOut ? t('finance.paymentRequests.payConfirm') : t('finance.paymentRequests.payReversalConfirm')}
                                body={isOut
                                    ? t('finance.paymentRequests.payBody', { date: payDate })
                                    : t('finance.paymentRequests.payReversalBody')}
                                confirmLabel={isOut ? t('finance.paymentRequests.pay') : t('finance.paymentRequests.payReversal')}
                                tier={isOut ? 'default' : 'reversal'}
                                triggerVariant={isOut ? 'default' : 'reversal'}
                                disabled={pending || payBlocked}
                                onConfirm={() => run(t('common.actionMessage.headline.notPaid'),
                                    () => payPaymentRequest(requestId, payDate, fxRate))}
                            >
                                {pending ? t('common.saving')
                                    : isOut ? t('finance.paymentRequests.pay') : t('finance.paymentRequests.payReversal')}
                            </ConfirmButton>
                        </div>
                        {isOut && <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('finance.paymentRequests.dealtRateHint')}</p>}
                        {payBlocked && <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('finance.paymentRequests.payNeedDate')}</p>}
                    </PermissionGate>
                </section>
            )}

            {(status === 'submitted' || status === 'approved') && (
                <PermissionGate code="module.finance.edit" allowed={canEdit}>
                    <ConfirmButton
                        subject={code}
                        title={t('finance.paymentRequests.withdrawConfirm')}
                        body={t('finance.paymentRequests.withdrawBody')}
                        confirmLabel={t('finance.paymentRequests.withdraw')}
                        tier="reversal"
                        triggerVariant="outline"
                        disabled={pending}
                        onConfirm={() => run(t('common.actionMessage.headline.notRequestWithdrawn'),
                            () => withdrawPaymentRequest(requestId))}
                    >
                        {t('finance.paymentRequests.withdraw')}
                    </ConfirmButton>
                </PermissionGate>
            )}
        </div>
    )
}
