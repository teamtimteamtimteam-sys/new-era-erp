// app/finance/claims/page.tsx
// CLAIM-1:审批那一半 —— 决定的人站的地方。
//
// 【两个听众,两张屏】提报的人在 /me(那里本来就有自助面板),
// 审批的人在这里。把提报人赶进财务模块去要回自己垫的钱,不合适;
// 而一个决定队列埋在别人的页面上,是一个没人会去看的队列。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '../Subnav'
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
        <div className="p-8">
            <Subnav />
            <h1 className="text-2xl font-bold mb-1">{t('expenseClaims.title')}</h1>
            <p className="text-sm text-gray-600 mb-1">{t('expenseClaims.subtitle')}</p>
            {/* 备用金是【被否决的】,不是还没做 —— 让读的人遇到一个决定 */}
            <p className="text-xs text-gray-400 mb-6">{t('expenseClaims.pettyCashRuledOut')}</p>

            <ClaimDecisionPanel
                pending={pending}
                decided={decided}
                accounts={accounts}
                taxCodes={taxCodes.filter((x) => x.is_active && x.side === 'input')}
                canDecide={canDecide}
                baseCurrency={baseCurrency}
            />
        </div>
    )
}
