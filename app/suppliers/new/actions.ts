'use server'

import { createClient } from '@/lib/supabase/server'
import { findNearDuplicate } from '@/lib/nearDuplicate'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

// 表单返回的状态(用于把错误信息回传给页面)
export type CreateSupplierState = {
    error?: string
    /** GO-4:名字近重复的【提醒】。有值 = 没有写入,等人再提交一次。 */
    nearDuplicateName?: string
    fieldErrors?: Record<string, string>
}

export async function createSupplier(
    _prevState: CreateSupplierState,
    formData: FormData
): Promise<CreateSupplierState> {
    const t = await getTranslations()

    // 1. 从表单里取出字段
    // LOG-1c:【同一条创建路径,两个入口】。货代也是一行 suppliers,只是类型不同 ——
    // 所以货代页复用这个 action,只用一个隐藏字段换掉回跳目标,
    // 而不是另写一处 insert(两处写同一张表,规矩迟早各自演化)。
    const redirect_to = ((formData.get('redirect_to') as string) || '/suppliers').trim()
    const legal_name = (formData.get('legal_name') as string)?.trim()
    // 再提交一次 = 已经读过提醒并坚持要建。
    const ackNearDuplicate = formData.get('ack_near_duplicate') !== null
    const short_name = (formData.get('short_name') as string)?.trim() || null
    const country = (formData.get('country') as string)?.trim().toUpperCase()
    const tax_id = (formData.get('tax_id') as string)?.trim() || null
    const address = (formData.get('address') as string)?.trim() || null
    const payment_terms = (formData.get('payment_terms') as string)?.trim() || null
    const incoterm = (formData.get('incoterm') as string)?.trim() || null
    const credit_rating = (formData.get('credit_rating') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null
    // 默认付款条款模板(空 = 无;非法 id 由外键拦下)
    const default_payment_term_template_id =
        (formData.get('default_payment_term_template_id') as string)?.trim() || null

    // 多选 checkbox:用 getAll 拿所有勾选的值
    const supplier_types = formData.getAll('supplier_types') as string[]
    // SUP-TYPE-1b:未勾选的 checkbox【什么都不发】—— 所以判据是"这个字段在不在",
    // 不是"它的值真不真"。用 formData.get(...) !== null 而不是 Boolean(值):
    // 后者会把 value="on" 之外的任何写法悄悄读成 false。
    // LOG-1a:supplies_goods 现在是 counterparty_type 的【派生列】,写不得 ——
    // 写它会被 PostgreSQL 直接拒绝(生成列)。所以这里写的是类型本身。
    const counterparty_type = String(formData.get('counterparty_type') ?? '')

    // 2. 基本校验
    const fieldErrors: Record<string, string> = {}
    if (!legal_name) fieldErrors.legal_name = t('suppliers.form.errLegalName')
    if (!country) fieldErrors.country = t('suppliers.form.errCountry')
    if (!['goods_supplier', 'forwarder', 'service_vendor'].includes(counterparty_type)) {
        fieldErrors.counterparty_type = t('suppliers.form.errCounterpartyType')
    }
    if (country && country.length !== 2) {
        fieldErrors.country = t('suppliers.form.errCountryFormat')
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 写入 Supabase
    const supabase = await createClient()
    // ── GO-4:名字的近重复【只提醒,不拦】────────────────────────────────────
    // 【为什么不拦】两家真正不同的公司可以同名(不同法域的同一个商号)。拦住一次
    // 正当的录入,只会把人逼去改个拼法绕过去 —— 造出的正是这条规矩要防的脏数据。
    // 【它有多强,说在这里,别让它看起来像执行】**这一层只在表单上,而且只能在
    // 表单上** —— 警告没法住在约束里(约束不会"提醒你然后放行")。所以直连
    // PostgREST 的写入【一句提醒都不会得到】,而 authenticated 对这张表持表级
    // INSERT 授权(GO-2 实测)。这是可以接受的:警告本来就不是执行。
    // **真正执行的是数据库上 tax_id 的部分唯一索引。两种强度,分开说。**
    if (!ackNearDuplicate) {
        const existing = await supabase
            .from('suppliers')
            .select('legal_name')
            .is('deleted_at', null)
        // 【查不到【不是】"没有近重复"】—— 读失败被当成空集,这条提醒就静静失效了。
        if (existing.error || !existing.data) {
            return { error: t('suppliers.form.saveError', { message: existing.error?.message ?? 'suppliers read failed' }) }
        }
        const clash = findNearDuplicate(
            legal_name, existing.data, (r: { legal_name: string }) => r.legal_name
        )
        if (clash) return { nearDuplicateName: clash }
    }

    const { error } = await supabase.from('suppliers').insert({
        legal_name,
        short_name,
        country,
        tax_id,
        address,
        supplier_types,
        counterparty_type,
        payment_terms,
        incoterm,
        credit_rating,
        notes,
        default_payment_term_template_id,
        // status 不传,用数据库默认值 'draft'
        // code 不传,用触发器自动生成
    } as InsertRow<'suppliers'>)

    if (error) {
        return { error: t('suppliers.form.saveError', { message: error.message }) }
    }

    // 4. 让列表页重新读取数据(否则会显示缓存的旧数据)
    revalidatePath('/suppliers')
    revalidatePath('/logistics/forwarders')

    // 5. 跳回来处的列表页
    redirect(redirect_to)
}