'use server'

import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'

export type UpdateOutputState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function updateOutput(
    id: string,
    _prevState: UpdateOutputState,
    formData: FormData
): Promise<UpdateOutputState> {
    const t = await getTranslations()

    // 1. 取字段(和 createOutput 一致)
    const material_id = (formData.get('material_id') as string) || ''
    const customer_id = (formData.get('customer_id') as string) || ''
    // quantity and state are no longer editable here: quantity is immutable (DB-guarded)
    // and state is driven by sales/operation/processing. Both flow through the movement ledger.
    const unit = (formData.get('unit') as string)?.trim() || 'kg'
    const output_date = (formData.get('output_date') as string)?.trim() || null
    const purity = (formData.get('purity') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null

    // 2. 校验(客户可选,不校验)
    const fieldErrors: Record<string, string> = {}
    if (!material_id) fieldErrors.material_id = t('output.form.errMaterial')

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 更新(不动 remaining_qty、code、status)
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('output_batches')
        .update({
            material_id,
            customer_id: customer_id || null, // 可选
            unit,
            output_date,
            purity,
            notes,
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不能改

    if (error) {
        return { error: t('output.form.saveError', { message: error.message }) }
    }

    revalidatePath('/output')
    revalidatePath(`/output/${id}/edit`)
    redirect('/output')
}
