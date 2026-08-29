'use server'

import { createClient } from '@/lib/supabase/server'
import { findNearDuplicate } from '@/lib/nearDuplicate'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { localizeContactError } from '@/app/customers/contactErrorCodes'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

// 表单返回的状态(用于把错误信息回传给页面)
export type CreateCustomerState = {
    error?: string
    /** GO-4:名字近重复的【提醒】。有值 = 没有写入,等人再提交一次。 */
    nearDuplicateName?: string
    fieldErrors?: Record<string, string>
}

export async function createCustomer(
    _prevState: CreateCustomerState,
    formData: FormData
): Promise<CreateCustomerState> {
    const t = await getTranslations()

    // 1. 从表单里取出字段
    const legal_name = (formData.get('legal_name') as string)?.trim()
    // 再提交一次 = 已经读过提醒并坚持要建。
    const ackNearDuplicate = formData.get('ack_near_duplicate') !== null
    const short_name = (formData.get('short_name') as string)?.trim() || null
    const country = (formData.get('country') as string)?.trim().toUpperCase()
    const tax_id = (formData.get('tax_id') as string)?.trim() || null
    const address = (formData.get('address') as string)?.trim() || null
    const contact_person = (formData.get('contact_person') as string)?.trim() || null
    const email = (formData.get('email') as string)?.trim() || null
    const phone = (formData.get('phone') as string)?.trim() || null
    const payment_terms = (formData.get('payment_terms') as string)?.trim() || null
    // CASHFLOW-1：数字账期。空字符串必须变成 null，不能变成 0 ——
    // 0 天账期与「没说」是两件事，而开票表单读到 null 才会退回它自己的默认。
    const ptdRaw = (formData.get('payment_terms_days') as string)?.trim()
    const payment_terms_days = ptdRaw ? Number(ptdRaw) : null
    const incoterm = (formData.get('incoterm') as string)?.trim() || null
    const credit_rating = (formData.get('credit_rating') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null

    // 多选 checkbox:用 getAll 拿所有勾选的值
    const customer_types = formData.getAll('customer_types') as string[]

    // 2. 基本校验
    const fieldErrors: Record<string, string> = {}
    if (!legal_name) fieldErrors.legal_name = t('customers.form.errLegalName')
    if (!country) fieldErrors.country = t('customers.form.errCountry')
    if (country && country.length !== 2) {
        fieldErrors.country = t('customers.form.errCountryFormat')
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
            .from('customers')
            .select('legal_name')
            .is('deleted_at', null)
        // 【查不到【不是】"没有近重复"】—— 读失败被当成空集,这条提醒就静静失效了。
        if (existing.error || !existing.data) {
            return { error: t('customers.form.saveError', { message: existing.error?.message ?? 'customers read failed' }) }
        }
        const clash = findNearDuplicate(
            legal_name, existing.data, (r: { legal_name: string }) => r.legal_name
        )
        if (clash) return { nearDuplicateName: clash }
    }

    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { data: inserted, error } = await supabase.from('customers').insert({
        legal_name,
        short_name,
        country,
        tax_id,
        address,
        customer_types,
        payment_terms,
        payment_terms_days,
        incoterm,
        credit_rating,
        notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
        // status 不传,用数据库默认值 'draft'
        // code 不传,用触发器自动生成
    } as InsertRow<'customers'>).select('id').single()

    if (error) {
        return { error: t('customers.form.saveError', { message: error.message }) }
    }

    // ── PARTY-1:第一个联系人写进 counterparty_contacts,不再写进 customers ──
    // 【联系人是【第二次】写入,而客户已经建好了 —— 这句话要说清楚】
    //   两次写入不在同一笔事务里(PostgREST 没有多语句事务)。所以联系人失败时
    //   客户【已经存在】,而正确的处置是把这件事【说出来并指路】,
    //   不是假装没发生、也不是回滚一个已经拿到编号的客户。
    // 【只有填了才写】三个框全空 = 没有联系人,那是合法的,不该造一行空记录。
    if (contact_person || email || phone) {
        const { error: cErr } = await supabase.rpc('save_counterparty_contact', {
            p_customer_id: inserted.id,
            // 【?? undefined 而不是 null】生成的类型对可选参数只接受 undefined;
            // 而"省略"与"传 NULL"在 PL/pgSQL 那侧是同一件事(默认值就是 NULL)。
            p_name: contact_person ?? undefined,
            p_email: email ?? undefined,
            p_phone: phone ?? undefined,
            p_is_primary: true,
        })
        if (cErr) {
            revalidatePath('/customers')
            return { error: t('customers.form.contactSavedPartly', {
                message: await localizeContactError(cErr.message) }) }
        }
    }

    // 4. 让 /customers 列表页重新读取数据(否则会显示缓存的旧数据)
    revalidatePath('/customers')

    // 5. 跳回列表页
    redirect('/customers')
}
