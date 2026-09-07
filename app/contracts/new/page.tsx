// MANUAL-FIX-2:新建合同(服务端壳)。结构取自 app/suppliers/new/page.tsx。
//
// ★【本页的门是【查看】级,写入的门由策略回答 —— Tim 的裁定 T4】★
//   /contracts 由 module.suppliers.view 把着,而 INSERT 策略要的是归属那一侧的
//   edit(买方要 suppliers.edit,卖方要 customers.edit)。**哪一个,要等对手方
//   选完才知道**,所以这里不预判:挡住一个持客户编辑权的人,与把一个只有查看权
//   的人领进必被拒的表单,两者都比让策略作答更坏。被拒时那句话是人话,
//   不是 42501(见 app/contracts/contractErrorCodes.ts)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import NewContractForm, { type PartyOption } from './NewContractForm'

export default async function NewContractPage() {
    // 进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    // ★★【先问权限,再决定要不要查 —— 而不是查了拿零行】★★
    //   客户表由 module.customers.view 把门。没有那个码的人直接查会拿到
    //   【零行】,而零行与"一个客户都还没建"在屏幕上长得一模一样。
    //   这正是本仓库反复付账的 OPS-14(跨模块的行会无声消失),
    //   所以这两个布尔量【要传到表单里去】,由它画出一句具名的缺席。
    const [canSeeSuppliers, canSeeCustomers] = await Promise.all([
        can('module.suppliers.view'),
        can('module.customers.view'),
    ])

    const [supRes, custRes, ccyRes] = await Promise.all([
        canSeeSuppliers
            ? supabase.from('suppliers').select('id, code, legal_name')
                  .is('deleted_at', null).order('legal_name')
            : Promise.resolve({ data: [] as { id: string; code: string; legal_name: string }[], error: null }),
        canSeeCustomers
            ? supabase.from('customers').select('id, code, legal_name')
                  .is('deleted_at', null).order('legal_name')
            : Promise.resolve({ data: [] as { id: string; code: string; legal_name: string }[], error: null }),
        supabase.from('currencies').select('code').order('code'),
    ])

    const toOption = (r: { id: string; code: string; legal_name: string }): PartyOption => ({
        id: r.id,
        label: `${r.code} — ${r.legal_name}`,
    })
    const suppliers = (mustRows(supRes) as { id: string; code: string; legal_name: string }[]).map(toOption)
    const customers = (mustRows(custRes) as { id: string; code: string; legal_name: string }[]).map(toOption)
    const currencies = (mustRows(ccyRes) as { code: string }[]).map((c) => c.code)

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link href="/contracts" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('contracts.newTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6 max-w-2xl">{t('contracts.newIntro')}</p>

            <NewContractForm
                suppliers={suppliers}
                customers={customers}
                canSeeSuppliers={canSeeSuppliers}
                canSeeCustomers={canSeeCustomers}
                currencies={currencies}
            />
        </div>
    )
}
