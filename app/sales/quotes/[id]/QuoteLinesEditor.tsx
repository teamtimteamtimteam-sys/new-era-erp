'use client'

// SO-4b:报价明细 —— 【签发之后仍然改得动】,而那正是它与订单的区别。
//
// 订单在确认时冻结(SO-1b 的三条下限就长在那之后);报价没有下游,改价改量
// 就是它的用途。所以这里是一张可编辑的表,而不是一张只读表加一个"改单"入口。
// 改完之后详情页顶上那条琥珀色横幅会亮起来 —— 提醒重新签发,因为客户手里
// 那份是某个具体版本。
//
// 【不可编辑时,理由长在表旁边】(CMP-2)—— 转过、谢绝了、或者没有写权限,
// 三种情形指向三句不同的话,而不是一张灰掉的表让人自己猜。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { updateQuoteLine, removeQuoteLine, addQuoteLine } from '../actions'
import { Button } from '@/app/components/ui/button'

type Line = {
    id: string; line_no: number; material: string; unit: string
    quantity: number; unit_price: number
}

export default function QuoteLinesEditor({
    quoteId, currency, editable, reason, lines, materials,
}: {
    quoteId: string; currency: string; editable: boolean; reason: string
    lines: Line[]; materials: { id: string; code: string; name: string }[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [qty, setQty] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, String(l.quantity)])))
    const [price, setPrice] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, String(l.unit_price)])))
    const [newMat, setNewMat] = useState('')
    const [newQty, setNewQty] = useState('')
    const [newPrice, setNewPrice] = useState('')

    const run = (fn: () => Promise<{ error?: string }>) => {
        setError('')
        startTransition(async () => {
            const res = await fn()
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <section>
            <h2 className="font-medium mb-2">{t('sales.form.lines')}</h2>
            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded mb-2 text-sm">
                    {error}
                </div>
            )}
            {!editable && reason && (
                <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-2">
                    {reason}
                </p>
            )}
            <table className="w-full border-collapse border border-gray-300 text-sm">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-2 py-2 text-left">#</th>
                        <th className="border border-gray-300 px-2 py-2 text-left">{t('sales.colMaterial')}</th>
                        <th className="border border-gray-300 px-2 py-2 text-right">{t('sales.form.qty')}</th>
                        <th className="border border-gray-300 px-2 py-2 text-right">
                            {t('quotes.colUnitPrice', { ccy: currency })}</th>
                        <th className="border border-gray-300 px-2 py-2 text-right">{t('quotes.colLineTotal')}</th>
                        {editable && <th className="border border-gray-300 px-2 py-2" />}
                    </tr>
                </thead>
                <tbody>
                    {lines.map((l) => {
                        const qn = Number(qty[l.id] ?? l.quantity)
                        const pn = Number(price[l.id] ?? l.unit_price)
                        const dirty = qn !== l.quantity || pn !== l.unit_price
                        return (
                            <tr key={l.id}>
                                <td className="border border-gray-300 px-2 py-2">{l.line_no}</td>
                                <td className="border border-gray-300 px-2 py-2">{l.material}</td>
                                <td className="border border-gray-300 px-2 py-2 text-right">
                                    {editable ? (
                                        <input type="number" step="any" min="0" value={qty[l.id] ?? ''}
                                               onChange={(e) => setQty((s) => ({ ...s, [l.id]: e.target.value }))}
                                               className="w-24 border border-gray-300 px-2 py-1 rounded text-right" />
                                    ) : (<span className="font-mono">{l.quantity} {l.unit}</span>)}
                                </td>
                                <td className="border border-gray-300 px-2 py-2 text-right">
                                    {editable ? (
                                        <input type="number" step="any" min="0" value={price[l.id] ?? ''}
                                               onChange={(e) => setPrice((s) => ({ ...s, [l.id]: e.target.value }))}
                                               className="w-24 border border-gray-300 px-2 py-1 rounded text-right" />
                                    ) : (
                                        <span className="font-mono">
                                            {formatMoneyBare(l.unit_price, '同表列头 单价({ccy})')}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-2 py-2 text-right font-mono">
                                    {formatMoneyBare(Math.round(qn * pn * 100) / 100, '整表同一个币种,见表头单价那一列')}
                                </td>
                                {editable && (
                                    <td className="border border-gray-300 px-2 py-2 whitespace-nowrap">
                                        <Button variant="link" size="inline" type="button" disabled={isPending || !dirty}
                                                onClick={() => run(() => updateQuoteLine(quoteId, l.id, qty[l.id] ?? '', price[l.id] ?? ''))}
                                                className="text-xs">
                                            {t('common.save')}
                                        </Button>
                                        <Button variant="destructive" size="inline" type="button" disabled={isPending}
                                                onClick={() => run(() => removeQuoteLine(quoteId, l.id))}
                                                className="ml-3 text-xs">
                                            {t('quotes.removeLine')}
                                        </Button>
                                    </td>
                                )}
                            </tr>
                        )
                    })}
                    {lines.length === 0 && (
                        <tr>
                            <td colSpan={editable ? 6 : 5}
                                className="border border-gray-300 px-3 py-4 text-center text-gray-500">
                                {t('quotes.noLines')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>

            {editable && (
                <div className="flex flex-wrap items-end gap-2 mt-2">
                    <select value={newMat} onChange={(e) => setNewMat(e.target.value)}
                            className="border border-gray-300 px-2 py-1 rounded text-sm">
                        <option value="">{t('sales.form.selectMaterial')}</option>
                        {materials.map((m) => (
                            <option key={m.id} value={m.id}>{m.code} — {m.name}</option>
                        ))}
                    </select>
                    <input type="number" step="any" min="0" value={newQty}
                           onChange={(e) => setNewQty(e.target.value)}
                           placeholder={t('sales.form.qty')}
                           className="w-24 border border-gray-300 px-2 py-1 rounded text-right text-sm" />
                    <input type="number" step="any" min="0" value={newPrice}
                           onChange={(e) => setNewPrice(e.target.value)}
                           placeholder={t('sales.form.unitPrice')}
                           className="w-24 border border-gray-300 px-2 py-1 rounded text-right text-sm" />
                    <Button variant="secondary" size="sm" type="button"
                            disabled={isPending || !newMat || newQty.trim() === '' || newPrice.trim() === ''}
                            onClick={() => run(async () => {
                                const r = await addQuoteLine(quoteId, newMat, newQty, newPrice)
                                if (!r.error) { setNewMat(''); setNewQty(''); setNewPrice('') }
                                return r
                            })}>
                        {t('quotes.addLine')}
                    </Button>
                </div>
            )}
            {editable && <p className="text-xs text-gray-500 mt-2">{t('quotes.editableNote')}</p>}
        </section>
    )
}
