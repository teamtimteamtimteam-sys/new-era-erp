'use client'

// PUR-2:修改采购单的表单。
//
// 【本表单不自己判断能不能改】守卫在触发器上,拒绝由 DB 点名。这里做的只有两件事:
//   * 把【已收多少】写在行上 —— 下限要在动手之前看得见,而不是保存之后才被拒(CMP-2);
//   * 理由必填 —— 一次改动没有理由,历史上就只是一行"数字变了"。
// 真正的把关仍在 DB:表单上的提示是【礼貌】,不是保护。
//
// ────────────────────────────────────────────────────────────────────────────
// ★★★ DRAFT-7(2026-09-21)· 这张表搬上 `EditableTable` + **两座 JSON 桥** ★★★
//
//   明细网格从手搓 `<table>` 换成 `mode='page-owned'` 的 `<EditableTable>`;
//   付款计划**不换**(它是一列表单行,不是一张表),但它**也上桥**。
//   ☞ 于是这一页的具名控件只剩九个:**七个抬头字段 + 两座桥**
//     (`reason` · `order_date` · `expected_delivery_date` · `incoterm` ·
//      `delivery_location` · `notes` · `edit_terms`,加 `lines_json` · `terms_json`)。
//   ★ 十一个 `name=` 一次拿掉:`line_id` · `line_quantity` · `line_price` ·
//     `line_remove` · `line_price_status` · `term_label` · `term_mode` ·
//     `term_percentage` · `term_fixed` · `term_event` · `term_due`。
//   ☞ 这是 Tim 的 (b) 裁定在**最后一张**并列数组表上的落地,
//     于是 `EDITABLETABLE-NAME-DOUBLE-SUBMIT` 这一条**关掉了**。
// ────────────────────────────────────────────────────────────────────────────
import { CONTROL_CHECKBOX, CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useActionState, useRef, useState } from 'react'
import Link from 'next/link'
import { amendOrder, type AmendState } from './actions'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { triggerLabel, type PaymentTriggerEvent } from '@/lib/paymentTriggers'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { Button } from '@/app/components/ui/button'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

export type AmendLine = {
    id: string
    line_no: number
    quantity: number
    unit: string
    estimated_unit_price: number | null
    received: number
    // PUR-1:这一行现在的定价状态选择('' = 按事实推导),以及它挂没挂公式。
    price_status: 'fixed' | 'provisional' | ''
    has_formula: boolean
}

/** PUR-1:一期付款 —— 形状与建单那一侧的 OrderTermInput 同族。 */
export type AmendTerm = {
    seq: number
    label: string
    mode: 'percentage' | 'fixed'
    percentage: string
    fixed_amount: string
    trigger_event: string
    due_date: string
}

/**
 * ★★ DRAFT-7 · 付款计划那一列的行键 —— **uid 放在那一期【旁边】,不放进它里面** ★★
 *
 * 形状与 `purchasing/orders/new/NewOrderForm.tsx:158` 的 `TermLine` 逐字同源,
 * 理由也同源:这一列**删得掉行**,而按下标做键会让一行底下换掉内容。
 * ★★★ **桥那一处写的是 `x.term`,【没有任何剥离动作】** —— 不是"记得剥掉 uid",
 *   是它根本不在那个对象里,剥不掉。于是交出去的那一份与搬家前逐字节相同。
 * ★ 计数器而不是 `crypto.randomUUID()`:计数器在服务端渲染与客户端水合两侧
 *   给出同一串值,随机数不会。
 */
type TermRow = { uid: string; term: AmendTerm }

/** 桥上交出去的一行 —— ★ **全是原始字符串**,一个转换都不在这一侧做。 */
type LineBridgeRow = {
    id: string
    line_no: number
    remove: boolean
    quantity: string
    estimated_unit_price: string
    price_status: string
}

const initialState: AmendState = {}

export default function AmendOrderForm({
    poId, code, status, currency, orderDate, expectedDelivery, incoterm, notes,
    deliveryLocation, lines, terms: initialTerms, triggers,
}: {
    poId: string; code: string; status: string; currency: string
    orderDate: string; expectedDelivery: string; incoterm: string; notes: string
    deliveryLocation: string
    lines: AmendLine[]
    terms: AmendTerm[]
    triggers: PaymentTriggerEvent[]
}) {
    const t = useTranslations()
    const locale = useLocale()
    const amendWithId = amendOrder.bind(null, poId)
    const [state, formAction, isPending] = useActionState(amendWithId, initialState)
    const [qty, setQty] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, String(l.quantity)])))
    const [price, setPrice] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, l.estimated_unit_price === null ? '' : String(l.estimated_unit_price)])))
    const [remove, setRemove] = useState<Record<string, boolean>>({})
    const [priceStatus, setPriceStatus] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, l.price_status])))
    // ── PUR-1:付款计划 ─────────────────────────────────────────────────────
    // ★【默认【不】改它,而这是刻意的】★ 一次只想改数量的修改,不该顺手把
    //   付款计划一起提交上去 —— 不勾这个框,actions 就不传那个参数,而 DB 那一侧
    //   NULL = 不动它。勾上之后传的是【下面这份完整的计划】(空的也算数:
    //   把所有期数删光并提交,就是明说"这张单没有分期计划了")。
    const [editTerms, setEditTerms] = useState(false)
    // ★ DRAFT-7:进门时那几期的 uid 是**确定的**(`t0` … `tn-1`),
    //   于是服务端渲染与客户端水合两侧给出同一串值。计数器从它们之后起跳,
    //   并且**只在事件处理器里推进** —— `react-hooks/refs` 按名拒「渲染期读 ref」。
    const [terms, setTerms] = useState<TermRow[]>(
        () => initialTerms.map((term, i) => ({ uid: `t${i}`, term })))
    const termUidSeq = useRef(initialTerms.length)
    const nextTermUid = () => `t${termUidSeq.current++}`
    const patchTerm = (uid: string, p: Partial<AmendTerm>) =>
        setTerms((ts) => ts.map((x) => (x.uid === uid ? { uid: x.uid, term: { ...x.term, ...p } } : x)))

    // 已结束/已作废的单不能改 —— 服务端会拒,页面不摆一个注定失败的按钮
    const frozen = status === 'closed' || status === 'cancelled'

    /* ════════════════════════════════════════════════════════════════════════
       ★★★ DRAFT-7 · 第一座桥的载荷 —— **每一行自己带着自己的值** ★★★

       ★ 交的是**原始字符串**,不是数字:空与零的区别、以及"还没敲完"的中间态,
         全部留给 `actions.ts` 那一段原样的判据。**这一刀不替它决定任何一格。**
       ★★ `line_no` 是**本刀新送的**(Tim 2026-09-21 的 Q1 裁定,顺手修掉一处
         在册之外的缺陷)—— `amend_purchase_order.sql` 的**五条**具名拒绝
         (`:112` `:116` `:121` `:127` `:136`)写的都是
         `COALESCE(v_el->>'line_no', '?')`,而搬家前的载荷**从来不送它**。
         ☞ 于是今天清空一行的数量,屏幕上printed 的是
           **「Line ?: quantity must be greater than 0.」**(`messages/en.ts:5631`)。
         送上它,那五句拒绝从此点的是**行号**。
         ⚠ **被删的那一行【不送】** —— 服务端那一支
           (`amend_purchase_order.sql:96-103`)只读 `id` 与 `remove`,
           送它一个字都不会被看见,而那条「被删的行恰好是 `{ id, remove: true }`」
           是一条承重的形状。**多送一个键买不到东西,却动了那个形状。**
           (⚠ `#22` 在被删的行上**送** `line_no` —— 两边不一致,照直记:
            销售那一侧的 `amend_sales_order.sql` 在删行那一支上**会**用它。)
       ════════════════════════════════════════════════════════════════════════ */
    const linesPayload: LineBridgeRow[] = lines.map((l) => ({
        id: l.id,
        line_no: l.line_no,
        remove: !!remove[l.id],
        quantity: qty[l.id] ?? '',
        estimated_unit_price: price[l.id] ?? '',
        price_status: priceStatus[l.id] ?? '',
    }))

    /* ★ `mode:'page-owned'` 的必填 `dirty` —— **与进门时那一份比**。
       这一页进门时格子里就有字(数量、单价、定价状态预填的是这张单当前的值),
       按「有没有字」算会一进门就脏。
       ⚠【它盖不住的那几半,照直说】① 站内 `<Link>`(取消钮)不拦 —— 组件抬头
       声明过的限制,而对一颗取消钮那也正是对的;② 抬头字段与付款计划
       **不在这张表里**,只改它们不会有提醒。**这张表的 `dirty` 只说这张表的事。** */
    const linesDirty = lines.some(
        (l) =>
            (qty[l.id] ?? '') !== String(l.quantity) ||
            (price[l.id] ?? '') !== (l.estimated_unit_price === null ? '' : String(l.estimated_unit_price)) ||
            (priceStatus[l.id] ?? '') !== l.price_status ||
            !!remove[l.id]
    )

    // ★ TABLE-PHONE-4:两档共用的内容【提出来写一次】——
    //   抄成两份就是让两份将来各走各的,而漂移在桌面上看不见。
    const receivedText = (l: AmendLine) => <>{l.received} {l.unit}</>
    // PUR-1:定价状态那一格只读时说的话。★ `page-owned` 下 `editing` 恒为真,
    //   于是这一句**只在手机那一行上**渲染得到(`editable-table.tsx:834`)。
    //   ⚠ 而它仍然要写成**真话**而不是一句占位:列描述符的契约要求 `render`,
    //   写一句假的,它哪天被画出来时就在撒谎(与 `#11` 那两列同源)。
    const priceStatusText = (v: string) =>
        v === 'fixed' ? t('purchasing.form.priceStatusFixed')
            : v === 'provisional' ? t('purchasing.form.priceStatusProvisional')
                : t('purchasing.form.priceStatusDerive')
    /* 下限写在行上 —— 保存之后才被拒是最差的一种告知。
       ★★ DRAFT-7 / Tim 的 Q5 裁的是【它在 390px 上要留在零次点按】,而**落法改过一次**,
         改的理由是探针量出来的,照直记在这里:
       ⚠★★★ **第一版把它放进 `qty.render`,而那一处【一个像素都渲染不到】。**
         `render` 在手机行上画得出来的前提是**那一列是 priority** ——
         非 priority 的列,`editable-table.tsx:819` 给整个 `<td>` 挂的是
         `hidden sm:table-cell`,**整格在 390px 上 `display:none`**。
         而这张表**只有行号是 priority**,数量不是。
       ☞ 所以它现在住在【行号那一格的叠加块】里(与【已收】同一处,`#22` 同形),
         而 `qty.edit` 里那一份照旧 —— 桌面就地编辑与手机展开区各看得到一份。
       ⚠ **两份不会同时出现在屏幕上**:桌面那一档叠加块是 `sm:hidden`;
         390px 那一档数量整格不画。 */
    const belowNote = (l: AmendLine) =>
        Number(qty[l.id] || 0) < l.received && !remove[l.id] ? (
            <p className="text-xs text-red-600 mt-1">
                {t('purchasing.amend.belowReceived', { received: l.received })}
            </p>
        ) : null

    /* ════════════════════════════════════════════════════════════════════════
       ★★ 明细网格的列(DRAFT-7)

       ~~★ TABLE-PHONE-4:六列 → 手机档留四列(# · 数量 · 单价 · 价格)。~~
       ~~被拿掉的两列(已收 / 删除)一个字段都没丢:带着各自的列头叠在~~
       ~~第一格(行号)里 —— ★ 这张表【没有物料列】,行号是它唯一的身份,~~
       ~~所以折叠块只能挂在它下面,而它本来就是这一行对外的号码。~~
       ~~☞ 留的三个都是要动手的:数量、单价、定价状态。已收是个读的数,~~
       ~~  而且真要用到它的那一刻(数量低于已收)那句告警本来就印在数量框底下。~~
       ~~★★【这三列留在明面上不是偏好,是正确性】★★~~
       ~~  line_quantity / line_price / line_price_status 是三条【并列数组】~~
       ~~  (见下面 PUR-1 那段原注)。折叠一列是用 CSS 藏,【藏起来的 input~~
       ~~  照样提交】—— 画两遍就是每行往数组里多塞一格,整组配对当场错位,~~
       ~~  而那正是 PUR-1 刚修掉的那个错位。带 name 的一个都没被复制。~~
       ~~  删除那个复选框【不带 name】(值由第一格渲染一次的 hidden~~
       ~~  line_remove 携带),所以它是这张表里唯一能安全画两份的控件。~~
       ~~★【# 的列头是硬编码的 "#",没有 i18n key】—— 留在明面上,一句都不用造。~~

       ★★★【收据 —— DRAFT-7,2026-09-21,Tim 的 Q2 裁定】★★★
       **划掉留着,不删** —— 一条标记被删掉,和它从来没有被写过,在读的人眼里
       没有区别(Tim 2026-09-21 的裁定)。

       ☞ **上面那一段【不是不再准确,是它的燃料没有了】。** 它整段论证的前提是
         「`line_quantity` / `line_price` / `line_price_status` 是三条**并列数组**」,
         而这一刀把它们换成了**一座桥**:每一行自己带着自己的值,
         **没有配对,就没有可错位的东西。** 于是「这三列必须留在明面上」
         **不再从任何东西推得出来** —— 它不是被投票投掉的,是它的理由消失了。
       ⚠ **代价照直记,而它是买过一次的那一次:** 数量 / 单价 / 定价状态三格
         在 390px 上从**零次点按**变成**一次点按**(它们现在住在手机展开区里)。
         ☞ 这与 `#22`(销售改单)和 `#3`(PayrollGrid)付的是**同一笔**:
           `editable-table.tsx:826-833` 让手机档的每一个格子都只读,
           **一个留在明面上的输入框会是打不了字的**。
       ★ **没有跟着一起走的两样,写出来:**
         ① **已收**仍然**零次点按**看得见 —— 它是一列只读且非 priority 的列,
            `page-owned` 下那种列在展开区里**整个不画**(`editable-table.tsx:791`),
            所以它照 `TABLE-PHONE-4` 原样叠在行号那一格里(`#22` 的三列同形);
         ② **「低于已收」那句告警**仍然**零次点按**读得到(Tim 的 Q5,见 `belowNote`)。
       ★ **而 `#` 的列头这一刀有 key 了:`purchasing.colSeq`**(`messages/en.ts:5353`)
         —— 它早就在册,一句文案都不用现造。
       ════════════════════════════════════════════════════════════════════════ */
    const lineColumns: EditableColumn<AmendLine, AmendLine>[] = [
        {
            key: 'seq',
            header: t('purchasing.colSeq'),
            priority: true,
            render: (l) => (
                <>
                    {l.line_no}
                    {/* ★ TABLE-PHONE-4 那块叠加块,逐字搬过来 —— 手机档拿掉的【已收】
                        带着它的列头叠在这里,**零次点按**。
                        ⚠ 它【不能】改走展开区:`page-owned` 下展开区只画有 `edit` 的列,
                        而已收是只读的 —— 走过去等于让它整个消失。
                        ☞ 删除那个勾选框**不在这里了**:它是要按的控件,走 `rowActions`,
                          于是手机上它画在展开区末尾(Tim 的 Q7)。 */}
                    <div className="sm:hidden mt-1 space-y-1 font-sans text-xs text-gray-600">
                        <div>
                            <span className="font-sans text-gray-500">{t('purchasing.amend.colReceived')}: </span>
                            {receivedText(l)}
                        </div>
                        {/* ★★ Tim 的 Q5:「低于已收」那句告警也叠在这里,于是它在 390px 上
                            仍然是**零次点按**。☞ 它必须待在一个 **priority** 列的 `render` 里
                            —— 非 priority 的列整格 `display:none`,放在那里等于没放
                            (探针量出来的,见上面 `belowNote` 抬头)。 */}
                        {belowNote(l)}
                    </div>
                </>
            ),
        },
        {
            key: 'quantity',
            header: t('purchasing.amend.colQty'),
            align: 'right',
            /* ⚠ **这一份 `render` 在这张表上【一次都渲染不到】** —— `page-owned` 下
               `editing` 恒为真,桌面画 `edit`;而 390px 上这一列不是 priority,
               整格 `display:none`。留着是**列描述符的契约**要求,
               ★ 而它写成**真话**(这一格只读时就是这个数),不是一句占位
               —— 与 `#11` 那两列同源。☞ 那句「低于已收」**不在这里**:
               见上面 `belowNote` 抬头,它放在这里等于放在没有人看得见的地方。 */
            render: (l) => qty[l.id] ?? '',
            edit: (l) => (
                <>
                    <DecimalInput value={qty[l.id] ?? ''}
                        onChange={(raw) => setQty((q) => ({ ...q, [l.id]: raw }))}
                        disabled={frozen}
                        className="w-28 text-right tabular-nums" />
                    {belowNote(l)}
                </>
            ),
        },
        {
            key: 'received',
            header: t('purchasing.amend.colReceived'),
            align: 'right',
            className: 'text-gray-600',
            render: (l) => receivedText(l),
        },
        {
            key: 'price',
            header: t('purchasing.amend.colPrice', { ccy: currency }),
            align: 'right',
            render: (l) => price[l.id] ?? '',
            edit: (l) => (
                <DecimalInput value={price[l.id] ?? ''}
                    onChange={(raw) => setPrice((p) => ({ ...p, [l.id]: raw }))}
                    disabled={frozen}
                    className="w-28 text-right tabular-nums" />
            ),
        },
        {
            /* PUR-1:定价状态。挂了公式的行【标不成定价】——
               禁用并把理由摆在旁边(CMP-2 的规矩);把关在
               guard_po_line_price_status 那道闸上。 */
            key: 'price_status',
            header: t('purchasing.form.priceStatus'),
            render: (l) => priceStatusText(priceStatus[l.id] ?? ''),
            edit: (l) => (
                <>
                    <select value={priceStatus[l.id] ?? ''}
                        disabled={frozen}
                        onChange={(e) => setPriceStatus((p) => ({ ...p, [l.id]: e.target.value }))}
                        className={CONTROL_SELECT}>
                        <option value="">{t('purchasing.form.priceStatusDerive')}</option>
                        <option value="fixed" disabled={l.has_formula}>
                            {t('purchasing.form.priceStatusFixed')}
                        </option>
                        <option value="provisional">{t('purchasing.form.priceStatusProvisional')}</option>
                    </select>
                    {l.has_formula && (
                        <p className="text-xs text-gray-500 mt-1 max-w-40">
                            {t('purchasing.form.priceStatusFormulaHint')}
                        </p>
                    )}
                </>
            ),
        },
    ]

    return (
        <div className="max-w-4xl">
            <div className="mb-6">
                <Link href={`/purchasing/orders/${poId}`} className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="mb-2">{t('purchasing.amend.title', { code })}</h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-6 max-w-3xl">{t('purchasing.amend.intro')}</p>

            {frozen && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4">
                    {t('purchasing.amend.frozen', { status: t('purchasing.status.' + status) })}
                </div>
            )}
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                <div>
                    <label className="block mb-1">
                        {t('purchasing.amend.reason')} <span className="text-red-600">*</span>
                    </label>
                    <input type="text" name="reason" required disabled={frozen}
                        className={`${CONTROL_INPUT} w-full`} />
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('purchasing.amend.reasonHint')}</p>
                </div>

                <div className="flex flex-wrap gap-4">
                    <div>
                        <label className="block mb-1">{t('purchasing.amend.orderDate')}</label>
                        <input type="date" name="order_date" defaultValue={orderDate} disabled={frozen}
                            className={CONTROL_INPUT} />
                        {/* 改单据日会重取牌价 —— 缺牌价即拒,绝不编一个 */}
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('purchasing.amend.orderDateHint')}</p>
                    </div>
                    <div>
                        <label className="block mb-1">{t('purchasing.amend.expected')}</label>
                        <input type="date" name="expected_delivery_date" defaultValue={expectedDelivery}
                            disabled={frozen} className={CONTROL_INPUT} />
                    </div>
                    <div>
                        <label className="block mb-1">{t('purchasing.amend.incoterm')}</label>
                        <input type="text" name="incoterm" defaultValue={incoterm} disabled={frozen}
                            className={CONTROL_INPUT} />
                    </div>
                    {/* PUR-1:交货地点 —— 清空它是一次正当的修改,所以空串照样提交
                        (服务端靠"键在不在"分开"不动它"与"清掉它")。 */}
                    <div className="flex-1 min-w-[16rem]">
                        <label className="block mb-1">{t('purchasing.form.deliveryLocation')}</label>
                        <input type="text" name="delivery_location" defaultValue={deliveryLocation}
                            disabled={frozen} className={`${CONTROL_INPUT} w-full`} />
                    </div>
                </div>

                {/* ════════════════════════════════════════════════════════════════
                    ~~★★【PUR-1 顺手修掉的一处既有缺陷 —— 而它是本刀【必须】修的】★★~~
                    ~~【症状】勾掉一条行、同时改另一条行的数量,那条【没被勾掉】的行~~
                    ~~会以 quantity = null 提交,被 DB 按名拒(PO_LINE_QUANTITY_INVALID)。~~
                    ~~【成因】服务端按【并列数组】对齐(line_id / line_quantity /~~
                    ~~line_price / line_remove 各一份,按下标配对),而~~
                    ~~DecimalInput 的 hidden input 带着 disabled —— 一个 disabled~~
                    ~~的字段【根本不提交】。于是被勾掉那一行在 line_quantity 里~~
                    ~~没有位置,它【后面】每一行的下标全部前移一格。~~
                    ~~(勾掉最后一行时不会发作 —— 所以它活到了今天。)~~
                    ~~【为什么本刀必须修】PUR-1 在这里加的是【第三条并列数组】~~
                    ~~(line_price_status)。不修就是把同一个错位再复制一份。~~
                    ~~【怎么修】不再按"这一行要删"去禁用输入框:那个禁用是纯装饰~~
                    ~~(整行本来就已经变灰,而且它马上要被删掉),代价却是让~~
                    ~~提交上去的数组少一格。frozen 那一半保留 —— 那时整张表单~~
                    ~~连提交钮都是禁用的,不会有半份负载被送出去。~~

                    ★★★【收据 —— DRAFT-7,2026-09-21,Tim 的裁定】★★★
                    **划掉留着,不删。** 上面那一段描述的**不再是一条活着的约束**:
                    它讲的是「并列数组按下标配对,一个 disabled 的格子会让后面整体前移」,
                    而这一刀让**每一行自己带着自己的值** —— **没有配对,就没有错位**。
                    ☞ **它不是被修好的,是被【拿掉了】**(与 `#22` 的
                      `SALES-AMEND-DISABLED-ARRAY-SHIFT` 逐字同一条处置)。
                    ⚠ ★★ **而它最后一段留下的那条规矩,这一刀也一并拿掉了,
                      照直记下来:** 搬家前这张表靠「**不要在删除时禁用输入框**」
                      这条**要人记住的规矩**活着,而那条规矩**是承重的**。
                    ⚠ ★★★ **它还有第二个触发器,而 PUR-1 【没有】修掉那一个:`frozen`。**
                      `frozen` 时 `DecimalInput` 的隐藏输入带 `disabled`(不提交),
                      而 `line_id` / `line_remove` 是**裸的 hidden,照样提交** ——
                      于是那几条数组在 `frozen` 下**今天就是错位的**。
                      ☞ **它从来没有发作过,靠的只是提交钮也被禁用了**
                        (搬家前 `:366`)。**一条由一颗禁用的钮守着的正确性。**
                      ☞ 这一刀把它和那条要人记住的规矩一起拿掉了 —— 桥上没有数组。
                    ════════════════════════════════════════════════════════════════ */}

                {/* ★★★ 第一座桥 —— **画在表【外面】,只画一遍** ★★★
                    这正是 Tim 的 (b) 裁定:格子里不再有具名输入,草稿经这一个
                    隐藏字段交出去。组件把 `edit()` / `render()` 画两遍
                    (`editable-table.tsx:826-833` 桌面格 + `:911` 展开区),
                    ☞ **而那个双渲染一个字都没有被改 —— 被拿走的是它的燃料。**
                    ★ 一道闸守着这条规矩:`scripts/check-editable-name.mjs`
                      (在 `npm run build` 链里),`columns` 区段里出现 `name=` 就变红。 */}
                <input type="hidden" name="lines_json" value={JSON.stringify(linesPayload)} />
                <EditableTable<AmendLine, AmendLine>
                    rows={lines}
                    columns={lineColumns}
                    rowKey={(l) => l.id}
                    phone={{ mode: 'columns' }}
                    mode="page-owned"
                    dirty={linesDirty}
                    labels={{ expand: t('common.expandRow') }}
                    // ★ 能力 B:勾掉的行变灰 —— 与搬家前逐字相同的两个类。
                    rowClassName={(l) => (remove[l.id] ? 'bg-gray-100 text-gray-400' : undefined)}
                    /* ★★★ 能力 A:移除勾选走 `rowActions`,于是它在手机上画在**展开区末尾**
                       —— **Tim 的 Q7 裁定(2026-09-21)**,理由与代价见
                       `app/components/ui/editable-table.tsx` 抬头 ④ 下面那一段。
                       ⚠ 照直记:**这一颗从 0 次点按变成 1 次点按。这是一次有意的回退**,
                       而它不是一次偏好:`editable-table.tsx:826-833` 让手机档的
                       每一个格子都只读,**一颗留在明面上的勾选框会是按不动的**。
                       ★ 收过货的行删不掉 —— 复选框直接禁用并说明(搬家前逐字相同)。 */
                    rowActions={(l) => (
                        <label className="">
                            <input className={CONTROL_CHECKBOX} type="checkbox" checked={!!remove[l.id]}
                                disabled={frozen || l.received > 0}
                                onChange={(e) => setRemove((r) => ({ ...r, [l.id]: e.target.checked }))} />
                            <span className="ml-1">
                                {l.received > 0 ? t('purchasing.amend.cannotRemove') : t('purchasing.amend.remove')}
                            </span>
                        </label>
                    )}
                />

                {/* ── PUR-1:付款条款 ────────────────────────────────────────
                    【此前改不了,而那不是一道锁】—— 没有参数、没有字段,
                    而 purchase_order_payment_terms 的策略对持采购编辑权的人全开:
                    这条路一直通着,只是走它要直连改库,而且【在档案里完全沉默】。
                    本刀把入口建出来,同时把档案扩到接得住它
                    (trg_po_history_payment_term)。理由与其余修改共用上面那一个。

                    ★★ DRAFT-7:**这一组【不】变成 `EditableTable`** —— 它是一列
                    表单行,不是一张表(没有列头、每一期的控件组随 mode 变形)。
                    **但它也上桥**:六条并列数组换成一个 `terms_json`。 */}
                <div className="border border-gray-300 rounded p-4">
                    <label className="flex items-center gap-2">
                        <input className={CONTROL_CHECKBOX} type="checkbox" name="edit_terms" value="1" checked={editTerms}
                            disabled={frozen}
                            onChange={(e) => setEditTerms(e.target.checked)} />
                        {t('purchasing.amend.editTerms')}
                    </label>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('purchasing.amend.editTermsHint')}</p>

                    {/* ★★★ 第二座桥 —— **无条件渲染,住在 `{editTerms && …}` 外面** ★★★
                        ☞ **`null`(不动付款计划)与 `[]`(把整份计划清掉)是两件事**,
                          而分开它们的是 `edit_terms` 这个勾选框,**不是这座桥在不在**:
                          `actions.ts` 先看 `edit_terms`,没勾就**一个字都不读这里**
                          (`terms` 留在 `null`,那个参数根本不传)。
                        ⚠ **把它画进 `{editTerms && …}` 里会得到一个安静的坑:**
                          勾上→改几期→取消勾选→提交,那一刻桥被卸载,
                          而 `formData.get('terms_json')` 变成 `null`。今天不会发作
                          (没勾就不读),但它让这两条路**互相依赖**,
                          而那正是「两份判断在写下的那天一致、此后各自漂移」的形状。
                        ★★ 交出去的是 `x.term`,**uid 在旁边,没进去** ——
                          **没有任何剥离动作**,所以载荷与搬家前逐字节相同。 */}
                    <input type="hidden" name="terms_json"
                        value={JSON.stringify(terms.map((x) => x.term))} />

                    {editTerms && (
                        <div className="mt-3 space-y-2">
                            {terms.length === 0 && (
                                <p className="text-xs text-amber-800 bg-amber-50 border border-amber-300 rounded px-3 py-2">
                                    {t('purchasing.amend.termsEmptyWarning')}
                                </p>
                            )}
                            {terms.map((x, i) => (
                                <div key={x.uid} className="flex flex-wrap items-end gap-2 border-b border-gray-200 pb-2">
                                    <span className="text-sm text-[color:var(--brand-muted-text)] pb-2">{i + 1}.</span>
                                    <div>
                                        <label className="block mb-1">{t('purchasing.form.termLabel')}</label>
                                        <input type="text" value={x.term.label} disabled={frozen}
                                            onChange={(e) => patchTerm(x.uid, { label: e.target.value })}
                                            className={`${CONTROL_INPUT} w-40`} />
                                    </div>
                                    <div>
                                        <label className="block mb-1">{t('purchasing.form.termMode')}</label>
                                        <select value={x.term.mode} disabled={frozen}
                                            onChange={(e) => patchTerm(x.uid, { mode: e.target.value as 'percentage' | 'fixed' })}
                                            className={`${CONTROL_SELECT} w-28`}>
                                            <option value="percentage">%</option>
                                            <option value="fixed">{currency}</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label className="block mb-1">
                                            {x.term.mode === 'percentage' ? '%' : currency}
                                        </label>
                                        {/* ~~【两个输入框都在 DOM 里,而只有一个可见】—— 并列数组按~~
                                            ~~出现顺序对齐,少一个就会整体错位。隐藏那一个仍然提交,~~
                                            ~~但服务端按 mode 只读它该读的那一个。~~

                                            ★★【收据 —— DRAFT-7,2026-09-21,Tim 的裁定】★★
                                            **划掉留着,不删。** 上面那一段描述的**不再是一条活着的约束**:
                                            它讲的是「并列数组按出现顺序对齐」,而 `term_percentage` /
                                            `term_fixed` 这两个 `name=` 本刀**一起拿掉了** ——
                                            两个输入框现在**只是两个受控输入框**,DOM 里有几个、
                                            哪个可见,**与提交上去的东西没有任何关系**。
                                            ☞ 桥交的是 `AmendTerm` 这个对象本身,它**两个值都带着**,
                                              而服务端照旧按 `mode` 只读它该读的那一个
                                              —— **那一句仍然成立,只是它现在读的是一个对象的键,
                                              不是一条数组的第 i 格。** */}
                                        <input type="text" value={x.term.percentage}
                                            disabled={frozen}
                                            onChange={(e) => patchTerm(x.uid, { percentage: e.target.value })}
                                            className={`${CONTROL_INPUT} w-24 text-right tabular-nums ` +
                                                (x.term.mode === 'percentage' ? '' : 'hidden')} />
                                        <input type="text" value={x.term.fixed_amount}
                                            disabled={frozen}
                                            onChange={(e) => patchTerm(x.uid, { fixed_amount: e.target.value })}
                                            className={`${CONTROL_INPUT} w-24 text-right tabular-nums ` +
                                                (x.term.mode === 'fixed' ? '' : 'hidden')} />
                                    </div>
                                    <div>
                                        <label className="block mb-1">{t('purchasing.form.termTrigger')}</label>
                                        <select value={x.term.trigger_event} disabled={frozen}
                                            onChange={(e) => patchTerm(x.uid, { trigger_event: e.target.value })}
                                            className={`${CONTROL_SELECT} w-44`}>
                                            {triggers.map((ev) => (
                                                <option key={ev.code} value={ev.code}>{triggerLabel(ev, locale)}</option>
                                            ))}
                                        </select>
                                    </div>
                                    <div>
                                        <label className="block mb-1">{t('purchasing.form.termDue')}</label>
                                        <input type="date" value={x.term.due_date} disabled={frozen}
                                            onChange={(e) => patchTerm(x.uid, { due_date: e.target.value })}
                                            className={CONTROL_INPUT} />
                                    </div>
                                    <Button variant="secondary" size="inline" type="button" disabled={frozen}
                                        onClick={() => setTerms((ts) => ts.filter((y) => y.uid !== x.uid))}
                                        className="text-sm mb-1">
                                        {t('purchasing.amend.removeTerm')}
                                    </Button>
                                </div>
                            ))}
                            <Button variant="secondary" size="inline" type="button" disabled={frozen}
                                onClick={() => setTerms((ts) => [...ts, {
                                    uid: nextTermUid(),
                                    term: {
                                        seq: ts.length + 1, label: '', mode: 'percentage',
                                        percentage: '', fixed_amount: '',
                                        trigger_event: triggers[0]?.code ?? '', due_date: '',
                                    },
                                }])}
                                className="text-sm">
                                {t('purchasing.amend.addTerm')}
                            </Button>
                        </div>
                    )}
                </div>

                <div>
                    <label className="block mb-1">{t('purchasing.amend.notes')}</label>
                    <textarea name="notes" defaultValue={notes} disabled={frozen}
                        className={`${CONTROL_TEXTAREA} w-full`} />
                </div>

                <div className="flex gap-3 pt-2">
                    <Button type="submit" disabled={isPending || frozen}>
                        {isPending ? t('common.saving') : t('purchasing.amend.submit')}
                    </Button>
                    <Button asChild variant="secondary">
                        <Link href={`/purchasing/orders/${poId}`}>
                            {t('common.cancel')}
                        </Link>
                    </Button>
                </div>
            </form>
        </div>
    )
}
