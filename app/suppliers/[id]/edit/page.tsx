import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditSupplierForm from './EditSupplierForm'
import StatusPanel from './StatusPanel'
import CompliancePanel from './CompliancePanel'
import AttachmentsPanel from './AttachmentsPanel'
import { getTranslations, getLocale } from '@/lib/i18n/server'

export default async function EditSupplierPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: supplier, error } = await supabase
        .from('suppliers')
        .select('*')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !supplier) {
        notFound()
    }

    const { data: complianceRows } = await supabase
        .from('supplier_compliance')
        .select('id, cert_type, cert_no, issuing_body, valid_from, valid_until, notes')
        .eq('supplier_id', id)
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    const { data: attachmentRows } = await supabase
        .from('supplier_attachments')
        .select('id, file_name, file_type, file_size, doc_category, storage_path, created_at')
        .eq('supplier_id', id)
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    // 默认付款条款模板下拉:启用的 + 该供应商当前指着的那个(即便已停用/已删,
    // 也得让它出现在选项里 —— 否则一打开编辑页就"看起来像无",一保存就静默清掉)
    const { data: templateRows } = await supabase
        .from('payment_term_templates')
        .select('id, name')
        .is('deleted_at', null)
        .eq('is_active', true)
        .order('name')
    const templates = [...(templateRows ?? [])]
    const currentTplId = supplier.default_payment_term_template_id
    if (currentTplId && !templates.some((tpl) => tpl.id === currentTplId)) {
        const { data: cur } = await supabase
            .from('payment_term_templates')
            .select('id, name')
            .eq('id', currentTplId)
            .single()
        if (cur) templates.unshift({ id: cur.id, name: `${cur.name} (${t('finance.inactive')})` })
    }

    // 在服务端按当前语言格式化时间,再传给客户端面板 —— 避免客户端 toLocaleString 引发水合不一致
    const attachments = (attachmentRows ?? []).map((a) => ({
        id: a.id,
        file_name: a.file_name,
        file_type: a.file_type,
        file_size: a.file_size,
        doc_category: a.doc_category,
        storage_path: a.storage_path,
        created_at_display: new Date(a.created_at).toLocaleString(dateLocale),
    }))

    return (
        <div className="p-8 max-w-4xl">
            <div className="mb-6">
                <Link
                    href="/suppliers"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('suppliers.editTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{supplier.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {t('suppliers.status.' + supplier.status)}
                </span>
            </p>

            <StatusPanel id={supplier.id} currentStatus={supplier.status} />
            <EditSupplierForm supplier={supplier} templates={templates} />
            <CompliancePanel supplierId={supplier.id} rows={complianceRows ?? []} />
            <AttachmentsPanel supplierId={supplier.id} rows={attachments} />
        </div>
    )
}