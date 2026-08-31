// app/purchasing/payment-terms/[id]/edit/page.tsx
// 模板编辑:头 + 行读出来喂给共用表单;行序即期次。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../../Subnav'
import TemplateForm from '../../TemplateForm'
import type { TemplateLineInput } from '../../actions'
import { maskedRows } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { loadPaymentTriggerEvents } from '@/lib/paymentTriggers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function EditTemplatePage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.purchasing)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const [tplRes, lineRes] = await Promise.all([
        supabase
            .from('payment_term_templates')
            .select('id, name, description, is_active, currency')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('payment_term_template_lines_masked')
            .select('label, percentage, fixed_amount_ccy, trigger_event, days_offset')
            .eq('template_id', id)
            .order('seq'),
    ])

    if (tplRes.error || !tplRes.data) {
        notFound()
    }
    // FIN-29:币种是数据,不是写死的清单
    const currencies = mustRows(await supabase.from('currencies').select('code').order('code'))
    // EQP-PAY-1:里程碑清单来自字典,不再是表单里的一个常量数组。
    const triggerEvents = await loadPaymentTriggerEvents(supabase)

    // 遮蔽的是 fixed_amount_ccy;label/trigger_event 等恢复基表类型。
    const lines: TemplateLineInput[] = maskedRows<Tables<'payment_term_template_lines'>, 'fixed_amount_ccy'>(mustRows(lineRes)).map((l) => ({
        label: l.label,
        mode: l.percentage !== null ? ('percentage' as const) : ('fixed' as const),
        percentage: l.percentage !== null ? String(l.percentage) : '',
        fixed_amount: l.fixed_amount_ccy !== null ? String(l.fixed_amount_ccy) : '',
        trigger_event: l.trigger_event,
        days_offset: l.days_offset !== null ? String(l.days_offset) : '',
    }))

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/purchasing/payment-terms" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">
                {t('purchasing.templatesTitle')}
                <span className="ml-3 text-base text-gray-500">{tplRes.data.name}</span>
            </h1>
            <Subnav />
            <TemplateForm template={{ ...tplRes.data, lines }} currencies={currencies} triggerEvents={triggerEvents} />
        </div>
    )
}
