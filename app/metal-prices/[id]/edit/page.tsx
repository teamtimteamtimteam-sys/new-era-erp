import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditMetalPriceForm from './EditMetalPriceForm'
import DeleteButton from './DeleteButton'
import { getTranslations } from '@/lib/i18n/server'

export default async function EditMetalPricePage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: row, error } = await supabase
        .from('metal_prices')
        .select('id, metal, price_usd_per_tonne, price_date, notes')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !row) {
        notFound()
    }

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/metal-prices"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex items-start justify-between mb-6">
                <h1 className="text-2xl font-bold">{t('metalPrices.editTitle')}</h1>
                <DeleteButton id={row.id} />
            </div>

            <EditMetalPriceForm row={row} />
        </div>
    )
}
