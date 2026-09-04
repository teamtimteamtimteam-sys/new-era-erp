'use server'

// 客户附件的服务端动作,端口自 suppliers 的 attachmentActions.ts。
// 上传流程:浏览器端先把文件直传 Storage(私有桶 customer-attachments),
// 再调用 recordAttachment 把元数据写入 customer_attachments 表。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { isAllowedAttachmentType } from './attachmentTypes'

const BUCKET = 'customer-attachments'

// 浏览器端上传成功后传过来的元数据(纯可序列化对象,不含 File 本体)。
export interface RecordAttachmentInput {
    customerId: string
    storagePath: string
    fileName: string
    fileType?: string | null
    fileSize?: number | null
    docCategory?: string | null
    notes?: string | null
}

// 文件已直传 Storage 后,写入元数据行。created_by 取当前登录用户。
export async function recordAttachment(input: RecordAttachmentInput) {
    const t = await getTranslations()

    const storagePath = input.storagePath?.trim()
    const fileName = input.fileName?.trim()
    if (!storagePath || !fileName) {
        return { error: t('customers.attachments.recordError', { message: 'missing path or name' }) }
    }

    const supabase = await createClient()

    // 服务端兜底:文件类型必须在白名单内(防止伪造的客户端绕过前端校验直接调用本动作)。
    // 文件此刻已直传到 Storage,被拒时顺手删掉刚上传的对象,避免留下孤儿文件。
    if (!isAllowedAttachmentType(input.fileType)) {
        await supabase.storage.from(BUCKET).remove([storagePath])
        return { error: t('customers.attachments.errType') }
    }

    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase.from('customer_attachments').insert({
        customer_id: input.customerId,
        storage_path: storagePath,
        file_name: fileName,
        file_type: input.fileType?.trim() || null,
        file_size: input.fileSize ?? null,
        doc_category: input.docCategory?.trim() || null,
        notes: input.notes?.trim() || null,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
    })

    if (error) {
        return { error: t('customers.attachments.recordError', { message: error.message }) }
    }

    revalidatePath(`/sales/customers/${input.customerId}/edit`)
    return { success: true }
}

// 私有桶不能用公开 URL —— 每次点击现生成一个 60s 的签名链接。
// download 选项让浏览器以原始文件名下载,而不是 UUID 化的 storage key。
export async function getAttachmentDownloadUrl(storagePath: string, fileName?: string) {
    const t = await getTranslations()
    const supabase = await createClient()

    const { data, error } = await supabase.storage
        .from(BUCKET)
        .createSignedUrl(storagePath, 60, { download: fileName || true })

    if (error || !data?.signedUrl) {
        return { error: t('customers.attachments.downloadError', { message: error?.message ?? 'no url' }) }
    }

    return { url: data.signedUrl }
}

// 软删除元数据行。
// 注意:这里【故意不删除 Storage 里的文件对象】—— 行只是软删(deleted_at),
// 保留文件以便将来恢复;真正的硬清理(对账后批量删 Storage 对象)留待以后。
export async function deleteAttachment(id: string, customerId: string) {
    const t = await getTranslations()
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('customer_attachments')
        .update({
            deleted_at: new Date().toISOString(),
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null)

    if (error) {
        return { error: t('customers.attachments.deleteError', { message: error.message }) }
    }

    revalidatePath(`/sales/customers/${customerId}/edit`)
    return { success: true }
}
