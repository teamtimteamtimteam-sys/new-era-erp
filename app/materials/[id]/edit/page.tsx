import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditMaterialForm from './EditMaterialForm'
import { getTranslations } from '@/lib/i18n/server'

export default async function EditMaterialPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: material, error } = await supabase
        .from('materials')
        .select('*')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !material) {
        notFound()
    }

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/materials"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('materials.editTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{material.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {material.status}
                </span>
            </p>

            <EditMaterialForm material={material} />
        </div>
    )
}
