// app/hr/claims/[id]/page.tsx
// 单笔报销:金额、当年剩余额度、审批,以及【建费用】——
// 后者要 module.finance.edit,HR 看得见按钮但按不动(带解释),因为那是财务的动作。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'
import Subnav from '../../Subnav'
import ClaimControls from './ClaimControls'
import { mustRows } from '@/lib/db-helpers'

export default async function ClaimDetail({ params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: claim, error } = await supabase
        .from('medical_claim_status').select('*').eq('claim_id', id).single()
    if (error || !claim) notFound()

    // 视图没有 NOT NULL 约束,生成的类型把每一列都标成可空;这几列由视图的 JOIN 保证有值
    const employeeId = claim.employee_id as string
    const claimYear = claim.claim_year as number

    const [balRes, supRes] = await Promise.all([
        supabase.rpc('medical_claim_balance', {
            p_employee_id: employeeId, p_year: claimYear,
        }),
        supabase.from('suppliers').select('id, legal_name').is('deleted_at', null)
            .eq('status', 'active').order('legal_name'),
    ])
    const bal = balRes.data as {
        pro_rated_limit_sgd: number; claimed_sgd: number; remaining_sgd: number; months_of_service: number
    } | null
    const canFinance = await can('module.finance.edit')

    const card = 'rounded border border-gray-200 p-4 mb-6'
    const dt = 'text-xs text-gray-500'
    const dd = 'text-sm font-medium'

    return (
        <div className="p-8 max-w-3xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />
            <div className="mb-4"><Link href="/hr/claims" className="text-blue-600 hover:underline text-sm">{t('common.back')}</Link></div>

            <div className="flex items-baseline gap-3 mb-4">
                <h2 className="text-xl font-bold">{claim.code}</h2>
                <span className="text-sm text-gray-500">{claim.employee_code} — {claim.legal_name}</span>
            </div>

            <section className={card}>
                <div className="grid gap-4 sm:grid-cols-3">
                    <div><div className={dt}>{t('claims.date')}</div><div className={dd}>{claim.claim_date}</div></div>
                    <div><div className={dt}>{t('claims.amount')}</div>
                        <div className={dd + ' font-mono'}>{Number(claim.amount_sgd).toFixed(2)} SGD</div></div>
                    <div><div className={dt}>{t('claims.state')}</div>
                        <div className={dd}>{t(`claims.state_${claim.settlement_state}`)}</div></div>
                    {claim.description && (
                        <div className="sm:col-span-2"><div className={dt}>{t('claims.description')}</div>
                            <div className={dd}>{claim.description}</div></div>
                    )}
                    {claim.receipt_ref && (
                        <div><div className={dt}>{t('claims.receipt')}</div><div className={dd}>{claim.receipt_ref}</div></div>
                    )}
                </div>
            </section>

            {bal && (
                <section className={card}>
                    <h3 className="font-bold mb-3">{t('claims.limitTitle', { 0: String(claimYear) })}</h3>
                    <div className="grid gap-4 sm:grid-cols-3">
                        <div><div className={dt}>{t('claims.limit')}</div>
                            <div className={dd + ' font-mono'}>{bal.pro_rated_limit_sgd} SGD</div>
                            <div className="text-xs text-gray-500">{t('claims.monthsOfService', { 0: String(bal.months_of_service) })}</div></div>
                        <div><div className={dt}>{t('claims.claimed')}</div>
                            <div className={dd + ' font-mono'}>{bal.claimed_sgd} SGD</div></div>
                        <div><div className={dt}>{t('claims.remaining')}</div>
                            <div className={dd + ' font-mono text-lg'}>{bal.remaining_sgd} SGD</div></div>
                    </div>
                </section>
            )}

            {claim.expense_code && (
                <section className={card}>
                    <h3 className="font-bold mb-2">{t('claims.linkedExpense')}</h3>
                    <Link href="/finance/expenses" className="text-blue-600 hover:underline font-mono text-sm">
                        {claim.expense_code}
                    </Link>
                    <p className="mt-1 text-xs text-gray-500">{t('claims.expenseHint')}</p>
                </section>
            )}

            <ClaimControls
                claimId={claim.claim_id as string}
                status={claim.status as string}
                alreadyLinked={!!claim.expense_id}
                canFinance={canFinance}
                suppliers={(mustRows(supRes)).map((s) => ({ id: s.id, name: s.legal_name }))}
            />
        </div>
    )
}
