// app/hr/employees/new/page.tsx
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import EmployeeForm, { type PickOption } from '../EmployeeForm'
import { mustRows } from '@/lib/db-helpers'

export default async function NewEmployeePage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const [deptRes, empRes] = await Promise.all([
        supabase.from('departments').select('id, code, name_en, name_zh').is('deleted_at', null).eq('is_active', true).order('code'),
        supabase
            .from('employees')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .neq('employment_status', 'separated')
            .order('code'),
    ])

    const departments: PickOption[] = (mustRows(deptRes)).map((d) => ({
        id: d.id,
        label: `${d.code} — ${locale === 'zh' ? d.name_zh : d.name_en}`,
    }))
    // 新建时还没有"自己",在职的人都可以是上级
    const managers: PickOption[] = (mustRows(empRes)).map((e) => ({
        id: e.id,
        label: `${e.code} — ${e.legal_name}`,
    }))

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/hr/employees" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">{t('hr.newEmployee')}</h1>
            <Subnav />
            <EmployeeForm departments={departments} managers={managers} />
        </div>
    )
}
