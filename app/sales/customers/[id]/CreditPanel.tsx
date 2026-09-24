'use client'

// ROLE-1 Batch 2a(Tim,Q11):客户信用限额与冻结的【唯一】编辑处 —— 客户页上单独一块,
// 不再是客户编辑表单里的两格。CFO 一个(action.customer_credit);没有这个码的人
// 看得见这一块、按不下,并且在按之前就看见缺的是哪个码(DBLOCK-1 · PermissionGate)。
import { useActionState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT, CONTROL_CHECKBOX } from '@/app/components/ui/control-style'
import { setCustomerCredit, type CreditState } from '../creditActions'

export default function CreditPanel({
    customerId,
    creditLimitBase,
    creditHold,
    canSetCredit,
}: {
    customerId: string
    creditLimitBase: number | null
    creditHold: boolean
    /** 由页面 `can('action.customer_credit')` 算好传进来 —— 判据只有一份实现。 */
    canSetCredit: boolean
}) {
    const t = useTranslations()
    const [state, action, pending] = useActionState<CreditState, FormData>(
        setCustomerCredit.bind(null, customerId), {})

    return (
        <form action={action} className="mt-3 max-w-md space-y-3" data-credit-panel="1">
            <h3 className="text-sm font-medium">{t('customers.creditPanel.title')}</h3>
            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('customers.creditPanel.who')}</p>
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded text-sm" role="alert">
                    {state.error}
                    {state.detail && <div className="text-xs mt-1 opacity-80">{state.detail}</div>}
                </div>
            )}
            {state.success && (
                <p className="text-sm text-green-700" role="status">{t('customers.creditPanel.saved')}</p>
            )}
            <PermissionGate code="action.customer_credit" allowed={canSetCredit}>
                <div>
                    <label className="block mb-1" htmlFor="credit_limit_base">{t('customers.form.creditLimit')}</label>
                    {/* SAL-B:【留空 = 没设限额(放行);0 = 现款现货(任何赊销都拒)—— 相反,不是相近】 */}
                    <input
                        id="credit_limit_base"
                        type="number"
                        step="0.01"
                        min="0"
                        name="credit_limit_base"
                        defaultValue={creditLimitBase ?? ''}
                        placeholder={t('customers.form.creditLimitPlaceholder')}
                        className={`${CONTROL_INPUT} w-full`}
                    />
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('customers.form.creditLimitHint')}</p>
                </div>
                <div>
                    <label className="inline-flex items-center gap-2">
                        <input type="checkbox" className={CONTROL_CHECKBOX} name="credit_hold" defaultChecked={creditHold} />
                        {t('customers.form.creditHold')}
                    </label>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('customers.form.creditHoldHint')}</p>
                </div>
                <Button type="submit" disabled={pending}>
                    {pending ? t('common.saving') : t('customers.creditPanel.save')}
                </Button>
            </PermissionGate>
        </form>
    )
}
