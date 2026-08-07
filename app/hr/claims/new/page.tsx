import Link from 'next/link'
import { mustRows } from '@/lib/db-helpers'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import ClaimForm, { type EmpOpt } from '../ClaimForm'

export default async function NewClaimPage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const res = await supabase.from('employees').select('id, code, legal_name')
        .is('deleted_at', null).neq('employment_status', 'separated').order('code')
    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />
            <div className="mb-4"><Link href="/hr/claims" className="text-blue-600 hover:underline text-sm">{t('common.back')}</Link></div>
            <h2 className="text-xl font-bold mb-4">{t('claims.record')}</h2>
            <ClaimForm employees={mustRows(res) as EmpOpt[]} redirectTo="/hr/claims" />
        </div>
    )
}
