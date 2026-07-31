// app/purchasing/payment-terms/new/page.tsx
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import TemplateForm from '../TemplateForm'

export default async function NewTemplatePage() {
    const t = await getTranslations()
    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/purchasing/payment-terms" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">{t('purchasing.newTemplate')}</h1>
            <Subnav />
            <TemplateForm />
        </div>
    )
}
