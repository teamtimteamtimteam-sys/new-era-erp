'use client'

// SO-1:新建销售订单。
// 【信用面板在录入之前就在】—— 一张对被冻结客户的订单会在确认那一步被按名拒
// (SO_CUSTOMER_ON_HOLD),但让人填完整张单再告诉他,是把一次可以提前给出的
// 答复推到最后。所以选完客户就把限额/敞口/余额/冻结画出来。
// 【受限 ≠ 零】没有 module.customers.view 的读者看到的是「受限」,不是 0 ——
// 0 在信用面板上读作"没有限额、余额充足"(SAL-B6 的原话)。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { createSalesOrder, type OrderFormState } from '../actions'
import type { CreditRow } from '../salesOrderTypes'
import { Button } from '@/app/components/ui/button'

const initialState: OrderFormState = {}
const LINE_SLOTS = 5

export default function NewOrderForm({
    customers, materials, currencies, credit, canSeeCredit,
}: {
    customers: { id: string; code: string; legal_name: string }[]
    materials: { id: string; code: string; name: string }[]
    currencies: string[]
    credit: CreditRow[]
    canSeeCredit: boolean
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createSalesOrder, initialState)
    const [customerId, setCustomerId] = useState('')
    const [orderDate, setOrderDate] = useState('')

    const row = customerId ? credit.find((c) => c.customer_id === customerId) ?? null : null
    const blocked = row?.sales_blocked === true
    const restricted = customerId !== '' && !canSeeCredit

    return (
        <div className="p-8 max-w-3xl">
            <div className="mb-6">
                <Link href="/sales/orders" className="text-blue-600 hover:underline text-sm">{t('common.back')}</Link>
            </div>
            <h1 className="text-2xl font-bold mb-6">{t('sales.newTitle')}</h1>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">{state.error}</div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 客户(必填)—— 订单的主语 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('sales.form.customer')} <span className="text-red-600">*</span>
                    </label>
                    <select name="customer_id" value={customerId} onChange={(e) => setCustomerId(e.target.value)}
                            required className="w-full border border-gray-300 px-3 py-2 rounded">
                        <option value="">{t('sales.form.selectCustomer')}</option>
                        {customers.map((c) => (
                            <option key={c.id} value={c.id}>{c.code} — {c.legal_name}</option>
                        ))}
                    </select>
                    {state.fieldErrors?.customer_id && (
                        <p className="text-red-600 text-xs mt-1">{state.fieldErrors.customer_id}</p>
                    )}
                    <p className="text-xs text-gray-500 mt-1">{t('sales.form.customerWhy')}</p>
                </div>

                {/* 信用面板 */}
                {customerId && (
                    <div className={'border rounded px-4 py-3 text-sm ' +
                        (blocked ? 'border-red-400 bg-red-50' : 'border-gray-300 bg-gray-50')}>
                        {restricted ? (
                            <p className="text-gray-600">{t('common.restricted')}</p>
                        ) : row ? (
                            <>
                                <div className="flex flex-wrap gap-x-6 gap-y-1">
                                    <span>{t('sales.credit.limit')}: {row.credit_limit_base ?? t('sales.credit.none')}</span>
                                    <span>{t('sales.credit.exposure')}: {row.exposure_base ?? '—'}</span>
                                    <span>{t('sales.credit.headroom')}: {row.headroom_base ?? '—'}</span>
                                </div>
                                {row.credit_hold && (
                                    <p className="text-red-700 mt-2">{t('sales.credit.onHold')}</p>
                                )}
                            </>
                        ) : (
                            <p className="text-gray-600">{t('sales.credit.noRow')}</p>
                        )}
                    </div>
                )}

                {/* 订单日 —— 物理事件日,永不默认 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('sales.form.orderDate')} <span className="text-red-600">*</span>
                    </label>
                    <input type="date" name="order_date" value={orderDate}
                           onChange={(e) => setOrderDate(e.target.value)} required
                           className="w-full border border-gray-300 px-3 py-2 rounded" />
                    {state.fieldErrors?.order_date && (
                        <p className="text-red-600 text-xs mt-1">{state.fieldErrors.order_date}</p>
                    )}
                    <p className="text-xs text-gray-500 mt-1">{t('sales.form.orderDateWhy')}</p>
                </div>

                <div className="grid grid-cols-2 gap-4">
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('sales.form.currency')} <span className="text-red-600">*</span></label>
                        <select name="currency" required className="w-full border border-gray-300 px-3 py-2 rounded">
                            {currencies.map((c) => <option key={c} value={c}>{c}</option>)}
                        </select>
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('sales.form.fxRate')} <span className="text-red-600">*</span></label>
                        <input type="number" step="any" min="0" name="fx_rate" required
                               className="w-full border border-gray-300 px-3 py-2 rounded" />
                        {state.fieldErrors?.fx_rate && (
                            <p className="text-red-600 text-xs mt-1">{state.fieldErrors.fx_rate}</p>
                        )}
                        {/* FIN-35:没有默认值是有意的 */}
                        <p className="text-xs text-gray-500 mt-1">{t('sales.form.fxRateWhy')}</p>
                    </div>
                </div>

                {/* 行 */}
                <div>
                    <label className="block text-sm font-medium mb-2">{t('sales.form.lines')}</label>
                    {state.fieldErrors?.lines && (
                        <p className="text-red-600 text-xs mb-2">{state.fieldErrors.lines}</p>
                    )}
                    <div className="space-y-2">
                        {Array.from({ length: LINE_SLOTS }, (_, i) => (
                            <div key={i} className="flex gap-2">
                                <select name={`line_material_${i}`} className="flex-1 border border-gray-300 px-2 py-1 rounded text-sm">
                                    <option value="">{t('sales.form.selectMaterial')}</option>
                                    {materials.map((m) => <option key={m.id} value={m.id}>{m.code} — {m.name}</option>)}
                                </select>
                                <input type="number" step="any" min="0" name={`line_qty_${i}`}
                                       placeholder={t('sales.form.qty')} className="w-28 border border-gray-300 px-2 py-1 rounded text-sm" />
                                <input type="number" step="any" min="0" name={`line_price_${i}`}
                                       placeholder={t('sales.form.unitPrice')} className="w-32 border border-gray-300 px-2 py-1 rounded text-sm" />
                            </div>
                        ))}
                    </div>
                    <p className="text-xs text-gray-500 mt-1">{t('sales.form.linesWhy')}</p>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('sales.form.notes')}</label>
                    <textarea name="notes" rows={3} className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>

                {/* 【草稿,不是承诺】保存只建草稿;确认是另一步,而确认才会冻结 */}
                <p className="text-sm text-gray-600">{t('sales.form.savesAsDraft')}</p>
                {!orderDate && <p className="text-sm text-amber-700">{t('sales.form.blockedOrderDate')}</p>}

                <div className="flex gap-3 pt-2">
                    <Button type="submit" disabled={isPending || !orderDate || !customerId}>
                        {isPending ? t('common.saving') : t('common.save')}
                    </Button>
                    <Link href="/sales/orders" className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50">
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </div>
    )
}
