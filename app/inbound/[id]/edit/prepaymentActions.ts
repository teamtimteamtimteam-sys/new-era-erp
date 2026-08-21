'use server'

// 抵扣预付:rpc apply_prepayment(校验与分录都在 DB —— 借 2000 / 贷 1300)。
// 资格与建议金额来自 po_prepayment_applicable(页面读的就是它),这里只传意图。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizePurchasingError } from '@/app/purchasing/purchasingErrorCodes'

export type ApplyPrepaymentState = { error?: string; success?: boolean }

export async function applyPrepayment(
    batchId: string,
    poId: string,
    _prevState: ApplyPrepaymentState,
    formData: FormData
): Promise<ApplyPrepaymentState> {
    const t = await getTranslations()

    const amountRaw = String(formData.get('amount') ?? '').trim()
    const amount = Number(amountRaw)
    if (!amountRaw || Number.isNaN(amount) || amount <= 0) {
        return { error: t('purchasing.errors.AMOUNT_INVALID') }
    }

    // EQP-1c-b(X1):冲抵日必填,且【不给默认值】。它决定这笔分录的期间;
    // 服务端 apply_prepayment 也独立拒空(RELEASE_DATE_REQUIRED)——
    // 这里是第一层,不是唯一那层。
    const releaseDate = String(formData.get('release_date') ?? '').trim()
    if (!releaseDate) {
        return { error: t('purchasing.errors.RELEASE_DATE_REQUIRED') }
    }

    const supabase = await createClient()
    const { error } = await supabase.rpc('apply_prepayment', {
        p_purchase_order_id: poId,
        p_inbound_batch_id: batchId,
        p_amount: amount,
        p_release_date: releaseDate,
    } as never)

    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }

    revalidatePath(`/inbound/${batchId}/edit`)
    revalidatePath(`/purchasing/orders/${poId}`)
    revalidatePath('/finance/payables')
    revalidatePath('/finance/journal')
    return { success: true }
}
