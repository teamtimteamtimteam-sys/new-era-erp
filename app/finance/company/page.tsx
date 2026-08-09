// app/finance/company/page.tsx
// 公司抬头设置(服务端壳):取那唯一一行,logo 用 60s 签名 URL 做预览(私有桶)。
// PDF 生成走的是另一条路 —— 在服务端下载字节内嵌,不依赖签名 URL。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../Subnav'
import CompanyProfileForm, { type CompanyProfileRow } from './CompanyProfileForm'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

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

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('company.title')}</h1>
            <Subnav />
            <CompanyProfileForm profile={profile} logoUrl={logoUrl} />
        </div>
    )
}
