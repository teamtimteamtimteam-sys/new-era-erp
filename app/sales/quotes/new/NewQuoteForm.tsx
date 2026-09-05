'use client'

// SO-4b:新建报价的表单。形状取自 /sales/orders/new,三处 why-line 逐字同源:
//   * 两个日期【永不默认】—— 物理承诺日;补一个今天会让"留空"比"填对"更容易通过,
//     而一个补出来的有效期永远不会在它该过期的那天过期;
//   * 汇率【没有默认值】(FIN-35)—— 假设出来的 1:1 在非本位币单据上永远是错的,
//     而且看起来完全正常;
//   * 行指向【物料】,不指向批次 —— 报价的时候那批货可能还没生产出来。
//
// 【保存出来的是一张草稿】签发是另一步,而签发才是"发给对方"这件事本身。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { createQuote, type QuoteFormState } from '../actions'
import { Button } from '@/app/components/ui/button'

const initialState: QuoteFormState = {}
const LINE_SLOTS = 5

export default function NewQuoteForm({
    customers, materials, currencies,
}: {
    customers: { id: string; code: string; legal_name: string }[]
    materials: { id: string; code: string; name: string }[]
    currencies: string[]
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createQuote, initialState)
    const [quoteDate, setQuoteDate] = useState('')
    const [validUntil, setValidUntil] = useState('')

    // 【两个日期都空着就不给按】它们都决定一件真实的事,而服务端也【独立】拒空
    // (AGENTS.md:两道闸,UI 那道不是保护)。
    const blocked = quoteDate.trim() === '' || validUntil.trim() === ''

    return (
        <div className="p-8 max-w-3xl">
            <div className="mb-6">
                <Link href="/sales/quotes" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-6">{t('quotes.newTitle')}</h1>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('quotes.form.customer')} <span className="text-red-600">*</span>
                    </label>
                    <select name="customer_id" required defaultValue=""
                            className="w-full border border-gray-300 px-3 py-2 rounded">
                        <option value="">{t('sales.form.selectCustomer')}</option>
                        {customers.map((c) => (
                            <option key={c.id} value={c.id}>{c.code} — {c.legal_name}</option>
                        ))}
                    </select>
                    {state.fieldErrors?.customer_id && (
                        <p className="text-xs text-red-600 mt-1">{state.fieldErrors.customer_id}</p>
                    )}
                    <p className="text-xs text-gray-500 mt-1">{t('quotes.form.customerWhy')}</p>
                </div>

                <div className="flex flex-wrap gap-4">
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('quotes.form.quoteDate')} <span className="text-red-600">*</span>
                        </label>
                        <input type="date" name="quote_date" value={quoteDate}
                               onChange={(e) => setQuoteDate(e.target.value)}
                               className="border border-gray-300 px-3 py-2 rounded" />
                        {state.fieldErrors?.quote_date && (
                            <p className="text-xs text-red-600 mt-1">{state.fieldErrors.quote_date}</p>
                        )}
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('quotes.form.validUntil')} <span className="text-red-600">*</span>
                        </label>
                        <input type="date" name="valid_until" value={validUntil}
                               onChange={(e) => setValidUntil(e.target.value)}
                               className="border border-gray-300 px-3 py-2 rounded" />
                        {state.fieldErrors?.valid_until && (
                            <p className="text-xs text-red-600 mt-1">{state.fieldErrors.valid_until}</p>
                        )}
                    </div>
                </div>
                <p className="text-xs text-gray-500">{t('quotes.form.datesWhy')}</p>

                <div className="flex flex-wrap gap-4">
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('sales.form.currency')} <span className="text-red-600">*</span>
                        </label>
                        <select name="currency" required defaultValue=""
                                className="border border-gray-300 px-3 py-2 rounded">
                            <option value="">—</option>
                            {currencies.map((c) => (<option key={c} value={c}>{c}</option>))}
                        </select>
                        {state.fieldErrors?.currency && (
                            <p className="text-xs text-red-600 mt-1">{state.fieldErrors.currency}</p>
                        )}
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('sales.form.fxRate')} <span className="text-red-600">*</span>
                        </label>
                        <input type="number" step="any" min="0" name="fx_rate"
                               className="border border-gray-300 px-3 py-2 rounded" />
                        {state.fieldErrors?.fx_rate && (
                            <p className="text-xs text-red-600 mt-1">{state.fieldErrors.fx_rate}</p>
                        )}
                    </div>
                </div>
                <p className="text-xs text-gray-500">{t('sales.form.fxRateWhy')}</p>

                <h2 className="font-medium pt-2">{t('sales.form.lines')}</h2>
                <p className="text-xs text-gray-500">{t('quotes.form.linesWhy')}</p>
                {state.fieldErrors?.lines && (
                    <p className="text-xs text-red-600">{state.fieldErrors.lines}</p>
                )}
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-2 py-2 text-left">{t('sales.colMaterial')}</th>
                            <th className="border border-gray-300 px-2 py-2 text-right">{t('sales.form.qty')}</th>
                            <th className="border border-gray-300 px-2 py-2 text-right">{t('sales.form.unitPrice')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {Array.from({ length: LINE_SLOTS }, (_, i) => (
                            <tr key={i}>
                                <td className="border border-gray-300 px-2 py-2">
                                    <select name={`line_material_${i}`} defaultValue=""
                                            className="w-full border border-gray-300 px-2 py-1 rounded">
                                        <option value="">{t('sales.form.selectMaterial')}</option>
                                        {materials.map((m) => (
                                            <option key={m.id} value={m.id}>{m.code} — {m.name}</option>
                                        ))}
                                    </select>
                                </td>
                                <td className="border border-gray-300 px-2 py-2 text-right">
                                    <input type="number" step="any" min="0" name={`line_qty_${i}`}
                                           className="w-28 border border-gray-300 px-2 py-1 rounded text-right" />
                                </td>
                                <td className="border border-gray-300 px-2 py-2 text-right">
                                    <input type="number" step="any" min="0" name={`line_price_${i}`}
                                           className="w-28 border border-gray-300 px-2 py-1 rounded text-right" />
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('sales.form.notes')}</label>
                    <textarea name="notes" rows={2}
                              className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('quotes.form.terms')}</label>
                    <textarea name="terms_text" rows={3}
                              className="w-full border border-gray-300 px-3 py-2 rounded" />
                    <p className="text-xs text-gray-500 mt-1">{t('quotes.form.termsWhy')}</p>
                </div>

                <p className="text-xs text-gray-600">{t('quotes.form.savesAsDraft')}</p>
                <div className="flex gap-3 pt-2">
                    <Button type="submit" disabled={isPending || blocked}>
                        {isPending ? t('common.saving') : t('quotes.form.save')}
                    </Button>
                    <Link href="/sales/quotes"
                          className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50">
                        {t('common.cancel')}
                    </Link>
                </div>
                {blocked && <p className="text-xs text-amber-700">{t('quotes.form.blockedDates')}</p>}
            </form>
        </div>
    )
}
