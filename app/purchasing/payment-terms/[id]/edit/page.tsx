// app/purchasing/payment-terms/[id]/edit/page.tsx
// 模板编辑:头 + 行读出来喂给共用表单;行序即期次。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../../Subnav'
import TemplateForm from '../../TemplateForm'
import type { TemplateLineInput } from '../../actions'

export default async function EditTemplatePage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const [tplRes, lineRes] = await Promise.all([
        supabase
            .from('payment_term_templates')
            .select('id, name, description, is_active')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('payment_term_template_lines')
            .select('label, percentage, fixed_amount_usd, trigger_event, days_offset')
            .eq('template_id', id)
            .order('seq'),
    ])

    if (tplRes.error || !tplRes.data) {
        notFound()
    }

    const lines: TemplateLineInput[] = (lineRes.data ?? []).map((l) => ({
        label: l.label,
        mode: l.percentage !== null ? ('percentage' as const) : ('fixed' as const),
        percentage: l.percentage !== null ? String(l.percentage) : '',
        fixed_amount: l.fixed_amount_usd !== null ? String(l.fixed_amount_usd) : '',
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
            <TemplateForm template={{ ...tplRes.data, lines }} />
        </div>
    )
}
