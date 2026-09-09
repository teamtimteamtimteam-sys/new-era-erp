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
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

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
            {/* ════════════════════════════════════════════════════════════════
                ★ TABLE-PHONE-4:六列(editable)/ 五列(只读)→ 手机档一律留四列
                (# · 物料 · 数量 · 单价)。两支留的是【同一组】,所以人在两种状态下
                看到的是同一张表,只是格子里的东西从输入框变回文字。
                被拿掉的:金额(算出来的)+ 末列那一组按钮(editable 时才有)。
                ☞ 金额 = 数量 × 单价,两个乘数都在明面上而且都是要动手的;
                  一个读得到的算式结果放在折叠区里不多花一次点击 —— 这正是
                  TABLE-PHONE-3 定下的那条:第四格给【要打字的】,不给【算出来的】。
                ★ 末列的列头是【真的空】,格子里两个按钮各自带着自己的字
                  (保存 / 删除)—— 按已定的做法:折叠区里照画,不现造文案。
                ★ 这张表【一个带 name 的输入框都没有】(数量/单价是受控 state,
                  提交走的是 server action 参数),所以复制不会往任何表单里多塞一格。
                  ConfirmButton 也经得起复制:id 是 useId 生成的、不开 portal、
                  keydown 监听只在对话框开着时挂 —— 而 display:none 的那一份点不开。
                ★ colSpan 写两份(R-Q1 的代价):手机档恒为 4,桌面档 editable ? 6 : 5。
                ════════════════════════════════════════════════════════════════ */}
            <table className="w-full border-collapse border border-gray-300 text-sm">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-2 py-2 text-left">#</th>
                        <th className="border border-gray-300 px-2 py-2 text-left">{t('sales.colMaterial')}</th>
                        <th className="border border-gray-300 px-2 py-2 text-right">{t('sales.form.qty')}</th>
                        <th className="border border-gray-300 px-2 py-2 text-right">
                            {t('quotes.colUnitPrice', { ccy: currency })}</th>
                        <th className="hidden sm:table-cell border border-gray-300 px-2 py-2 text-right">{t('quotes.colLineTotal')}</th>
                        {editable && <th className="hidden sm:table-cell border border-gray-300 px-2 py-2" />}
                    </tr>
                </thead>
                <tbody>
                    {lines.map((l) => {
                        const qn = Number(qty[l.id] ?? l.quantity)
                        const pn = Number(price[l.id] ?? l.unit_price)
                        const dirty = qn !== l.quantity || pn !== l.unit_price
                        // ★ TABLE-PHONE-4:两档共用的两份内容【提出来写一次】——
                        //   抄成两份就是让两份将来各走各的,而漂移在桌面上看不见。
                        const lineTotalText = formatMoneyBare(Math.round(qn * pn * 100) / 100, '整表同一个币种,见表头单价那一列')
                        const rowActions = editable ? (
                            <>
                                <Button variant="link" size="inline" type="button" disabled={isPending || !dirty}
                                        onClick={() => run(() => updateQuoteLine(quoteId, l.id, qty[l.id] ?? '', price[l.id] ?? ''))}
                                        className="text-xs">
                                    {t('common.save')}
                                </Button>
                                {/* ★【硬删,所以有门】★(ALERT-2c)
                                    removeQuoteLine 走的是 quote_lines 上一次裸
                                    `.delete()` —— 没有理由、没有墓碑、没有回头路。
                                    ALERT-2a 已经把这个钮的字从 "remove" 改成
                                    「删除」,那是把【牌子】写对;这里补上【门】。
                                    主语取【行号 · 物料】:两者都印在同一行里,
                                    本页没有一处 MaskedValue,所以主语不会说出
                                    这个读者在表上看不到的东西(CONFIRM-1 的逐消费者判据)。
                                    ★ TABLE-PHONE-4 复核:行号与物料【两档都留在明面上】,
                                      所以这句主语在 390px 上照样指得着它说的那一行。
                                    金额【刻意不进主语】—— 与 CostPanel 同一条理由。 */}
                                <ConfirmButton
                                    subject={`#${l.line_no} · ${l.material}`}
                                    title={t('quotes.removeLineConfirmTitle')}
                                    body={t('common.hardDeleteNote')}
                                    details={
                                        <p className="text-sm font-medium text-foreground">
                                            {t('quotes.removeLineConsequence')}
                                        </p>
                                    }
                                    confirmLabel={t('common.delete')}
                                    triggerVariant="destructive"
                                    triggerSize="inline"
                                    disabled={isPending}
                                    className="ml-3 text-xs"
                                    onConfirm={() => run(() => removeQuoteLine(quoteId, l.id))}
                                >
                                    {t('quotes.removeLine')}
                                </ConfirmButton>
                            </>
                        ) : null
                        return (
                            <tr key={l.id}>
                                <td className="border border-gray-300 px-2 py-2">{l.line_no}</td>
                                <td className="border border-gray-300 px-2 py-2">
                                    {l.material}
                                    {/* ★ TABLE-PHONE-4:手机档拿掉的两样,叠在这里。
                                        金额带着它的列头;末列的列头是真的空,而那两个
                                        按钮各自带着自己的字,所以照画、不现造文案。 */}
                                    <div className="sm:hidden mt-1 space-y-1 font-sans text-xs text-gray-600">
                                        <div className="font-mono">
                                            <span className="font-sans text-gray-500">{t('quotes.colLineTotal')}: </span>
                                            {lineTotalText}
                                        </div>
                                        {rowActions && (
                                            <div className="whitespace-nowrap">{rowActions}</div>
                                        )}
                                    </div>
                                </td>
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
                                <td className="hidden sm:table-cell border border-gray-300 px-2 py-2 text-right font-mono">
                                    {lineTotalText}
                                </td>
                                {editable && (
                                    <td className="hidden sm:table-cell border border-gray-300 px-2 py-2 whitespace-nowrap">
                                        {rowActions}
                                    </td>
                                )}
                            </tr>
                        )
                    })}
                    {lines.length === 0 && (
                        <tr>
                            {/* ★ TABLE-PHONE-4:colSpan 写两份 —— 这是 R-Q1 明写的代价。
                                手机档恒为 4(两支留的是同一组);桌面档 editable ? 6 : 5。 */}
                            <td colSpan={4}
                                className="sm:hidden border border-gray-300 px-3 py-4 text-center text-gray-500">
                                {t('quotes.noLines')}
                            </td>
                            <td colSpan={editable ? 6 : 5}
                                className="hidden sm:table-cell border border-gray-300 px-3 py-4 text-center text-gray-500">
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
