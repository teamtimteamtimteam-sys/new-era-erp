import Link from 'next/link'
import { formatTimestamp } from '@/lib/format'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import EditSupplierForm from './EditSupplierForm'
import StatusPanel from './StatusPanel'
import CompliancePanel from './CompliancePanel'
import AttachmentsPanel from './AttachmentsPanel'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function EditSupplierPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied

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
        // 上面那句注释警告的正是这个失败模式,但它只挡住了"已停用",没挡住【查询失败】:
        // 读不到当前模板 → 选项里没有它 → 下拉回落到空的"无" → 一保存就静默清掉。
        const curRes = await supabase
            .from('payment_term_templates')
            .select('id, name')
            .eq('id', currentTplId)
            .single()
        const cur = mustOne(curRes, 'payment_term_templates current')
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
        created_at_display: formatTimestamp(a.created_at, dateLocale),
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