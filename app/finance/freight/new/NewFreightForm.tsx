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
import { Button } from '@/app/components/ui/button'

export type BatchOption = {
    id: string
    code: string
    quantity: number
    unit: string
    remaining_qty: number
    unit_price: number | null
    arrival_date: string | null
}

export type ContainerOption = {
    id: string
    code: string
    lane: string | null
    departure_date: string
}

const initialState: FreightState = {}

export default function NewFreightForm({
    suppliers,
    batches,
    currencies,
    baseCurrency,
    containers,
}: {
    suppliers: { id: string; code: string; legal_name: string }[]
    batches: BatchOption[]
    currencies: string[]
    baseCurrency: string
    containers: ContainerOption[]
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createFreightDocument, initialState)
    // LOG-4b:【方向不是一个标签,它决定这笔钱去哪里】。没有默认成"进货"的诱惑:
    // 两个都摆出来,人选一个 —— 与 allocation_basis 同一条(FIN-36)。
    const [direction, setDirection] = useState<'inbound' | 'outbound'>('inbound')
    const outbound = direction === 'outbound'
    const [basis, setBasis] = useState('weight')
    const [paid, setPaid] = useState(false)
    const [picked, setPicked] = useState<Record<string, boolean>>({})
    const [stated, setStated] = useState<Record<string, string>>({})
    const [amount, setAmount] = useState('')

    const chosen = batches.filter((b) => picked[b.id])
    // value 口径遇未计价批次:服务端会点名拒 —— 页面【先说出来】,
    // 不把一张注定被拒的表单摆到人面前(CMP-2 的规矩)
    const unpriced = !outbound && basis === 'value' ? chosen.filter((b) => b.unit_price === null) : []

    return (
        <div className="max-w-4xl">
            <div className="mb-6">
                <Link href="/finance/freight" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-2">{t('finance.freight.newTitle')}</h1>
            <p className="text-sm text-gray-600 mb-4 max-w-3xl">
                {outbound ? t('finance.freight.exportHint') : t('finance.freight.newIntro')}
            </p>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 【方向先问】它决定后面这张表单是哪一张 —— 分摊那一段在出境时
                    根本不存在,而不是"存在但空着"。 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('finance.freight.colDirection')} <span className="text-red-600">*</span>
                    </label>
                    <select name="direction" value={direction}
                        onChange={(e) => setDirection(e.target.value as 'inbound' | 'outbound')}
                        className="border border-gray-300 px-3 py-2 rounded min-w-96">
                        <option value="inbound">{t('finance.freight.direction.inbound')}</option>
                        <option value="outbound">{t('finance.freight.direction.outbound')}</option>
                    </select>
                    <p className="text-xs text-gray-600 mt-1 max-w-3xl">{t('finance.freight.directionHint')}</p>
                </div>

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
                        {/* LOG-1b:【空名单要说出它是哪一种空】。这里过滤的是货代,
                            所以空的时候要说"还没有货代",而不是画一个空的下拉框 ——
                            一个空下拉读起来像"选项加载失败",而真相是"还没有人被标成货代"。
                            今天线上货代数为 0,所以这一支【就是当前会看到的那一支】。 */}
                        {suppliers.length === 0 ? (
                            <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 max-w-xl">
                                {t('suppliers.pickerEmptyForwarders')}
                            </p>
                        ) : (
                            <select name="supplier_id" required defaultValue=""
                                className="border border-gray-300 px-3 py-2 rounded min-w-64">
                                <option value="" disabled>{t('finance.freight.selectForwarder')}</option>
                                {suppliers.map((s) => (
                                    <option key={s.id} value={s.id}>{s.legal_name}</option>
                                ))}
                            </select>
                        )}
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

                {/* 口径:一次明写的选择。【出境没有这一项】—— 出口运费不分摊,
                    摆一个禁用的下拉等于说"这里本该有个答案";它本来就不该有。 */}
                {!outbound && <div>
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
                </div>}

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

                {/* 【出境:集装箱选择器,而且【没有】任何分摊 UI】。
                    不是"分摊那一段禁用了",是它根本不在这张表单上 —— 出口运费
                    不摊到任何批次,摆一个空的批次表等于暗示这里少填了东西。 */}
                {outbound && (
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('finance.freight.colContainer')}</label>
                        {containers.length === 0 ? (
                            <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 max-w-xl">
                                {t('finance.freight.noContainers')}
                            </p>
                        ) : (
                            <select name="container_id" defaultValue=""
                                className="border border-gray-300 px-3 py-2 rounded min-w-96">
                                {/* 【不指定是一个正当选项】—— 单据才是钱的对象 */}
                                <option value="">{t('finance.freight.selectContainer')}</option>
                                {containers.map((c) => (
                                    <option key={c.id} value={c.id}>
                                        {c.code}{c.lane ? ` · ${c.lane}` : ''} · {c.departure_date}
                                    </option>
                                ))}
                            </select>
                        )}
                        <p className="text-xs text-gray-600 mt-1 max-w-3xl">{t('finance.freight.containerHint')}</p>
                    </div>
                )}

                {/* 批次(仅进境)*/}
                {!outbound && <div>
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
                </div>}

                <div>
                    <label className="block text-sm font-medium mb-1">{t('finance.freight.colNotes')}</label>
                    <textarea name="notes" rows={2} className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>

                <div className="flex gap-3 pt-2">
                    {/* 【提交条件按方向分】进境必须挑至少一个批次(服务端 FREIGHT_NO_BATCHES);
                        出境没有批次可挑,把那条禁用条件留着会让按钮永远按不下去。 */}
                    <Button type="submit" disabled={isPending || (!outbound && chosen.length === 0)}>
                        {isPending ? t('common.saving') : t('common.save')}
                    </Button>
                    <Button asChild variant="secondary">
                        <Link href="/finance/freight">
                            {t('common.cancel')}
                        </Link>
                    </Button>
                </div>
            </form>
        </div>
    )
}
