'use client'

// 财务凭据附件面板(AR 单据 / AP 单据 / 收付款单共用),端口自
// app/suppliers/[id]/edit/AttachmentsPanel.tsx 的架构:
// 上传:浏览器端直传 Storage(@/lib/supabase/client),成功后再调 recordFinanceAttachment 写元数据。
// 下载:点文件名时现取一个签名 URL 再打开(私有桶)。删除:软删元数据行。
// 列表 append-only,最新在前 —— 同一单据可多次上传,上传时间(created_at_display)始终可见。
import { useRef, useState, useTransition } from 'react'
import { createClient } from '@/lib/supabase/client'
import {
    recordFinanceAttachment,
    getFinanceAttachmentDownloadUrl,
    deleteFinanceAttachment,
} from './financeAttachmentActions'
import { useTranslations } from '@/lib/i18n/client'
import {
    FINANCE_ATTACHMENT_ACCEPT,
    FINANCE_DOC_TYPES,
    isAllowedFinanceAttachmentType,
    type FinanceAttachmentParent,
    type FinanceAttachmentRow,
} from './financeAttachmentTypes'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'

const BUCKET = 'finance-attachments'

// 客户端大小上限(前置拦一道,给出友好提示)。
const MAX_FILE_SIZE = 50 * 1024 * 1024

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

export default function FinanceAttachmentsPanel({
    parent,
    rows,
}: {
    parent: FinanceAttachmentParent
    rows: FinanceAttachmentRow[]
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()
    const [formKey, setFormKey] = useState(0)
    const fileRef = useRef<HTMLInputElement>(null)

    // 已知类型显示翻译标签;遇到未知/历史值则原样显示,避免显示成 key 路径。
    function docTypeLabel(value: string | null): string {
        if (!value) return '—'
        return (FINANCE_DOC_TYPES as readonly string[]).includes(value)
            ? t('finAttach.docTypes.' + value)
            : value
    }

    async function handleUpload(formData: FormData) {
        const file = fileRef.current?.files?.[0]
        if (!file) return
        if (file.size > MAX_FILE_SIZE) {
            setError(t('finAttach.errTooLarge'))
            return
        }
        if (!isAllowedFinanceAttachmentType(file.type)) {
            setError(t('finAttach.errType'))
            return
        }

        const docType = (formData.get('doc_type') as string)?.trim() || 'other'
        const notes = (formData.get('notes') as string)?.trim() || null

        setError(null)
        startTransition(async () => {
            const supabase = createClient()
            const path = `${parent.id}/${crypto.randomUUID()}-${sanitizeFilename(file.name)}`

            // 1) 文件本体直传 Storage
            const { error: uploadErr } = await supabase.storage
                .from(BUCKET)
                .upload(path, file, {
                    contentType: file.type || undefined,
                    upsert: false,
                })
            if (uploadErr) {
                setError(t('finAttach.uploadError', { message: uploadErr.message }))
                return
            }

            // 2) 元数据落库(原始文件名存这里用于展示)
            const result = await recordFinanceAttachment({
                parent,
                filePath: path,
                fileName: file.name,
                mimeType: file.type || null,
                fileSize: file.size,
                docType,
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

    // 点文件名 = 现取签名 URL 下载(私有桶)
    function handleDownload(row: FinanceAttachmentRow) {
        startTransition(async () => {
            const result = await getFinanceAttachmentDownloadUrl(row.file_path, row.file_name)
            if (result?.error) {
                setError(result.error)
                return
            }
            setError(null)
            if (result.url) window.open(result.url, '_blank', 'noopener,noreferrer')
        })
    }

    function handleDelete(id: string) {
        if (!window.confirm(t('finAttach.deleteConfirm'))) return
        startTransition(async () => {
            const result = await deleteFinanceAttachment(id, parent)
            if (result?.error) {
                setError(result.error)
            } else {
                setError(null)
            }
        })
    }

    // ════════════════════════════════════════════════════════════════════════
    // ★ CONV-9(2026-09-04):这张表转成 DataTable
    // ════════════════════════════════════════════════════════════════════════
    // 【为什么它是这一刀的事】它是【四张详情页共用的一张表】
    // (/finance/payments/[id] · /finance/payables/[batchId] ·
    //  /finance/receivables/[saleId] · /finance/expenses/[id]),
    // 而 CONV-9 转完那四页之后重测,**/finance/receivables/[saleId] 仍然
    // 溢出 +99px、并且有一张表被裁**,探针点名的元凶正是下面那枚
    // `button.text-red-600` —— 也就是【这个面板】,不是那四页各自的表。
    // CONV-8 §⑥ 把这一页记成「元凶不是表」是对的;而它没说的是:
    // **元凶住在一个共用组件里,所以修一次就修好四页。**
    //
    // 【为什么仍然是 DataTable,不是 EditableTable】两枚按钮(下载 / 删除)
    // 各自【自带状态机】(isPending 由这个面板自己管),表的其余部分彻底只读。
    // 这正是 Tim 在 CONV-8 Q3 的裁定:判据是【谁拥有那个状态】,
    // 不是【格子里有没有出现一个 <button>】。
    //
    // ★【手机上留【文件名】与【单据种类】】★
    // 一份凭据列表被打开的问题是「这张单据的凭据在不在、是哪一种」。
    // 大小 / 上传时间 / 备注 / 删除进展开区 —— 它们是选中某一份之后的第二个问题。
    const attachmentColumns: Column<FinanceAttachmentRow>[] = [
        {
            key: 'file',
            header: t('finAttach.file'),
            // 身份列 —— 一份凭据的主语是它的文件名(而它同时是下载入口)。
            priority: true,
            className: 'break-all',
            render: (row) => (
                <button
                    type="button"
                    onClick={() => handleDownload(row)}
                    disabled={isPending}
                    className="text-blue-600 text-sm hover:underline disabled:text-gray-400 text-left break-all"
                >
                    {row.file_name}
                </button>
            ),
        },
        {
            key: 'docType',
            header: t('finAttach.docType'),
            // ★ 这张表存在的理由:这是发票、收据,还是别的什么。
            priority: true,
            className: 'text-sm',
            render: (row) => docTypeLabel(row.doc_type),
        },
        { key: 'size', header: t('finAttach.size'), className: 'text-sm', render: (row) => formatBytes(row.file_size) },
        {
            key: 'uploadedAt',
            header: t('finAttach.uploadedAt'),
            className: 'text-sm text-gray-600',
            render: (row) => row.created_at_display,
        },
        {
            key: 'notes',
            header: t('finAttach.notes'),
            className: 'text-sm text-gray-600',
            render: (row) => row.notes ?? '—',
        },
        {
            // 转换前这一列的表头就是空的(<th … />),保持原样。
            key: 'delete',
            header: '',
            className: 'whitespace-nowrap',
            render: (row) => (
                <button
                    type="button"
                    onClick={() => handleDelete(row.id)}
                    disabled={isPending}
                    className="text-red-600 text-sm hover:underline disabled:text-gray-400"
                >
                    {t('common.delete')}
                </button>
            ),
        },
    ]

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">{t('finAttach.title')}</h2>

            {error && <p className="text-red-600 text-sm mb-3">{error}</p>}

            {/* ★ 空态由表自己说(DataTable 的 empty)—— CONV-8 §⑤ 的推论。 */}
            <div className="mb-6">
                <DataTable
                    rows={rows}
                    columns={attachmentColumns}
                    rowKey={(r) => r.id}
                    phone={{ mode: 'columns' }}
                    empty={t('finAttach.empty')}
                />
            </div>

            <form key={formKey} action={handleUpload} className="flex flex-wrap items-end gap-3">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('finAttach.file')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        ref={fileRef}
                        type="file"
                        name="file"
                        required
                        accept={FINANCE_ATTACHMENT_ACCEPT}
                        className="text-sm file:mr-3 file:rounded file:border-0 file:bg-blue-600 file:px-4 file:py-2 file:text-white hover:file:bg-blue-700"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('finAttach.docType')}</label>
                    <select
                        name="doc_type"
                        defaultValue="other"
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        {FINANCE_DOC_TYPES.map((c) => (
                            <option key={c} value={c}>
                                {t('finAttach.docTypes.' + c)}
                            </option>
                        ))}
                    </select>
                </div>

                <div className="grow">
                    <label className="block text-sm font-medium mb-1">{t('finAttach.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <Button
                    type="submit"
                    disabled={isPending}
                >
                    {isPending ? t('finAttach.uploading') : t('finAttach.upload')}
                </Button>
            </form>
        </section>
    )
}
