// app/hr/leave/[id]/page.tsx
// 单条申请:申请本身 + 【此刻】的余额 + 批准后的消耗明细 + 审批控件。
//
// 余额是【打开这一页时现算的】,不是提交时那个数 —— 中间可能有别的申请被批过,
// 所以审批人看到的必须是当下的真实余额;真正的守卫仍在 decide_leave_request 里。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import LeaveSubnav from '../LeaveSubnav'
import DecideControls from './DecideControls'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import { GrantBreakdownTable, ConsumptionTable, type GrantBreakdownRow, type ConsumptionRow } from './LeaveDetailTables'

export default async function LeaveRequestDetail({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const { data: req, error } = await supabase
        .from('leave_requests')
        .select('*')
        .eq('id', id)
        .is('deleted_at', null)
        .single()
    if (error || !req) notFound()

    const [empRes, typeRes, balRes, consRes] = await Promise.all([
        supabase.from('employees').select('id, code, legal_name, employment_status')
            .eq('id', req.employee_id).single(),
        supabase.from('leave_types').select('*').eq('code', req.leave_type_code).single(),
        supabase.rpc('leave_balance', {
            p_employee_id: req.employee_id,
            p_leave_type_code: req.leave_type_code,
            p_as_of: req.start_date,
        }),
        supabase.from('leave_consumption')
            .select('id, leave_grant_id, entry_type, days, notes, created_at')
            .eq('leave_request_id', id)
            .order('created_at'),
    ])

    const emp = empRes.data
    const ty = typeRes.data
    const bal = balRes.data as {
        granted: number; consumed: number; expired: number; available: number
        breakdown: { grant_id: string; leave_year: number; grant_type: string; days: number
                     consumed: number; remaining: number; expires_on: string | null; status: string }[]
    } | null


    const card = 'rounded border border-gray-200 p-4'

    // ★【行数据在服务端压平】locale(假别名 zh/en)、动态前缀 t('leave.grantType_'+x)
    //   都只有服务端知道 —— 一个判据都不过界(CONV-1 §①)。
    const grantRows: GrantBreakdownRow[] = (bal?.breakdown ?? []).map((b) => ({
        id: b.grant_id,
        leaveYear: String(b.leave_year),
        grantTypeText: t(`leave.grantType_${b.grant_type}`),
        days: String(b.days),
        consumed: String(b.consumed),
        remaining: String(b.remaining),
        expiresOn: b.expires_on ?? '—',
        statusText: t(`leave.grantStatus_${b.status}`),
    }))

    const consumptionRows: ConsumptionRow[] = (mustRows(consRes)).map((c) => ({
        id: c.id,
        entryTypeText: t(`leave.entry_${c.entry_type}`),
        days: String(c.days),
        grantIdShort: c.leave_grant_id?.slice(0, 8) ?? '—',
        notes: c.notes ?? '—',
    }))

    return (
        <ListPage
            maxWidth="max-w-4xl"
            title={t('hr.title')}
            // ★★ 详情页恒为 ok —— 这张请假单在不在由上面的 notFound() 回答。
            state={{ kind: 'ok' }}
            notices={
                <>
                    {/* ★ 出口:假别子导航。CONV-5 §⑩-3 点名过这一类 ——
                        它【必须】走 notices(画在状态分支之前),塞进 children
                        会让一次空态把人留在一张走不出去的页上。 */}
                    <LeaveSubnav />

                    {/* 【返回链接留在标题【下面】】这一页转换前就是这样(它在子导航之后),
                        所以【不】用 breadcrumb 槽 —— 用了会把它挪到标题之上。 */}
                    <div className="mb-4">
                        <Link href="/hr/leave" className="text-blue-600 hover:underline text-sm">
                            {t('common.back')}
                        </Link>
                    </div>

                    <div className="flex flex-wrap items-baseline gap-3 mb-4">
                        <h2 className="text-xl font-bold">{req.code}</h2>
                        <span className="text-sm text-gray-500">
                            {emp ? `${emp.code} — ${emp.legal_name}` : ''}
                        </span>
                        {req.is_exception && (
                            <span className="rounded bg-purple-100 px-2 py-0.5 text-xs text-purple-800">
                                {t('leave.exception')}
                            </span>
                        )}
                    </div>
                </>
            }
        >
            {/* ★ 记录抬头 —— 转换前是一块 rounded border 的 grid 面板。 */}
            <RecordHeader
                fields={[
                    {
                        label: t('leave.type'),
                        value: ty ? (locale === 'zh' ? ty.name_zh : ty.name_en) : req.leave_type_code,
                    },
                    { label: t('leave.dates'), value: `${req.start_date} → ${req.end_date}` },
                    { label: t('leave.days'), value: String(req.days), mono: true },
                    { label: t('leave.status'), value: t(`leave.status_${req.status}`) },
                    ...(req.reason ? [{ label: t('leave.reason'), value: req.reason }] : []),
                    ...(req.certificate_ref ? [{ label: t('leave.certificate'), value: req.certificate_ref }] : []),
                    ...(req.is_exception ? [{ label: t('leave.exceptionReason'), value: req.exception_reason }] : []),
                    ...(req.decision_notes ? [{ label: t('leave.decisionNotes'), value: req.decision_notes }] : []),
                ]}
            />

            {/* 余额:审批之前该看的那个数 */}
            {ty?.is_accrued && bal && (
                <section className={card + ' mb-6'}>
                    <h3 className="font-bold mb-1">{t('leave.balanceNow')}</h3>
                    <p className="text-xs text-gray-500 mb-3">{t('leave.balanceAsOfHint')}</p>
                    {/* 第二块抬头 —— 同一个 RecordHeader,不是第二种写法。 */}
                    <RecordHeader
                        fields={[
                            { label: t('leave.granted'), value: String(bal.granted), mono: true },
                            { label: t('leave.taken'), value: String(bal.consumed), mono: true },
                            { label: t('leave.expired'), value: String(bal.expired), mono: true },
                            { label: t('leave.available'), value: String(bal.available), mono: true },
                        ]}
                    />
                    <GrantBreakdownTable rows={grantRows} />
                </section>
            )}

            {/* 批准之后:这几天到底从哪几笔授予里扣的 */}
            {consumptionRows.length > 0 && (
                <section className={card + ' mb-6'}>
                    <h3 className="font-bold mb-1">{t('leave.consumption')}</h3>
                    <p className="text-xs text-gray-500 mb-3">{t('leave.consumptionHint')}</p>
                    <ConsumptionTable rows={consumptionRows} />
                </section>
            )}

            {/* ★ 出口:批准 / 驳回。住 children,而 state 恒为 'ok'。 */}
            <DecideControls
                requestId={req.id}
                status={req.status}
                available={ty?.is_accrued ? (bal?.available ?? null) : null}
                requested={req.days}
            />
        </ListPage>
    )
}
