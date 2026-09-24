// MANUAL-FIX-2:新建合同(服务端壳)。结构取自 app/suppliers/new/page.tsx。
//
// ★【本页的门是【查看】级;写入要 action.contract_terms —— ROLE-1 Batch 2b】★
//   /contracts 由 module.suppliers.view 把着(读)。此前 INSERT 策略要的是归属那一侧的
//   edit(买方要 suppliers.edit,卖方要 customers.edit),要等对手方选完才知道是哪一个,
//   所以这一页当时不预判(Tim 的 T4)。**Batch 2b 之后写合同只有一个码**(Tim,Batch 2
//   grilling Q12 · Batch 2b grilling Q1:合同条款归 cco),于是这一页【判得了】了:
//   保存钮看得见、按不动、说出码(DBLOCK-1 的 PermissionGate)。库里那道门不变 ——
//   被拒时那句话仍是人话,不是 42501(见 app/contracts/contractErrorCodes.ts)。
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
    const [canSeeSuppliers, canSeeCustomers, canWriteContracts] = await Promise.all([
        can('module.suppliers.view'),
        can('module.customers.view'),
        can('action.contract_terms'),
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
                <Link href="/contracts" className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="mb-2">{t('contracts.newTitle')}</h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-6 max-w-2xl">{t('contracts.newIntro')}</p>

            <NewContractForm
                suppliers={suppliers}
                customers={customers}
                canSeeSuppliers={canSeeSuppliers}
                canSeeCustomers={canSeeCustomers}
                canWriteContracts={canWriteContracts}
                currencies={currencies}
            />
        </div>
    )
}
