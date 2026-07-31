// app/hr/training/page.tsx
// 全员培训记录列表,按类别与到期状态筛选。到期日临近的行挂标记 ——
// 安全/合规证书过期意味着这个人暂时不能上那道工序。
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../Subnav'
import TrainingToolbar from './TrainingToolbar'
import DeleteTrainingButton from './DeleteTrainingButton'

type Row = {
    id: string
    training_name: string
    category: string | null
    completed_date: string
    expiry_date: string | null
    provider: string | null
    certificate_ref: string | null
    employees: { id: string; code: string; legal_name: string } | null
}

export default async function TrainingPage({
    searchParams,
}: {
    searchParams: Promise<{ category?: string; expiry?: string }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const category = (sp.category ?? '').trim()
    const expiry = (sp.expiry ?? '').trim()

    const now = new Date()
    const today = now.toISOString().slice(0, 10)
    const in90Date = new Date(now)
    in90Date.setDate(in90Date.getDate() + 90) // "即将到期" = 90 天内,与 hr_alerts 同档
    const in90 = in90Date.toISOString().slice(0, 10)

    interface Chain {
        eq(c: string, v: string): Chain
        lt(c: string, v: string): Chain
        gte(c: string, v: string): Chain
        lte(c: string, v: string): Chain
        is(c: string, v: null): Chain
        not(c: string, op: string, v: null): Chain
    }
    let query = supabase
        .from('training_records')
        .select('id, training_name, category, completed_date, expiry_date, provider, certificate_ref, employees(id, code, legal_name)')
        .is('deleted_at', null) as unknown as Chain
    if (category) query = query.eq('category', category)
    if (expiry === 'expired') query = query.not('expiry_date', 'is', null).lt('expiry_date', today)
    else if (expiry === 'soon') query = query.gte('expiry_date', today).lte('expiry_date', in90)
    else if (expiry === 'none') query = query.is('expiry_date', null)

    const { data } = await (query as unknown as {
        order(c: string, o: { ascending: boolean }): Promise<{ data: Row[] | null }>
    }).order('completed_date', { ascending: false })

    const rows = (data as unknown as Row[] | null) ?? []

    return (
        <div className="p-8">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">{t('hr.trainingTitle')}</h1>
                <Link
                    href="/hr/training/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('hr.newTraining')}
                </Link>
            </div>

            <Subnav />

            <Suspense fallback={<div className="mb-4 h-10" />}>
                <TrainingToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">{t('finance.recordCount', { count: rows.length })}</p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colEmployee')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colTrainingName')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colCategory')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colCompletedDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colExpiryDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colProvider')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colCertificateRef')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('metalPrices.colActions')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => {
                        const expired = r.expiry_date !== null && r.expiry_date < today
                        const soon = r.expiry_date !== null && !expired && r.expiry_date <= in90
                        return (
                            <tr key={r.id}>
                                <td className="border border-gray-300 px-4 py-2 text-sm">
                                    {r.employees ? (
                                        <Link
                                            href={`/hr/employees/${r.employees.id}`}
                                            className="text-blue-600 hover:underline"
                                        >
                                            <span className="font-mono text-xs text-gray-500 mr-2">
                                                {r.employees.code}
                                            </span>
                                            {r.employees.legal_name}
                                        </Link>
                                    ) : (
                                        '—'
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{r.training_name}</td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">
                                    {r.category ? t('hr.trainingCategory.' + r.category) : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">{r.completed_date}</td>
                                <td className="border border-gray-300 px-4 py-2 text-sm whitespace-nowrap">
                                    {r.expiry_date ?? '—'}
                                    {expired && (
                                        <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-red-100 text-red-800">
                                            {t('hr.severity.expired')}
                                        </span>
                                    )}
                                    {soon && (
                                        <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800">
                                            {t('hr.expiringSoon')}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">{r.provider ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2 text-sm font-mono">
                                    {r.certificate_ref ?? '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm whitespace-nowrap">
                                    <Link
                                        href={`/hr/training/${r.id}/edit`}
                                        className="text-blue-600 hover:underline mr-3"
                                    >
                                        {t('purchasing.editLink')}
                                    </Link>
                                    <DeleteTrainingButton id={r.id} name={r.training_name} />
                                </td>
                            </tr>
                        )
                    })}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={8} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('hr.trainingEmpty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
