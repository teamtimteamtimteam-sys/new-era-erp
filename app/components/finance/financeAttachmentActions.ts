'use server'

// 财务凭据附件的服务端动作,端口自 app/suppliers/[id]/edit/attachmentActions.ts。
// 上传流程:浏览器端先把文件直传 Storage(私有桶 finance-attachments),
// 再调用 recordFinanceAttachment 把元数据写入 finance_attachments 表(XOR 三选一外键)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import {
    isAllowedFinanceAttachmentType,
    parentPagePath,
    type FinanceAttachmentParent,
} from './financeAttachmentTypes'

const BUCKET = 'finance-attachments'

// 浏览器端上传成功后传过来的元数据(纯可序列化对象,不含 File 本体)。
export interface RecordFinanceAttachmentInput {
    parent: FinanceAttachmentParent
    filePath: string
    fileName: string
    mimeType?: string | null
    fileSize?: number | null
    docType?: string | null
    notes?: string | null
}

// 文件已直传 Storage 后,写入元数据行。created_by 由列默认 auth.uid() 取当前登录用户。
export async function recordFinanceAttachment(input: RecordFinanceAttachmentInput) {
    const t = await getTranslations()

    const filePath = input.filePath?.trim()
    const fileName = input.fileName?.trim()
    if (!filePath || !fileName) {
        return { error: t('finAttach.uploadError', { message: 'missing path or name' }) }
    }

    const supabase = await createClient()

    // 服务端兜底:文件类型必须在白名单内(防止伪造的客户端绕过前端校验直接调用本动作)。
    // 文件此刻已直传到 Storage,被拒时顺手删掉刚上传的对象,避免留下孤儿文件。
    if (!isAllowedFinanceAttachmentType(input.mimeType)) {
        await supabase.storage.from(BUCKET).remove([filePath])
        return { error: t('finAttach.errType') }
    }

    // XOR 四选一外键:显式分支(计算属性名会破坏 insert 的类型收窄)
    const parentCols =
        input.parent.kind === 'sale'
            ? { sales_record_id: input.parent.id }
            : input.parent.kind === 'inbound'
              ? { inbound_batch_id: input.parent.id }
              : input.parent.kind === 'payment'
                ? { payment_id: input.parent.id }
                : { expense_id: input.parent.id }

    const { error } = await supabase.from('finance_attachments').insert({
        ...parentCols,
        file_path: filePath,
        file_name: fileName,
        mime_type: input.mimeType?.trim() || null,
        file_size: input.fileSize ?? null,
        doc_type: input.docType?.trim() || 'other',
        notes: input.notes?.trim() || null,
    })

    if (error) {
        return { error: t('finAttach.uploadError', { message: error.message }) }
    }

    revalidatePath(parentPagePath(input.parent))
    return { success: true }
}

// 私有桶不能用公开 URL —— 每次点击现生成一个 60s 的签名链接。
// download 选项让浏览器以原始文件名下载,而不是 UUID 化的 storage key。
export async function getFinanceAttachmentDownloadUrl(filePath: string, fileName?: string) {
    const t = await getTranslations()
    const supabase = await createClient()

    const { data, error } = await supabase.storage
        .from(BUCKET)
        .createSignedUrl(filePath, 60, { download: fileName || true })

    if (error || !data?.signedUrl) {
        return { error: t('finAttach.downloadError', { message: error?.message ?? 'no url' }) }
    }

    return { url: data.signedUrl }
}

// 软删除元数据行。【故意不删除 Storage 里的文件对象】—— 行只是软删(deleted_at),
// 保留文件以便将来恢复;真正的硬清理(对账后批量删 Storage 对象)留待以后。
export async function deleteFinanceAttachment(id: string, parent: FinanceAttachmentParent) {
    const t = await getTranslations()
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('finance_attachments')
        .update({
            deleted_at: new Date().toISOString(),
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null)

    if (error) {
        return { error: t('finAttach.uploadError', { message: error.message }) }
    }

    revalidatePath(parentPagePath(parent))
    return { success: true }
}
