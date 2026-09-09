'use client'

// app/me/MyLeavePanel.tsx
// 自助的假期部分:余额(带逐笔来源与到期日)、自己的申请历史、以及一个申请表单。
// 【没有例外开关】—— 那是 HR 的口子。
//
// ★ TABLE-CONVERT-1(2026-09-10):这个文件里【两张】手搓表格一起 → 组件
//   (两张住在一个文件里,就是一个不可分的单位)。
//   【手机上留哪几列,两张都一个字没改】
//     · 余额逐笔(TABLE-PHONE-1 做的):留 年度 · 剩余 · 状态;
//       折 来源 · 天数 · 到期。「剩余」是这张表存在的理由 —— 一个人点开
//       「我的年假」要的就是这一个数,所以它在手机上留着。
//     · 申请历史(TABLE-PHONE-3 做的):留 单号 · 天数 · 状态;折 假别 · 起止。
//   转换把「留」写成 priority,「折」写成不带 priority —— 同一个判断,换一种说法。
//   叠在身份格里那两段手写的展开块【拿掉了】:组件自己画那一段。
//   ★ 余额那张表的 rowKey 用 grant_id ?? 派生累积的年份:leave_balance_internal
//     给【派生累积】那一行的 grant_id 是 NULL(db/functions/leave_balance_internal.sql:76),
//     而组件的 rowKey 要一个真的字符串。转换之前那里是 key={null} —— React 退回
//     用下标,并在开发档打一句警告。这一处【只改键,不改任何看得见的东西】。
import { useState } from 'react'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import LeaveForm, { type LeaveTypeOption } from '@/app/hr/leave/LeaveForm'
import { Button } from '@/app/components/ui/button'
import { DataTable, type Column } from '@/app/components/ui/data-table'

type Breakdown = {
    // ★ 派生累积那一行的 grant_id 是 NULL —— leave_balance_internal.sql:76 建的就是
    //   一个 'grant_id', NULL 的对象。转换之前这里写的是 string,而它一直不是。
    grant_id: string | null; leave_year: number; grant_type: string; days: number
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

    const breakdownColumns: Column<Breakdown>[] = [
        { key: 'grantYear', header: t('leave.grantYear'), priority: true, render: (b) => b.leave_year },
        {
            key: 'grantType', header: t('leave.grantType'),
            render: (b) => t(`leave.grantType_${b.grant_type}`),
        },
        {
            key: 'days', header: t('leave.days'), align: 'right', className: 'font-mono',
            render: (b) => b.days,
        },
        {
            key: 'remaining', header: t('leave.remaining'), align: 'right', priority: true,
            className: 'font-mono', render: (b) => b.remaining,
        },
        { key: 'expires', header: t('leave.expires'), render: (b) => b.expires_on ?? '—' },
        {
            key: 'grantStatus', header: t('leave.grantStatus'), priority: true,
            render: (b) => t(`leave.grantStatus_${b.status}`),
        },
    ]

    const requestColumns: Column<Req>[] = [
        { key: 'code', header: t('leave.code'), priority: true, className: 'font-mono', render: (r) => r.code },
        { key: 'type', header: t('leave.type'), render: (r) => typeName(r.leave_type_code) },
        {
            key: 'dates', header: t('leave.dates'),
            render: (r) => `${r.start_date} → ${r.end_date}`,
        },
        {
            key: 'days', header: t('leave.days'), align: 'right', priority: true, className: 'font-mono',
            render: (r) => r.days,
        },
        {
            key: 'status', header: t('leave.status'), priority: true,
            render: (r) => t(`leave.status_${r.status}`),
        },
    ]

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
                    <DataTable
                        rows={balance.breakdown}
                        columns={breakdownColumns}
                        rowKey={(b) => b.grant_id ?? `accrual-${b.leave_year}`}
                        phone={{ mode: 'columns' }}
                    />
                </div>
            )}

            {open && (
                <div className="mb-3">
                    <LeaveForm types={types} fixedEmployeeId={employeeId} redirectTo="/me" />
                </div>
            )}

            <DataTable
                rows={requests}
                columns={requestColumns}
                rowKey={(r) => r.id}
                phone={{ mode: 'columns' }}
                empty={t('me.noLeave')}
            />
        </section>
    )
}
