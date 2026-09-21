'use server'

// SO-1b:销售订单改单。判据、守卫与留痕全在 amend_sales_order 与触发器里 ——
// 页面【不自己判断能不能改】。理由与本仓库其它写入路径同一条:两份判断会在写下的
// 那天一致、此后各自漂移,而 RLS 今天就允许一条直连的 UPDATE 绕过页面(那条路
// 是有意留着的 —— 守卫必须挡得住它,而"挡得住"只有在路还通着时才证明得了)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeSalesOrderError } from '../../salesOrderErrorCodes'
import { getTranslations } from '@/lib/i18n/server'

export type AmendState = { error?: string }

type LinePayload = {
    id?: string
    line_no?: number
    remove?: boolean
    quantity?: number | null
    unit_price?: number | null
    material_id?: string
}

/** 桥上收到的既有行(全是原始字符串 —— 转换在下面那一段,与搬家前逐字相同)。 */
type ExistingLineIn = { id: string; line_no: number; remove: boolean; quantity: string; unit_price: string }
/** 桥上收到的加行槽。 */
type NewLineIn = { material_id: string; quantity: string; unit_price: string }

/** 桥 → 行。⚠ **读不懂的桥不当空集** —— 一张空的改单单会让服务端
 *  「什么都没改」地成功返回,而真相是这一次提交没有被读懂。按名拒。 */
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
    orderId: string,
    _prev: AmendState,
    formData: FormData
): Promise<AmendState> {
    const mode = String(formData.get('mode') ?? 'amend')
    const reason = String(formData.get('reason') ?? '').trim()

    // ★★★ DRAFT-4(2026-09-21):四条按下标配对的并列数组 → **两座 JSON 桥**
    //   (Tim 的 (b) 裁定)。既有行走 `lines_json`,加行槽走 `new_lines_json`。
    //
    //   ★★【顺手拿掉了一处缺陷,而它是【构造上】被拿掉的,不是被修好的】★★
    //   搬家前这里按下标把 `line_id` / `line_quantity` / `line_price` / `line_remove`
    //   配对,而 `DecimalInput` 渲染的那个具名隐藏输入**带着 `disabled`**
    //   (`app/components/forms/DecimalInput.tsx:78`)—— **disabled 的字段不提交**。
    //   于是被勾掉的行、以及**已开票**的行在 `line_quantity` 里没有位置,
    //   它【后面】每一行的下标全部前移一格,而末尾那几行读到 `undefined` → null
    //   → `SO_AMEND_LINE_INVALID|…|quantity`,**点名的是一条人根本没碰过的行**。
    //   ☞ `PUR-1` 在**采购**那一侧修过同一处(`purchasing/orders/[id]/amend/
    //     AmendOrderForm.tsx:165-179` 写着全过程),销售这一侧一直没修;
    //     而这里比采购**多一个触发器**:`billed`(采购那张表没有开票这一维)。
    //   ☞ 现在每一行自己带着自己的值,**那个配对不存在了**。
    //     见 `docs/known-issues.md` 的 `SALES-AMEND-DISABLED-ARRAY-SHIFT`。
    //
    //   ⚠ **下面每一处转换都与搬家前逐字相同,包括看起来不对称的那两处:**
    //     · 数量用**真值判断**(`q ? Number(q) : null`)—— 于是 `"0"` 变成 null;
    //     · 单价用 `.trim() === ''`。
    //     两者结果都会被 `amend_sales_order` 的 `v_qty <= 0` 拒掉,所以那个不对称
    //     **今天无害**;**而本刀不去"顺手统一"它** —— 一次没有人要求的归一,
    //     是这一刀唯一可能悄悄改掉行为的地方。
    const existing = parseBridge<ExistingLineIn>(
        String(formData.get('lines_json') ?? '[]'),
        (row) => {
            const id = String(row.id ?? '')
            if (id === '') return null
            return {
                id,
                line_no: Number(row.line_no ?? 0),
                remove: row.remove === true,
                quantity: String(row.quantity ?? ''),
                unit_price: String(row.unit_price ?? ''),
            }
        }
    )
    const slots = parseBridge<NewLineIn>(
        String(formData.get('new_lines_json') ?? '[]'),
        (row) => ({
            material_id: String(row.material_id ?? ''),
            quantity: String(row.quantity ?? '').trim(),
            unit_price: String(row.unit_price ?? '').trim(),
        })
    )
    if (existing === null || slots === null) {
        // ⚠ **不走 `localizeSalesOrderError`**:那一支认的是**数据库**吐出来的码,
        //   而这一条拒绝是**这一侧**发的 —— 把它塞进那张码表会让下一个读表的人
        //   以为库里有这么一个错误码。按本刀另外三张表同一个写法,直接取文案。
        return { error: (await getTranslations())('sales.amend.errPayloadUnreadable') }
    }

    const lines: LinePayload[] = []
    // 【shipped 的单只许加行】—— 既有行一条都不递过去。递了会被服务端按名拒
    // (SO_NOT_AMENDABLE),而那是一次注定失败的提交:表单已经把它们画成只读了。
    if (mode !== 'addonly') {
        for (const l of existing) {
            if (l.remove) { lines.push({ id: l.id, line_no: l.line_no, remove: true }); continue }
            lines.push({
                id: l.id,
                // ★ `line_no` 是本刀新送的:`amend_sales_order` 报错时优先用它
                //   (`db/functions/amend_sales_order.sql:165`),而搬家前不送,
                //   于是那句拒绝点的是一串 UUID。
                line_no: l.line_no,
                quantity: l.quantity ? Number(l.quantity) : null,
                // ⚠ **`unit_price` 这个键【必须】在,哪怕值是 null** ——
                //   `amend_sales_order.sql:170` 判的是 `v_el ? 'unit_price'`,
                //   也就是**键在不在**:键不在 = 保持原价,键在而值空 = 按名拒。
                //   写成 `undefined` 会被 `JSON.stringify` 丢掉,于是一次本该被拒的
                //   空单价会**悄悄变成"原价不动"**。
                unit_price: l.unit_price.trim() === '' ? null : Number(l.unit_price),
            })
        }
    }

    // 加行:空槽整槽跳过;填了一半的槽【原样递过去】,由 SO_AMEND_LINE_INVALID
    // 点名是哪一格 —— 在这里悄悄丢掉它,人会以为自己加过了(而屏幕上什么都没有)。
    for (const s of slots) {
        if (!s.material_id && !s.quantity && !s.unit_price) continue
        lines.push({
            material_id: s.material_id,
            quantity: s.quantity === '' ? null : Number(s.quantity),
            unit_price: s.unit_price === '' ? null : Number(s.unit_price),
        })
    }

    const supabase = await createClient()
    const { error } = await supabase.rpc('amend_sales_order', {
        p_order_id: orderId,
        // 【理由不在这里兜底】草稿态服务端根本不要它;非草稿态空理由由 DB 点名拒
        // (SO_AMEND_REASON_REQUIRED)—— 一次改动没有理由,历史上就只是一行"数字变了"。
        p_reason: reason,
        // 【addonly:表头一个字都不递】amend_sales_order 见到 p_header 非空就拒,
        // 因为一张发完的单的条款已经履行完了。递一个"内容没变"的对象同样会被拒,
        // 而那会让页面看起来坏了。
        ...(mode === 'addonly' ? {} : {
            p_header: {
                notes: String(formData.get('notes') ?? '').trim(),
                terms_text: String(formData.get('terms_text') ?? '').trim(),
            },
        }),
        p_lines: lines,
    })

    if (error) return { error: await localizeSalesOrderError(error.message) }

    revalidatePath('/sales/orders')
    revalidatePath(`/sales/orders/${orderId}`)
    redirect(`/sales/orders/${orderId}`)
}
