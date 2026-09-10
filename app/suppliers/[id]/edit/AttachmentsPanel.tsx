'use client'

// 供应商附件面板,镜像 CompliancePanel.tsx 的结构。
// 上传:浏览器端直传 Storage(@/lib/supabase/client),成功后再调 recordAttachment 写元数据。
// 下载:点按钮时现取一个签名 URL 再打开(私有桶)。删除:软删元数据行。
//
// ★ TABLE-CONVERT-3(2026-09-10):手搓表格 → 组件。
//   【这是【一次判断,三个文件】—— materials / sales-customers / suppliers 三份
//     AttachmentsPanel 是互相移植出来的,列、判断、动作逐字相同,所以三份一起转,
//     一份都不落下(委托书:三个文件是一个单位)。】
//   【手机上留哪几列一个字没改】TABLE-PHONE-1 留的是 名称 · 分类 · **操作**,
//     折起来的是 类型 · 大小 · 上传时间。
//   ★ 「操作」那一列转换前【就已经】留在明面上(它没有 hidden sm:table-cell),
//     所以这里 priority:true 是【原样搬过来】,不是 R1 又改了一次判断 ——
//     R1 当初正是照着这一列的理由写的(够不着的动作等于不存在)。
//   叠在名称格里那一段手写的展开块【拿掉了】:组件自己画那一段。
import { CONTROL_FILE_BUTTON, CONTROL_SELECT, CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useRef, useState, useTransition } from 'react'
import { createClient } from '@/lib/supabase/client'
import {
    recordAttachment,
    getAttachmentDownloadUrl,
    deleteAttachment,
} from './attachmentActions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { ATTACHMENT_ACCEPT, isAllowedAttachmentType } from './attachmentTypes'
import { Button } from '@/app/components/ui/button'
import { DataTable, type Column } from '@/app/components/ui/data-table'

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
        startTransition(async () => {
            const result = await deleteAttachment(id, supplierId)
            if (result?.error) {
                setError(result.error)
            } else {
                setError(null)
            }
        })
    }

    // ★ 手机上留三列:名称(身份)· 分类 · 操作。类型 / 大小 / 上传时间进展开区。
    const columns: Column<AttachmentRow>[] = [
        { key: 'name', header: t('suppliers.attachments.colName'), priority: true, className: 'break-all', render: (row) => row.file_name },
        { key: 'category', header: t('suppliers.attachments.colCategory'), priority: true, render: (row) => categoryLabel(row.doc_category) },
        { key: 'type', header: t('suppliers.attachments.colType'), render: (row) => row.file_type ?? '—' },
        { key: 'size', header: t('suppliers.attachments.colSize'), render: (row) => formatBytes(row.file_size) },
        { key: 'created', header: t('suppliers.attachments.colCreated'), className: 'text-gray-600', render: (row) => row.created_at_display },
        {
            key: 'actions', header: t('suppliers.attachments.colActions'), priority: true, className: 'whitespace-nowrap',
            render: (row) => (
                <>
                    <Button
                        variant="link"
                        size="inline"
                        type="button"
                        onClick={() => handleDownload(row)}
                        disabled={isPending}
                    >
                        {t('suppliers.attachments.download')}
                    </Button>
                    <span className="mx-2 text-gray-300">|</span>
                    {/* CONFIRM-1:这一列每行都长得一样,所以"删除这个附件?"
                        答不上来【哪一个】—— 文件名一直就在 row 上。 */}
                    <ConfirmButton
                        subject={row.file_name}
                        title={t('suppliers.attachments.deleteConfirm')}
                        body={t('common.softDeleteFileNote')}
                        confirmLabel={t('suppliers.attachments.deleteFile')}
                        tier="destructive"
                        disabled={isPending}
                        className="text-red-600 text-sm hover:underline disabled:text-gray-400"
                        onConfirm={() => handleDelete(row.id)}
                    >
                        {t('suppliers.attachments.deleteFile')}
                    </ConfirmButton>
                </>
            ),
        },
    ]

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">{t('suppliers.attachments.sectionTitle')}</h2>

            <div className="mb-6">
                <DataTable
                    rows={rows}
                    columns={columns}
                    rowKey={(row) => row.id}
                    phone={{ mode: 'columns' }}
                    empty={t('suppliers.attachments.empty')}
                />
            </div>

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
                        className={`${CONTROL_FILE_BUTTON} w-full`}
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.attachments.category')}</label>
                    <select
                        name="doc_category"
                        defaultValue=""
                        className={`${CONTROL_SELECT} w-full`}
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
                        className={`${CONTROL_INPUT} w-full`}
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
