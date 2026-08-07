// app/purchasing/payment-terms/new/page.tsx
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import Subnav from '../../Subnav'
import TemplateForm from '../TemplateForm'

export default async function NewTemplatePage() {
    const t = await getTranslations()
    // FIN-29:币种是【数据】(currencies 表),不是写死的清单
    const supabase = await createClient()
    const currencies = mustRows(await supabase.from('currencies').select('code').order('code'))
    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/purchasing/payment-terms" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">{t('purchasing.newTemplate')}</h1>
            <Subnav />
            <TemplateForm currencies={currencies} />
        </div>
    )
}
