'use client'

// SO-4b:新建报价的表单。形状取自 /sales/orders/new,三处 why-line 逐字同源:
//   * 两个日期【永不默认】—— 物理承诺日;补一个今天会让"留空"比"填对"更容易通过,
//     而一个补出来的有效期永远不会在它该过期的那天过期;
//   * 汇率【没有默认值】(FIN-35)—— 假设出来的 1:1 在非本位币单据上永远是错的,
//     而且看起来完全正常;
//   * 行指向【物料】,不指向批次 —— 报价的时候那批货可能还没生产出来。
//
// 【保存出来的是一张草稿】签发是另一步,而签发才是"发给对方"这件事本身。
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { createQuote, type QuoteFormState } from '../actions'
import { Button } from '@/app/components/ui/button'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

const initialState: QuoteFormState = {}
const LINE_SLOTS = 5

/** 一个报价行槽。★ 这就是交给服务端的那个形状 —— `lines_json` 里逐字是它。 */
type LineDraft = { material_id: string; qty: string; price: string }
/**
 * ★ 画在表里的那一行 = 草稿 + 它的槽号。
 *
 * 【为什么把下标烧进行里,而不是用 `rows.indexOf(row)` 捞回来】
 * `EditableTable` 的 `render(row)` / `edit(draft, set)` **都收不到下标**,而
 * `'page-owned'` 下页面必须走自己的 setter(`set` 是一条按名拒绝)——
 * 也就是说这一格非知道「我是第几槽」不可。捞回来要靠引用相等,那是一条
 * **看不见的、一次 `map` 就会断掉的**依赖;烧进行里是一条看得见的。
 * ☞ 它**不进** `lines_json`:交出去的是 `lines`,`i` 只活在渲染这一侧。
 */
type LineRow = LineDraft & { i: number }
const emptyLine = (): LineDraft => ({ material_id: '', qty: '', price: '' })

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
    // ★★ DRAFT-2 / Tim 的 Q1 裁定 (b):**这个数组由页面持有**,草稿经表【外面】
    //   一个隐藏的 `lines_json` 交出去。格子里因此一个 `name=` 都没有 ——
    //   而那正是 `EDITABLETABLE-NAME-DOUBLE-SUBMIT` 那条坑的燃料。
    //   先例:`TemplateForm:108` · `NewOrderForm:371,372` · `PayrollGrid:119`。
    const [lines, setLines] = useState<LineDraft[]>(() =>
        Array.from({ length: LINE_SLOTS }, emptyLine))

    function patchLine(i: number, patch: Partial<LineDraft>) {
        setLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)))
    }

    // ★ Q5 的必填 `dirty`:这张表现在有没有没保存的东西。它只喂 `beforeunload`。
    //   ☞【它盖不住的那一半,照直说】站内 <Link>(下面那颗「取消」)**不会拦** ——
    //     那是组件抬头声明过的限制,而对一颗取消钮来说那也正是对的:
    //     **明说要走的人不该被再问一遍。**
    const linesDirty = lines.some(
        (l) => l.material_id !== '' || l.qty.trim() !== '' || l.price.trim() !== '')

    const rows: LineRow[] = lines.map((l, i) => ({ ...l, i }))
    const materialLabel = (id: string) => {
        const m = materials.find((x) => x.id === id)
        return m ? `${m.code} — ${m.name}` : '—'
    }

    /* ★ DRAFT-2 / Q4:**序号那一列是新加的,今天这张表没有它。**
       建单页的五个空槽内容完全相同 —— 手机上留下来的那一列如果只有物料,
       没挑之前五行全是「—」,**屏幕上认不出在改哪一行**。序号把它们分开,
       而这正是 `#8 NewOrderForm` 与 `#9 TemplateForm` 已经有的那一列(「序号」)。 */
    const lineColumns: EditableColumn<LineRow, LineRow>[] = [
        {
            key: 'seq',
            header: t('sales.colSeq'),
            priority: true,
            className: 'w-10',
            render: (r) => (
                <span className="text-[color:var(--brand-muted-text)]">{r.i + 1}</span>
            ),
        },
        {
            key: 'material',
            header: t('sales.colMaterial'),
            priority: true,
            render: (r) => materialLabel(r.material_id),
            // ★ `'page-owned'` 下 `edit` 的第一个参数【就是那一行】,而那个 `set`
            //   是一条按名拒绝 —— 页面走自己的 `patchLine`。
            edit: (r) => (
                <select value={r.material_id} aria-label={t('sales.colMaterial')}
                        onChange={(e) => patchLine(r.i, { material_id: e.target.value })}
                        className={`${CONTROL_SELECT} w-full`}>
                    <option value="">{t('sales.form.selectMaterial')}</option>
                    {materials.map((m) => (
                        <option key={m.id} value={m.id}>{m.code} — {m.name}</option>
                    ))}
                </select>
            ),
        },
        {
            key: 'qty',
            header: t('sales.form.qty'),
            align: 'right',
            render: (r) => (r.qty.trim() === '' ? '—' : r.qty),
            edit: (r) => (
                <input type="number" step="any" min="0" value={r.qty}
                       aria-label={t('sales.form.qty')}
                       onChange={(e) => patchLine(r.i, { qty: e.target.value })}
                       className={`${CONTROL_INPUT} w-28 text-right tabular-nums`} />
            ),
        },
        {
            key: 'price',
            header: t('sales.form.unitPrice'),
            align: 'right',
            render: (r) => (r.price.trim() === '' ? '—' : r.price),
            edit: (r) => (
                <input type="number" step="any" min="0" value={r.price}
                       aria-label={t('sales.form.unitPrice')}
                       onChange={(e) => patchLine(r.i, { price: e.target.value })}
                       className={`${CONTROL_INPUT} w-28 text-right tabular-nums`} />
            ),
        },
    ]

    // 【两个日期都空着就不给按】它们都决定一件真实的事,而服务端也【独立】拒空
    // (AGENTS.md:两道闸,UI 那道不是保护)。
    const blocked = quoteDate.trim() === '' || validUntil.trim() === ''

    return (
        <div className="p-8 max-w-3xl">
            <div className="mb-6">
                <Link href="/sales/quotes" className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="mb-6">{t('quotes.newTitle')}</h1>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                <div>
                    <label className="block mb-1">
                        {t('quotes.form.customer')} <span className="text-red-600">*</span>
                    </label>
                    <select name="customer_id" required defaultValue=""
                            className={`${CONTROL_SELECT} w-full`}>
                        <option value="">{t('sales.form.selectCustomer')}</option>
                        {customers.map((c) => (
                            <option key={c.id} value={c.id}>{c.code} — {c.legal_name}</option>
                        ))}
                    </select>
                    {state.fieldErrors?.customer_id && (
                        <p className="text-xs text-red-600 mt-1">{state.fieldErrors.customer_id}</p>
                    )}
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('quotes.form.customerWhy')}</p>
                </div>

                <div className="flex flex-wrap gap-4">
                    <div>
                        <label className="block mb-1">
                            {t('quotes.form.quoteDate')} <span className="text-red-600">*</span>
                        </label>
                        <input type="date" name="quote_date" value={quoteDate}
                               onChange={(e) => setQuoteDate(e.target.value)}
                               className={CONTROL_INPUT} />
                        {state.fieldErrors?.quote_date && (
                            <p className="text-xs text-red-600 mt-1">{state.fieldErrors.quote_date}</p>
                        )}
                    </div>
                    <div>
                        <label className="block mb-1">
                            {t('quotes.form.validUntil')} <span className="text-red-600">*</span>
                        </label>
                        <input type="date" name="valid_until" value={validUntil}
                               onChange={(e) => setValidUntil(e.target.value)}
                               className={CONTROL_INPUT} />
                        {state.fieldErrors?.valid_until && (
                            <p className="text-xs text-red-600 mt-1">{state.fieldErrors.valid_until}</p>
                        )}
                    </div>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('quotes.form.datesWhy')}</p>

                <div className="flex flex-wrap gap-4">
                    <div>
                        <label className="block mb-1">
                            {t('sales.form.currency')} <span className="text-red-600">*</span>
                        </label>
                        <select name="currency" required defaultValue=""
                                className={CONTROL_SELECT}>
                            <option value="">—</option>
                            {currencies.map((c) => (<option key={c} value={c}>{c}</option>))}
                        </select>
                        {state.fieldErrors?.currency && (
                            <p className="text-xs text-red-600 mt-1">{state.fieldErrors.currency}</p>
                        )}
                    </div>
                    <div>
                        <label className="block mb-1">
                            {t('sales.form.fxRate')} <span className="text-red-600">*</span>
                        </label>
                        <input type="number" step="any" min="0" name="fx_rate"
                               className={CONTROL_INPUT} />
                        {state.fieldErrors?.fx_rate && (
                            <p className="text-xs text-red-600 mt-1">{state.fieldErrors.fx_rate}</p>
                        )}
                    </div>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('sales.form.fxRateWhy')}</p>

                <h2 className="pt-2">{t('sales.form.lines')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('quotes.form.linesWhy')}</p>
                {state.fieldErrors?.lines && (
                    <p className="text-xs text-red-600">{state.fieldErrors.lines}</p>
                )}
                {/* ★★ (b) 那座桥 —— **画在表外面,只画一遍**。
                    组件把列回调画两遍(桌面格 + 手机展开区),所以具名输入不许进格子;
                    这一个不在格子里,于是它在 FormData 里**只出现一次**。
                    `scripts/check-editable-name.mjs` 守着前半句,footer/表外刻意不在它判据内。 */}
                <input type="hidden" name="lines_json" value={JSON.stringify(lines)} />
                <EditableTable<LineRow, LineRow>
                    rows={rows}
                    columns={lineColumns}
                    // 槽号即键:这张表没有加行/删行,所以下标不会在行底下挪动。
                    rowKey={(r) => String(r.i)}
                    phone={{ mode: 'columns' }}
                    mode="page-owned"
                    dirty={linesDirty}
                    // ★ Q6:`'page-owned'` 只要一个 `expand` —— 另外五个渲染不到。
                    labels={{ expand: t('common.expandRow') }}
                />

                <div>
                    <label className="block mb-1">{t('sales.form.notes')}</label>
                    <textarea name="notes"
                              className={`${CONTROL_TEXTAREA} w-full`} />
                </div>
                <div>
                    <label className="block mb-1">{t('quotes.form.terms')}</label>
                    <textarea name="terms_text"
                              className={`${CONTROL_TEXTAREA} w-full`} />
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('quotes.form.termsWhy')}</p>
                </div>

                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('quotes.form.savesAsDraft')}</p>
                <div className="flex gap-3 pt-2">
                    <Button type="submit" disabled={isPending || blocked}>
                        {isPending ? t('common.saving') : t('quotes.form.save')}
                    </Button>
                    <Button asChild variant="secondary">
                        <Link href="/sales/quotes">
                            {t('common.cancel')}
                        </Link>
                    </Button>
                </div>
                {blocked && <p className="text-xs text-amber-700">{t('quotes.form.blockedDates')}</p>}
            </form>
        </div>
    )
}
