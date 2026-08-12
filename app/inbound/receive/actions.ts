'use server'

// 现场收货:复用与 inbound/new 完全相同的建单路径(自动 code + 库存 receipt 流水 + 不变式),
// 只是把 UI 精简成移动端一步式。单位固定 kg,不收 unit_price / stage(stage 用 DB 默认 '待加工')。
import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizePurchasingError } from '@/app/purchasing/purchasingErrorCodes'
import { localizeStockError } from '@/app/components/inventory/stockErrorCodes'

export type ReceiveState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createFieldReceipt(
    _prevState: ReceiveState,
    formData: FormData
): Promise<ReceiveState> {
    const t = await getTranslations()

    const supplier_id = (formData.get('supplier_id') as string) || ''
    const material_id = (formData.get('material_id') as string) || ''
    const quantity_raw = (formData.get('quantity') as string) || ''
    // FIN-32:到货日【必填】,而且服务端【独立】拒空 —— 界面那道守卫可以被绕过,
    // 这一道不能。也【不给服务端默认值】:补一个 CURRENT_DATE 会让"留空"比"填对"
    // 更容易通过,那条路专门奖励留空(AGENTS.md 的日期规则)。
    const arrival_date = (formData.get('arrival_date') as string)?.trim() || null
    // IOD-1b:收货库位【可选】。经 RPC 传进去 —— 建批次从此只有这一扇门,
    // 库位因此进得来(app 里 set_config 到不了:每次 PostgREST 调用都是
    // 独立会话,而 set_config 本身也不可调,实测 404 PGRST202)。
    const location_id = (formData.get('location_id') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null
    // 关联采购单(cut 4c,可选;成对出现)
    const purchase_order_id = (formData.get('purchase_order_id') as string) || null
    const purchase_order_line_id = (formData.get('purchase_order_line_id') as string) || null

    const fieldErrors: Record<string, string> = {}
    if (!supplier_id) fieldErrors.supplier_id = t('receive.errSupplier')
    if (!material_id) fieldErrors.material_id = t('receive.errMaterial')

    let quantity: number | null = null
    if (!quantity_raw) {
        fieldErrors.quantity = t('receive.errQuantity')
    } else {
        const n = Number(quantity_raw)
        if (Number.isNaN(n) || n <= 0) fieldErrors.quantity = t('receive.errQuantity')
        else quantity = n
    }

    if (!arrival_date) fieldErrors.arrival_date = t('receive.errArrivalDate')
    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()
    // 到这里 quantity 必非空(上面的校验分支已经 return),但 TS narrow 不到。
    // 显式收窄而不是 as number:强转会把「其实可能为空」这件事藏起来,
    // 而这一行是进 RPC 之前的最后一道。
    if (quantity === null) return { fieldErrors: { quantity: 'quantity' } }


    const { data, error } = await supabase
        .rpc('receive_inbound_batch_against_po', {
            p_material_id: material_id,
            p_supplier_id: supplier_id,
            p_quantity: quantity,
            ...(arrival_date ? { p_arrival_date: arrival_date } : {}),
            ...(notes === null ? {} : { p_notes: notes }),
            ...(purchase_order_id ? { p_purchase_order_id: purchase_order_id } : {}),
            ...(purchase_order_line_id ? { p_purchase_order_line_id: purchase_order_line_id } : {}),
            ...(location_id ? { p_location_id: location_id } : {}),
        })

    if (error || !data) {

        // IOD-1b:收货库位的两个具名拒绝翻成人话(表单开着时库位被停用,就落这里)

        if (/IOD_RECEIPT_LOCATION_/.test(error?.message ?? '')) {

            return { error: await localizeStockError(error!.message) }

        }
        // 收货触发器的编码错误本地化;其余仍走原样的 saveError
        if (error && /PO_NOT_RECEIVABLE|PO_LINE_MISMATCH|PO_NOT_APPROVED|SUPPLIER_QUALIFICATION_EXPIRED/.test(error.message)) {
            return { error: await localizePurchasingError(error.message) }
        }
        return { error: t('receive.saveError', { message: error?.message ?? '' }) }
    }

    revalidatePath('/inbound')
    // IOD-1b:RPC 返回的是新批次的 uuid 本身(不再是一行)
    redirect(`/inbound/receive/done/${data}`)
}
