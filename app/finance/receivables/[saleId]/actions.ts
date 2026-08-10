'use server'

// SAL-C:补挂客户。价格/敞口都由 DB 算,这里只转达。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { localizeSaleError } from '@/app/output/[id]/edit/saleErrorCodes'

export async function attributeSaleCustomer(
    saleId: string,
    customerId: string,
    note: string
): Promise<{ error?: string; message?: string }> {
    const t = await getTranslations()
    if (!customerId) return { error: t('receivables.attribute.blockedNoCustomer') }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('attribute_sale_customer', {
        p_sales_record_id: saleId,
        p_customer_id: customerId,
        p_note: note.trim() || undefined,
    })
    if (error) return { error: await localizeSaleError(error.message) }

    const row = data as unknown as {
        customer_code: string; exposure_after: number; credit_limit_base: number | null; over_limit: boolean
    }
    revalidatePath('/finance/receivables')
    revalidatePath(`/finance/receivables/${saleId}`)
    // 补挂【如实报告】它把敞口推到了哪里 —— 越限不是拒绝的理由,但必须当场说出来
    return {
        message: row.over_limit
            ? t('receivables.attribute.doneOver', {
                  customer: row.customer_code,
                  exposure: String(row.exposure_after),
                  limit: String(row.credit_limit_base ?? ''),
              })
            : t('receivables.attribute.done', {
                  customer: row.customer_code,
                  exposure: String(row.exposure_after),
              }),
    }
}
