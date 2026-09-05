'use client'

// SO-1b:改单表单。
//
// 【本表单不自己判断能不能改】三条下限在触发器上,五列身份字段在表头守卫上,
// 拒绝由数据库点名。这里做的只有两件事:
//   * 把【三个数】写在行上 —— 已发 / 已开票 / 已预留,三件事咬着同一行,而它们
//     的出路完全不同(不可逆 / 先作废发票 / 先释放预留)。看不见这三个数的人,
//     只能靠保存一次再读一句拒绝去猜(CMP-2);
//   * 理由必填 —— 但【草稿不要】:草稿还不是承诺,给一件还没发生的事要一句
//     解释,只会训练人随手敲一个句号。
// 表单上的提示是【礼貌】,不是保护。
//
// 【永久冻结的五列画出来,而不是省略】客户 / 单据日 / 币种 / 汇率 / 单号 ——
// 它们【看得见但改不动】,而且旁边写着为什么。省略它们会让人以为这张页面
// 只是不完整;画成只读并给出理由,才是在回答"我要改客户怎么办"。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { soStatusKey } from '../../salesOrderTypes'
import { amendOrder, type AmendState } from './actions'
import { Button } from '@/app/components/ui/button'

export type AmendLine = {
    id: string
    line_no: number
    material_code: string
    material_name: string
    unit: string
    quantity: number
    unit_price: number
    shipped: number
    shipment_code: string | null
    reserved: number
    /** null = 没有在册的订单流发票行,或者【读不到发票】—— 两者由 canSeeInvoices 分辨 */
    invoiced: number | null
    invoice_code: string | null
    /** SO-1b fu1:这一行背后还有【过去】—— 释放过的预留、作废了的发票行。
     *  它们是只增不改的记录,所以这一行【删不掉了】(只能改小)。 */
    has_record: boolean
}

const initialState: AmendState = {}
const NEW_SLOTS = 3

export default function AmendOrderForm({
    orderId, code, status, currency, customerLabel, orderDate, fxRate,
    notes, termsText, lines, materials, canSeeInvoices,
}: {
    orderId: string; code: string; status: string; currency: string
    customerLabel: string; orderDate: string; fxRate: string
    notes: string; termsText: string
    lines: AmendLine[]
    materials: { id: string; code: string; name: string }[]
    canSeeInvoices: boolean
}) {
    const t = useTranslations()
    const bound = amendOrder.bind(null, orderId)
    const [state, formAction, isPending] = useActionState(bound, initialState)

    const isDraft = status === 'draft'
    // 【shipped 只开一条缝:加行】—— 表头与既有行都动不了,而加一行会让状态
    // 按"已发 vs 已订"重新算出来,自己翻回 partially_shipped。
    const addOnly = status === 'shipped'
    // closed / cancelled:服务端会拒,这里不摆一个注定失败的按钮
    const frozen = !isDraft && !addOnly && status !== 'confirmed' && status !== 'partially_shipped'

    const [qty, setQty] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, String(l.quantity)])))
    const [price, setPrice] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, String(l.unit_price)])))
    const [remove, setRemove] = useState<Record<string, boolean>>({})

    const mode = isDraft ? 'draft' : addOnly ? 'addonly' : 'amend'

    return (
        <div className="max-w-5xl">
            <div className="mb-6">
                <Link href={`/sales/orders/${orderId}`} className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-2">
                {isDraft ? t('sales.amend.draftTitle', { code }) : t('sales.amend.title', { code })}
            </h1>
            <p className="text-sm text-gray-600 mb-6 max-w-3xl">
                {isDraft ? t('sales.amend.draftIntro') : t('sales.amend.intro')}
            </p>

            {frozen && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4">
                    {/* 【静态映射,不拼动态键】soStatusKey 是那一份唯一的表 */}
                    {t('sales.amend.notAmendable', { status: t(soStatusKey(status)) })}
                </div>
            )}
            {addOnly && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4">
                    {t('sales.amend.addOnly')}
                </div>
            )}
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            {/* ── 永久冻结的五列:看得见,改不动,旁边写着为什么 ───────────────── */}
            <div className="border border-gray-300 rounded p-4 mb-6 bg-gray-50">
                <h2 className="font-medium mb-1">{t('sales.amend.frozenTitle')}</h2>
                <p className="text-xs text-gray-600 mb-3 max-w-3xl">{t('sales.amend.frozenWhy')}</p>
                <dl className="grid grid-cols-2 gap-x-8 gap-y-1 text-sm">
                    <div><dt className="inline text-gray-500">{t('sales.colCode')}: </dt>
                         <dd className="inline font-mono">{code}</dd></div>
                    <div><dt className="inline text-gray-500">{t('sales.colCustomer')}: </dt>
                         <dd className="inline">{customerLabel}</dd></div>
                    <div><dt className="inline text-gray-500">{t('sales.colDate')}: </dt>
                         <dd className="inline">{orderDate}</dd></div>
                    <div><dt className="inline text-gray-500">{t('sales.colCurrency')}: </dt>
                         <dd className="inline">{currency} @ {fxRate}</dd></div>
                </dl>
            </div>

            <form action={formAction} className="space-y-4">
                <input type="hidden" name="mode" value={mode} />

                {/* 【草稿没有理由这一栏】—— 不是隐藏一个必填项,是它在草稿态真的不存在 */}
                {!isDraft && (
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('sales.amend.reason')} <span className="text-red-600">*</span>
                        </label>
                        <input type="text" name="reason" required disabled={frozen}
                               className="w-full border border-gray-300 px-3 py-2 rounded" />
                        <p className="text-xs text-gray-500 mt-1">{t('sales.amend.reasonHint')}</p>
                    </div>
                )}

                {/* ── 明细 ──────────────────────────────────────────────────── */}
                <h2 className="font-medium pt-2">{t('sales.form.lines')}</h2>
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-2 py-2 text-left">#</th>
                            <th className="border border-gray-300 px-2 py-2 text-left">{t('sales.colMaterial')}</th>
                            <th className="border border-gray-300 px-2 py-2 text-right">{t('sales.amend.colOrdered')}</th>
                            <th className="border border-gray-300 px-2 py-2 text-right">{t('sales.amend.colInvoiced')}</th>
                            <th className="border border-gray-300 px-2 py-2 text-right">{t('sales.amend.colReserved')}</th>
                            <th className="border border-gray-300 px-2 py-2 text-right">{t('sales.amend.colShipped')}</th>
                            <th className="border border-gray-300 px-2 py-2 text-right">{t('sales.amend.colPrice', { ccy: currency })}</th>
                            <th className="border border-gray-300 px-2 py-2 text-left">{t('sales.amend.colRemove')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {lines.map((l) => {
                            const n = Number(qty[l.id] || 0)
                            const gone = !!remove[l.id]
                            const billed = l.invoice_code !== null
                            const lockedRow = frozen || addOnly || gone
                            const belowShipped = !gone && n < l.shipped
                            const belowReserved = !gone && !belowShipped && n < l.shipped + l.reserved
                            // 【三条可操作的 + 一条不可操作的】前三条指得出下一步
                            // (作废那张票 / 释放那笔预留 / 货已经发了);has_record
                            // 指不出 —— 没有任何动作能让一件发生过的事没发生过。
                            const cannotRemove = billed || l.shipped > 0 || l.reserved > 0 || l.has_record
                            return (
                                <tr key={l.id} className={gone ? 'bg-gray-100 text-gray-400' : ''}>
                                    <td className="border border-gray-300 px-2 py-2">
                                        {l.line_no}
                                        <input type="hidden" name="line_id" value={l.id} />
                                        <input type="hidden" name="line_remove" value={gone ? '1' : '0'} />
                                    </td>
                                    <td className="border border-gray-300 px-2 py-2">
                                        <span className="font-mono">{l.material_code}</span>{' '}
                                        <span className="text-gray-500">{l.material_name}</span>
                                    </td>
                                    <td className="border border-gray-300 px-2 py-2 text-right">
                                        <DecimalInput name="line_quantity" value={qty[l.id] ?? ''}
                                            onChange={(raw) => setQty((q) => ({ ...q, [l.id]: raw }))}
                                            disabled={lockedRow || billed}
                                            className="w-24 border border-gray-300 px-2 py-1 rounded text-right" />
                                        {/* 【硬下限】货已经出去了 */}
                                        {belowShipped && (
                                            <p className="text-xs text-red-600 mt-1">
                                                {t('sales.amend.belowShipped', { shipped: String(l.shipped) })}
                                            </p>
                                        )}
                                        {/* 【软下限】拒绝,但绝不替人释放 —— 释放要留名 */}
                                        {belowReserved && (
                                            <p className="text-xs text-amber-700 mt-1">
                                                {t('sales.amend.belowReserved', { reserved: String(l.reserved) })}
                                            </p>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-2 text-right font-mono text-xs">
                                        {/* 【受限 ≠ 未开票】前者是"你看不到",后者是"确实没有" */}
                                        {!canSeeInvoices ? (
                                            <span className="text-gray-500 font-sans">{t('common.restricted')}</span>
                                        ) : billed ? (
                                            <>
                                                {l.invoiced} {l.unit}
                                                <span className="block text-gray-500">{l.invoice_code}</span>
                                            </>
                                        ) : (
                                            <span className="text-gray-400 font-sans">{t('sales.invoice.lineUnbilled')}</span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-2 text-right font-mono text-xs">
                                        {l.reserved} {l.unit}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-2 text-right font-mono text-xs">
                                        {l.shipped} {l.unit}
                                        {l.shipment_code && (
                                            <span className="block text-gray-500">{l.shipment_code}</span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-2 text-right">
                                        <DecimalInput name="line_price" value={price[l.id] ?? ''}
                                            onChange={(raw) => setPrice((p) => ({ ...p, [l.id]: raw }))}
                                            disabled={lockedRow || billed}
                                            className="w-24 border border-gray-300 px-2 py-1 rounded text-right" />
                                    </td>
                                    <td className="border border-gray-300 px-2 py-2">
                                        <label className="text-xs">
                                            <input type="checkbox" checked={gone}
                                                disabled={frozen || addOnly || cannotRemove}
                                                onChange={(e) => setRemove((r) => ({ ...r, [l.id]: e.target.checked }))} />
                                            <span className="ml-1">
                                                {cannotRemove ? t('sales.amend.cannotRemove') : t('sales.amend.remove')}
                                            </span>
                                        </label>
                                    </td>
                                </tr>
                            )
                        })}
                    </tbody>
                </table>

                {/* 【已开票的行:两条出路都说出来】数字错了 → 先作废那张票;
                    客户要加量 → 另起一行(整单发完之后也走得通) */}
                {lines.some((l) => l.invoice_code !== null) && (
                    <p className="text-xs text-gray-600">{t('sales.amend.invoicedNote')}</p>
                )}

                {/* ── 加行 ──────────────────────────────────────────────────── */}
                {!frozen && (
                    <>
                        <h2 className="font-medium pt-2">{t('sales.amend.addLines')}</h2>
                        <p className="text-xs text-gray-500">{t('sales.amend.addLinesHint')}</p>
                        <table className="w-full border-collapse border border-gray-300 text-sm">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="border border-gray-300 px-2 py-2 text-left">{t('sales.colMaterial')}</th>
                                    <th className="border border-gray-300 px-2 py-2 text-right">{t('sales.form.qty')}</th>
                                    <th className="border border-gray-300 px-2 py-2 text-right">{t('sales.amend.colPrice', { ccy: currency })}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {Array.from({ length: NEW_SLOTS }, (_, i) => (
                                    <tr key={i}>
                                        <td className="border border-gray-300 px-2 py-2">
                                            <select name={`new_material_${i}`} defaultValue=""
                                                    className="w-full border border-gray-300 px-2 py-1 rounded">
                                                <option value="">{t('sales.form.selectMaterial')}</option>
                                                {materials.map((m) => (
                                                    <option key={m.id} value={m.id}>{m.code} — {m.name}</option>
                                                ))}
                                            </select>
                                        </td>
                                        <td className="border border-gray-300 px-2 py-2 text-right">
                                            <input type="number" step="any" min="0" name={`new_qty_${i}`}
                                                   className="w-24 border border-gray-300 px-2 py-1 rounded text-right" />
                                        </td>
                                        <td className="border border-gray-300 px-2 py-2 text-right">
                                            <input type="number" step="any" min="0" name={`new_price_${i}`}
                                                   className="w-24 border border-gray-300 px-2 py-1 rounded text-right" />
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </>
                )}

                {/* ── 表头上可改的那两列 ─────────────────────────────────────── */}
                {!addOnly && (
                    <>
                        <h2 className="font-medium pt-2">{t('sales.amend.headerTitle')}</h2>
                        <p className="text-xs text-gray-500">{t('sales.amend.headerWhy')}</p>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('sales.form.notes')}</label>
                            <textarea name="notes" rows={2} defaultValue={notes} disabled={frozen}
                                      className="w-full border border-gray-300 px-3 py-2 rounded" />
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('sales.amend.terms')}</label>
                            <textarea name="terms_text" rows={3} defaultValue={termsText} disabled={frozen}
                                      className="w-full border border-gray-300 px-3 py-2 rounded" />
                            <p className="text-xs text-gray-500 mt-1">{t('sales.amend.termsHint')}</p>
                        </div>
                    </>
                )}

                <div className="flex gap-3 pt-2">
                    <Button type="submit" disabled={isPending || frozen}>
                        {isPending ? t('common.saving') : t('sales.amend.submit')}
                    </Button>
                    <Link href={`/sales/orders/${orderId}`}
                          className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50">
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </div>
    )
}
