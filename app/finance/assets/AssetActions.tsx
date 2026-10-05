'use client'

// FA-1b:一台资产的两个动作 —— 投用与处置。
//
// 【引擎早就有,屏幕一直没有】dispose_fixed_asset 从 FIN-22 起就在,而 FA-0 的
// 调查发现它【在 app 里一个调用点都没有】:第一台机器卖掉或报废,只能有人去写
// SQL。这就是这个仓库记过三次的那个形状(引擎齐了、页面没有),第四次。
//
// 【每一个禁用都把理由摆在旁边】(CMP-2)—— 一个按不下去又不说为什么的按钮,
// 读起来像是坏了。已处置的资产两个动作都关掉,而且各说各的理由。
//
// 【投用日不给默认值】它决定折旧起点(FIN-10);空着就禁钮,并在旁边说出来;服务端也独立拒空。
//
// ★ APR-9(Tim 2026-09-27,grilling Q7):**处置从此是一张申请,CFO 批准当场处置。** 表单上【没有日期框了】——
//   处置日就是批准那一天,由库定,不是提单人挑的(所以期间锁永远咬不到一张在等的处置)。提单人给的是
//   收款、银行科目与理由,提交时冻结;提交时按批准那一刻的同一条路试跑一遍,估算的损益交给 CFO 看。
//   已有一张在等的 → 处置钮按不动,并指向那一张(资产页顶上那一块,#adr-<id>)。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { commissionAsset } from '../month-end/actions'
import { submitDisposalRequest } from './disposalRequestActions'
import { setPlannedInService } from './[id]/actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'

export default function AssetActions({
    assetId, code, status, inServiceDate, plannedInServiceDate, acquisitionDate, hasCost, canEdit, bankAccounts,
    pendingDisposalLabel,
}: {
    assetId: string; code: string; status: string
    inServiceDate: string | null; plannedInServiceDate: string | null; acquisitionDate: string
    // FIX-2(D):「还没有成本」此前只说在页面那份清单里，而清单已经去掉了 ——
    // 三条理由从此在【按钮旁边】一处说完。
    hasCost: boolean
    canEdit: boolean; bankAccounts: string[]
    /** APR-9:这台资产上那一张在等的处置申请的 label;没有就是 null */
    pendingDisposalLabel: string | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [open, setOpen] = useState<'' | 'commission' | 'dispose' | 'plan'>('')
    const [plan, setPlan] = useState(plannedInServiceDate ?? '')
    const [inSvc, setInSvc] = useState('')
    // DATE-PICK-1:两个面板都靠按钮 onClick 提交,不走原生表单 —— 框里是一个敲错的日子时把按钮关掉
    const [planBad, setPlanBad] = useState(false)
    const [inSvcBad, setInSvcBad] = useState(false)
    const [dispReason, setDispReason] = useState('')
    const [proceeds, setProceeds] = useState('0')
    const [bank, setBank] = useState('')

    const disposed = status === 'disposed'
    // 每个动作:能不能做,以及【为什么不能】—— 两者一起算,免得有分支只画了禁用
    // FIX-2(D):三条理由一处说完,顺序 = 先权限、再终态、再业务前提。
    const commissionWhy = !canEdit ? t('assets.needsFinanceEdit')
        : disposed ? t('assets.blocked.commissionDisposed')
        : inServiceDate ? t('assets.blocked.alreadyInService', { date: inServiceDate })
        : !hasCost ? t('assets.blocked.commissionNoCost')
        : ''
    const disposeWhy = !canEdit ? t('assets.needsFinanceEdit')
        : disposed ? t('assets.blocked.alreadyDisposed')
        : pendingDisposalLabel ? t('assets.blocked.disposalRequested', { label: pendingDisposalLabel })
        : ''

    function run(fn: () => Promise<{ error?: string }>) {
        setError(null)
        start(async () => {
            const r = await fn()
            if (r.error) { setError(r.error); return }
            setOpen(''); router.refresh()
        })
    }

    return (
        <div className="text-sm">
            {error && <p className="text-red-600 text-xs mb-1">{error}</p>}

            <div className="flex flex-wrap items-center gap-2">
                <Button variant="secondary" size="xs" type="button" disabled={pending || commissionWhy !== ''}
                        aria-expanded={open === 'commission'}
                        onClick={() => setOpen(open === 'commission' ? '' : 'commission')}>
                    {t('assets.actions.commission')}
                </Button>
                <Button variant="secondary" size="xs" type="button" disabled={pending || disposeWhy !== ''}
                        aria-expanded={open === 'dispose'}
                        onClick={() => setOpen(open === 'dispose' ? '' : 'dispose')}>
                    {t('assets.actions.dispose')}
                </Button>
                {/* FIX-1:记一个【计划】投用日。
                    没有这扇门,"那是计划投用日"那句拒绝就是一条死路(D6:拒绝要说去哪儿)。
                    它【永远可点】—— 计划与在不在役无关,已投用的机器也可能有下一次计划。 */}
                {/* ★★ ALERT-2d ④(b):`pending || !canEdit` —— 一个【一秒后自己消失】的
                       瞬态,和一个【不会自己消失】的权限答复,挤在同一个 disabled 里。
                       CMP-2 的房规只要求**非瞬态**条件配一行常驻的解释,而这个钮
                       两样都没有:旁边那两句 why 是给投用/处置写的,这一个一句都没有。
                       ☞ 瞬态留在 disabled(它一秒后自己好),权限交给 <PermissionGate>
                         —— 看得见、按不动、点名 module.finance.edit。
                       ☞ 上面那两个钮【不动】:它们的 commissionWhy / disposeWhy 已经
                         按【先权限、再终态、再业务前提】逐支给出了不同的话,
                         那正是这一刀在别处装的东西。 */}
                <PermissionGate code="module.finance.edit" allowed={canEdit} inline>
                    <Button type="button" disabled={pending}
                            aria-expanded={open === 'plan'}
                            onClick={() => setOpen(open === 'plan' ? '' : 'plan')}
                            variant="secondary" size="xs">
                        {t('assets.actions.plan')}
                    </Button>
                </PermissionGate>
            </div>
            {/* 【禁用了就说为什么】两个动作各说各的 */}
            {commissionWhy && <p className="text-xs text-amber-700 mt-1">{commissionWhy}</p>}
            {disposeWhy && disposeWhy !== commissionWhy && (
                <p className="text-xs text-amber-700 mt-1">{disposeWhy}</p>
            )}

            {open === 'commission' && (
                <div className="mt-2 border border-gray-300 rounded p-2 space-y-1">
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('assets.actions.commissionWhy')}</p>
                    <DatePicker value={inSvc} min={acquisitionDate}
                                onChange={setInSvc} onInvalidChange={setInSvcBad} />
                    <Button type="button" disabled={pending || inSvc.trim() === '' || inSvcBad}
                            onClick={() => run(() => commissionAsset(assetId, inSvc))}
                            variant="default" size="xs" className="ml-2">
                        {pending ? t('common.saving') : t('assets.actions.commissionConfirm', { code })}
                    </Button>
                    {inSvc.trim() === '' && (
                        <p className="text-xs text-amber-700">{t('assets.actions.inServiceRequired')}</p>
                    )}
                </div>
            )}

            {open === 'plan' && (
                <div className="mt-2 border border-gray-300 rounded p-2 space-y-1">
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('assets.plannedHint')}</p>
                    <DatePicker value={plan} onChange={setPlan} onInvalidChange={setPlanBad} />
                    <Button type="button" disabled={pending || planBad}
                            onClick={() => run(() => setPlannedInService({ assetId, plannedDate: plan }))}
                            variant="default" size="xs" className="ml-2">
                        {pending ? t('common.saving') : t('common.save')}
                    </Button>
                    {/* 【留空 = 撤掉这个计划】计划会变,撤回它是正当的动作 */}
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('assets.actions.planClear')}</p>
                </div>
            )}

            {open === 'dispose' && (
                <div className="mt-2 border border-gray-300 rounded p-2 space-y-1">
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('assets.actions.disposeWhy')}</p>
                    <div className="flex flex-wrap items-center gap-2">
                        <input type="number" step="any" min="0" value={proceeds}
                               onChange={(e) => setProceeds(e.target.value)}
                               className={`${CONTROL_INPUT} w-28 text-right tabular-nums`}
                               placeholder={t('assets.actions.proceeds')} />
                        {/* 【有价款才要收款账户】报废(价款 0)不该逼人挑一个银行账户 */}
                        {Number(proceeds) > 0 && (
                            <select value={bank} onChange={(e) => setBank(e.target.value)}
                                    className={CONTROL_SELECT}>
                                <option value="">{t('assets.actions.selectBank')}</option>
                                {bankAccounts.map((b) => <option key={b} value={b}>{b}</option>)}
                            </select>
                        )}
                        <input type="text" value={dispReason}
                               onChange={(e) => setDispReason(e.target.value)}
                               className={`${CONTROL_INPUT} grow min-w-0`}
                               placeholder={t('assets.actions.disposeReason')} />
                        <Button size="xs" type="button"
                                disabled={pending || dispReason.trim() === ''
                                          || (Number(proceeds) > 0 && bank === '')}
                                onClick={() => run(() => submitDisposalRequest(
                                    assetId, Number(proceeds) || 0,
                                    Number(proceeds) > 0 ? bank : null, dispReason))}>
                            {pending ? t('common.saving') : t('assets.actions.disposeConfirm', { code })}
                        </Button>
                    </div>
                    {dispReason.trim() === '' && (
                        <p className="text-xs text-amber-700">{t('assets.actions.disposeReasonRequired')}</p>
                    )}
                    {Number(proceeds) > 0 && bank === '' && (
                        <p className="text-xs text-amber-700">{t('assets.actions.bankRequired')}</p>
                    )}
                </div>
            )}
        </div>
    )
}
