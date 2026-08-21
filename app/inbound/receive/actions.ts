'use server'

// 现场收货:复用与 inbound/new 完全相同的建单路径(自动 code + 库存 receipt 流水 + 不变式),
// 只是把 UI 精简成移动端一步式。单位固定 kg,不收 unit_price / stage(stage 用 DB 默认 '待加工')。
import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizePurchasingError } from '@/app/purchasing/purchasingErrorCodes'
import { isStockErrorCode, localizeStockError, warningCodesFrom, warnQuery } from '@/app/components/inventory/stockErrorCodes'
import { localizeMaterialError } from '@/app/materials/materialErrorCodes'
import { CERTAINTY_UNCHOSEN, FIELD_SAFETY_STATES, FIELD_CERTAINTY } from '../IntakeConditionFields'

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
    // GRN-1b:申报量【可选】。空 = 没记录过,【不是 0】—— 所以空的时候
    // 整个 p_declared_qty 参数都不传(下面用展开),让库里落 NULL。
    // 传 0 会让"供应商申报了零"成为一条记录,而那是一句没人说过的话。
    const declared_raw = (formData.get('declared_qty') as string)?.trim() || ''
    // PROC-2c:到货状态的两条轴 —— 【门口已经知道的事,在门口就记下来】。
    // 安全状态是多值,所以用 getAll;哨兵串翻成"没有记过"(NULL / 不传)。
    // 【空的一组不传,而不是传空数组】建批次时这两者【逐字同结果】(新批次本来
    // 就没有任何状态行),而不传更诚实:它说的是"这次没有人记过",不是
    // "有人看过、结论是一条都不符合"。那个区别本身是 D3 记在
    // set_inbound_safety_states 的函数注释里的一条【已知缺口】,PROC-3 会碰它。
    const safety_states = formData.getAll(FIELD_SAFETY_STATES)
        .map((v) => String(v).trim()).filter((v) => v !== '')
    const certainty_raw = String(formData.get(FIELD_CERTAINTY) ?? '').trim()
    const chemistry_certainty =
        certainty_raw === '' || certainty_raw === CERTAINTY_UNCHOSEN ? null : certainty_raw

    const fieldErrors: Record<string, string> = {}
    if (!supplier_id) fieldErrors.supplier_id = t('receive.errSupplier')
    if (!material_id) fieldErrors.material_id = t('receive.errMaterial')

    // 填了就必须是个正数;没填是合法的(那是"没记录")。
    let declared_qty: number | null = null
    if (declared_raw) {
        const d = Number(declared_raw)
        if (Number.isNaN(d) || d <= 0) fieldErrors.declared_qty = t('receive.errDeclaredQty')
        else declared_qty = d
    }

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
            // GRN-1b:没填就【整个参数不传】,库里落 NULL(具名的"没记录过")
            ...(declared_qty === null ? {} : { p_declared_qty: declared_qty }),
            // PROC-2c:两条轴跟着建批次【一笔写完】—— 建批次成功而状态没记上,
            // 或者反过来,都不可能发生(RPC 是一个事务)。
            ...(safety_states.length === 0 ? {} : { p_safety_states: safety_states }),
            ...(chemistry_certainty === null ? {} : { p_chemistry_certainty: chemistry_certainty }),
        })

    if (error || !data) {

        // IOD-1b/IOD-2:库存侧的具名拒绝一律翻成人话。判据来自 STOCK_ERROR_CODES
        // 本身(isStockErrorCode)—— 手抄一份正则到三个 action 里,就是第二份会漂开
        // 的清单,而漏掉的那一处会把机器码原样端给操作员。

        if (isStockErrorCode(error?.message)) {

            return { error: await localizeStockError(error!.message) }

        }
        // 收货触发器的编码错误本地化;其余仍走原样的 saveError
        if (error && /PO_NOT_RECEIVABLE|PO_LINE_MISMATCH|PO_NOT_APPROVED|SUPPLIER_QUALIFICATION_EXPIRED/.test(error.message)) {
            return { error: await localizePurchasingError(error.message) }
        }
        // PROC-2c:状态轴那几条具名拒绝翻成人话(判据来自 MATERIAL_ERROR_CODES)。
        if (error) {
            const localized = await localizeMaterialError(error.message)
            if (localized !== error.message.trim()) return { error: localized }
        }
        return { error: t('receive.saveError', { message: error?.message ?? '' }) }
    }

    revalidatePath('/inbound')
    // IOD-2:RPC 现在返回 jsonb（{batch_id, warnings}）—— 【这一处是唯一真的读了
    // 返回值的调用方】(另外两个只看 error),所以改返回类型必须同时改这一行,
    // 否则 done 页会拿到一个对象去当 uuid 用。告警带进 done 页。
    const batchId = (data as { batch_id?: string } | null)?.batch_id
    redirect(`/inbound/receive/done/${batchId}${warnQuery(warningCodesFrom(data))}`)
}
