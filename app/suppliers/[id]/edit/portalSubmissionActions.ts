'use server'

// app/suppliers/[id]/edit/portalSubmissionActions.ts
// ════════════════════════════════════════════════════════════════════════════
// MES-9c(2026-10-20,MES-9 Step 0 Q19,Tim):供应商页上审核门户交上来的证书 —— 看文件、接受、驳回。
// ════════════════════════════════════════════════════════════════════════════
// 【门】module.suppliers.edit(Q19 —— 与在这一页手工加一张证书同一个码)。判据在库里(portal_submission_accept / _reject 先查码);
//   这里先问一次 can() 只是为了不白抄一份文件。
// 【接受】① 以【按按钮的人自己的会话】把文件从 portal-uploads 抄到 supplier-attachments 的 <供应商 id>/<uuid>-<文件名>
//   (读 portal-uploads 要 module.suppliers.view、写 supplier-attachments 要 module.suppliers.edit —— 都是存储策略判,不用 service role);
//   ② portal_submission_accept 在一笔事务里确认文件真的抄到了、建附件行与 supplier_compliance 行、把申请标成 accepted。
//   ② 失败 → 把 ① 抄过去的那一份删掉(supplier-attachments 的删除策略只放行没有附件行指着的孤儿 —— 这一份正是),并说清楚删没删成。
// 【驳回】portal_submission_reject:理由必填,供应商在门户里看得见。
// 【看文件】60 秒的签名链接(与附件那一块同一个做法),员工自己的会话 —— portal-uploads 的读策略 module.suppliers.view。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { can } from '@/lib/permissions'
import { getTranslations } from '@/lib/i18n/server'
import { localizePortalError } from '@/app/portal/portalErrorCodes'

export type SubmissionActionState = { error?: string; success?: boolean; url?: string }

const CODE = 'module.suppliers.edit'
const SOURCE_BUCKET = 'portal-uploads'
const TARGET_BUCKET = 'supplier-attachments'

function safeName(name: string): string {
    return name.replace(/[\\/\u0000-\u001f]+/g, '_').slice(0, 150) || 'certificate'
}

export async function getSubmissionFileUrl(form: { submissionId: string }): Promise<SubmissionActionState> {
    const t = await getTranslations()
    const supabase = await createClient()
    const { data: s, error } = await supabase.from('portal_certificate_submissions')
        .select('storage_path, file_name').eq('id', form.submissionId).maybeSingle()
    if (error) return { error: (await localizePortalError(error.message)).text }
    if (!s) return { error: t('portal.errors.PORTAL_SUBMISSION_NOT_FOUND') }
    const { data, error: uErr } = await supabase.storage.from(SOURCE_BUCKET).createSignedUrl(s.storage_path, 60, { download: s.file_name })
    if (uErr || !data?.signedUrl) return { error: t('portal.review.errFile', { 0: uErr?.message ?? 'no url' }) }
    return { url: data.signedUrl }
}

export async function acceptPortalSubmission(form: {
    supplierId: string; submissionId: string; certNo: string; issuingBody: string; validFrom: string; validUntil: string
}): Promise<SubmissionActionState> {
    const t = await getTranslations()
    if (!(await can(CODE))) return { error: t('permissions.errDenied') }
    const supabase = await createClient()
    const { data: s, error } = await supabase.from('portal_certificate_submissions')
        .select('id, supplier_id, storage_path, file_name, status').eq('id', form.submissionId).maybeSingle()
    if (error) return { error: (await localizePortalError(error.message)).text }
    if (!s || s.supplier_id !== form.supplierId) return { error: t('portal.errors.PORTAL_SUBMISSION_NOT_FOUND') }
    if (s.status !== 'submitted') return { error: t('portal.errors.PORTAL_SUBMISSION_NOT_WAITING', { 0: s.status }) }

    // ① 抄文件(员工自己的会话)
    const target = `${s.supplier_id}/${crypto.randomUUID()}-${safeName(s.file_name)}`
    const copied = await supabase.storage.from(SOURCE_BUCKET).copy(s.storage_path, target, { destinationBucket: TARGET_BUCKET })
    if (copied.error) return { error: t('portal.review.errCopy', { 0: copied.error.message }) }

    // ② 一笔事务:确认抄到了 · 附件行 · 证书行 · accepted
    const { error: aErr } = await supabase.rpc('portal_submission_accept', {
        p_submission_id: s.id,
        p_attachment_path: target,
        p_cert_no: form.certNo.trim() || undefined,
        p_issuing_body: form.issuingBody.trim() || undefined,
        p_valid_from: form.validFrom || undefined,
        p_valid_until: form.validUntil || undefined,
    })
    if (aErr) {
        const said = (await localizePortalError(aErr.message)).text
        const rm = await supabase.storage.from(TARGET_BUCKET).remove([target])
        if (rm.error || !rm.data || rm.data.length === 0) {
            return { error: t('portal.review.errAcceptCopyLeft', { 0: said, 1: target }) }
        }
        return { error: said }
    }
    revalidatePath(`/suppliers/${form.supplierId}/edit`)
    return { success: true }
}

export async function rejectPortalSubmission(form: { supplierId: string; submissionId: string; reason: string }): Promise<SubmissionActionState> {
    const t = await getTranslations()
    if (!(await can(CODE))) return { error: t('permissions.errDenied') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('portal_submission_reject', { p_submission_id: form.submissionId, p_reason: form.reason })
    if (error) return { error: (await localizePortalError(error.message)).text }
    revalidatePath(`/suppliers/${form.supplierId}/edit`)
    return { success: true }
}
