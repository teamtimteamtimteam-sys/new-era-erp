// app/suppliers/new/page.tsx
// 新建供应商(服务端壳):取启用的付款条款模板喂给默认模板下拉,表单在客户端组件。
// (cut 4b 前这里是纯客户端页;为了服务端取数改成通行的 shell + form 结构。)
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import NewSupplierForm, { type TemplateOption } from './NewSupplierForm'

export default async function NewSupplierPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: templateRows } = await supabase
        .from('payment_term_templates')
        .select('id, name')
        .is('deleted_at', null)
        .eq('is_active', true)
        .order('name')
    const templates: TemplateOption[] = templateRows ?? []

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/suppliers"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('suppliers.newTitle')}</h1>

            <NewSupplierForm templates={templates} />
        </div>
    )
}
