'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizeSaleError } from './saleErrorCodes'

export type SaleState = { error?: string; success?: boolean }

export async function recordSale(
    batchId: string,
    _prevState: SaleState,
    formData: FormData
): Promise<SaleState> {
    const t = await getTranslations()

    const quantity_raw = (formData.get('quantity') as string) || ''
    const sale_date = (formData.get('sale_date') as string)?.trim() || ''
    const notes = (formData.get('notes') as string)?.trim() || ''

    const n = Number(quantity_raw)
    if (!quantity_raw || Number.isNaN(n) || n <= 0) {
        return { error: t('output.sale.errQuantity') }
    }

    const supabase = await createClient()
    const { error } = await supabase.rpc('record_output_sale', {
        p_output_batch_id: batchId,
        p_quantity: n,
        p_sale_date: sale_date || undefined,
        p_notes: notes || undefined,
    })

    if (error) {
        return { error: await localizeSaleError(error.message) }
    }

    revalidatePath(`/output/${batchId}/edit`)
    return { success: true }
}
