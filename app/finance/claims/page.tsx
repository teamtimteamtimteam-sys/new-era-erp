// app/finance/claims/page.tsx
// CLAIM-1:审批那一半 —— 决定的人站的地方。
//
// 【两个听众,两张屏】提报的人在 /me(那里本来就有自助面板),
// 审批的人在这里。把提报人赶进财务模块去要回自己垫的钱,不合适;
// 而一个决定队列埋在别人的页面上,是一个没人会去看的队列。
//
// ★★ CONV-3(Kind D,转换【它自己】,不为它另设模板)★★
// 上半是决定队列(卡片,不是表格),下半是已决登记簿(CONV-1 已经换成
// DataTable)。这一页只做一件事:套上 ListPage 外壳,让拒绝态与三张
// 邻居页面(claims 自己下半、payroll-payments、processing-costs)共用同一个
// 组件。**不为决定队列造一个新的可复用形状** —— 它是这个仓库里唯一一张
// 决定队列,CONV-2 §① 已经拒绝过"一个例子就设计模板"。
//
// 【为什么恒为 ok,不是 empty/too-few】这一页有【两个独立的列表】,各自的
// 空态各说各的话(expenseClaims.noPending / .noneForEmployee),都住在
// ClaimDecisionPanel 内部、不受任何行数门槛管 —— 与 CONV-2 §⑧ 第 3 条
// 撞见的缺陷同形:让 ListPage 的 empty 分支替其中一半说话,会把另一半
// 一起藏起来。两个独立空态只能由各自的容器自己说。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import ClaimDecisionPanel, { type ClaimRow } from './ClaimDecisionPanel'

export default async function ClaimsPage() {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const t = await getTranslations()
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const canDecide = await can('module.finance.edit')

    const rows = mustRows(
        await supabase
            .from('expense_claim_status')
            .select('*')
            .order('spend_date', { ascending: false })
    ) as unknown as ClaimRow[]

    const accounts = mustRows(
        await supabase.from('accounts')
            .select('code, name_en, account_type')
            .eq('account_type', 'expense')
            .order('code')
    ) as unknown as { code: string; name_en: string }[]

    const taxCodes = mustRows(
        await supabase.from('tax_codes').select('code, name_en, side, is_active')
    ) as unknown as { code: string; name_en: string; side: string; is_active: boolean }[]

    const pending = rows.filter((r) => r.status === 'submitted')
    const decided = rows.filter((r) => r.status !== 'submitted')

    return (
        <ListPage
            title={t('expenseClaims.title')}
            intro={t('expenseClaims.subtitle')}
            // 备用金是【被否决的】,不是还没做 —— 无条件渲染,与有没有数据无关
            // (与 CONV-1 §③ 的 notices 槽同一条理由)。
            notices={
                <p className="mb-6 text-xs text-[color:var(--brand-muted-text)]">{t('expenseClaims.pettyCashRuledOut')}</p>
            }
            state={{ kind: 'ok' }}
        >
            <ClaimDecisionPanel
                pending={pending}
                decided={decided}
                accounts={accounts}
                taxCodes={taxCodes.filter((x) => x.is_active && x.side === 'input')}
                canDecide={canDecide}
                baseCurrency={baseCurrency}
            />
        </ListPage>
    )
}
