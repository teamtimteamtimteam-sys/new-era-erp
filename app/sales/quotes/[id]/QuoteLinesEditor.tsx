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
//
// ════════════════════════════════════════════════════════════════════════════
// ★★ DRAFT-1(2026-09-21)· 这张表搬到了 `<EditableTable>` 上 ★★
// ════════════════════════════════════════════════════════════════════════════
//   ★ 与 `AttendanceGrid` 同一个形状:`mode: 'all-rows'` **加 `onSave`**
//     ——【整格都在编辑态,每一行一颗保存钮】。搬家前的 `qty` / `price` 两个
//     `Record<lineId, string>` 就是整格草稿,而 `:98` 那一行逐行算出来的 `dirty`
//     正是组件 Q5 的那条「脏是算出来的,不是存下来的 flag」。**同一个想法,
//     搬家只是让它不必在每一页重写一遍。**
//
//   ★ 搬家收下的两件:
//     ① 保存失败的错误从【页顶红框】变成【那一行下面,带 role="alert"】——
//        改三行报错一行时,从前屏幕上说不出是哪一行;
//     ② 脏着关标签页会拦一下(组件自带的 `beforeunload`)。
//        ⚠ 站内 <Link> 跳走盖不住,那是一条声明过的限制。
//   ★ 删除仍然是【页面自己的】那颗 `ConfirmButton`(能力 A 的槽)——
//     组件借它一个位置,不知道它是什么。硬删的那道门一个字没改。
//   ★ 加行表单【本来就在表外面】,搬家前后都是 —— 它现在坐在 `footer` 槽里。
//   ★ 变体 C:这张表此前就穿着 `border border-gray-300`(变体 A 的衣服),
//     现在走组件自己的表体,衣服跟着搬家免费换了。
//
//   ⚠ **TABLE-PHONE-4 那条「手机档留四列」的手搓版在这次搬家里退役了。**
//     留下来的是同一个判断,只是换成组件的说法:`priority` 的四列
//     (# · 物料 · 数量 · 单价),金额下到展开区(它是算出来的,读一眼不花点按)。
//     ⚠ 一处**真的行为变化**:搬家前手机上格子里就是输入框;
//     组件的契约是**手机上格子只读,编辑在展开区**(组件抬头 ④)。
//     ☞ 这不是这一刀的选择,是那个组件的既定契约 —— 写在这里免得日后当成退步。
// ════════════════════════════════════════════════════════════════════════════
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { updateQuoteLine, removeQuoteLine, addQuoteLine } from '../actions'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

type Line = {
    id: string; line_no: number; material: string; unit: string
    quantity: number; unit_price: number
}

type Draft = { qty: string; price: string }

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
    const [newMat, setNewMat] = useState('')
    const [newQty, setNewQty] = useState('')
    const [newPrice, setNewPrice] = useState('')

    // ★ 这一支现在只装【加行 / 删行】那两支的失败 —— 逐行保存的失败
    //   由组件画在那一行下面。
    const run = (fn: () => Promise<{ error?: string }>) => {
        setError('')
        startTransition(async () => {
            const res = await fn()
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    const lineTotalOf = (qty: string, price: string) =>
        formatMoneyBare(
            Math.round(Number(qty || 0) * Number(price || 0) * 100) / 100,
            '整表同一个币种,见表头单价那一列',
        )

    const columns: EditableColumn<Line, Draft>[] = [
        {
            key: 'line_no',
            header: '#',
            priority: true,
            className: 'w-8',
            render: (l) => l.line_no,
        },
        {
            key: 'material',
            header: t('sales.colMaterial'),
            priority: true,
            render: (l) => l.material,
        },
        {
            key: 'qty',
            header: t('sales.form.qty'),
            priority: true,
            align: 'right',
            render: (l) => <span>{l.quantity} {l.unit}</span>,
            edit: (d, set) => (
                <input type="number" step="any" min="0" value={d.qty}
                       aria-label={t('sales.form.qty')}
                       onChange={(e) => set({ qty: e.target.value })}
                       className={`${CONTROL_INPUT} w-24 text-right tabular-nums`} />
            ),
        },
        {
            key: 'unit_price',
            header: t('quotes.colUnitPrice', { ccy: currency }),
            priority: true,
            align: 'right',
            render: (l) => <span>{formatMoneyBare(l.unit_price, '同表列头 单价({ccy})')}</span>,
            edit: (d, set) => (
                <input type="number" step="any" min="0" value={d.price}
                       aria-label={t('quotes.colUnitPrice', { ccy: currency })}
                       onChange={(e) => set({ price: e.target.value })}
                       className={`${CONTROL_INPUT} w-24 text-right tabular-nums`} />
            ),
        },
        {
            // 金额是算出来的,谁也改不动它。
            // ★★ 但它【必须给 edit】—— 而那个 `edit` 不是一个输入框,是**一份草稿的投影**。
            //   搬家前它读的是 `qn`/`pn`(两个 state),**打一个字金额就跟着动**;
            //   `render` 只收得到 `row`,写成 `render` 就会让金额停在库里那个旧值上,
            //   直到保存才跳一下 —— 那是一处会骗人的读数。
            //   ☞ 组件的 `edit(draft, set)` 本来就允许不用 `set`:
            //     它的契约是「编辑态这一格画什么」,不是「这一格一定是个输入框」。
            key: 'line_total',
            header: t('quotes.colLineTotal'),
            align: 'right',
            render: (l) => lineTotalOf(String(l.quantity), String(l.unit_price)),
            edit: (d) => lineTotalOf(d.qty, d.price),
        },
    ]

    return (
        <section>
            <h2 className="mb-2">{t('sales.form.lines')}</h2>
            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded mb-2 text-sm">
                    {error}
                </div>
            )}
            {!editable && reason && (
                <p className="text-sm text-[color:var(--brand-muted-text)] bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-2">
                    {reason}
                </p>
            )}

            <EditableTable<Line, Draft>
                rows={lines}
                columns={columns}
                rowKey={(l) => l.id}
                phone={{ mode: 'columns' }}
                mode="all-rows"
                canEdit={editable}
                empty={t('quotes.noLines')}
                toDraft={(l) => ({ qty: String(l.quantity), price: String(l.unit_price) })}
                labels={{
                    edit: t('common.edit'), save: t('common.save'), saving: t('common.saving'),
                    cancel: t('common.cancel'), unsaved: t('common.unsavedRow'), expand: t('common.expandRow'),
                }}
                onSave={async (d, l) => {
                    const res = await updateQuoteLine(quoteId, l.id, d.qty, d.price)
                    if (res.error) return { error: res.error }
                    router.refresh()
                }}
                /* ★【硬删,所以有门】★(ALERT-2c)
                    removeQuoteLine 走的是 quote_lines 上一次裸 `.delete()` ——
                    没有理由、没有墓碑、没有回头路。ALERT-2a 已经把这个钮的字从
                    "remove" 改成「删除」,那是把【牌子】写对;这里是那道【门】。
                    主语取【行号 · 物料】:两者都印在同一行里,本页没有一处
                    MaskedValue,所以主语不会说出这个读者在表上看不到的东西
                    (CONFIRM-1 的逐消费者判据)。
                    ★ 复核:行号与物料两档都是 priority,所以这句主语在 390px 上
                      照样指得着它说的那一行。金额【刻意不进主语】—— 与 CostPanel 同一条理由。 */
                rowActions={
                    editable
                        ? (l) => (
                              <ConfirmButton
                                  subject={`#${l.line_no} · ${l.material}`}
                                  title={t('quotes.removeLineConfirmTitle')}
                                  body={t('common.hardDeleteNote')}
                                  details={
                                      <p className="text-sm font-medium text-[color:var(--brand-text)]">
                                          {t('quotes.removeLineConsequence')}
                                      </p>
                                  }
                                  confirmLabel={t('common.delete')}
                                  triggerVariant="destructive"
                                  triggerSize="inline"
                                  disabled={isPending}
                                  className="text-xs"
                                  onConfirm={() => run(() => removeQuoteLine(quoteId, l.id))}
                              >
                                  {t('quotes.removeLine')}
                              </ConfirmButton>
                          )
                        : undefined
                }
                footer={() =>
                    editable ? (
                        <>
                            <div className="flex flex-wrap items-end gap-2 mt-2">
                                <select value={newMat} onChange={(e) => setNewMat(e.target.value)}
                                        aria-label={t('sales.form.selectMaterial')}
                                        className={CONTROL_SELECT}>
                                    <option value="">{t('sales.form.selectMaterial')}</option>
                                    {materials.map((m) => (
                                        <option key={m.id} value={m.id}>{m.code} — {m.name}</option>
                                    ))}
                                </select>
                                <input type="number" step="any" min="0" value={newQty}
                                       onChange={(e) => setNewQty(e.target.value)}
                                       placeholder={t('sales.form.qty')}
                                       aria-label={t('sales.form.qty')}
                                       className={`${CONTROL_INPUT} w-24 text-right tabular-nums`} />
                                <input type="number" step="any" min="0" value={newPrice}
                                       onChange={(e) => setNewPrice(e.target.value)}
                                       placeholder={t('sales.form.unitPrice')}
                                       aria-label={t('sales.form.unitPrice')}
                                       className={`${CONTROL_INPUT} w-24 text-right tabular-nums`} />
                                <Button variant="secondary" type="button"
                                        disabled={isPending || !newMat || newQty.trim() === '' || newPrice.trim() === ''}
                                        onClick={() => run(async () => {
                                            const r = await addQuoteLine(quoteId, newMat, newQty, newPrice)
                                            if (!r.error) { setNewMat(''); setNewQty(''); setNewPrice('') }
                                            return r
                                        })}>
                                    {t('quotes.addLine')}
                                </Button>
                            </div>
                            <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('quotes.editableNote')}</p>
                        </>
                    ) : null
                }
            />
        </section>
    )
}
