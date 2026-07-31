'use server'

// 培训记录的增/改/软删。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeHrError } from '../hrErrorCodes'

export type TrainingFormState = { error?: string }

export async function saveTraining(
    _prevState: TrainingFormState,
    formData: FormData
): Promise<TrainingFormState> {
    const t = await getTranslations()

    const id = String(formData.get('training_id') ?? '').trim()
    const employeeId = String(formData.get('employee_id') ?? '').trim()
    const name = String(formData.get('training_name') ?? '').trim()
    const category = String(formData.get('category') ?? '').trim()
    const completed = String(formData.get('completed_date') ?? '').trim()
    const expiry = String(formData.get('expiry_date') ?? '').trim()
    const provider = String(formData.get('provider') ?? '').trim()
    const certRef = String(formData.get('certificate_ref') ?? '').trim()
    const notes = String(formData.get('notes') ?? '').trim()
    // 从员工档案页进来时带着 ?employee=,保存后回那一页
    const returnTo = String(formData.get('return_to') ?? '').trim()

    if (!employeeId) return { error: t('hr.errors.EMPLOYEE_NOT_FOUND', { 0: '?' }) }
    if (!name) return { error: t('hr.errTrainingName') }
    if (!completed || Number.isNaN(Date.parse(completed))) return { error: t('finance.errDate') }
    if (expiry && Number.isNaN(Date.parse(expiry))) return { error: t('finance.errDate') }

    const supabase = await createClient()
    const payload = {
        employee_id: employeeId,
        training_name: name,
        category: category || null,
        completed_date: completed,
        expiry_date: expiry || null,
        provider: provider || null,
        certificate_ref: certRef || null,
        notes: notes || null,
    }

    const { error } = id
        ? await supabase.from('training_records').update(payload).eq('id', id)
        : await supabase.from('training_records').insert(payload)

    if (error) return { error: await localizeHrError(error.message) }

    revalidatePath('/hr/training')
    revalidatePath('/hr')
    revalidatePath(`/hr/employees/${employeeId}`)
    redirect(returnTo || '/hr/training')
}

export async function deleteTraining(trainingId: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase
        .from('training_records')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', trainingId)
    if (error) return { error: await localizeHrError(error.message) }
    revalidatePath('/hr/training')
    revalidatePath('/hr')
    return {}
}
