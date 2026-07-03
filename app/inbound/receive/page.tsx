// app/inbound/receive/page.tsx
// 移动端现场收货页(服务端抓下拉数据,渲染客户端表单)。可在任意设备用 URL 直达。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import ReceiveForm from './ReceiveForm'
import { getTranslations } from '@/lib/i18n/server'

export default async function ReceivePage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const [suppliersRes, materialsRes] = await Promise.all([
        supabase
            .from('suppliers')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('materials')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
    ])

    return (
        <div className="p-4 max-w-md mx-auto">
            <div className="mb-4">
                <Link href="/inbound" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('receive.title')}</h1>

            <ReceiveForm
                suppliers={suppliersRes.data ?? []}
                materials={materialsRes.data ?? []}
            />
        </div>
    )
}
