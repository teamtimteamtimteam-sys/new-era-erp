'use server'

// app/operation/weighbridge/actions.ts
// MES-2(2026-10-06,MES-0 Q19 · Q20;MES-2 Step 0 Q16–Q21,Tim):地磅单页上的动作。
//   · shareTicket       —— 从单上分一份:给一张【已经存在】的收货单(action.receive_goods,它的数量一个字都不动)
//                          或一条发货行(action.ship_goods,不挪钱)。建收货单【那一刻】给份走收货那两支函数,不在这里。
//   · voidTicket        —— 作废(action.confirm_capture;理由必填,只在一份都没分出去时)。
//   · recordTicketPhoto —— 照片已经由浏览器传进私有桶 capture-photos,这里落登记行(action.confirm_capture)。
//   · withdrawTicketPhoto —— 撤下一张拍错的照片(理由必填;行与对象都留着)。
//   · ticketPhotoUrl    —— 私有桶不能用公开地址:每次点开现生成一个 60 秒的签名链接(读策略:收货或物流查看码)。
// 判据全在库里;这里只再挡一道"公斤数是正数、理由不是空白、类型在白名单里"。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { localizeCaptureError } from '@/app/operation/capture/captureErrorCodes'
import { positiveKg } from '@/app/operation/capture/captureFields'
import { PHOTO_BUCKET, PHOTO_TYPES } from './ticketFields'

function refresh(ticketId: string) {
    revalidatePath('/operation/weighbridge')
    revalidatePath(`/operation/weighbridge/${ticketId}`)
}

export async function shareTicket(ticketId: string, target: { kind: 'receipt' | 'line'; id: string }, kgRaw: string): Promise<ActionOutcome> {
    const kg = positiveKg(kgRaw)
    if (kg === null) return { error: (await getTranslations())('capture.form.needPositiveKg'), field: 'kg' }
    const supabase = await createClient()
    const { error } = await supabase.rpc('share_weighbridge_ticket', {
        p_ticket_id: ticketId, p_kg: kg,
        ...(target.kind === 'receipt' ? { p_inbound_batch_id: target.id } : { p_shipment_line_id: target.id }),
    })
    if (error) return await refuseFromCoded(error.message, localizeCaptureError)
    refresh(ticketId)
    return { success: true }
}

export async function voidTicket(ticketId: string, reason: string): Promise<ActionOutcome> {
    if (reason.trim() === '') return { error: (await getTranslations())('capture.errors.TICKET_VOID_REASON_REQUIRED') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('void_weighbridge_ticket', { p_ticket_id: ticketId, p_reason: reason.trim() })
    if (error) return await refuseFromCoded(error.message, localizeCaptureError)
    refresh(ticketId)
    return { success: true }
}

export async function recordTicketPhoto(ticketId: string, filePath: string, fileName: string, mimeType: string, size: number): Promise<ActionOutcome> {
    if (!(PHOTO_TYPES as readonly string[]).includes(mimeType)) {
        return { error: (await getTranslations())('capture.errors.TICKET_PHOTO_TYPE_INVALID', { 0: mimeType }) }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_ticket_photo', {
        p_ticket_id: ticketId, p_file_path: filePath, p_file_name: fileName, p_mime_type: mimeType, p_size_bytes: size,
    })
    if (error) return await refuseFromCoded(error.message, localizeCaptureError)
    refresh(ticketId)
    return { success: true }
}

export async function withdrawTicketPhoto(ticketId: string, photoId: string, reason: string): Promise<ActionOutcome> {
    if (reason.trim() === '') return { error: (await getTranslations())('capture.errors.TICKET_PHOTO_WITHDRAW_REASON_REQUIRED') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_ticket_photo', { p_photo_id: photoId, p_reason: reason.trim() })
    if (error) return await refuseFromCoded(error.message, localizeCaptureError)
    refresh(ticketId)
    return { success: true }
}

export async function ticketPhotoUrl(filePath: string): Promise<{ url?: string; error?: string }> {
    const supabase = await createClient()
    const { data, error } = await supabase.storage.from(PHOTO_BUCKET).createSignedUrl(filePath, 60)
    if (error || !data?.signedUrl) return { error: (await getTranslations())('weighbridge.photoOpenError') }
    return { url: data.signedUrl }
}
