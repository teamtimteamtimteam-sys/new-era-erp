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
// 【两个日期都不给默认值】投用日决定折旧起点,处置日决定分录落在哪个期间 ——
// 补一个今天,会让一次本该 PERIOD_LOCKED 的处置悄悄落进开着的月份(FIN-10)。
// 空着就禁钮,并在旁边说出来;服务端也各自独立拒空。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { disposeAsset, commissionAsset } from '../month-end/actions'

export default function AssetActions({
    assetId, code, status, inServiceDate, acquisitionDate, canEdit, bankAccounts,
}: {
    assetId: string; code: string; status: string
    inServiceDate: string | null; acquisitionDate: string
    canEdit: boolean; bankAccounts: string[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [open, setOpen] = useState<'' | 'commission' | 'dispose'>('')
    const [inSvc, setInSvc] = useState('')
    const [dispDate, setDispDate] = useState('')
    const [proceeds, setProceeds] = useState('0')
    const [bank, setBank] = useState('')

    const disposed = status === 'disposed'
    // 每个动作:能不能做,以及【为什么不能】—— 两者一起算,免得有分支只画了禁用
    const commissionWhy = !canEdit ? t('assets.needsFinanceEdit')
        : disposed ? t('assets.blocked.commissionDisposed')
        : inServiceDate ? t('assets.blocked.alreadyInService', { date: inServiceDate })
        : ''
    const disposeWhy = !canEdit ? t('assets.needsFinanceEdit')
        : disposed ? t('assets.blocked.alreadyDisposed')
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
                <button type="button" disabled={pending || commissionWhy !== ''}
                        onClick={() => setOpen(open === 'commission' ? '' : 'commission')}
                        className="border border-gray-400 px-2 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                    {t('assets.actions.commission')}
                </button>
                <button type="button" disabled={pending || disposeWhy !== ''}
                        onClick={() => setOpen(open === 'dispose' ? '' : 'dispose')}
                        className="border border-gray-400 px-2 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                    {t('assets.actions.dispose')}
                </button>
            </div>
            {/* 【禁用了就说为什么】两个动作各说各的 */}
            {commissionWhy && <p className="text-xs text-amber-700 mt-1">{commissionWhy}</p>}
            {disposeWhy && disposeWhy !== commissionWhy && (
                <p className="text-xs text-amber-700 mt-1">{disposeWhy}</p>
            )}

            {open === 'commission' && (
                <div className="mt-2 border border-gray-300 rounded p-2 space-y-1">
                    <p className="text-xs text-gray-500">{t('assets.actions.commissionWhy')}</p>
                    <input type="date" value={inSvc} min={acquisitionDate}
                           onChange={(e) => setInSvc(e.target.value)}
                           className="border border-gray-300 px-2 py-1 rounded text-xs" />
                    <button type="button" disabled={pending || inSvc.trim() === ''}
                            onClick={() => run(() => commissionAsset(assetId, inSvc))}
                            className="ml-2 bg-gray-900 text-white px-2 py-1 rounded text-xs disabled:opacity-50">
                        {pending ? t('common.saving') : t('assets.actions.commissionConfirm', { code })}
                    </button>
                    {inSvc.trim() === '' && (
                        <p className="text-xs text-amber-700">{t('assets.actions.inServiceRequired')}</p>
                    )}
                </div>
            )}

            {open === 'dispose' && (
                <div className="mt-2 border border-gray-300 rounded p-2 space-y-1">
                    <p className="text-xs text-gray-500">{t('assets.actions.disposeWhy')}</p>
                    <div className="flex flex-wrap items-center gap-2">
                        <input type="date" value={dispDate} min={acquisitionDate}
                               onChange={(e) => setDispDate(e.target.value)}
                               className="border border-gray-300 px-2 py-1 rounded text-xs" />
                        <input type="number" step="any" min="0" value={proceeds}
                               onChange={(e) => setProceeds(e.target.value)}
                               className="w-28 border border-gray-300 px-2 py-1 rounded text-xs text-right"
                               placeholder={t('assets.actions.proceeds')} />
                        {/* 【有价款才要收款账户】报废(价款 0)不该逼人挑一个银行账户 */}
                        {Number(proceeds) > 0 && (
                            <select value={bank} onChange={(e) => setBank(e.target.value)}
                                    className="border border-gray-300 px-2 py-1 rounded text-xs">
                                <option value="">{t('assets.actions.selectBank')}</option>
                                {bankAccounts.map((b) => <option key={b} value={b}>{b}</option>)}
                            </select>
                        )}
                        <button type="button"
                                disabled={pending || dispDate.trim() === ''
                                          || (Number(proceeds) > 0 && bank === '')}
                                onClick={() => run(() => disposeAsset(
                                    assetId, dispDate, Number(proceeds) || 0,
                                    Number(proceeds) > 0 ? bank : null))}
                                className="bg-gray-900 text-white px-2 py-1 rounded text-xs disabled:opacity-50">
                            {pending ? t('common.saving') : t('assets.actions.disposeConfirm', { code })}
                        </button>
                    </div>
                    {dispDate.trim() === '' && (
                        <p className="text-xs text-amber-700">{t('assets.actions.disposalDateRequired')}</p>
                    )}
                    {Number(proceeds) > 0 && bank === '' && (
                        <p className="text-xs text-amber-700">{t('assets.actions.bankRequired')}</p>
                    )}
                </div>
            )}
        </div>
    )
}
