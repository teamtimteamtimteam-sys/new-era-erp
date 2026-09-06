'use client'

// CMPL-1:进口尽调面板。
//
// ★★【三个状态必须【长得不一样】,而空白【不等于】"不是进口货"】★★
//   · 还没有人说   → 琥珀色,一句"还没有人说过这批是不是进口的"
//   · 明确不是进口 → 灰色,一句陈述
//   · 是进口、未核 → 红色,点名【还欠一次人工核对】(看板上同时有一支告警)
//   · 是进口、已核 → 绿色,说出【谁核的、什么时候核的、核的是哪张准证】
//   一个空白与一个"不是"在屏幕上长得一样,正是本仓库反复付账的那种沉默。

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { saveImportDiligence } from './importDiligenceActions'
import { Button } from '@/app/components/ui/button'

export default function ImportDiligencePanel({
    batchId, imported, permitRef, verifiedAt, canEdit,
}: {
    batchId: string
    imported: boolean | null
    permitRef: string | null
    verifiedAt: string | null
    canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [sel, setSel] = useState<'unknown' | 'no' | 'yes'>(
        imported === null ? 'unknown' : imported ? 'yes' : 'no')
    const [ref, setRef] = useState(permitRef ?? '')
    const [verified, setVerified] = useState(verifiedAt !== null)
    const [error, setError] = useState<string | null>(null)
    const [saving, setSaving] = useState(false)

    async function onSave() {
        setSaving(true); setError(null)
        const res = await saveImportDiligence(batchId, sel, ref, verified)
        setSaving(false)
        if (res.error) { setError(res.error); return }
        router.refresh()
    }

    // ★ 当前状态那一句 —— 四种,各自不同 ★
    const state =
        imported === null ? 'unstated'
        : imported === false ? 'notImported'
        : verifiedAt === null ? 'unverified'
        : 'verified'
    const tone =
        state === 'unstated' ? 'bg-amber-50 border-amber-300 text-amber-900'
        : state === 'notImported' ? 'bg-gray-50 border-gray-300 text-gray-800'
        : state === 'unverified' ? 'bg-red-50 border-red-300 text-red-900'
        : 'bg-green-50 border-green-300 text-green-900'

    return (
        <div className="mb-8">
            <h2 className="text-sm font-medium text-gray-700 mb-2">{t('inbound.importDiligence.title')}</h2>
            <div className="border border-gray-300 rounded p-3 max-w-2xl">
                <p className="text-xs text-gray-600 mb-2">{t('inbound.importDiligence.what')}</p>

                <p className={'text-sm mb-3 px-2 py-1 rounded border ' + tone}>
                    {/* 【显式四选一,不用字符串拼键】拼出来的键 check-i18n 只能靠
                        MANIFEST 归类,而这里的四种是写死的,列出来更直白也更好查。 */}
                    {state === 'verified'
                        ? t('inbound.importDiligence.stateVerified', { at: verifiedAt ?? '', ref: permitRef ?? '' })
                        : state === 'unverified'
                          ? t('inbound.importDiligence.stateUnverified')
                          : state === 'notImported'
                            ? t('inbound.importDiligence.stateNotImported')
                            : t('inbound.importDiligence.stateUnstated')}
                </p>

                {/* 【为什么这里只提醒不拦】—— 说在人看得见的地方,不只写在函数抬头 */}
                <p className="text-xs text-gray-600 mb-3">{t('inbound.importDiligence.whyWarnOnly')}</p>

                {canEdit && (
                    <div className="space-y-2">
                        <div>
                            <label className="block text-xs font-medium text-gray-600 mb-1" htmlFor="imp">
                                {t('inbound.importDiligence.fieldImported')}
                            </label>
                            <select id="imp" className="border border-gray-300 rounded px-2 py-1 text-sm"
                                    value={sel} onChange={(e) => setSel(e.target.value as 'unknown' | 'no' | 'yes')}>
                                <option value="unknown">{t('inbound.importDiligence.optUnstated')}</option>
                                <option value="no">{t('inbound.importDiligence.optNo')}</option>
                                <option value="yes">{t('inbound.importDiligence.optYes')}</option>
                            </select>
                        </div>
                        {sel === 'yes' && (
                            <>
                                <div>
                                    <label className="block text-xs font-medium text-gray-600 mb-1" htmlFor="ref">
                                        {t('inbound.importDiligence.fieldPermitRef')}
                                    </label>
                                    <input id="ref" className="border border-gray-300 rounded px-2 py-1 text-sm w-full"
                                           value={ref} onChange={(e) => setRef(e.target.value)} />
                                </div>
                                <label className="flex items-center gap-2 text-sm">
                                    <input type="checkbox" checked={verified}
                                           onChange={(e) => setVerified(e.target.checked)} />
                                    {t('inbound.importDiligence.fieldVerified')}
                                </label>
                            </>
                        )}
                        {error ? <p className="text-sm text-red-700">{error}</p> : null}
                        <Button size="sm" type="button" onClick={onSave} disabled={saving}>
                            {t('inbound.importDiligence.save')}
                        </Button>
                    </div>
                )}
            </div>
        </div>
    )
}
