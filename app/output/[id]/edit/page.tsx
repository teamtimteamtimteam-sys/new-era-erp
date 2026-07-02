import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditOutputForm from './EditOutputForm'
import MetalContentPanel from '@/app/components/metals/MetalContentPanel'
import type { MetalContentRow } from '@/app/components/metals/metalContentTypes'
import { saveOutputMetal, deleteOutputMetal } from '@/app/components/metals/metalContentActions'
import { getTranslations, getLocale } from '@/lib/i18n/server'

export default async function EditOutputPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const [batchRes, materialsRes, customersRes, metalsRes] = await Promise.all([
        supabase
            .from('output_batches')
            .select('*')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('materials')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
        supabase
            .from('customers')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('output_batch_metals')
            .select('metal, content_pct, updated_at')
            .eq('output_batch_id', id)
            .order('metal'),
    ])

    if (batchRes.error || !batchRes.data) {
        notFound()
    }

    if (materialsRes.error || customersRes.error) {
        const err = materialsRes.error ?? customersRes.error
        return (
            <div className="p-8 max-w-2xl">
                <h1 className="text-2xl font-bold mb-4">{t('output.editTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('output.dropdownLoadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const batch = batchRes.data

    // 金属含量行:服务端预格式化 updated_at,避免客户端水合不一致
    const metalRows: MetalContentRow[] = (metalsRes.data ?? []).map((m) => ({
        metal: m.metal,
        content_pct: m.content_pct,
        updated_at_display: new Date(m.updated_at).toLocaleString(dateLocale),
    }))

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/output"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('output.editTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{batch.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {batch.status}
                </span>
            </p>

            <EditOutputForm
                batch={batch}
                materials={materialsRes.data ?? []}
                customers={customersRes.data ?? []}
            />

            <MetalContentPanel
                rows={metalRows}
                saveAction={saveOutputMetal.bind(null, id)}
                deleteAction={deleteOutputMetal.bind(null, id)}
            />
        </div>
    )
}
