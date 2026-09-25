'use client'

// CN-1:开一张贷项凭证的表单。
//
// 【本表单不自己判断能冲多少】三条天花板在服务端,拒绝由数据库按名给出。
// 这里做的只有三件事:
//   * 把【两个上限】写在行上 —— 未释放的负债 / 已释放的收入,两个数对应两种
//     完全不同的事,而"这一行还能冲多少"取决于你选哪一种(CMP-2);
//   * 类型是【选出来的,不是猜出来的】—— 少发了货与事后减价过的账不同科目,
//     让系统按"有没有发货"替人选,就是替他做了一个会计判断;
//   * 后果句在按下之前:这张凭证会减少客户在【这张发票】上欠的钱。
// 表单上的提示是【礼貌】,不是保护。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useActionState, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import { createCreditNote, type CreditNoteState } from './creditNoteActions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

/** 桥上交出去的一行。
 *  ★ **`qty` 是可选的,而那【不是】图省事** —— 服务端的
 *  `...(q === '' ? {} : { qty: Number(q) })`(`creditNoteActions.ts:41`)判的是
 *  **键在不在**。写成 `null` 或 `undefined` 都不是同一件事。 */
type CnLinePayload = { invoice_line_id: string; kind: string; amount: string; qty: string }

export type CnLineOption = {
    id: string
    line_no: number
    description: string
    unit: string
    amount_ccy: number
    /** null = 看不到发货(module.sales.view 缺席),不是 0 */
    unreleased: number | null
    releasedRemaining: number | null
}

const initialState: CreditNoteState = {}

export default function CreateCreditNoteControl({
    invoiceId, invoiceCode, currency, openCcy, lines,
canEdit
}: {
    invoiceId: string; invoiceCode: string; currency: string
    openCcy: number; lines: CnLineOption[]

canEdit: boolean
}) {
    const t = useTranslations()
    const bound = createCreditNote.bind(null, invoiceId)
    const [state, formAction, isPending] = useActionState(bound, initialState)
    const [open, setOpen] = useState(false)
    const [noteDate, setNoteDate] = useState('')
    const [kind, setKind] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, 'unshipped_cancel'])))
    const [amount, setAmount] = useState<Record<string, string>>({})
    /* ★★ `cn_qty` 搬家前是**唯一一个真正非受控**的格子
       (`<input type="number" name="cn_qty" />`,没有 value、没有 onChange)——
       桥要求页面持有它,所以它从今天起是页面 state。
       ⚠ 另外两个(`cn_kind` / `cn_line_id`)**本来就已经是页面 state 了**:
         前者镜像 `kind[l.id]`,后者就是行 id。**不要重新推导它们。** */
    const [qty, setQty] = useState<Record<string, string>>({})

    const entered = lines
        .map((l) => ({ l, n: Number(amount[l.id] ?? '') }))
        .filter((x) => (amount[x.l.id] ?? '').trim() !== '' && !Number.isNaN(x.n))
    const total = Math.round(entered.reduce((s, x) => s + x.n, 0) * 100) / 100
    const overOpen = total > openCcy
    // 【日期空着就不给按】它决定冲销落进哪个会计期间,而服务端也【独立】拒空
    // (AGENTS.md:两道闸,UI 那道不是保护)。
    // ★ APR-5b(grilling Q1):一条【未发货取消】要说出取消了多少数量 —— 发货的天花板是
    //   开票数量 − 取消的数量 − 已发,所以服务端在提交时按名拒 CN_UNSHIPPED_CANCEL_QTY_REQUIRED。
    //   这里是同一条判据的第一道(看得见、按不动、说出理由),不是保护。
    const missingQty = entered.some((x) =>
        (kind[x.l.id] ?? 'unshipped_cancel') === 'unshipped_cancel'
        && !(Number((qty[x.l.id] ?? '').trim()) > 0))
    const blocked = noteDate.trim() === '' || entered.length === 0 || overOpen || missingQty

    // ── 逐行派生值:搬家前住在 `lines.map` 的闭包里,现在是行的函数 ──────────
    //    ★ 两份「两档共用的内容」照旧【提出来写一次】(TABLE-PHONE-4 的原话)。
    const kindOf = (l: CnLineOption) => kind[l.id] ?? 'unshipped_cancel'
    const ceilingOf = (l: CnLineOption) =>
        kindOf(l) === 'unshipped_cancel' ? l.unreleased : l.releasedRemaining
    const overOf = (l: CnLineOption) => {
        const c = ceilingOf(l)
        return (amount[l.id] ?? '').trim() !== '' && c !== null && Number(amount[l.id] ?? '') > c
    }
    const MONEY_WHY = '同表列头 冲减({ccy}),整张表单同一个币种'
    const unreleasedText = (l: CnLineOption) => l.unreleased === null
        ? <span className="font-sans text-[color:var(--brand-muted-text)]">{t('common.restricted')}</span>
        : formatMoneyBare(l.unreleased, MONEY_WHY)
    const releasedText = (l: CnLineOption) => l.releasedRemaining === null
        ? <span className="font-sans text-[color:var(--brand-muted-text)]">{t('common.restricted')}</span>
        : formatMoneyBare(l.releasedRemaining, MONEY_WHY)
    const kindSelect = (l: CnLineOption) => (
        <select value={kindOf(l)}
                aria-label={t('cn.colKind')}
                onChange={(e) => setKind((s) => ({ ...s, [l.id]: e.target.value }))}
                className={CONTROL_SELECT}>
            <option value="unshipped_cancel">{t('cn.kind.unshipped_cancel')}</option>
            <option value="revenue_reduction">{t('cn.kind.revenue_reduction')}</option>
        </select>
    )

    /* ★★ 桥的载荷。**每一行带着自己的四个值** —— 服务端因此不再按下标配对。
       ⚠ 交的是**原始字符串**:空与零的区别、以及「填了一半」这件事,
         都留给服务端那一段原样的判据去处理。**这一刀不替它决定任何一格。** */
    const cnPayload: CnLinePayload[] = lines.map((l) => ({
        invoice_line_id: l.id,
        kind: kindOf(l),
        amount: amount[l.id] ?? '',
        qty: qty[l.id] ?? '',
    }))

    /* ★ Q5 的必填 `dirty` —— 这张表单开局全空(`amount` / `qty` 都是 `{}`),
       所以「有没有内容」与「与进门时那一份比」在这里是同一件事,取简单的。
       ☞ `kind` 不算脏:它进门就有一个默认值(`unshipped_cancel`),
         改它而一个金额都没填,**没有任何东西会丢**。
       ☞ 站内 `<Link>` 不拦 —— 组件抬头声明过的限制;而这张表单的「取消」
         是一颗 `type="button"`,它把整块收起来,同样不经过 `beforeunload`。 */
    const cnDirty = lines.some(
        (l) => (amount[l.id] ?? '').trim() !== '' || (qty[l.id] ?? '').trim() !== '')

    /* ════════════════════════════════════════════════════════════════════════
       ★★★【七列怎么活下来 —— Tim 的 Q2 裁定,照 `#22` 的办法】★★★
       `page-owned` 下展开区只画【有 `edit` 的列】(`editable-table.tsx:632`),
       于是「尚未交付 / 已交付,可冲减」这两列只读的数在 390px 上会**整个消失**。
       ☞ 裁定不是把它们 priority 掉,而是**照这个文件今天已经在做的那样**
         (`TABLE-PHONE-4` 的叠加块)把它们叠进发票行那一格的 `render` 里 ——
         桌面照旧是列,手机上**零次点按**看得见。
       ★★ 而「类型」那一列的处置【变了,照直记】:搬家前它两档各画一份
         (安全,因为它不带 name);现在它是一个**有 `edit` 的列**,
         于是手机上它进展开区 —— **0 → 1 次点按**。
         ☞ 那句旧注释说「收进折叠区意味着改它要多滚一下,换得起」——
           今天换的是「多点一下」,而**那个判断照旧成立**。
       ★ 而搬家前那条「凡是带 name 的输入框一律留在明面上」的规矩,
         今天**整条不存在了**:格子里一个 `name=` 都没有。
       ════════════════════════════════════════════════════════════════════════ */
    const cnColumns: EditableColumn<CnLineOption, CnLineOption>[] = [
        {
            key: 'seq',
            header: t('invoice.colLineNo'),
            priority: true,
            render: (l) => l.line_no,
        },
        {
            key: 'line',
            header: t('cn.colLine'),
            priority: true,
            render: (l) => (
                <>
                    {l.description}
                    {/* ★★ TABLE-PHONE-4 那块叠加块,逐字搬过来 —— 两列只读的数
                        带着各自的列头叠在这里,**零次点按**。
                        ⚠ 它们【不能】改走展开区:那里只画有 `edit` 的列。 */}
                    <div className="sm:hidden mt-1 space-y-1 font-sans text-xs text-gray-600">
                        <div>
                            <span className="font-sans text-gray-500">{t('cn.colUnreleased')}: </span>
                            {unreleasedText(l)}
                        </div>
                        <div>
                            <span className="font-sans text-gray-500">{t('cn.colReleased')}: </span>
                            {releasedText(l)}
                        </div>
                    </div>
                </>
            ),
        },
        {
            key: 'unreleased',
            header: t('cn.colUnreleased'),
            align: 'right',
            render: (l) => unreleasedText(l),
        },
        {
            key: 'released',
            header: t('cn.colReleased'),
            align: 'right',
            render: (l) => releasedText(l),
        },
        {
            key: 'kind',
            header: t('cn.colKind'),
            render: (l) => t('cn.kind.' + kindOf(l)),
            edit: (l) => kindSelect(l),
        },
        {
            key: 'qty',
            header: t('cn.colQty'),
            align: 'right',
            /* 【数量可空,而且这不是偷懒】一次整批折让往往不对应任何数量,
               硬要一个就得编一个 —— 金额才是主语。 */
            render: (l) => ((qty[l.id] ?? '').trim() === '' ? '—' : qty[l.id]),
            edit: (l) => (
                <input type="number" step="any" min="0" value={qty[l.id] ?? ''}
                       aria-label={t('cn.colQty')}
                       onChange={(e) => setQty((s) => ({ ...s, [l.id]: e.target.value }))}
                       className={`${CONTROL_INPUT} w-20 text-right tabular-nums`} />
            ),
        },
        {
            key: 'amount',
            header: t('cn.colAmount', { ccy: currency }),
            align: 'right',
            render: (l) => ((amount[l.id] ?? '').trim() === '' ? '—' : amount[l.id]),
            edit: (l) => (
                <>
                    <input type="number" step="any" min="0" value={amount[l.id] ?? ''}
                           aria-label={t('cn.colAmount', { ccy: currency })}
                           onChange={(e) => setAmount((s) => ({ ...s, [l.id]: e.target.value }))}
                           className={`${CONTROL_INPUT} w-24 text-right tabular-nums`} />
                    {overOf(l) && (
                        <p className="text-xs text-red-600 mt-1">
                            {t('cn.overCeiling', { ceiling: formatMoneyBare(ceilingOf(l) as number, MONEY_WHY) })}
                        </p>
                    )}
                </>
            ),
        },
    ]

    // APR-5a:申请已提、在等 CFO —— 表单收起,说清楚它去了哪里(页面刷新后申请那一块会摆出它)
    if (state.submitted) {
        return (
            <p className="text-sm border-l-4 border-amber-500 pl-3" data-state-note="credit-note-requested">
                {t('finance.invoiceRequest.creditNoteSubmitted', { label: state.submitted })}
            </p>
        )
    }

    if (!open) {
        return (
            <PermissionGate code="module.finance.edit" allowed={canEdit}>
            <Button type="button" onClick={() => setOpen(true)}
                    variant="secondary">
                {t('cn.create')}
            </Button>
            </PermissionGate>
        )
    }

    // 【这张表单不再单独上闸】上面那个"新建"钮已经上了闸,没有权限的人打不开它;
    // 而给整张表单上闸会连它自己的「取消」一起禁掉 —— 把人困在一张既提交不了、
    // 也关不掉的表单里。闸放在【打得开它的那个钮】上。
    return (
        <form action={formAction} className="border border-gray-300 rounded p-3 space-y-3">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded text-sm">
                    {state.error}
                </div>
            )}

            <div className="flex flex-wrap items-end gap-4">
                <div>
                    <label className="block mb-1">
                        {t('cn.noteDate')} <span className="text-red-600">*</span>
                    </label>
                    <input type="date" name="note_date" value={noteDate}
                           onChange={(e) => setNoteDate(e.target.value)}
                           className={CONTROL_INPUT} />
                </div>
                <div className="flex-1 min-w-[16rem]">
                    <label className="block mb-1">
                        {t('cn.reason')} <span className="text-red-600">*</span>
                    </label>
                    <input type="text" name="reason" required
                           className={`${CONTROL_INPUT} w-full`} />
                </div>
            </div>
            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('cn.noteDateHint')}</p>

            {/* ★★ (b) 那座桥 —— **画在表外面,只画一遍**(Tim 2026-09-21 的 Q1 裁定)。
                ★ 搬家前这里是**四条按下标配对的并列数组**(`cn_line_id` / `cn_kind` /
                  `cn_qty` / `cn_amount`),而上面那块被拆掉的注释整段都在讲
                  「凡是带 name 的输入框一律留在明面上,否则折叠会把配对弄错位」。
                ☞ **那条规矩今天整条不存在了** —— 格子里一个 `name=` 都没有,
                  每一行自己带着自己的四个值,**没有配对可以错位**。
                  (与 `#22` 是同一件事的另一张脸,见 `docs/known-issues.md` 的
                   `SALES-AMEND-DISABLED-ARRAY-SHIFT`。) */}
            <input type="hidden" name="cn_lines_json" value={JSON.stringify(cnPayload)} />
            <EditableTable<CnLineOption, CnLineOption>
                rows={lines}
                columns={cnColumns}
                rowKey={(l) => l.id}
                phone={{ mode: 'columns' }}
                mode="page-owned"
                dirty={cnDirty}
                labels={{ expand: t('common.expandRow') }}
            />

            <div className="flex flex-wrap items-baseline gap-x-4 text-sm">
                <span>
                    <span className="text-[color:var(--brand-muted-text)]">{t('cn.totalLabel')}:</span>{' '}
                    <span>{formatAmount(total, currency)}</span>
                </span>
                <span className="text-[color:var(--brand-muted-text)]">
                    {t('cn.openLabel', { amount: formatMoneyBare(openCcy, '本句里紧跟着 {ccy}'), ccy: currency })}
                </span>
            </div>
            {overOpen && <p className="text-xs text-red-600">{t('cn.overOpen')}</p>}

            {/* 【后果句在按下之前】—— 这张凭证会过账,而凭证只增不改 */}
            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('cn.consequence', { code: invoiceCode })}</p>

            <div className="flex gap-3">
                <Button type="submit" disabled={isPending || blocked}>
                    {isPending ? t('common.saving') : t('cn.submit')}
                </Button>
                <Button type="button" onClick={() => setOpen(false)}
                        variant="secondary">
                    {t('common.cancel')}
                </Button>
            </div>
            {noteDate.trim() === '' && <p className="text-xs text-amber-700">{t('cn.blockedNoDate')}</p>}
            {missingQty && <p className="text-xs text-amber-700">{t('cn.blockedNoQty')}</p>}
        </form>
    )
}
