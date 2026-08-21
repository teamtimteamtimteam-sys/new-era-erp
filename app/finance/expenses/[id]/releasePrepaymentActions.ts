'use server'

// EQP-1c-b(P5):把采购单上的定金冲抵到【这张费用单】的应付上。
//
// 【为什么这扇门在费用单上,而不在资产卡上】既有的那扇(进料侧)挂在
// app/inbound/[id]/edit —— 也就是【那张应付单据】上。设备侧的应付单据是
// 费用单,不是机器:一台机器可以挂好几张费用单(运费、关税、安装),
// 而一次冲抵冲的是【某一张发票】。资产卡负责【显示】还有多少定金没冲(P4),
// 动作在这里。
//
// 【金额与可用额都不在这里算】apply_prepayment 自己算 —— 它读定金的加权汇率、
// 判 R1/R2/R3 三条支路、拒超额(EXCEEDS_OPEN / PREPAY_INSUFFICIENT)。
// 页面只把意图递进去。**尤其不要在这里跨币种取 min** —— 那就是 FIN-12
// 那个"页面自己算汇率"的老毛病换个地方重演。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizePurchasingError } from '@/app/purchasing/purchasingErrorCodes'

export type ReleaseState = { error?: string; success?: boolean }

export async function releasePrepayment(
    expenseId: string,
    poId: string,
    _prev: ReleaseState,
    formData: FormData,
): Promise<ReleaseState> {
    const t = await getTranslations()

    const amountRaw = String(formData.get('amount') ?? '').trim()
    const amount = Number(amountRaw)
    if (!amountRaw || Number.isNaN(amount) || amount <= 0) {
        return { error: t('purchasing.errors.AMOUNT_INVALID') }
    }
    // 【日期不给默认值】X1:它决定这笔分录落在哪个期间。服务端也独立拒空
    // (RELEASE_DATE_REQUIRED)—— 这里是第一层,不是唯一那层。
    const releaseDate = String(formData.get('release_date') ?? '').trim()
    if (!releaseDate) return { error: t('purchasing.errors.RELEASE_DATE_REQUIRED') }

    const supabase = await createClient()
    const { error } = await supabase.rpc('apply_prepayment', {
        p_purchase_order_id: poId,
        p_inbound_batch_id: null,
        p_amount: amount,
        p_notes: String(formData.get('notes') ?? '').trim() || null,
        p_expense_id: expenseId,
        p_release_date: releaseDate,
    } as never)

    if (error) return { error: await localizePurchasingError(error.message) }

    revalidatePath(`/finance/expenses/${expenseId}`)
    revalidatePath(`/purchasing/orders/${poId}`)
    revalidatePath('/finance/assets')
    revalidatePath('/finance/payables')
    revalidatePath('/finance/journal')
    return { success: true }
}
