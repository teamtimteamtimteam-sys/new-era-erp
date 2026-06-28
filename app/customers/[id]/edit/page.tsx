import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditCustomerForm from './EditCustomerForm'
import AttachmentsPanel from './AttachmentsPanel'
import { getTranslations, getLocale } from '@/lib/i18n/server'

export default async function EditCustomerPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: customer, error } = await supabase
        .from('customers')
        .select('*')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !customer) {
        notFound()
    }

    const { data: attachmentRows } = await supabase
        .from('customer_attachments')
        .select('id, file_name, file_type, file_size, doc_category, storage_path, created_at')
        .eq('customer_id', id)
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

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
                    href="/customers"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('customers.editTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{customer.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {customer.status}
                </span>
            </p>

            <EditCustomerForm customer={customer} />
            <AttachmentsPanel customerId={customer.id} rows={attachments} />
        </div>
    )
}
