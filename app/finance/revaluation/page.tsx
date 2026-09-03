// 期末重估(FIN-7 C4;FIN-9 起口径统一):预览【不再自己算】——
// 直接问 preview_revalue_foreign_balances,过账走 revalue_foreign_balances,
// 两者共用同一份算术。
//
// 【为什么不能在这里用 TypeScript 再算一遍】本页原先自己聚合、自己并入既往重估行、
// 自己算调整额。那份实现已经和数据库那份漂开了(既往重估行的归集口径不同),
// 而且屏幕上的数字会被人当成"过账会发生什么"的承诺 —— 它却算错。
// 同样的病之前出现过两次:验配影响预览(Phase 4 cut 5b)、GrantRunner 的假期公式
// (HR-2c 已删)。修法一样:删掉重复实现,只留数据库那一份。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne } from '@/lib/db-helpers'
import RevalueButton from './RevalueButton'
import { getBaseCurrency } from '@/lib/currency'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import RevaluationPreviewTable, { type RevaluationRow } from './RevaluationPreviewTable'

type PreviewRow = {
    account: string
    currency: string
    native: number
    carry_base: number
    rate: number | null
    rate_as_of: string | null
    target_base: number | null
    adjustment: number | null
}
type Preview = {
    period_end: string
    rows: PreviewRow[]
    total_adjustment: number
    missing_rates: string[]
}

export default async function RevaluationPage({ searchParams }: { searchParams: Promise<{ date?: string }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const d = sp.date ?? new Date().toISOString().slice(0, 10)
    const supabase = await createClient()
    const t = await getTranslations()
    // 行标签写的是【外币】(科目 · 币种),而承载额/调整额/合计是本位币 ——
    // 后三者不能借行标签那句话,必须自己带币种(CCY-1 RULE 3)
    const baseCurrency = await getBaseCurrency()

    // 读不出来就报错,不许把失败画成"没有要重估的东西"——
    // 这一页的数字会被过账进总账,不是只错在屏幕上。
    const preview = mustOne(
        await supabase.rpc('preview_revalue_foreign_balances', { p_period_end: d }),
        'preview_revalue_foreign_balances'
    ) as unknown as Preview | null

    const rows = preview?.rows ?? []
    const missing = preview?.missing_rates ?? []
    const total = preview?.total_adjustment ?? 0
    // 有要重估的行、且每个币种都有当日中间价,才谈得上过账
    const canPost = rows.length > 0 && missing.length === 0

    const previewRows: RevaluationRow[] = [
        ...rows.map((p) => ({
            key: p.account + p.currency,
            account: p.account,
            currency: p.currency,
            native: p.native,
            carryBase: p.carry_base,
            rate: p.rate,
            rateAsOf: p.rate_as_of,
            periodEnd: d,
            adjustment: p.adjustment,
            baseCurrency,
        })),
        ...(rows.length > 0
            ? [{
                key: '__total__', account: null, currency: null, native: null, carryBase: null,
                rate: null, rateAsOf: null, periodEnd: d, adjustment: total, baseCurrency,
                isTotal: true, totalUnknown: missing.length > 0,
            }]
            : []),
    ]

    return (
        <ListPage title={t('finance.reval.title')} maxWidth="max-w-4xl" state={{ kind: 'ok' }}>
            <form method="get" className="mb-4">
                <input type="date" name="date" defaultValue={d} className="border border-gray-300 rounded px-2 py-1 text-sm" />
                <button type="submit" className="ml-2 border border-gray-300 rounded px-3 py-1 text-sm">{t('reviews.filter')}</button>
            </form>

            {/* 缺牌价:点名【是哪些币种】缺,而不是笼统说"当天没有中间价" */}
            {missing.length > 0 && (
                <div className="mb-4 rounded border border-red-300 bg-red-50 px-4 py-3 text-sm text-red-800">
                    {t('finance.reval.noMidFor', { 0: d, 1: missing.join(', ') })}
                </div>
            )}

            {rows.length === 0 ? (
                <p className="mb-4 text-sm text-gray-500">{t('finance.reval.nothingToRevalue')}</p>
            ) : (
                <div className="mb-4">
                    <RevaluationPreviewTable rows={previewRows} />
                </div>
            )}

            <RevalueButton periodEnd={d} disabled={!canPost} />
        </ListPage>
    )
}
