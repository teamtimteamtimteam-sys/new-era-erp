'use server'

// PUR-2:采购单修改。判据、守卫与留痕全在 amend_purchase_order 与触发器里 ——
// 页面【不自己判断能不能改】。理由与本仓库其它写入路径同一条:两份判断会在写下的
// 那天一致,此后各自漂移,而 RLS 今天就允许一条直连的 UPDATE 绕过页面。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizePurchasingError } from '../../../purchasingErrorCodes'
import { getTranslations } from '@/lib/i18n/server'

export type AmendState = { error?: string }

/** 桥上收到的一行明细(★ **全是原始字符串** —— 转换在下面那一段,与搬家前逐字相同)。 */
type LineIn = {
    id: string
    line_no: number
    remove: boolean
    quantity: string
    estimated_unit_price: string
    price_status: string
}
/** 桥上收到的一期付款。★ `seq` 收得到,但【故意不用】—— 见下面那个循环。 */
type TermIn = {
    seq: number
    label: string
    mode: string
    percentage: string
    fixed_amount: string
    trigger_event: string
    due_date: string
}

/**
 * 桥 → 行。⚠ **读不懂的桥不当空集** —— 一张空的改单单会让服务端
 * 「什么都没改」地成功返回,而真相是这一次提交没有被读懂。按名拒。
 * ☞ 形状与 `sales/orders/[id]/amend/actions.ts:31` 那一支逐字同源。
 */
function parseBridge<T>(raw: string, pick: (row: Record<string, unknown>) => T | null): T[] | null {
    let parsed: unknown
    try {
        parsed = JSON.parse(raw)
    } catch {
        return null
    }
    if (!Array.isArray(parsed)) return null
    const out: T[] = []
    for (const el of parsed) {
        if (el === null || typeof el !== 'object') continue
        const row = pick(el as Record<string, unknown>)
        if (row !== null) out.push(row)
    }
    return out
}

export async function amendOrder(
    poId: string,
    _prev: AmendState,
    formData: FormData
): Promise<AmendState> {
    const t = await getTranslations()
    const reason = String(formData.get('reason') ?? '').trim()
    const orderDate = String(formData.get('order_date') ?? '').trim()
    const expected = String(formData.get('expected_delivery_date') ?? '').trim()
    const incoterm = String(formData.get('incoterm') ?? '').trim()
    const notes = String(formData.get('notes') ?? '').trim()
    // PUR-1:交货地点。【空串要传下去,不能吞成 undefined】—— 清空它是一次
    // 正当的修改,而 DB 那一侧靠"键在不在"区分"不动它"与"清掉它"。
    const deliveryLocation = String(formData.get('delivery_location') ?? '').trim()

    // ★★★ DRAFT-7(2026-09-21):五条按下标配对的并列数组 → **一座 JSON 桥**
    //   (Tim 的 (b) 裁定,而 `#21` 是这八张里的**最后一张**)。
    //
    //   ★★【两处承重的东西是被【构造上】拿掉的,不是被修好的】★★
    //   搬家前这里按下标把 `line_id` / `line_quantity` / `line_price` /
    //   `line_remove` / `line_price_status` 配对,而 `DecimalInput` 渲染的那个
    //   具名隐藏输入**带着 `disabled`**(`app/components/forms/DecimalInput.tsx:78`)
    //   —— **disabled 的字段不提交**,于是被禁用那一行后面的下标全部前移一格。
    //     ① `PUR-1` 修掉了**删除**那个触发器(靠一条「不要在删除时禁用输入框」的
    //        **要人记住的规矩**),而那条规矩此后一直是承重的;
    //     ② ⚠ **`frozen` 那个触发器【没有人修】** —— 它只是被「提交钮也禁用了」
    //        挡着,从来没有发作过。**一条由一颗禁用的钮守着的正确性。**
    //   ☞ 现在每一行自己带着自己的值,**那个配对不存在了**。
    //     **没有配对,就没有可错位的东西** —— 两条一起消失。
    //
    //   ⚠ **下面每一处转换都与搬家前逐字相同,包括看起来不对称的那两处:**
    //     · 数量用**真值判断**(`q ? Number(q) : null`)—— 于是 `"0"` 变成 null;
    //     · 单价用 `.trim() === ''`。
    //     两者结果都会被 `amend_purchase_order` 的 `v_qty <= 0` 拒掉,所以那个不对称
    //     **今天无害**;**而本刀不去"顺手统一"它** —— 一次没有人要求的归一,
    //     是这一刀唯一可能悄悄改掉行为的地方。
    const rows = parseBridge<LineIn>(
        String(formData.get('lines_json') ?? '[]'),
        (row) => {
            const id = String(row.id ?? '')
            if (id === '') return null
            return {
                id,
                line_no: Number(row.line_no ?? 0),
                remove: row.remove === true,
                quantity: String(row.quantity ?? ''),
                estimated_unit_price: String(row.estimated_unit_price ?? ''),
                price_status: String(row.price_status ?? ''),
            }
        }
    )
    if (rows === null) {
        // ⚠ **不走 `localizePurchasingError`**:那一支认的是**数据库**吐出来的码,
        //   而这一条拒绝是**这一侧**发的 —— 把它塞进那张码表会让下一个读表的人
        //   以为库里有这么一个错误码。与 `#22` 同一个写法,直接取文案。
        return { error: t('purchasing.amend.errLinesUnreadable') }
    }

    const lines = rows.map((l) => {
        if (l.remove) return { id: l.id, remove: true }
        return {
            id: l.id,
            // ★★ DRAFT-7 / Tim 的 Q1:`line_no` 是**本刀新送的**。
            //   `amend_purchase_order.sql` 的**五条**具名拒绝(`:112` `:116` `:121`
            //   `:127` `:136`)写的都是 `COALESCE(v_el->>'line_no', '?')`,
            //   而搬家前的载荷**从来不送它** —— 于是清空一行的数量,屏幕上
            //   印出来的是 **「Line ?: quantity must be greater than 0.」**
            //   (`messages/en.ts:5631`)。见 `docs/known-issues.md` 的
            //   `PUR-AMEND-LINE-NO-MISSING`。
            //   ⚠ **被删的那一行【不送】** —— 服务端那一支(`:96-103`)只读
            //   `id` 与 `remove`,而「被删的行恰好是 `{ id, remove: true }`」
            //   是一条承重的形状。多送一个键买不到东西,却动了那个形状。
            line_no: l.line_no,
            quantity: l.quantity ? Number(l.quantity) : null,
            // ⚠ **`estimated_unit_price` 这个键【必须】在,哪怕值是 null** ——
            //   `amend_purchase_order.sql:180` 测的是**键在不在**
            //   (`v_el ? 'estimated_unit_price'`),不是值是不是空。
            //   一次 `...(x ? { k: v } : {})` 式的"整理"会让**清空单价**这件事
            //   安静地失效。
            estimated_unit_price: l.estimated_unit_price.trim() === '' ? null : Number(l.estimated_unit_price),
            // PUR-1:这一行的定价状态。空串 = 清回"按事实推导",而那与
            // "不动它"不是同一件事 —— 所以这个键【总是】送出去(表单上每一行
            // 都有这个下拉框,它的当前值就是这一行的答案)。
            // ☞ 服务端那一侧同样测**键在不在**(`amend_purchase_order.sql:177`)。
            price_status: l.price_status.trim(),
        }
    })

    // ── PUR-1:付款计划 ─────────────────────────────────────────────────────
    // 【没有勾"同时修改付款计划"就不传这个参数】—— DB 那一侧 NULL = 不动它,
    // 空数组 = 把整份计划清掉。两者必须分得开:一次只想改数量的修改,
    // 不该顺手把付款计划抹了。
    // ★★ DRAFT-7:**分开这两者的仍然是 `edit_terms` 这个勾选框,不是那座桥在不在。**
    //   `terms_json` 在页面上是**无条件渲染**的(它住在 `{editTerms && …}` 外面),
    //   而没勾的时候这里**一个字都不读它** —— 下面这一整支不进去,`terms` 留在 `null`。
    const editTerms = String(formData.get('edit_terms') ?? '') === '1'
    let terms: Record<string, unknown>[] | null = null
    if (editTerms) {
        const termRows = parseBridge<TermIn>(
            String(formData.get('terms_json') ?? '[]'),
            (row) => ({
                seq: Number(row.seq ?? 0),
                label: String(row.label ?? ''),
                mode: String(row.mode ?? ''),
                percentage: String(row.percentage ?? ''),
                fixed_amount: String(row.fixed_amount ?? ''),
                trigger_event: String(row.trigger_event ?? ''),
                due_date: String(row.due_date ?? ''),
            })
        )
        if (termRows === null) {
            // ⚠ ★★ **这一条【不能】退回一个空集** —— 空集在 DB 那一侧的意思是
            //   「把整份付款计划清掉」。一次读不懂的提交,绝不许被读成
            //   一次「清空计划」的指令。所以它是一句**按名的拒绝**,
            //   而且与上面那一条**分开写**:两者坏掉的后果不是同一件事。
            return { error: t('purchasing.amend.errTermsUnreadable') }
        }
        // 【与建单那一侧【同一句话】】建单的 createOrder 对每一期做的正是这三条
        // 检查(标签非空、比例 0<n≤100、定额 >0),拒绝文案也是这一条。
        // 不抄过来,改单这条路会把一个空的比例送成 0,撞上表上那条
        // `percentage > 0`,而操作员拿到的是一句裸约束原文 —— 同一个错误,
        // 两条路两副面孔,正是 CMP-2 点名的那种缺陷。
        // ★★ DRAFT-7 / Tim 的 Q6:**桥上那个 `seq` 是【故意不用】的。**
        //   期次序号在这里一直是【位置】算出来的(`i + 1`),而页面上那个
        //   `AmendTerm.seq` 删一期之后【不重排】、加一期用 `ts.length + 1`
        //   【会撞号】。搬家前它根本到不了服务端;桥把它带上来了,
        //   所以这一句写下来:**它是读出来的,不是用来算的。**
        terms = []
        for (let i = 0; i < termRows.length; i++) {
            const r = termRows[i]
            const label = r.label.trim()
            if (!label) return { error: t('purchasing.errTermLine', { 0: i + 1 }) }
            if (r.mode === 'percentage') {
                const n = Number(r.percentage)
                if (!r.percentage || Number.isNaN(n) || n <= 0 || n > 100) {
                    return { error: t('purchasing.errTermLine', { 0: i + 1 }) }
                }
                terms.push({ seq: i + 1, label, percentage: n, trigger_event: r.trigger_event,
                             ...(r.due_date?.trim() ? { due_date: r.due_date } : {}) })
            } else {
                const n = Number(r.fixed_amount)
                if (!r.fixed_amount || Number.isNaN(n) || n <= 0) {
                    return { error: t('purchasing.errTermLine', { 0: i + 1 }) }
                }
                terms.push({ seq: i + 1, label, fixed_amount_ccy: n, trigger_event: r.trigger_event,
                             ...(r.due_date?.trim() ? { due_date: r.due_date } : {}) })
            }
        }
    }

    const supabase = await createClient()
    const { error } = await supabase.rpc('amend_purchase_order', {
        p_purchase_order_id: poId,
        // 【理由不在这里兜底】空的理由由 DB 点名拒(PO_AMEND_REASON_REQUIRED):
        // 一次改动没有理由,历史上就只是一行"数字变了"。
        p_reason: reason,
        p_header: {
            order_date: orderDate || undefined,
            expected_delivery_date: expected || null,
            incoterm: incoterm || null,
            notes: notes || null,
            // 【总是带这个键】空串在 DB 那一侧收成 NULL —— 也就是"清掉它"。
            delivery_location: deliveryLocation,
        },
        p_lines: lines,
        // 【不勾就传 null】—— null 与 [] 在 DB 那一侧是两件事(不动它 / 清空它)。
        p_payment_terms: terms as unknown as import('@/lib/database.types').Json,
    })

    if (error) return { error: await localizePurchasingError(error.message) }

    revalidatePath('/purchasing/orders')
    revalidatePath(`/purchasing/orders/${poId}`)
    redirect(`/purchasing/orders/${poId}`)
}
