'use server'

// CONTRACT-ESIGN(Tim 2026-10-30 Q4):签署人【本人】在 /me 上画的签名 —— 存成自己的签字样本。
//   浏览器交来一张画布导出的 PNG(几十 KB,远低于 Vercel 的 4.5 MB 请求体上限,所以走服务端动作);这里:
//   ① 只收 PNG、不超过 1 MB、能解码、像素不超过 4000 × 4000(与 avatar 那一条同一个顺序:先看大小,再读文件头,最后才解码);
//   ② 裁掉四周的空白、缩到最宽 1200 px、保留透明 —— 【存进桶里的是这一步产出的字节】;
//   ③ 以本人的会话传到 signing-assets 的 specimens/<本人员工 id>/<新 id>.png(存储只放行本人、而且在签署人名单上的人);
//   ④ signature_specimen_record:旧的那一张记 superseded_at(换掉留历史),新的这张在用。admin 替别人设不了(库与存储两头都判)。
import { randomUUID } from 'node:crypto'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { SIGNING_ASSETS_BUCKET, normalisePng, sha256Hex } from '@/lib/contractFiles'
import { localizeEsignError } from '@/app/contracts/[id]/files/esignErrorCodes'

const MAX_BYTES = 1048576
const refuse = (code: string) => refuseFromCoded(code, localizeEsignError)

export async function saveSignatureSpecimen(dataUrl: string): Promise<ActionOutcome> {
    const m = /^data:image\/png;base64,([A-Za-z0-9+/=]+)$/.exec(dataUrl ?? '')
    if (!m) return refuse('SIGNING_IMAGE_INVALID')
    const input = Buffer.from(m[1], 'base64')
    if (input.length === 0 || input.length > MAX_BYTES) return refuse('SIGNING_IMAGE_INVALID')
    const png = await normalisePng(input, { maxWidth: 1200, trim: true })
    if (!png) return refuse('SIGNING_IMAGE_INVALID')

    const supabase = await createClient()
    const me = mustOne(await supabase.rpc('current_user_employee'), 'current_user_employee') as string | null
    if (!me) return refuse('CONTRACT_SIGN_NOT_SIGNATORY')
    const id = randomUUID()
    const up = await supabase.storage.from(SIGNING_ASSETS_BUCKET).upload(`specimens/${me}/${id}.png`, png, { contentType: 'image/png', upsert: false })
    if (up.error) {
        // 存储拒 = 不在名单上(或别的存储故障);库那一句说得更准,问它一次
        const active = mustOne(await supabase.rpc('contract_signatory_active'), 'contract_signatory_active') === true
        return refuse(active ? 'SIGNING_UPLOAD_FAILED' : 'CONTRACT_SIGN_NOT_SIGNATORY')
    }
    const { error } = await supabase.rpc('signature_specimen_record', { p_specimen_id: id, p_sha256: sha256Hex(png) })
    if (error) return refuseFromCoded(error.message, localizeEsignError)
    revalidatePath('/me')
    revalidatePath('/contracts/[id]/sign', 'page')
    return { success: true }
}
