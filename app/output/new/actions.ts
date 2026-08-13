'use server'

import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeStockError, warningCodesFrom, warnQuery } from '@/app/components/inventory/stockErrorCodes'

export type CreateOutputState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createOutput(
    _prevState: CreateOutputState,
    formData: FormData
): Promise<CreateOutputState> {
    const t = await getTranslations()

    // 1. 取字段
    const material_id = (formData.get('material_id') as string) || ''
    const customer_id = (formData.get('customer_id') as string) || ''
    const quantity_raw = (formData.get('quantity') as string) || ''
    const unit = (formData.get('unit') as string)?.trim() || 'kg'
    // 产出日【必填】,而且服务端【独立】拒空 —— 界面那道守卫可以被绕过,这一道
    // 不能。也【不给服务端默认值】:补一个 CURRENT_DATE 会让"留空"比"填对"更容易
    // 通过,那条路专门奖励留空(AGENTS.md 的日期规则)。与到货日同一条(FIN-32)。
    const output_date = (formData.get('output_date') as string)?.trim() || null
    // IOD-1b:收货库位【可选】。经 RPC 传进去 —— 建批次从此只有这一扇门,
    // 库位因此进得来(app 里 set_config 到不了:每次 PostgREST 调用都是
    // 独立会话,而 set_config 本身也不可调,实测 404 PGRST202)。
    const location_id = (formData.get('location_id') as string)?.trim() || null
    const state = (formData.get('state') as string)?.trim() || '库存中'
    const purity = (formData.get('purity') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null

    // 2. 校验(客户可选,不校验)
    const fieldErrors: Record<string, string> = {}
    if (!material_id) fieldErrors.material_id = t('output.form.errMaterial')

    let quantity: number | null = null
    if (!quantity_raw) {
        fieldErrors.quantity = t('output.form.errQuantity')
    } else {
        const n = Number(quantity_raw)
        if (Number.isNaN(n) || n <= 0) {
            fieldErrors.quantity = t('output.form.errQuantityPositive')
        } else {
            quantity = n
        }
    }

    if (!output_date) fieldErrors.output_date = t('output.form.errOutputDate')
    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 写入
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()
    // 到这里 quantity 必非空(上面的校验分支已经 return),但 TS narrow 不到。
    // 显式收窄而不是 as number:强转会把「其实可能为空」这件事藏起来,
    // 而这一行是进 RPC 之前的最后一道。
    if (quantity === null) return { fieldErrors: { quantity: 'quantity' } }


    // IOD-2:返回值从 uuid 变成 jsonb（{batch_id, warnings}）—— 告警要有地方回来。
    const { data, error } = await supabase.rpc('create_output_batch', {
        p_material_id: material_id,
        p_quantity: quantity,
        p_unit: unit,
        ...(output_date ? { p_output_date: output_date } : {}),
        p_state: state,
        ...(customer_id ? { p_customer_id: customer_id } : {}),
        ...(purity === null ? {} : { p_purity: purity }),
        ...(notes === null ? {} : { p_notes: notes }),
        ...(location_id ? { p_location_id: location_id } : {}),
    })

    if (error) {

        // IOD-1b:收货库位的两个具名拒绝翻成人话(表单开着时库位被停用,就落这里)

        if (/IOD_RECEIPT_LOCATION_|IOD_CLASS_EXCLUDED/.test(error?.message ?? '')) {

            return { error: await localizeStockError(error!.message) }

        }
        return { error: t('output.form.saveError', { message: error.message }) }
    }

    revalidatePath('/output')
    // IOD-2:告警随重定向带到列表页 —— 不带,它就只存在于数据库里。
    redirect(`/output${warnQuery(warningCodesFrom(data))}`)
}
