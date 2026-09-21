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
import { CONTROL_CHECKBOX, CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { soStatusKey } from '../../salesOrderTypes'
import { amendOrder, type AmendState } from './actions'
import { Button } from '@/app/components/ui/button'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

/** ★ 桥上交出去的【既有行】。`amend_sales_order` 靠 `id` 与 `material_id` 哪一个在
 *  来分辨改行与加行(`db/functions/amend_sales_order.sql:100` · `:132`),
 *  所以这两个键的**有无**是承重的,不是装饰。 */
type ExistingLinePayload = {
    id: string
    line_no: number
    remove: boolean
    quantity: string
    unit_price: string
}
/** ★ 桥上交出去的【加行槽】。三格全空的槽由服务端整槽跳过;
 *  **填了一半的槽原样递过去** —— 由 `SO_AMEND_LINE_INVALID` 点名是哪一格。 */
type NewLinePayload = { material_id: string; quantity: string; unit_price: string }
/** 渲染用的行:多带一个槽号,而它【不进桥】—— 与 `#24` 的 `i` 同一条。
 *  这三个空槽内容完全相同,光看 `row` 生不出一个互不相同的键。 */
type NewLineRow = NewLinePayload & { i: number }

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
    /* ★★ `#23` 从【非受控的具名空槽】变成【页面持有的数组】(Tim 的 (b) 裁定)。
       搬家前它是 `new_material_${i}` / `new_qty_${i}` / `new_price_${i}` 三组下标名字。 */
    const [newLines, setNewLines] = useState<NewLinePayload[]>(
        () => Array.from({ length: NEW_SLOTS }, () => ({ material_id: '', quantity: '', unit_price: '' })))

    const mode = isDraft ? 'draft' : addOnly ? 'addonly' : 'amend'

    // ── 逐行派生值:搬家前它们住在 `lines.map` 的闭包里,现在是行的函数 ──────
    //    ★ 四份「两档共用的内容」照旧【提出来写一次】(TABLE-PHONE-4 的原话:
    //      抄成两份就是让两份将来各走各的,而漂移在桌面上看不见)。
    const isGone = (l: AmendLine) => !!remove[l.id]
    const isBilled = (l: AmendLine) => l.invoice_code !== null
    // 【三条可操作的 + 一条不可操作的】has_record 指不出下一步 ——
    // 没有任何动作能让一件发生过的事没发生过。
    const cannotRemove = (l: AmendLine) =>
        isBilled(l) || l.shipped > 0 || l.reserved > 0 || l.has_record
    const invoicedText = (l: AmendLine) =>
        !canSeeInvoices ? (
            // 【受限 ≠ 未开票】前者是"你看不到",后者是"确实没有"
            <span className="text-[color:var(--brand-muted-text)] font-sans">{t('common.restricted')}</span>
        ) : isBilled(l) ? (
            <>
                {l.invoiced} {l.unit}
                <span className="block text-[color:var(--brand-muted-text)]">{l.invoice_code}</span>
            </>
        ) : (
            <span className="text-gray-400 font-sans">{t('sales.invoice.lineUnbilled')}</span>
        )
    const reservedText = (l: AmendLine) => <>{l.reserved} {l.unit}</>
    const shippedText = (l: AmendLine) => (
        <>
            {l.shipped} {l.unit}
            {l.shipment_code && (
                <span className="block text-[color:var(--brand-muted-text)]">{l.shipment_code}</span>
            )}
        </>
    )

    /* ★ Q5 的必填 `dirty` —— 与进门时那一份比。这一页进门时格子里就有字
       (数量与单价预填的是这张单当前的值),按「有没有字」算会一进门就脏。
       ☞ 加行那三个空槽用「有没有内容」算 —— 它们进门时是空的,两种判据在这里同义。
       ☞ 站内 `<Link>`(取消钮)不拦,是组件抬头声明过的限制。 */
    const linesDirty = lines.some(
        (l) =>
            (qty[l.id] ?? '') !== String(l.quantity) ||
            (price[l.id] ?? '') !== String(l.unit_price) ||
            !!remove[l.id]
    )
    const newLinesDirty = newLines.some(
        (s) => s.material_id !== '' || s.quantity.trim() !== '' || s.unit_price.trim() !== '')

    function patchNewLine(i: number, patch: Partial<NewLinePayload>) {
        setNewLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)))
    }

    /* ★★ 既有行的桥载荷。**每一行带着它自己的值** —— 这正是那处下标错位
       被【拿掉】而不是被修好的地方(见下面桥那一处的注释)。
       ★ 交的是**原始字符串**,不是数字:空与零的区别、以及"还没敲完"的中间态,
         都留给服务端那一段原样的判据去处理。**这一刀不替它决定任何一格。**
       ★ `line_no` 是**新加的**(Tim 2026-09-21 收进本刀范围):
         `amend_sales_order` 报错时 `COALESCE(v_el->>'line_no', v_line_id::text)`
         优先用它(`db/functions/amend_sales_order.sql:165`),而搬家前的载荷
         **从来不送它** —— 于是 `SO_AMEND_LINE_INVALID` 点的是一串 **UUID**。
         送上它,那句拒绝从此点的是**行号**。 */
    const existingPayload: ExistingLinePayload[] = lines.map((l) => ({
        id: l.id,
        line_no: l.line_no,
        remove: isGone(l),
        quantity: qty[l.id] ?? '',
        unit_price: price[l.id] ?? '',
    }))

    /* ════════════════════════════════════════════════════════════════════════
       ★★★【`#22` 的列:四列只读的数怎么活下来 —— Tim 的 Q2 裁定(DRAFT-4)】★★★

       `page-owned` 下 `editing` 恒为真,而展开区只画【有 `edit` 的列】
       (`editable-table.tsx:632`)—— 一个**只读且非 priority** 的列在 390px 上
       **整个消失**(DRAFT-3 §0 的 G1,`#8` 的金额列付过一次账)。
       而这张表有【三列】这种:已开票 / 已预留 / 已发。

       ☞ **裁定不是把它们 priority 掉** —— 四个 priority 列正是这次搬家要治的那种溢出。
         裁的是:**照 `TABLE-PHONE-4` 今天已经在做的那样,把它们叠进物料那一格的
         `render` 里**,三份内容与上面那三个共用的函数**同源**。
       ☞ 于是:**桌面照旧是三列**(它们仍然是列,只是不 priority);
         **手机上它们仍然零次点按看得见**(叠在物料格里)。
         ★ 这与 `#8` 的金额那一半是同一条法则的两种载体:
           `#8` 只有一个数,`priority` 装得下;这里有三份带标签的内容,装不下,
           所以走的是「叠加块」那条 —— **而两条都不是走展开区**。
       ════════════════════════════════════════════════════════════════════════ */
    const lineColumns: EditableColumn<AmendLine, AmendLine>[] = [
        {
            /* ★ 序号留在明面上。搬家前它的列头是硬编码的 "#",而 `sales.colSeq`
               已经在册(`#24` 用的就是它)—— 于是一句文案都不用现造,
               而行号本来就是这张表跟人对话时用的号码(报错、审计都指它)。 */
            key: 'seq',
            header: t('sales.colSeq'),
            priority: true,
            render: (l) => l.line_no,
        },
        {
            key: 'material',
            header: t('sales.colMaterial'),
            priority: true,
            render: (l) => (
                <>
                    <span>{l.material_code}</span>{' '}
                    <span className="text-gray-500">{l.material_name}</span>
                    {/* ★★ TABLE-PHONE-4 那块叠加块,逐字搬过来 —— 手机档拿掉的三列,
                        带着各自的列头叠在这里,**零次点按**。
                        ⚠ 它【不能】改走展开区:`page-owned` 下展开区只画有 `edit` 的列,
                        而这三列是只读的 —— 走过去等于让它们整个消失。 */}
                    <div className="sm:hidden mt-1 space-y-1 font-sans text-xs text-gray-600">
                        <div>
                            <span className="font-sans text-gray-500">{t('sales.amend.colInvoiced')}: </span>
                            {invoicedText(l)}
                        </div>
                        <div>
                            <span className="font-sans text-gray-500">{t('sales.amend.colReserved')}: </span>
                            {reservedText(l)}
                        </div>
                        <div>
                            <span className="font-sans text-gray-500">{t('sales.amend.colShipped')}: </span>
                            {shippedText(l)}
                        </div>
                    </div>
                </>
            ),
        },
        {
            key: 'ordered',
            header: t('sales.amend.colOrdered'),
            align: 'right',
            render: (l) => qty[l.id] ?? '',
            edit: (l) => {
                const n = Number(qty[l.id] || 0)
                const gone = isGone(l)
                const belowShipped = !gone && n < l.shipped
                const belowReserved = !gone && !belowShipped && n < l.shipped + l.reserved
                return (
                    <>
                        <DecimalInput
                            value={qty[l.id] ?? ''}
                            onChange={(raw) => setQty((q) => ({ ...q, [l.id]: raw }))}
                            disabled={frozen || addOnly || gone || isBilled(l)}
                            className="w-24 text-right tabular-nums"
                        />
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
                    </>
                )
            },
        },
        {
            key: 'invoiced',
            header: t('sales.amend.colInvoiced'),
            align: 'right',
            render: (l) => invoicedText(l),
        },
        {
            key: 'reserved',
            header: t('sales.amend.colReserved'),
            align: 'right',
            render: (l) => reservedText(l),
        },
        {
            key: 'shipped',
            header: t('sales.amend.colShipped'),
            align: 'right',
            render: (l) => shippedText(l),
        },
        {
            key: 'price',
            header: t('sales.amend.colPrice', { ccy: currency }),
            align: 'right',
            render: (l) => price[l.id] ?? '',
            edit: (l) => (
                <DecimalInput
                    value={price[l.id] ?? ''}
                    onChange={(raw) => setPrice((p) => ({ ...p, [l.id]: raw }))}
                    disabled={frozen || addOnly || isGone(l) || isBilled(l)}
                    className="w-24 text-right tabular-nums"
                />
            ),
        },
    ]

    const materialLabel = (id: string) => {
        const m = materials.find((x) => x.id === id)
        return m ? `${m.code} — ${m.name}` : '—'
    }
    const newLineRows: NewLineRow[] = newLines.map((l, i) => ({ ...l, i }))

    /* ★ `#23` 的列。序号那一列是**新加的** —— 三个空槽内容完全相同,
       手机上留下来的那一列如果只有物料,没挑之前三行全是「—」,
       **屏幕上认不出在改哪一行**。这与 `#24` 的 Q4 裁定逐字同源,用的也是同一个键。 */
    const newLineColumns: EditableColumn<NewLineRow, NewLineRow>[] = [
        {
            key: 'seq',
            header: t('sales.colSeq'),
            priority: true,
            render: (r) => r.i + 1,
        },
        {
            key: 'material',
            header: t('sales.colMaterial'),
            render: (r) => materialLabel(r.material_id),
            edit: (r) => (
                <select
                    value={r.material_id}
                    aria-label={t('sales.colMaterial')}
                    onChange={(e) => patchNewLine(r.i, { material_id: e.target.value })}
                    className={`${CONTROL_SELECT} w-full`}
                >
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
            render: (r) => (r.quantity.trim() === '' ? '—' : r.quantity),
            edit: (r) => (
                <input type="number" step="any" min="0" value={r.quantity}
                       aria-label={t('sales.form.qty')}
                       onChange={(e) => patchNewLine(r.i, { quantity: e.target.value })}
                       className={`${CONTROL_INPUT} w-24 text-right tabular-nums`} />
            ),
        },
        {
            key: 'price',
            header: t('sales.amend.colPrice', { ccy: currency }),
            align: 'right',
            render: (r) => (r.unit_price.trim() === '' ? '—' : r.unit_price),
            edit: (r) => (
                <input type="number" step="any" min="0" value={r.unit_price}
                       aria-label={t('sales.amend.colPrice', { ccy: currency })}
                       onChange={(e) => patchNewLine(r.i, { unit_price: e.target.value })}
                       className={`${CONTROL_INPUT} w-24 text-right tabular-nums`} />
            ),
        },
    ]


    return (
        <div className="max-w-5xl">
            <div className="mb-6">
                <Link href={`/sales/orders/${orderId}`} className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="mb-2">
                {isDraft ? t('sales.amend.draftTitle', { code }) : t('sales.amend.title', { code })}
            </h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-6 max-w-3xl">
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
                <h2 className="mb-1">{t('sales.amend.frozenTitle')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-3 max-w-3xl">{t('sales.amend.frozenWhy')}</p>
                <dl className="grid grid-cols-2 gap-x-8 gap-y-1 text-sm">
                    <div><dt className="inline text-[color:var(--brand-muted-text)]">{t('sales.colCode')}: </dt>
                         <dd className="inline">{code}</dd></div>
                    <div><dt className="inline text-[color:var(--brand-muted-text)]">{t('sales.colCustomer')}: </dt>
                         <dd className="inline">{customerLabel}</dd></div>
                    <div><dt className="inline text-[color:var(--brand-muted-text)]">{t('sales.colDate')}: </dt>
                         <dd className="inline">{orderDate}</dd></div>
                    <div><dt className="inline text-[color:var(--brand-muted-text)]">{t('sales.colCurrency')}: </dt>
                         <dd className="inline">{currency} @ {fxRate}</dd></div>
                </dl>
            </div>

            <form action={formAction} className="space-y-4">
                <input type="hidden" name="mode" value={mode} />

                {/* 【草稿没有理由这一栏】—— 不是隐藏一个必填项,是它在草稿态真的不存在 */}
                {!isDraft && (
                    <div>
                        <label className="block mb-1">
                            {t('sales.amend.reason')} <span className="text-red-600">*</span>
                        </label>
                        <input type="text" name="reason" required disabled={frozen}
                               className={`${CONTROL_INPUT} w-full`} />
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('sales.amend.reasonHint')}</p>
                    </div>
                )}

                {/* ── 明细 ──────────────────────────────────────────────────── */}
                <h2 className="pt-2">{t('sales.form.lines')}</h2>
                {/* ════════════════════════════════════════════════════════════════
                    ★ TABLE-PHONE-4:八列 → 手机档留四列(# · 物料 · 已订 · 单价)。
                    被拿掉的三列(已开票 / 已预留 / 已发)一个字段都没丢:
                    带着各自的列头叠在物料那一格里,见下面 sm:hidden 的那一块。
                    ★★ TABLE-STYLE-1 / R1(Tim 裁定,2026-09-09):【删除那一列不再折】。
                      原来它是被拿掉的第四列;现在它留在明面上,叠着的那一份拿掉了。
                      理由不是"这一列更值得读",而是**它不是一个要读的数,是一个要按的控件**
                      —— 够不着的动作等于不存在(DBLOCK-1 用在版式上)。
                      规矩见 docs/base-components.md §二十。
                    ☞ 改一张销售单,手指落在【已订】与【单价】上 —— 两个输入框都留住。
                      已开票/已预留/已发是三个【读】的数,读在折叠区里不多花一次点击;
                      而两条下限告警(belowShipped / belowReserved)本来就印在数量框底下,
                      所以"已发多少"在真要用到它的那一刻仍然在眼前。
                    ★【# 这一列留在明面上,不是凑数】它的列头是硬编码的 "#",没有 i18n key;
                      收进折叠区就要现造一句话,而委托书禁止现造。留着它,一句都不用造 ——
                      而行号本来就是这张表跟人对话时用的号码(报错、审计都指它)。
                    ★ 删除那一列的复选框【不带 name】(它的值由第一格里渲染一次的
                      <input type="hidden" name="line_remove"> 携带)。R1 之后它只画【一份】,
                      而在此之前画两份也是安全的 —— 两句话都记着,因为安全的理由(没有 name)
                      与只画一份的理由(不重复控件)不是同一条。
                      带 name 的两个(line_quantity / line_price)都留在明面上,没有一个被复制。
                    ════════════════════════════════════════════════════════════════ */}
                {/* ★★ (b) 那座桥 —— **画在表外面,只画一遍**(Tim 2026-09-21 的 Q1 裁定)。
                    ★★★ 而这一座桥【顺手修掉了一处在册之外的缺陷】,理由是构造上的:
                    搬家前服务端按【并列数组的下标】把 `line_id` / `line_quantity` /
                    `line_price` / `line_remove` 配对,而 `DecimalInput` 给了 `name` 时
                    渲染的那个隐藏输入**带着 `disabled`**(`DecimalInput.tsx:78`)——
                    **一个 disabled 的字段根本不提交**。于是被勾掉的行、以及已开票的行
                    在 `line_quantity` 里没有位置,它【后面】每一行的下标全部前移一格。
                    ☞ **`PUR-1` 在采购那一侧修过同一处**(`purchasing/orders/[id]/amend/
                    AmendOrderForm.tsx:165-179` 写着全过程),**而销售这一侧没有人修**,
                    并且这里还多一个采购没有的触发器:**已开票(`billed`)**。
                    ☞ 桥让每一行**自己带着自己的值**,于是那个配对不再存在 ——
                    **它不是被修好的,是被【拿掉了】。** 见 `docs/known-issues.md`。 */}
                <input type="hidden" name="lines_json" value={JSON.stringify(existingPayload)} />
                <EditableTable<AmendLine, AmendLine>
                    rows={lines}
                    columns={lineColumns}
                    rowKey={(l) => l.id}
                    phone={{ mode: 'columns' }}
                    mode="page-owned"
                    dirty={linesDirty}
                    labels={{ expand: t('common.expandRow') }}
                    // ★ 能力 B:勾掉的行变灰 —— 与搬家前逐字相同的两个类。
                    rowClassName={(l) => (isGone(l) ? 'bg-gray-100 text-gray-400' : undefined)}
                    /* ★★★ 能力 A:移除勾选走 `rowActions`,于是它在手机上画在**展开区末尾**
                       —— **Tim 的 Q7 裁定(2026-09-21)**,理由与代价见
                       `app/components/ui/editable-table.tsx` 抬头 ④ 下面那一段。
                       ⚠ 照直记:**这一颗从 0 次点按变成 1 次点按**,正是
                       `TABLE-STYLE-1 / R1`(`docs/base-components.md` §20.1)当年
                       在**这一张表**上刚买下来的那一次。**这是一次有意的回退**,
                       而它不是一次偏好:`editable-table.tsx:676-679` 让手机档的
                       每一个格子都只读,**一颗留在明面上的勾选框会是按不动的**。 */
                    rowActions={(l) => (
                        <label className="">
                            <input className={CONTROL_CHECKBOX} type="checkbox" checked={isGone(l)}
                                disabled={frozen || addOnly || cannotRemove(l)}
                                onChange={(e) => setRemove((r) => ({ ...r, [l.id]: e.target.checked }))} />
                            <span className="ml-1">
                                {cannotRemove(l) ? t('sales.amend.cannotRemove') : t('sales.amend.remove')}
                            </span>
                        </label>
                    )}
                />

                {/* 【已开票的行:两条出路都说出来】数字错了 → 先作废那张票;
                    客户要加量 → 另起一行(整单发完之后也走得通) */}
                {lines.some((l) => l.invoice_code !== null) && (
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('sales.amend.invoicedNote')}</p>
                )}

                {/* ── 加行 ──────────────────────────────────────────────────── */}
                {!frozen && (
                    <>
                        <h2 className="pt-2">{t('sales.amend.addLines')}</h2>
                        <p className="text-xs text-[color:var(--brand-muted-text)]">{t('sales.amend.addLinesHint')}</p>
                        {/* ★★ 第二座桥 —— **两张表,两座桥**,而不是一个合起来的数组。
                            理由:两张表的列不是同一组(既有行可以逐行锁住、加行槽永远敞着),
                            合成一个联合行类型会让**一半的列在另一半上没有意义**;
                            而服务端本来就靠 `id` / `material_id` 哪一个在来分辨这两族
                            (`amend_sales_order.sql:100` · `:132`),**不靠它们在不在同一个数组里**。 */}
                        <input type="hidden" name="new_lines_json" value={JSON.stringify(newLines)} />
                        <EditableTable<NewLineRow, NewLineRow>
                            rows={newLineRows}
                            columns={newLineColumns}
                            // 槽号即键:这张表不加行不删行,下标不会在行底下挪动。
                            rowKey={(r) => String(r.i)}
                            phone={{ mode: 'columns' }}
                            mode="page-owned"
                            dirty={newLinesDirty}
                            labels={{ expand: t('common.expandRow') }}
                        />
                    </>
                )}

                {/* ── 表头上可改的那两列 ─────────────────────────────────────── */}
                {!addOnly && (
                    <>
                        <h2 className="pt-2">{t('sales.amend.headerTitle')}</h2>
                        <p className="text-xs text-[color:var(--brand-muted-text)]">{t('sales.amend.headerWhy')}</p>
                        <div>
                            <label className="block mb-1">{t('sales.form.notes')}</label>
                            <textarea name="notes" defaultValue={notes} disabled={frozen}
                                      className={`${CONTROL_TEXTAREA} w-full`} />
                        </div>
                        <div>
                            <label className="block mb-1">{t('sales.amend.terms')}</label>
                            <textarea name="terms_text" defaultValue={termsText} disabled={frozen}
                                      className={`${CONTROL_TEXTAREA} w-full`} />
                            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('sales.amend.termsHint')}</p>
                        </div>
                    </>
                )}

                <div className="flex gap-3 pt-2">
                    <Button type="submit" disabled={isPending || frozen}>
                        {isPending ? t('common.saving') : t('sales.amend.submit')}
                    </Button>
                    <Button asChild variant="secondary">
                        <Link href={`/sales/orders/${orderId}`}>
                            {t('common.cancel')}
                        </Link>
                    </Button>
                </div>
            </form>
        </div>
    )
}
