// app/finance/company/page.tsx
// 公司抬头设置(服务端壳):取那唯一一行,logo 用 60s 签名 URL 做预览(私有桶)。
// PDF 生成走的是另一条路 —— 在服务端下载字节内嵌,不依赖签名 URL。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import CompanyProfileForm, { type CompanyProfileRow } from './CompanyProfileForm'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD, FN } from '@/lib/modules'
import { getFunctionAccess } from '@/lib/moduleAccess'

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

    // ★ IA-BUILD-1 / D7:【公司自家执照搬到采购去了】★
    // 这一页从此只管公司抬头。执照登记簿在 /purchasing/licences ——
    // 它的把关码本来就是 module.suppliers.view(不是 finance.view,勘察 M2 那一句
    // 是错的),而 suppliers 在新的信息架构里正是采购底下的二级。
    //
    // 【留一条交叉引用,而不是让它凭空消失】来这一页找执照的人得知道它去哪了。
    // 【地址从注册表取,不写死】—— 与 /margin 那条上下文交叉引用同一个做法:
    // 措辞是这一处的话,所以标签不从注册表取;但地址是 FN.licences.href,
    // 于是搬第二次的时候这里不会指向一个 404。
    const licenceAccess = (await getFunctionAccess('purchasing'))
        .find((f) => f.fn.href === FN.licences.href)

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('company.title')}</h1>
            <CompanyProfileForm profile={profile} logoUrl={logoUrl} />
            {/* D7:执照登记簿的新家。进不去的人【照样看得见它在哪】,
                画成一条具名的限制 —— 与顶栏同一套词(D5)。 */}
            <div className="border border-gray-200 rounded p-4 mb-6 bg-white">
                <h2 className="font-semibold mb-1">{t('company.licence.title')}</h2>
                {licenceAccess?.allowed ? (
                    <Link href={FN.licences.href} className="text-sm text-blue-700 hover:underline">
                        {t('company.licence.movedToPurchasing')}
                    </Link>
                ) : (
                    <p data-module-restricted="1" title={t('dashboard.restrictedHint')} className="text-sm text-gray-600">
                        {t('company.licence.movedToPurchasing')} · {t('common.restricted')}
                    </p>
                )}
            </div>
        </div>
    )
}
