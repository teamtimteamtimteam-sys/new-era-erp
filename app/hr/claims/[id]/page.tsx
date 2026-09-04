// app/hr/claims/[id]/page.tsx
// 单笔报销:金额、当年剩余额度、审批,以及【建费用】——
// 后者要 module.finance.edit,HR 看得见按钮但按不动(带解释),因为那是财务的动作。
//
// ★ CONV-9(2026-09-04):转成 ListPage + RecordHeader。**这一页一张表都没有**
//   —— 37 张详情页里只有两张是这样(另一张是 /inbound/receive/done/[id])。
//   于是它不多一个客户端文件:RecordHeader 是服务端组件(见它的抬头),
//   而"详情页多一个文件"这件事只由【有表的那一半】承担。
//   【出口检查】唯一的出口是 ClaimControls(批准 / 驳回 / 建费用),住 children;
//   而详情页 state 恒为 'ok',所以它不可能被空分支吃掉。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'
import ClaimControls from './ClaimControls'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'

export default async function ClaimDetail({ params }: { params: Promise<{ id: string }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: claim, error } = await supabase
        .from('medical_claim_status').select('*').eq('claim_id', id).single()
    if (error || !claim) notFound()

    // 视图没有 NOT NULL 约束,生成的类型把每一列都标成可空;这几列由视图的 JOIN 保证有值
    const employeeId = claim.employee_id as string
    const claimYear = claim.claim_year as number

    // PAYEE-1a:供应商下拉【已删除】—— 报销的收款人就是提交报销的那个员工,
    // pay_medical_claim 自己从报销单取。此前那个下拉筛 status='active',
    // 而线上没有任何 active 供应商,于是付款按钮被 !supplierId 永久禁用:
    // 这条路径在本刀之前【根本走不通】。
    const balRes = await supabase.rpc('medical_claim_balance', {
        p_employee_id: employeeId, p_year: claimYear,
    })
    const bal = balRes.data as {
        pro_rated_limit_sgd: number; claimed_sgd: number; remaining_sgd: number; months_of_service: number
    } | null
    const canFinance = await can('module.finance.edit')

    const card = 'rounded border border-gray-200 p-4 mb-6'

    // 金额一律以【报销单自己的币种】表示 —— 视图的列名就叫 amount_sgd,
    // 而那个 SGD 是列名的一部分,不是这一屏挑出来的一个币种(check-currency-literals
    // 的 jsx-text 类守的正是"屏幕上凭空长出一个币种代码")。所以它走 i18n 的
    // claims.amountWithCcy,币种由消息里那个 {ccy} 参数带。
    const claimCcy = 'SGD'

    return (
        <ListPage
            maxWidth="max-w-3xl"
            title={t('hr.title')}
            // ★★ 详情页恒为 ok —— 这张报销单在不在由上面的 notFound() 回答。
            state={{ kind: 'ok' }}
            notices={
                <>
                    {/* 【返回链接留在标题【下面】】这一页转换前就是这样,
                        所以【不】用 breadcrumb 槽 —— 用了会把它挪到标题之上。 */}
                    <div className="mb-4">
                        <Link href="/hr/claims" className="text-blue-600 hover:underline text-sm">{t('common.back')}</Link>
                    </div>
                    <div className="flex flex-wrap items-baseline gap-3 mb-4">
                        <h2 className="text-xl font-bold">{claim.code}</h2>
                        <span className="text-sm text-gray-500">{claim.employee_code} — {claim.legal_name}</span>
                    </div>
                </>
            }
        >
            {/* ★ 记录抬头 —— 转换前是一块 rounded border 的 grid 面板,
                也就是 CONV-8 §② 那张表里的第三种写法。 */}
            <RecordHeader
                fields={[
                    { label: t('claims.date'), value: claim.claim_date },
                    {
                        label: t('claims.amount'),
                        value: t('claims.amountWithCcy', { amount: Number(claim.amount_sgd).toFixed(2), ccy: claimCcy }),
                        mono: true,
                    },
                    { label: t('claims.state'), value: t(`claims.state_${claim.settlement_state}`) },
                    ...(claim.description ? [{ label: t('claims.description'), value: claim.description }] : []),
                    ...(claim.receipt_ref ? [{ label: t('claims.receipt'), value: claim.receipt_ref }] : []),
                ]}
            />

            {bal && (
                <section className={card}>
                    <h3 className="font-bold mb-3">{t('claims.limitTitle', { 0: String(claimYear) })}</h3>
                    {/* 第二块抬头 —— 同一个 RecordHeader,不是第二种写法。
                        它带一个自己的小标题,所以留在 section 里而不是并到上面那一块。 */}
                    <RecordHeader
                        className="mb-0"
                        fields={[
                            {
                                label: t('claims.limit'),
                                value: (
                                    <>
                                        {t('claims.amountWithCcy', { amount: String(bal.pro_rated_limit_sgd), ccy: claimCcy })}
                                        <span className="block text-xs text-gray-500">
                                            {t('claims.monthsOfService', { 0: String(bal.months_of_service) })}
                                        </span>
                                    </>
                                ),
                                mono: true,
                            },
                            {
                                label: t('claims.claimed'),
                                value: t('claims.amountWithCcy', { amount: String(bal.claimed_sgd), ccy: claimCcy }),
                                mono: true,
                            },
                            {
                                label: t('claims.remaining'),
                                value: t('claims.amountWithCcy', { amount: String(bal.remaining_sgd), ccy: claimCcy }),
                                mono: true,
                            },
                        ]}
                    />
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

            {/* ★ 出口:批准 / 驳回 / 建费用。住 children,而 state 恒为 'ok'。 */}
            <ClaimControls
                claimId={claim.claim_id as string}
                status={claim.status as string}
                alreadyLinked={!!claim.expense_id}
                canFinance={canFinance}
            />
        </ListPage>
    )
}
