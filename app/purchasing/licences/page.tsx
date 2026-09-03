// app/purchasing/licences/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// 【公司执照登记簿】—— IA-BUILD-1 / D7:它从财务搬到了采购,把关码跟着一起搬。
// ════════════════════════════════════════════════════════════════════════════
//
// ★【一处必须写下来的更正】★
// docs/information-architecture-scoping.md 的 M2 说"执照面板今天在
// module.finance.view 后面"。**那一句是错的,而这一刀之前没人核过。**
// 实测(CMPL-1 落地时就是这样):
//     company_compliance 的 RLS   select = module.suppliers.view
//                                 write  = module.suppliers.edit
//     那块面板自己的判据            can('module.suppliers.view') / .edit
// module.finance.view 把的是【它此前寄居的那一页】(/finance/company),
// 不是这块面板。
//
// ★【所以 D7 在这一条上是一次【搬家】,不是一次【改码】】★
// 码本来就是对的 —— suppliers 在新的信息架构里正是采购底下的二级。
// 真正变的是【外面那道门】:从 module.finance.view 换成 module.purchasing.view。
// 【谁因此多看见了东西】procurement:它持有 module.suppliers.view 却【没有】
// module.finance.view,所以在今天的系统里它【永远走不到】这张登记簿。
// 【谁少看见了东西】没有人 —— 今天看得见的四个角色(admin/gm/finance/auditor)
// 全都持有 module.purchasing.view。逐角色的实测表在 docs/information-architecture.md。
// Tim 的裁定(A2):"一个看不见管着他能收什么料的执照的采购角色,本来就是错的形状。"
//
// 【为什么这一页自己再查一次 suppliers 权限】本页的门是 module.purchasing.view,
// 而 company_compliance 的 RLS 是 suppliers.view —— 两者不是同一批人(cfo 就是
// 一个例子:有采购、没有供应商)。只有采购权限的人读这张表会拿到【零行】,
// 而"零行"在这套系统里已经有别的含义(还没有执照)。所以显式区分:
// **没有权限 → 说"受限";有权限而零行 → 说"还没有执照"**。
//
// ★ CONV-3:套 ListPage 外壳。suppliers.view 缺失那一支从一块手写的琥珀框
// 改走 state:'restricted'(与 CONV-0 的整页拒绝合成同一个组件)——
// 有权限那一支【恒为 ok】,「还没有执照」的空态住在 DataTable 自己的 empty,
// 不住在 ListPage 的 empty 分支(那会把「新增执照」按钮一起藏掉)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { mustRows } from '@/lib/db-helpers'
import { ListPage } from '@/app/components/ui/list-page'
import LicencePanel, { type LicenceRow, type CertType } from './LicencePanel'

export default async function CompanyLicencesPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.purchasing)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const canSeeLicences = await can('module.suppliers.view')
    const canEditLicences = await can('module.suppliers.edit')

    if (!canSeeLicences) {
        return (
            <ListPage
                title={t('company.licence.title')}
                maxWidth="max-w-2xl"
                state={{ kind: 'restricted', title: t('company.licence.title'), statement: t('company.licence.restricted') }}
            />
        )
    }

    const licences = mustRows(
        await supabase.from('company_compliance')
            .select('id, cert_type_code, cert_no, issuing_body, status, issue_date, valid_from, valid_until, approved_storage_limit_tonnes, scope, notes')
            .is('deleted_at', null)
            .order('valid_until', { ascending: true, nullsFirst: false }),
        'company_compliance') as LicenceRow[]
    const certTypes = mustRows(
        await supabase.from('certificate_types')
            .select('code, name_en, name_zh').order('sort_order'),
        'certificate_types') as CertType[]

    return (
        <ListPage title={t('company.licence.title')} state={{ kind: 'ok' }}>
            <LicencePanel rows={licences} certTypes={certTypes} canEdit={canEditLicences} />
        </ListPage>
    )
}
