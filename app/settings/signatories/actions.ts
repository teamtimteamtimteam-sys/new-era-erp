'use server'

// CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 Q3):设置 · 签署人 —— 名单的增减与公司印章的上传。三扇门都要 action.manage_signatories(只授 admin),
//   由库判(contract_signatory_add / _remove · company_stamp_record,外加 signing-assets 的存储策略);这里不另判,只把拒绝说成人话。
//   印章图:PNG 或 JPEG、不超过 2 MB(走服务端动作 —— 远低于 Vercel 的 4.5 MB),在服务端重编码成 PNG、保留透明、最宽 800 px,
//   【存进桶里的是重编码后的字节】;旧的那一张记 superseded_at(换掉留历史)。名单与印章的每一次改动都进变更记录(表上的触发器)。
import { randomUUID } from 'node:crypto'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { SIGNING_ASSETS_BUCKET, normalisePng, sha256Hex } from '@/lib/contractFiles'
import { localizeEsignError } from '@/app/contracts/[id]/files/esignErrorCodes'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const STAMP_MAX_BYTES = 2097152
const refuse = (code: string) => refuseFromCoded(code, localizeEsignError)

function refresh() {
    revalidatePath('/settings/signatories')
}

export async function addSignatory(employeeId: string, title: string): Promise<ActionOutcome> {
    if (!UUID.test(employeeId)) return { ...(await refuse('CONTRACT_SIGNATORY_EMPLOYEE_NOT_FOUND')), field: 'employee' }
    if (!title.trim()) return { ...(await refuse('CONTRACT_SIGNATORY_TITLE_REQUIRED')), field: 'title' }
    const supabase = await createClient()
    const { error } = await supabase.rpc('contract_signatory_add', { p_employee_id: employeeId, p_title: title.trim() })
    if (error) return refuseFromCoded(error.message, localizeEsignError)
    refresh()
    return { success: true }
}

export async function removeSignatory(signatoryId: string): Promise<ActionOutcome> {
    if (!UUID.test(signatoryId)) return refuse('CONTRACT_SIGNATORY_NOT_LISTED')
    const supabase = await createClient()
    const { error } = await supabase.rpc('contract_signatory_remove', { p_signatory_id: signatoryId })
    if (error) return refuseFromCoded(error.message, localizeEsignError)
    refresh()
    return { success: true }
}

export async function uploadCompanyStamp(formData: FormData): Promise<ActionOutcome> {
    const file = formData.get('stamp')
    if (!(file instanceof File) || file.size === 0 || file.size > STAMP_MAX_BYTES || !['image/png', 'image/jpeg'].includes(file.type)) {
        return { ...(await refuse('SIGNING_IMAGE_INVALID')), field: 'stamp' }
    }
    const png = await normalisePng(Buffer.from(await file.arrayBuffer()), { maxWidth: 800, trim: false })
    if (!png) return { ...(await refuse('SIGNING_IMAGE_INVALID')), field: 'stamp' }
    const supabase = await createClient()
    const id = randomUUID()
    const up = await supabase.storage.from(SIGNING_ASSETS_BUCKET).upload(`stamps/${id}.png`, png, { contentType: 'image/png', upsert: false })
    if (up.error) return refuse('SIGNING_UPLOAD_FAILED')
    const { error } = await supabase.rpc('company_stamp_record', { p_stamp_id: id, p_sha256: sha256Hex(png) })
    if (error) return refuseFromCoded(error.message, localizeEsignError)
    refresh()
    revalidatePath('/contracts/[id]/sign', 'page')
    return { success: true }
}
