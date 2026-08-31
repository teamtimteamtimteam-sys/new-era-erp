// app/purchasing/payment-terms/new/page.tsx
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { loadPaymentTriggerEvents } from '@/lib/paymentTriggers'
import Subnav from '../../Subnav'
import TemplateForm from '../TemplateForm'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewTemplatePage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.purchasing)
    if (denied) return denied

    const t = await getTranslations()
    // FIN-29:币种是【数据】(currencies 表),不是写死的清单
    const supabase = await createClient()
    const currencies = mustRows(await supabase.from('currencies').select('code').order('code'))
    // EQP-PAY-1:里程碑清单来自字典,不再是表单里的一个常量数组。
    const triggerEvents = await loadPaymentTriggerEvents(supabase)
    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/purchasing/payment-terms" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">{t('purchasing.newTemplate')}</h1>
            <Subnav />
            <TemplateForm currencies={currencies} triggerEvents={triggerEvents} />
        </div>
    )
}
