// app/finance/company/page.tsx
// 公司抬头设置(服务端壳):取那唯一一行,logo 用 60s 签名 URL 做预览(私有桶)。
// PDF 生成走的是另一条路 —— 在服务端下载字节内嵌,不依赖签名 URL。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../Subnav'
import CompanyProfileForm, { type CompanyProfileRow } from './CompanyProfileForm'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { mustRows } from '@/lib/db-helpers'
import LicencePanel, { type LicenceRow, type CertType } from './LicencePanel'

export default async function CompanyPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const { data, error } = await supabase.from('company_profile_masked').select('*').limit(1).single()

    if (error || !data) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('company.title')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const profile = data as CompanyProfileRow

    let logoUrl: string | null = null
    if (profile.logo_path) {
        const { data: signed } = await supabase.storage
            .from('company-assets')
            .createSignedUrl(profile.logo_path, 60)
        logoUrl = signed?.signedUrl ?? null
    }

    // CMPL-1:公司自家执照。
    // 【为什么这一段自己再查一次权限】本页的门是 module.finance.view,而
    // company_compliance 的 RLS 是 module.suppliers.view/edit(CMP-1 定的,理由在
    // docs/compliance-scoping.md §C)。两者不是同一批人 —— 只有财务权限的人
    // 读这张表会拿到【零行】,而"零行"在这套系统里已经有别的含义(还没有执照)。
    // 所以这里显式区分:**没有权限 → 说"受限";有权限而零行 → 说"还没有执照"**。
    // 这正是 lib/permissions.ts 存在的理由(null 与"不给看"必须分得开)。
    const canSeeLicences = await can('module.suppliers.view')
    const canEditLicences = await can('module.suppliers.edit')
    let licences: LicenceRow[] = []
    let certTypes: CertType[] = []
    if (canSeeLicences) {
        licences = mustRows(
            await supabase.from('company_compliance')
                .select('id, cert_type_code, cert_no, issuing_body, status, issue_date, valid_from, valid_until, approved_storage_limit_tonnes, scope, notes')
                .is('deleted_at', null)
                .order('valid_until', { ascending: true, nullsFirst: false }),
            'company_compliance') as LicenceRow[]
        certTypes = mustRows(
            await supabase.from('certificate_types')
                .select('code, name_en, name_zh').order('sort_order'),
            'certificate_types') as CertType[]
    }

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('company.title')}</h1>
            <Subnav />
            <CompanyProfileForm profile={profile} logoUrl={logoUrl} />
            {canSeeLicences ? (
                <LicencePanel rows={licences} certTypes={certTypes} canEdit={canEditLicences} />
            ) : (
                <div className="border border-gray-200 rounded p-4 mb-6">
                    <h2 className="font-semibold mb-1">{t('company.licence.title')}</h2>
                    <p className="text-sm text-gray-600">{t('company.licence.restricted')}</p>
                </div>
            )}
        </div>
    )
}
