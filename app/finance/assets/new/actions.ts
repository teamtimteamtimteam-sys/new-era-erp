'use server'

// EQP-1c-b(P1):登记一台机器 —— 【第二扇】建卡的门。
// 校验全在 DB(create_fixed_asset),这里只组装意图并把拒绝翻成人话。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { getTranslations } from '@/lib/i18n/server'
import { localizePaymentError } from '@/app/finance/paymentErrorCodes'

export type NewAssetState = { error?: string }

export async function createAsset(
    _prev: NewAssetState,
    formData: FormData,
): Promise<NewAssetState> {
    const t = await getTranslations()

    const description = String(formData.get('description') ?? '').trim()
    const lifeRaw = String(formData.get('useful_life_months') ?? '').trim()
    const acquisitionDate = String(formData.get('acquisition_date') ?? '').trim()
    const category = String(formData.get('category') ?? 'equipment')
    const notes = String(formData.get('notes') ?? '').trim()

    // 【前置检查只是礼貌,不是保证】服务端 create_fixed_asset 每一条都再判一次
    // (AGENTS.md:提交控件禁用是第一层,服务端独立拒绝是第二层,而 UI 的
    //  required 只是第三层、不是保护)。
    if (!description) return { error: t('finance.errors.ASSET_DESCRIPTION_REQUIRED') }
    if (!acquisitionDate) return { error: t('finance.errors.ASSET_ACQUISITION_DATE_REQUIRED') }
    const life = Number(lifeRaw)
    if (!lifeRaw || Number.isNaN(life) || life <= 0 || !Number.isInteger(life)) {
        return { error: t('finance.errors.ASSET_LIFE_INVALID', { 0: lifeRaw || '?' }) }
    }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('create_fixed_asset', {
        p_description: description,
        p_useful_life_months: life,
        // 【日期不给默认值】它是投用日的下界;悄悄填今天会把投用日的合法范围
        // 一起挪掉(与 FIN-10 那十一个函数同一条规矩)。
        p_acquisition_date: acquisitionDate,
        p_category: category,
        p_notes: notes || null,
    } as never)

    if (error) return { error: await localizePaymentError(error.message) }

    revalidatePath('/finance/assets')
    const assetId = (data as { asset_id?: string } | null)?.asset_id
    redirect(assetId ? `/finance/assets/${assetId}` : '/finance/assets')
}
