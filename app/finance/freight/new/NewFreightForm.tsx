'use client'

// 运费单录入表单(FRT-1)。
//
// 【口径是一次选择,不是一个默认值】weight / value / stated 三选一,表单上必须
// 明写选了哪一个 —— 与 allocation_basis 同一条(FIN-36:看得见的默认值才不是假设)。
// 【重量与货值恰恰在最要紧的时候分歧最大】:一批轻而贵的货与一批重而便宜的货同船,
// 两种口径给出的答案差得最远。这句话印在表单上,不是藏在文档里。
//
// 【本表单不自己算分摊】金额、拆账、过账全由 record_freight_document 决定;
// 这里只把选择送下去。两份算术会在写下的那天一致,此后各自漂移。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { createFreightDocument, type FreightState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'

export type BatchOption = {
    id: string
    code: string
    quantity: number
    unit: string
    remaining_qty: number
    unit_price: number | null
    arrival_date: string | null
}

const initialState: FreightState = {}

export default function NewFreightForm({
    suppliers,
    batches,
    currencies,
    baseCurrency,
}: {
    suppliers: { id: string; code: string; legal_name: string }[]
    batches: BatchOption[]
    currencies: string[]
    baseCurrency: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createFreightDocument, initialState)
    const [basis, setBasis] = useState('weight')
    const [paid, setPaid] = useState(false)
    const [picked, setPicked] = useState<Record<string, boolean>>({})
    const [stated, setStated] = useState<Record<string, string>>({})
    const [amount, setAmount] = useState('')

    const chosen = batches.filter((b) => picked[b.id])
    // value 口径遇未计价批次:服务端会点名拒 —— 页面【先说出来】,
    // 不把一张注定被拒的表单摆到人面前(CMP-2 的规矩)
    const unpriced = basis === 'value' ? chosen.filter((b) => b.unit_price === null) : []

    return (
        <div className="max-w-4xl">
            <div className="mb-6">
                <Link href="/finance/freight" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-2">{t('finance.freight.newTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6 max-w-3xl">{t('finance.freight.newIntro')}</p>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                <div className="flex flex-wrap gap-4">
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('finance.freight.colDate')} <span className="text-red-600">*</span>
                        </label>
                        <input type="date" name="doc_date" required
                            className="border border-gray-300 px-3 py-2 rounded" />
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('finance.freight.colForwarder')} <span className="text-red-600">*</span>
                        </label>
                        <select name="supplier_id" required defaultValue=""
                            className="border border-gray-300 px-3 py-2 rounded min-w-64">
                            <option value="" disabled>{t('finance.freight.selectForwarder')}</option>
                            {suppliers.map((s) => (
                                <option key={s.id} value={s.id}>{s.legal_name}</option>
                            ))}
                        </select>
                        {/* 【货代,不是材料供应商】—— 未付运费的应付记在这个人名下 */}
                        <p className="text-xs text-gray-500 mt-1">{t('finance.freight.forwarderHint')}</p>
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('finance.freight.colAmount')} <span className="text-red-600">*</span>
                        </label>
                        <div className="flex gap-2">
                            <DecimalInput name="amount" value={amount} onChange={setAmount}
                                className="w-40 border border-gray-300 px-3 py-2 rounded" />
                            <select name="currency" defaultValue={baseCurrency}
                                className="border border-gray-300 px-3 py-2 rounded">
                                {currencies.map((c) => (
                                    <option key={c} value={c}>{c}</option>
                                ))}
                            </select>
                        </div>
                    </div>
                </div>

                {/* 口径:一次明写的选择 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('finance.freight.colBasis')} <span className="text-red-600">*</span>
                    </label>
                    <select name="allocation_basis" value={basis} onChange={(e) => setBasis(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded">
                        <option value="weight">{t('finance.freight.basis.weight')}</option>
                        <option value="value">{t('finance.freight.basis.value')}</option>
                        <option value="stated">{t('finance.freight.basis.stated')}</option>
                    </select>
                    <p className="text-xs text-gray-600 mt-1 max-w-3xl">{t('finance.freight.basisHint')}</p>
                </div>

                {/* 付款方式 */}
                <div className="flex flex-wrap gap-4 items-end">
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('finance.freight.colPayment')}</label>
                        <select name="payment_status" value={paid ? 'paid' : 'unpaid'}
                            onChange={(e) => setPaid(e.target.value === 'paid')}
                            className="border border-gray-300 px-3 py-2 rounded">
                            <option value="unpaid">{t('finance.freight.payment.unpaid')}</option>
                            <option value="paid">{t('finance.freight.payment.paid')}</option>
                        </select>
                    </div>
                    {paid && (
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('finance.freight.colBank')}</label>
                            <select name="bank_account_code" defaultValue="1000"
                                className="border border-gray-300 px-3 py-2 rounded">
                                <option value="1000">1000</option>
                                <option value="1010">1010</option>
                            </select>
                        </div>
                    )}
                </div>

                {/* 批次 */}
                <div>
                    <p className="block text-sm font-medium mb-1">{t('finance.freight.pickBatches')}</p>
                    <p className="text-xs text-gray-600 mb-2">{t('finance.freight.pickBatchesHint')}</p>
                    {unpriced.length > 0 && (
                        <div className="bg-amber-50 border border-amber-300 text-amber-900 px-3 py-2 rounded mb-2 text-sm">
                            {t('finance.freight.unpricedWarning', { codes: unpriced.map((b) => b.code).join(', ') })}
                        </div>
                    )}
                    <div className="border border-gray-300 rounded max-h-96 overflow-y-auto">
                        <table className="w-full border-collapse">
                            <thead className="bg-gray-100 sticky top-0">
                                <tr>
                                    <th className="px-3 py-2 text-left w-10" />
                                    <th className="px-3 py-2 text-left">{t('finance.freight.colBatch')}</th>
                                    <th className="px-3 py-2 text-right">{t('finance.freight.colQty')}</th>
                                    <th className="px-3 py-2 text-right">{t('finance.freight.colRemaining')}</th>
                                    {basis === 'stated' && (
                                        <th className="px-3 py-2 text-right">{t('finance.freight.colShare')}</th>
                                    )}
                                </tr>
                            </thead>
                            <tbody>
                                {batches.map((b) => (
                                    <tr key={b.id} className="border-t border-gray-200">
                                        <td className="px-3 py-2">
                                            <input type="checkbox" checked={!!picked[b.id]}
                                                onChange={(e) => setPicked((p) => ({ ...p, [b.id]: e.target.checked }))} />
                                            {picked[b.id] && <input type="hidden" name="batch_id" value={b.id} />}
                                        </td>
                                        <td className="px-3 py-2 font-mono text-sm">{b.code}</td>
                                        <td className="px-3 py-2 text-right font-mono text-sm">{b.quantity} {b.unit}</td>
                                        <td className="px-3 py-2 text-right font-mono text-sm">{b.remaining_qty}</td>
                                        {basis === 'stated' && (
                                            <td className="px-3 py-2 text-right">
                                                {picked[b.id] && (
                                                    <DecimalInput name="stated_amount"
                                                        value={stated[b.id] ?? ''}
                                                        onChange={(raw) => setStated((s) => ({ ...s, [b.id]: raw }))}
                                                        className="w-32 border border-gray-300 px-2 py-1 rounded" />
                                                )}
                                            </td>
                                        )}
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('finance.freight.colNotes')}</label>
                    <textarea name="notes" rows={2} className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>

                <div className="flex gap-3 pt-2">
                    <button type="submit" disabled={isPending || chosen.length === 0}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400">
                        {isPending ? t('common.saving') : t('common.save')}
                    </button>
                    <Link href="/finance/freight"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50">
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </div>
    )
}
