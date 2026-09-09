'use client'

// app/me/MyLeavePanel.tsx
// 自助的假期部分:余额(带逐笔来源与到期日)、自己的申请历史、以及一个申请表单。
// 【没有例外开关】—— 那是 HR 的口子。
import { useState } from 'react'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import LeaveForm, { type LeaveTypeOption } from '@/app/hr/leave/LeaveForm'
import { Button } from '@/app/components/ui/button'

type Breakdown = {
    grant_id: string; leave_year: number; grant_type: string; days: number
    consumed: number; remaining: number; expires_on: string | null; status: string
}
type Balance = { granted: number; consumed: number; expired: number; available: number; breakdown: Breakdown[] }
type Req = {
    id: string; code: string; leave_type_code: string
    start_date: string; end_date: string; days: number; status: string
}

export default function MyLeavePanel({
    employeeId, balance, requests, types,
}: {
    employeeId: string
    balance: Balance | null
    requests: Req[]
    types: LeaveTypeOption[]
}) {
    const t = useTranslations()
    const locale = useLocale()
    const [open, setOpen] = useState(false)
    const typeName = (c: string) => {
        const x = types.find((y) => y.code === c)
        return x ? (locale === 'zh' ? x.name_zh : x.name_en) : c
    }

    return (
        <section className="mb-6">
            <div className="flex items-center justify-between mb-2">
                <h2 className="text-lg font-bold">{t('me.leave')}</h2>
                <Button type="button" onClick={() => setOpen((o) => !o)}
                        variant="default">
                    {open ? t('common.cancel') : t('me.requestLeave')}
                </Button>
            </div>

            {balance && (
                <div className="rounded border border-gray-200 p-4 mb-3">
                    <div className="grid gap-4 sm:grid-cols-4 mb-3">
                        <div><div className="text-xs text-gray-500">{t('leave.granted')}</div>
                            <div className="text-sm font-mono">{balance.granted}</div></div>
                        <div><div className="text-xs text-gray-500">{t('leave.taken')}</div>
                            <div className="text-sm font-mono">{balance.consumed}</div></div>
                        <div><div className="text-xs text-gray-500">{t('leave.expired')}</div>
                            <div className="text-sm font-mono">{balance.expired}</div></div>
                        <div><div className="text-xs text-gray-500">{t('leave.available')}</div>
                            <div className="text-lg font-mono font-medium">{balance.available}</div></div>
                    </div>
                    {/* 【"我的余额为什么是 19.5"就靠这张表回答】 */}
                    <p className="text-xs text-gray-500 mb-2">{t('me.balanceExplainer')}</p>
                    <table className="w-full border-collapse text-xs">
                        <thead>
                            <tr className="bg-gray-50 text-left">
                                <th className="border border-gray-300 px-2 py-1">{t('leave.grantYear')}</th>
                                <th className="hidden sm:table-cell border border-gray-300 px-2 py-1">{t('leave.grantType')}</th>
                                <th className="hidden sm:table-cell border border-gray-300 px-2 py-1 text-right">{t('leave.days')}</th>
                                {/* ★ TABLE-PHONE-1:「剩余」是这张表存在的理由 —— 一个人点开
                                    「我的年假」要的就是这一个数,所以它在手机上留着。 */}
                                <th className="border border-gray-300 px-2 py-1 text-right">{t('leave.remaining')}</th>
                                <th className="hidden sm:table-cell border border-gray-300 px-2 py-1">{t('leave.expires')}</th>
                                <th className="border border-gray-300 px-2 py-1">{t('leave.grantStatus')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {balance.breakdown.map((b) => (
                                <tr key={b.grant_id}>
                                    <td className="border border-gray-300 px-2 py-1">
                                        {b.leave_year}
                                        {/* ★ TABLE-PHONE-1:手机档被拿掉的三列(类型 / 天数 / 到期),
                                            原样叠在这里,各带各的列头 —— 拿掉的是那一列,不是那个事实。 */}
                                        <div className="sm:hidden mt-1 space-y-0.5 text-[11px] text-gray-600">
                                            <div>
                                                <span className="text-gray-500">{t('leave.grantType')}: </span>
                                                {t(`leave.grantType_${b.grant_type}`)}
                                            </div>
                                            <div>
                                                <span className="text-gray-500">{t('leave.days')}: </span>
                                                <span className="font-mono">{b.days}</span>
                                            </div>
                                            <div>
                                                <span className="text-gray-500">{t('leave.expires')}: </span>
                                                {b.expires_on ?? '—'}
                                            </div>
                                        </div>
                                    </td>
                                    <td className="hidden sm:table-cell border border-gray-300 px-2 py-1">{t(`leave.grantType_${b.grant_type}`)}</td>
                                    <td className="hidden sm:table-cell border border-gray-300 px-2 py-1 text-right font-mono">{b.days}</td>
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono">{b.remaining}</td>
                                    <td className="hidden sm:table-cell border border-gray-300 px-2 py-1">{b.expires_on ?? '—'}</td>
                                    <td className="border border-gray-300 px-2 py-1">{t(`leave.grantStatus_${b.status}`)}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}

            {open && (
                <div className="mb-3">
                    <LeaveForm types={types} fixedEmployeeId={employeeId} redirectTo="/me" />
                </div>
            )}

            {requests.length === 0 ? (
                <p className="text-sm text-gray-500">{t('me.noLeave')}</p>
            ) : (
                <table className="w-full border-collapse text-sm">
                    <thead>
                        <tr className="bg-gray-50 text-left">
                            <th className="border border-gray-300 px-3 py-2">{t('leave.code')}</th>
                            <th className="hidden sm:table-cell border border-gray-300 px-3 py-2">{t('leave.type')}</th>
                            <th className="hidden sm:table-cell border border-gray-300 px-3 py-2">{t('leave.dates')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('leave.days')}</th>
                            <th className="border border-gray-300 px-3 py-2">{t('leave.status')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {requests.map((r) => (
                            <tr key={r.id}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">
                                    {r.code}
                                    {/* ★ TABLE-PHONE-3:手机档被拿掉的两列(假别 / 起止),原样叠在这里,
                                        各带各的列头 —— 拿掉的是那一列,不是那个事实。
                                        留在列上的是:单号 + 几天 + 批没批。天数是这张表的那个数
                                        (它就是上面那张余额表扣掉的东西);批没批是它的状态。
                                        ★ 本文件上面那张余额表是 TABLE-PHONE-1 做的,这一张
                                        当时的委托书没有点名,所以留到了本刀 —— 这个文件到此清完。 */}
                                    <div className="sm:hidden mt-1 space-y-0.5 font-sans text-xs text-gray-600">
                                        <div>
                                            <span className="text-gray-500">{t('leave.type')}: </span>
                                            {typeName(r.leave_type_code)}
                                        </div>
                                        <div>
                                            <span className="text-gray-500">{t('leave.dates')}: </span>
                                            {r.start_date} → {r.end_date}
                                        </div>
                                    </div>
                                </td>
                                <td className="hidden sm:table-cell border border-gray-300 px-3 py-2">{typeName(r.leave_type_code)}</td>
                                <td className="hidden sm:table-cell border border-gray-300 px-3 py-2">{r.start_date} → {r.end_date}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">{r.days}</td>
                                <td className="border border-gray-300 px-3 py-2">{t(`leave.status_${r.status}`)}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </section>
    )
}
