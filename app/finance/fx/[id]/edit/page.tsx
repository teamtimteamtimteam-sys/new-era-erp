// app/finance/fx/[id]/edit/page.tsx
// 编辑牌价页(服务端壳):取行 + 非 SGD 币种选项,表单交给客户端组件。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import EditFxRateForm from './EditFxRateForm'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import EndedBanner, { EndedFieldset } from '@/app/components/trail/EndedBanner'

export default async function EditFxRatePage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const canEditGate = await can('module.finance.edit')

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    // AUDIT-TRAIL-1c-2(Tim 的 Q7 · Q21 · Q8):一条撤回了的汇率以前在这里 404 —— 撤回是一件有人、有理由的业务事件,
    //   所以它对这一页本来的读者【只读打开】:顶上 "Withdrawn on DD/MM/YYYY by <name>" + 理由(汇率表上没有撤回人 ——
    //   谁、何时、为什么取自那一行 'withdrawn' 修改史),表单整个按不下去,页底是它的审计记录。
    //   ☞ 只读不是装饰:record_fx_rate 只认 deleted_at IS NULL 的那一行,在一条撤回了的汇率上提交表单会【另起一行】新汇率。
    const [rateRes, currenciesRes] = await Promise.all([
        supabase
            .from('fx_rates')
            .select('id, currency, rate_type, rate_sgd_per_unit, rate_date, source, notes, deleted_at')
            .eq('id', id)
            .single(),
        supabase.from('currencies').select('code').eq('is_base', false).order('code'),
    ])

    if (rateRes.error || !rateRes.data) {
        notFound()
    }
    const withdrawnAt = rateRes.data.deleted_at
    const withdrawal = withdrawnAt
        ? mustOne(await supabase.from('fx_rate_history').select('changed_at, changed_by, reason')
            .eq('fx_rate_id', id).eq('action', 'withdrawn').order('changed_at', { ascending: false }).limit(1).maybeSingle(),
            'fx_rate_history') as { changed_at: string; changed_by: string | null; reason: string | null } | null
        : null

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link href="/finance/fx" className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="mb-6">{t('finance.fxPage.editTitle')}</h1>

            {withdrawnAt && (
                <EndedBanner kind="withdrawn" at={withdrawal?.changed_at ?? withdrawnAt} by={withdrawal?.changed_by ?? null} reason={withdrawal?.reason ?? null} />
            )}
            <EndedFieldset ended={!!withdrawnAt}>
                <EditFxRateForm canEdit={canEditGate}
                    rate={rateRes.data}
                    currencies={(mustRows(currenciesRes)).map((c) => c.code)}
                />
            </EndedFieldset>

            {/* AUDIT-TRAIL-1c-2:这一条汇率的审计记录 —— 录入、更正(带理由)、撤回 */}
            <AuditTrail subject="fx_rate" id={id} show={trailCount((await searchParams).trail)} />
        </div>
    )
}
