'use client'

// 供应商附件面板,镜像 CompliancePanel.tsx 的结构。
// 上传:浏览器端直传 Storage(@/lib/supabase/client),成功后再调 recordAttachment 写元数据。
// 下载:点按钮时现取一个签名 URL 再打开(私有桶)。删除:软删元数据行。
import { useRef, useState, useTransition } from 'react'
import { createClient } from '@/lib/supabase/client'
import {
    recordAttachment,
    getAttachmentDownloadUrl,
    deleteAttachment,
} from './attachmentActions'
import { useTranslations } from '@/lib/i18n/client'
import { ATTACHMENT_ACCEPT, isAllowedAttachmentType } from './attachmentTypes'
import { Button } from '@/app/components/ui/button'

const BUCKET = 'supplier-attachments'

// 客户端大小上限(桶本身是 50MB,这里前置拦一道,给出友好提示)。
const MAX_FILE_SIZE = 50 * 1024 * 1024

// 文档分类:目前只是 UI 选项,按规范值存成 text。Tim 之后可细化/收敛这个清单。
const DOC_CATEGORIES = [
    'hazardous-waste-permit',
    'import-license',
    'export-license',
    'basel-document',
    'contract',
    'other',
] as const

// created_at 已在服务端按当前语言格式化好传进来,避免客户端再 toLocaleString 造成水合不一致。
type AttachmentRow = {
    id: string
    file_name: string
    file_type: string | null
    file_size: number | null
    doc_category: string | null
    storage_path: string
    created_at_display: string
}

// 文件名安全化:只用于 storage key(去掉空格/中文/特殊字符);原始文件名仍存 file_name 列用于展示。
function sanitizeFilename(name: string): string {
    const cleaned = name
        .normalize('NFKD')
        .replace(/[^\w.\-]+/g, '_')
        .replace(/_+/g, '_')
        .replace(/^[._]+/, '')
    return cleaned || 'file'
}

// 人类可读的文件大小
function formatBytes(bytes: number | null): string {
    if (bytes === null || Number.isNaN(bytes)) return '—'
    if (bytes < 1024) return `${bytes} B`
    const kb = bytes / 1024
    if (kb < 1024) return `${kb.toFixed(1)} KB`
    const mb = kb / 1024
    return `${mb.toFixed(1)} MB`
}

export default function AttachmentsPanel({
    supplierId,
    rows,
}: {
    supplierId: string
    rows: AttachmentRow[]
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()
    const [formKey, setFormKey] = useState(0)
    const fileRef = useRef<HTMLInputElement>(null)

    // 已知分类显示翻译标签;遇到未知/历史值则原样显示,避免显示成 key 路径。
    function categoryLabel(value: string | null): string {
        if (!value) return '—'
        return (DOC_CATEGORIES as readonly string[]).includes(value)
            ? t('suppliers.attachments.cat.' + value)
            : value
    }

    async function handleUpload(formData: FormData) {
        const file = fileRef.current?.files?.[0]
        if (!file) {
            setError(t('suppliers.attachments.errNoFile'))
            return
        }
        if (file.size > MAX_FILE_SIZE) {
            setError(t('suppliers.attachments.errTooLarge', { max: formatBytes(MAX_FILE_SIZE) }))
            return
        }
        if (!isAllowedAttachmentType(file.type)) {
            setError(t('suppliers.attachments.errType'))
            return
        }

        const docCategory = (formData.get('doc_category') as string)?.trim() || null
        const notes = (formData.get('notes') as string)?.trim() || null

        setError(null)
        startTransition(async () => {
            const supabase = createClient()
            const path = `${supplierId}/${crypto.randomUUID()}-${sanitizeFilename(file.name)}`

            // 1) 文件本体直传 Storage
            const { error: uploadErr } = await supabase.storage
                .from(BUCKET)
                .upload(path, file, {
                    contentType: file.type || undefined,
                    upsert: false,
                })
            if (uploadErr) {
                setError(t('suppliers.attachments.uploadError', { message: uploadErr.message }))
                return
            }

            // 2) 元数据落库(原始文件名存这里用于展示)
            const result = await recordAttachment({
                supplierId,
                storagePath: path,
                fileName: file.name,
                fileType: file.type || null,
                fileSize: file.size,
                docCategory,
                notes,
            })
            if (result?.error) {
                // 文件已上传但元数据写入失败 —— 明确告知(文件留在 Storage,行未创建)
                setError(result.error)
                return
            }

            setFormKey((k) => k + 1)
            if (fileRef.current) fileRef.current.value = ''
        })
    }

    function handleDownload(row: AttachmentRow) {
        startTransition(async () => {
            const result = await getAttachmentDownloadUrl(row.storage_path, row.file_name)
            if (result?.error) {
                setError(result.error)
                return
            }
            setError(null)
            if (result.url) window.open(result.url, '_blank', 'noopener,noreferrer')
        })
    }

    function handleDelete(id: string) {
        if (!window.confirm(t('suppliers.attachments.deleteConfirm'))) return
        startTransition(async () => {
            const result = await deleteAttachment(id, supplierId)
            if (result?.error) {
                setError(result.error)
            } else {
                setError(null)
            }
        })
    }

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">{t('suppliers.attachments.sectionTitle')}</h2>

            {rows.length === 0 ? (
                <p className="text-sm text-gray-500 mb-6">{t('suppliers.attachments.empty')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 mb-6">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('suppliers.attachments.colName')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('suppliers.attachments.colCategory')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('suppliers.attachments.colType')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('suppliers.attachments.colSize')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('suppliers.attachments.colCreated')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('suppliers.attachments.colActions')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((row) => (
                            <tr key={row.id}>
                                <td className="border border-gray-300 px-4 py-2 break-all">{row.file_name}</td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">{categoryLabel(row.doc_category)}</td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">{row.file_type ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">{formatBytes(row.file_size)}</td>
                                <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">{row.created_at_display}</td>
                                <td className="border border-gray-300 px-4 py-2 whitespace-nowrap">
                                    <button
                                        type="button"
                                        onClick={() => handleDownload(row)}
                                        disabled={isPending}
                                        className="text-blue-600 text-sm hover:underline disabled:text-gray-400"
                                    >
                                        {t('suppliers.attachments.download')}
                                    </button>
                                    <span className="mx-2 text-gray-300">|</span>
                                    <button
                                        type="button"
                                        onClick={() => handleDelete(row.id)}
                                        disabled={isPending}
                                        className="text-red-600 text-sm hover:underline disabled:text-gray-400"
                                    >
                                        {t('suppliers.attachments.deleteFile')}
                                    </button>
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            <h3 className="text-lg font-semibold mb-3">{t('suppliers.attachments.addTitle')}</h3>

            {error && <p className="text-red-600 text-sm mb-3">{error}</p>}

            <form key={formKey} action={handleUpload} className="space-y-3">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('suppliers.attachments.fileLabel')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        ref={fileRef}
                        type="file"
                        name="file"
                        required
                        accept={ATTACHMENT_ACCEPT}
                        className="w-full text-sm file:mr-3 file:rounded file:border-0 file:bg-blue-600 file:px-4 file:py-2 file:text-white hover:file:bg-blue-700"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.attachments.category')}</label>
                    <select
                        name="doc_category"
                        defaultValue=""
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">{t('suppliers.attachments.categoryPlaceholder')}</option>
                        {DOC_CATEGORIES.map((c) => (
                            <option key={c} value={c}>
                                {t('suppliers.attachments.cat.' + c)}
                            </option>
                        ))}
                    </select>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.attachments.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        placeholder={t('suppliers.attachments.notesPlaceholder')}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div className="pt-2">
                    <Button
                        type="submit"
                        disabled={isPending}
                    >
                        {isPending ? t('suppliers.attachments.uploading') : t('suppliers.attachments.uploadButton')}
                    </Button>
                </div>
            </form>
        </section>
    )
}
