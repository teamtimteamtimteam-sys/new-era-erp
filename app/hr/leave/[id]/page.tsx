// app/hr/leave/[id]/page.tsx
// 单条申请:申请本身 + 【此刻】的余额 + 批准后的消耗明细 + 审批控件。
//
// 余额是【打开这一页时现算的】,不是提交时那个数 —— 中间可能有别的申请被批过,
// 所以审批人看到的必须是当下的真实余额;真正的守卫仍在 decide_leave_request 里。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import LeaveSubnav from '../LeaveSubnav'
import DecideControls from './DecideControls'

export default async function LeaveRequestDetail({
    params,
}: {
    params: Promise<{ id: string }>
}) {
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
    const dt = 'text-xs text-gray-500'
    const dd = 'text-sm font-medium'

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />
            <LeaveSubnav />

            <div className="mb-4">
                <Link href="/hr/leave" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex items-baseline gap-3 mb-4">
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

            <section className={card + ' mb-6'}>
                <div className="grid gap-4 sm:grid-cols-4">
                    <div><div className={dt}>{t('leave.type')}</div>
                        <div className={dd}>{ty ? (locale === 'zh' ? ty.name_zh : ty.name_en) : req.leave_type_code}</div></div>
                    <div><div className={dt}>{t('leave.dates')}</div>
                        <div className={dd}>{req.start_date} → {req.end_date}</div></div>
                    <div><div className={dt}>{t('leave.days')}</div>
                        <div className={dd + ' font-mono'}>{req.days}</div></div>
                    <div><div className={dt}>{t('leave.status')}</div>
                        <div className={dd}>{t(`leave.status_${req.status}`)}</div></div>
                    {req.reason && (
                        <div className="sm:col-span-2"><div className={dt}>{t('leave.reason')}</div>
                            <div className={dd}>{req.reason}</div></div>
                    )}
                    {req.certificate_ref && (
                        <div><div className={dt}>{t('leave.certificate')}</div>
                            <div className={dd}>{req.certificate_ref}</div></div>
                    )}
                    {req.is_exception && (
                        <div className="sm:col-span-4">
                            <div className={dt}>{t('leave.exceptionReason')}</div>
                            <div className={dd}>{req.exception_reason}</div>
                        </div>
                    )}
                    {req.decision_notes && (
                        <div className="sm:col-span-4"><div className={dt}>{t('leave.decisionNotes')}</div>
                            <div className={dd}>{req.decision_notes}</div></div>
                    )}
                </div>
            </section>

            {/* 余额:审批之前该看的那个数 */}
            {ty?.is_accrued && bal && (
                <section className={card + ' mb-6'}>
                    <h3 className="font-bold mb-1">{t('leave.balanceNow')}</h3>
                    <p className="text-xs text-gray-500 mb-3">{t('leave.balanceAsOfHint')}</p>
                    <div className="grid gap-4 sm:grid-cols-4 mb-4">
                        <div><div className={dt}>{t('leave.granted')}</div><div className={dd + ' font-mono'}>{bal.granted}</div></div>
                        <div><div className={dt}>{t('leave.taken')}</div><div className={dd + ' font-mono'}>{bal.consumed}</div></div>
                        <div><div className={dt}>{t('leave.expired')}</div><div className={dd + ' font-mono'}>{bal.expired}</div></div>
                        <div><div className={dt}>{t('leave.available')}</div>
                            <div className={dd + ' font-mono text-lg'}>{bal.available}</div></div>
                    </div>
                    <table className="w-full border-collapse text-xs">
                        <thead>
                            <tr className="bg-gray-50 text-left">
                                <th className="border border-gray-300 px-2 py-1">{t('leave.grantYear')}</th>
                                <th className="border border-gray-300 px-2 py-1">{t('leave.grantType')}</th>
                                <th className="border border-gray-300 px-2 py-1 text-right">{t('leave.days')}</th>
                                <th className="border border-gray-300 px-2 py-1 text-right">{t('leave.taken')}</th>
                                <th className="border border-gray-300 px-2 py-1 text-right">{t('leave.remaining')}</th>
                                <th className="border border-gray-300 px-2 py-1">{t('leave.expires')}</th>
                                <th className="border border-gray-300 px-2 py-1">{t('leave.grantStatus')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {bal.breakdown.map((b) => (
                                <tr key={b.grant_id}>
                                    <td className="border border-gray-300 px-2 py-1">{b.leave_year}</td>
                                    <td className="border border-gray-300 px-2 py-1">{t(`leave.grantType_${b.grant_type}`)}</td>
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono">{b.days}</td>
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono">{b.consumed}</td>
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono">{b.remaining}</td>
                                    <td className="border border-gray-300 px-2 py-1">{b.expires_on ?? '—'}</td>
                                    <td className="border border-gray-300 px-2 py-1">{t(`leave.grantStatus_${b.status}`)}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </section>
            )}

            {/* 批准之后:这几天到底从哪几笔授予里扣的 */}
            {(consRes.data ?? []).length > 0 && (
                <section className={card + ' mb-6'}>
                    <h3 className="font-bold mb-1">{t('leave.consumption')}</h3>
                    <p className="text-xs text-gray-500 mb-3">{t('leave.consumptionHint')}</p>
                    <table className="w-full border-collapse text-xs">
                        <thead>
                            <tr className="bg-gray-50 text-left">
                                <th className="border border-gray-300 px-2 py-1">{t('leave.entryType')}</th>
                                <th className="border border-gray-300 px-2 py-1 text-right">{t('leave.days')}</th>
                                <th className="border border-gray-300 px-2 py-1">{t('leave.grantId')}</th>
                                <th className="border border-gray-300 px-2 py-1">{t('leave.notes')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {(consRes.data ?? []).map((c) => (
                                <tr key={c.id}>
                                    <td className="border border-gray-300 px-2 py-1">{t(`leave.entry_${c.entry_type}`)}</td>
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono">{c.days}</td>
                                    <td className="border border-gray-300 px-2 py-1 font-mono">{c.leave_grant_id?.slice(0, 8)}</td>
                                    <td className="border border-gray-300 px-2 py-1">{c.notes ?? '—'}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </section>
            )}

            <DecideControls
                requestId={req.id}
                status={req.status}
                available={ty?.is_accrued ? (bal?.available ?? null) : null}
                requested={req.days}
            />
        </div>
    )
}
