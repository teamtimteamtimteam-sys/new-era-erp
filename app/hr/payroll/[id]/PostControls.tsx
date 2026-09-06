'use client'

// 过账 / 撤销过账。
// 过账前的 confirm 把【合计与将要动的科目】原样摆出来 —— 过账会真的动总账,
// 点之前应该看得见自己在批准什么。撤销带内联原因,并说明分录会被冲销。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { formatAmount } from '@/lib/format'
import { postPayroll, unpostPayroll } from '../actions'

export function PostPayrollButton({
    periodId,
    subject,
    currency,
    totals,
    bankAccount,
}: {
    periodId: string
    /** CONFIRM-1:这一次过账动的是【哪一个期间】—— 原来一个字都不说。 */
    subject: string
    currency: string
    totals: { gross: number; employerCpf: number; employeeCpf: number; other: number; net: number }
    bankAccount: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    // ★★【CONFIRM-1:这里是本刀最值得看的一处 —— 一张表被还原成一张表】★★
    //   原来这五行是 `.join('\n')` 拼成一个字符串,再 `${msg}\n\n${lines}` 塞进
    //   原生对话框。**那不是排版问题,那是原生对话框在【主动毁掉信息】** ——
    //   它只收得下一个字符串,于是一张【科目 / 金额】的对照表被压平成一段文本,
    //   对不齐、不能选、在窄屏上换行换得看不出哪个数属于哪个科目。
    //   现在它是 <dl>:科目一列、金额一列,对得齐,读得出。
    //   ☞ 金额【没有被遮】—— 这一页的合计本来就是 formatMoneyBare 直接画的
    //     (app/hr/payroll/[id]/page.tsx:97-101),不走 MaskedValue。
    //     主语与正文因此没有说出任何这一页不肯说的东西。
    const postingLines = [
        { acct: '6100', name: t('hr.acct6100'), amount: `+${formatAmount(totals.gross, currency)}` },
        { acct: '6110', name: t('hr.acct6110'), amount: `+${formatAmount(totals.employerCpf, currency)}` },
        { acct: '2400', name: t('hr.acct2400'), amount: `−${formatAmount(totals.employerCpf + totals.employeeCpf, currency)}` },
        { acct: '2200', name: t('hr.acct2200'), amount: `−${formatAmount(totals.other, currency)}` },
        { acct: bankAccount, name: t('finance.bank.' + bankAccount), amount: `−${formatAmount(totals.net, currency)}` },
    ]

    function doPost() {
        setError('')
        startTransition(async () => {
            const res = await postPayroll(periodId)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-3">
            <ConfirmButton
                subject={subject}
                title={t('hr.postConfirm')}
                details={
                    <dl className="divide-y divide-[color:var(--brand-border)] rounded border border-[color:var(--brand-border)]">
                        {postingLines.map((l) => (
                            <div key={l.acct} className="flex items-baseline justify-between gap-4 px-3 py-1.5 text-sm">
                                <dt className="text-muted-foreground">
                                    <span className="font-mono">{l.acct}</span> {l.name}
                                </dt>
                                <dd className="font-mono whitespace-nowrap">{l.amount}</dd>
                            </div>
                        ))}
                    </dl>
                }
                confirmLabel={t('hr.postPayroll')}
                tier="destructive"
                triggerVariant="default"
                disabled={isPending}
                onConfirm={doPost}
            >
                {isPending ? t('common.saving') : t('hr.postPayroll')}
            </ConfirmButton>
            {error && <span className="text-sm text-red-600">{error}</span>}
        </div>
    )
}

export function UnpostPayrollControl({
    periodId,
    subject,
}: {
    periodId: string
    /** CONFIRM-1:撤销的是【哪一个期间】—— 与过账那一侧同一个主语。 */
    subject: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onUnpost(reason: string) {
        setError('')
        startTransition(async () => {
            const res = await unpostPayroll(periodId, reason)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="space-y-2">
            {/* ☞ hr.unpostNote(「分录会被冲销」)【留在页面上】,没有搬进对话框:
                hr.unpostConfirm 本身不说后果,而重写那一句是 COPY-2 的事。
                本刀只给它一个主语。 */}
            <p className="text-xs text-gray-500">{t('hr.unpostNote')}</p>
            <div className="flex flex-wrap items-center gap-2">
                {/* CONFIRM-1:★ 撤销档,不是破坏档 —— 撤销过账冲掉的是分录,
                    原分录与冲销分录都留在账上。理由输入框搬进了对话框,
                    传给 unpostPayroll 的仍是同一个字符串、同一个参数位。 */}
                <ConfirmButton
                    subject={subject}
                    title={t('hr.unpostConfirm')}
                    confirmLabel={t('hr.unpostPayroll')}
                    tier="reversal"
                    reason={{ placeholder: t('hr.unpostReason') }}
                    onConfirm={onUnpost}
                    disabled={isPending}
                    className="border border-red-300 text-red-600 px-3 py-1.5 rounded hover:bg-red-50 text-sm disabled:opacity-50"
                >
                    {t('hr.unpostPayroll')}
                </ConfirmButton>
                {error && <span className="text-sm text-red-600">{error}</span>}
            </div>
        </div>
    )
}
