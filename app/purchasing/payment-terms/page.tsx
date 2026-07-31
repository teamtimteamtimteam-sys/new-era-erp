// app/purchasing/payment-terms/page.tsx
// 付款条款模板列表:名称、说明、各期摘要(紧凑一行)、启用状态、编辑入口。
// 模板只为省去回头客的重复录入 —— 不是标准条款,系统也不预置任何模板。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatUsd } from '@/lib/format'
import Subnav from '../Subnav'
import DeleteTemplateButton from './DeleteTemplateButton'

type TemplateLine = {
    template_id: string
    seq: number
    label: string
    percentage: number | null
    fixed_amount_usd: number | null
    trigger_event: string
    days_offset: number | null
}

export default async function PaymentTermTemplatesPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const [tplRes, lineRes] = await Promise.all([
        supabase
            .from('payment_term_templates')
            .select('id, name, description, is_active')
            .is('deleted_at', null)
            .order('name'),
        supabase
            .from('payment_term_template_lines')
            .select('template_id, seq, label, percentage, fixed_amount_usd, trigger_event, days_offset')
            .order('seq'),
    ])

    const templates = tplRes.data ?? []
    const linesByTpl = new Map<string, TemplateLine[]>()
    for (const l of (lineRes.data as TemplateLine[] | null) ?? []) {
        const arr = linesByTpl.get(l.template_id) ?? []
        arr.push(l)
        linesByTpl.set(l.template_id, arr)
    }

    // 各期摘要:"60% 下单时 · 30% 到货时 · 10% 化验后"(定额期显示金额)
    const summary = (tplId: string) =>
        (linesByTpl.get(tplId) ?? [])
            .map((l) => {
                const share =
                    l.percentage !== null ? `${l.percentage}%` : `${formatUsd(l.fixed_amount_usd)} USD`
                const trigger = t('purchasing.trigger.' + l.trigger_event)
                const offset =
                    l.trigger_event === 'fixed_date' && l.days_offset !== null
                        ? ` +${l.days_offset}d`
                        : ''
                return `${share} ${trigger}${offset}`
            })
            .join(' · ')

    return (
        <div className="p-8 max-w-5xl">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">{t('purchasing.templatesTitle')}</h1>
                <Link
                    href="/purchasing/payment-terms/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('purchasing.newTemplate')}
                </Link>
            </div>

            <Subnav />

            <p className="text-sm text-gray-600 mb-4">
                {t('finance.recordCount', { count: templates.length })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('purchasing.colName')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('purchasing.colDescription')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('purchasing.form.paymentTerms')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('purchasing.colStatus')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('metalPrices.colActions')}</th>
                    </tr>
                </thead>
                <tbody>
                    {templates.map((tpl) => (
                        <tr key={tpl.id}>
                            <td className="border border-gray-300 px-4 py-2 font-medium">{tpl.name}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {tpl.description ?? '—'}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">{summary(tpl.id) || '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span
                                    className={
                                        'px-2 py-1 rounded text-xs ' +
                                        (tpl.is_active
                                            ? 'bg-green-100 text-green-800'
                                            : 'bg-gray-200 text-gray-600')
                                    }
                                >
                                    {tpl.is_active ? t('pricing.form.active') : t('finance.inactive')}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm whitespace-nowrap">
                                <Link
                                    href={`/purchasing/payment-terms/${tpl.id}/edit`}
                                    className="text-blue-600 hover:underline mr-3"
                                >
                                    {t('purchasing.editLink')}
                                </Link>
                                <DeleteTemplateButton templateId={tpl.id} name={tpl.name} />
                            </td>
                        </tr>
                    ))}
                    {templates.length === 0 && (
                        <tr>
                            <td colSpan={5} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('purchasing.templatesEmpty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
