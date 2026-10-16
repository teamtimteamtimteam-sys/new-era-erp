'use server'

// MES-8b-1(2026-10-17,MES-0 Q82 · MES-8 Step 0 Q15 · Q16 · Q18,Tim):合规包页上的两个动作 —— 冻一个已关账的月份(或带理由重出一份)、给 V26 / V27。
//   【冻的是数据库自己的那一份预览】freeze_compliance_pack 内部调 compliance_pack_data(页面画的也是它)—— 这里一行算术都没有。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { localizeComplianceError } from './complianceErrorCodes'

export async function freezeCompliancePack(month: string, notes: string, supersedeReason: string):
    Promise<ActionOutcome & { packId?: string; code?: string }> {
    const supabase = await createClient()
    const reason = (supersedeReason ?? '').trim()
    const note = (notes ?? '').trim()
    const { data, error } = await supabase.rpc('freeze_compliance_pack', {
        p_period_month: month ? `${month}-01` : (null as unknown as string),
        ...(note !== '' ? { p_notes: note } : {}),
        ...(reason !== '' ? { p_supersede_reason: reason } : {}),
    })
    if (error) return await refuseFromCoded(error.message, localizeComplianceError)
    revalidatePath('/compliance/packs')
    const r = data as { pack_id?: string; code?: string } | null
    return { success: true, packId: r?.pack_id, code: r?.code }
}

export async function setComplianceSettings(neaFormat: string, neaFrequency: string, euMethod: string, euTargets: string): Promise<ActionOutcome> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_compliance_settings', {
        p_nea_return_format: neaFormat, p_nea_return_frequency: neaFrequency,
        p_eu_efficiency_method: euMethod, p_eu_efficiency_targets: euTargets,
    })
    if (error) return await refuseFromCoded(error.message, localizeComplianceError)
    revalidatePath('/compliance/packs')
    revalidatePath('/settings/pending-values')
    return { success: true }
}
