import Link from 'next/link'
import { mustRows } from '@/lib/db-helpers'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import ClaimForm, { type EmpOpt } from '../ClaimForm'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewClaimPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

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
