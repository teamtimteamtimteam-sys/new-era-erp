'use server'

// ROLE-1 Batch 2a(Tim,Q11):客户信用限额与冻结 —— CFO 一个(action.customer_credit)。
// 唯一的写入口是 set_customer_credit(SECURITY DEFINER);客户编辑表单从此【不再】带这两列,
// 直连改它们会被 guard_customer_credit_write 按名拒。留痕由表上的触发器照常写。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { refuseFromCoded } from '@/lib/action-refusal'
import { localizeCreditError } from './creditErrorCodes'

export type CreditState = { error?: string; detail?: string; field?: string; success?: boolean }

export async function setCustomerCredit(
    customerId: string,
    _prev: CreditState,
    formData: FormData
): Promise<CreditState> {
    const t = await getTranslations()
    // SAL-B:【空串 → NULL(没设限,放行);'0' → 0(现款现货,拒任何赊销)】—— 二者相反,
    // 所以显式区分空串与数值,不用 `|| null`(那会把 '0' 吞成不设限)。
    const limitRaw = String(formData.get('credit_limit_base') ?? '').trim()
    const limit = limitRaw === '' ? null : Number(limitRaw)
    if (limit !== null && (!Number.isFinite(limit) || limit < 0)) {
        return { error: t('customers.form.errCreditLimit'), field: 'credit_limit_base' }
    }
    const hold = formData.get('credit_hold') === 'on'

    const supabase = await createClient()
    const { error } = await supabase.rpc('set_customer_credit', {
        p_customer_id: customerId,
        // 函数的两个参数都必给:NULL 限额是一个【值】(不设限),不是"不改"。
        // ☞ 这一句 cast 关掉的是【生成类型不认 SQL 参数可为 NULL】那一格(supabase 的生成器
        //   把没有 DEFAULT 的 numeric 参数一律写成 number);它没有关掉任何列名或形状检查 ——
        //   函数签名里这个参数本来就接 NULL,而 NULL 正是"不设限"的写法。
        p_credit_limit_base: limit as number,
        p_credit_hold: hold,
    })
    if (error) {
        return await refuseFromCoded(error.message, localizeCreditError)
    }

    revalidatePath(`/sales/customers/${customerId}`)
    revalidatePath('/sales')
    return { success: true }
}
