'use client'

// COD-1:销毁证书面板 —— 它住在【进料批】页上,因为证书的主体就是这一票货。
//
// ★【四种状态必须长得不一样,而"还不能签发"永远带着【为什么】】★
//   · 还不能签发 —— 琥珀。判据说不成立,而它的具名理由原样显示:
//                   "还没整批加工完" 与 "这票货被注销了" 是两件事。
//   · 可以签发   —— 灰。已经成立、还没寄出;【没有编号】。
//   · 已签发     —— 绿。编号、签发日、核验网址。
//   · 已作废     —— 红。编号仍然在(供应商手里那张纸要查得到),外加作废理由。
//
// 【内部存档那个链接在四种状态里都在】—— 存档是内部的事,永远不因缺执照被拒。
//
// ★ APR-7(Tim 2026-09-25):作废是【一张给 CFO 的申请】,批准之前什么都不发生 —— 公开核验页照旧说"有效",
//   那是真的。签发不变(仓库,不经批准:资格由系统算)。一张在等的申请碰到这张证书时(作废它的,或回滚、
//   注销那票货的),作废钮看得见、按不动、说出是哪一张在等。
import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import WarehouseRequestButton from '@/app/components/inventory/WarehouseRequestButton'

export type CertificatePanelData = {
    codId: string | null
    code: string | null
    status: 'pending' | 'issued' | 'void' | null
    issuedAt: string | null
    completedOn: string | null
    verificationToken: string | null
    voidReason: string | null
    /** 判据说不成立时,它自己那句具名理由(已本地化);成立时为 null。 */
    blockedBecause: string | null
}

export default function CertificatePanel({
    batchId, data, canIssue, openRequestLabel,
}: {
    batchId: string
    data: CertificatePanelData
    canIssue: boolean
    /** APR-7:碰到这张证书(或这票货)的那一张在等的仓库申请 */
    openRequestLabel?: string | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [busy, setBusy] = useState(false)
    const [error, setError] = useState<string | null>(null)

    // 【没有这条能力就整块不画】—— 与本页其他跨模块面板同一条处置。
    if (!canIssue) return null

    const state = data.status ?? 'blocked'
    const tone =
        state === 'issued' ? 'bg-green-50 border-green-300 text-green-900'
        : state === 'void' ? 'bg-red-50 border-red-300 text-red-900'
        : state === 'pending' ? 'bg-gray-50 border-gray-300 text-gray-800'
        : 'bg-amber-50 border-amber-300 text-amber-900'

    async function onIssue() {
        setBusy(true); setError(null)
        // 签发走路由的 POST:它铸号、渲染、存桶、记档,四件事一条路。
        const res = await fetch(`/inbound/${batchId}/cod/pdf`, { method: 'POST' })
        setBusy(false)
        if (!res.ok) { setError(await res.text()); return }
        router.refresh()
    }

    return (
        <section className="mt-8">
            <h2 className="mb-1">{t('cod.title')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('cod.intro')}</p>

            <div className={`rounded border p-4 ${tone}`}>
                {state === 'blocked' && (
                    <p className="text-sm">
                        <span className="font-medium">{t('cod.notReady')}</span>
                        {data.blockedBecause ? ` — ${data.blockedBecause}` : ''}
                    </p>
                )}

                {state === 'pending' && (
                    <p className="text-sm font-medium">{t('cod.statusPending')}</p>
                )}

                {(state === 'issued' || state === 'void') && (
                    <dl className="text-sm space-y-1">
                        <div className="flex gap-2">
                            <dt className="w-40 opacity-70">{t('cod.number')}</dt>
                            <dd className="font-medium">{data.code}</dd>
                        </div>
                        <div className="flex gap-2">
                            <dt className="w-40 opacity-70">{t('cod.issuedOn')}</dt>
                            <dd>{data.issuedAt?.slice(0, 10) ?? '—'}</dd>
                        </div>
                        {data.verificationToken && (
                            <div className="flex gap-2">
                                <dt className="w-40 opacity-70">{t('cod.verifyUrl')}</dt>
                                {/* 【核验页是后一刀的事】—— 这里只把网址显示出来,
                                    不做成链接:一个指向 404 的链接比一段文字更坏。 */}
                                <dd className="break-all text-xs text-[color:var(--brand-muted-text)]">
                                    /verify/cod/{data.verificationToken}
                                </dd>
                            </div>
                        )}
                        {state === 'void' && data.voidReason && (
                            <div className="flex gap-2">
                                <dt className="w-40 opacity-70">{t('cod.statusVoid')}</dt>
                                <dd>{data.voidReason}</dd>
                            </div>
                        )}
                    </dl>
                )}

                {data.completedOn && (
                    <p className="text-xs mt-2 opacity-70 text-[color:var(--brand-muted-text)]">
                        {t('cod.completedOn')}: {data.completedOn}
                    </p>
                )}

                <div className="mt-4 flex flex-wrap gap-3 items-center">
                    {/* ★【签发之后,这里给的是【存档的那份字节】,不是当场重画的一份】★
                        头一版两个链接都在,标签还一样 —— 而它们是两份不同的东西:
                        一份是照【现在】的数据重画的,一份是【当时寄出去】的那些字节。
                        寄出去的那一份才是证书。所以签发之后只留 ?cod= 那一条,
                        它会对着 sha256 校验,对不上就拒绝。 */}
                    {(state === 'issued' || state === 'void') && data.code ? (
                        <a
                            className="text-sm underline"
                            href={`/inbound/${batchId}/cod/pdf?cod=${encodeURIComponent(data.code)}`}
                            target="_blank" rel="noopener noreferrer"
                        >
                            {t('cod.openIssued')}
                        </a>
                    ) : (
                        <a
                            className="text-sm underline"
                            href={`/inbound/${batchId}/cod/pdf`}
                            target="_blank" rel="noopener noreferrer"
                        >
                            {t('cod.internalExport')}
                        </a>
                    )}

                    {state === 'pending' && (
                        <Button onClick={onIssue} disabled={busy}>
                            {t('cod.issueButton')}
                        </Button>
                    )}

                    {state === 'issued' && data.codId && (
                        <WarehouseRequestButton kind="cod_void" subjectId={data.codId} subjectCode={data.code ?? ''}
                            permissionCode="action.issue_cod" allowed={canIssue}
                            openRequestLabel={openRequestLabel} extraPath={`/inbound/${batchId}/edit`} size="default" />
                    )}
                </div>

                {state === 'pending' && (
                    <p className="text-xs mt-2 opacity-70 text-[color:var(--brand-muted-text)]">{t('cod.issueHint')}</p>
                )}
                {state === 'blocked' && (
                    <p className="text-xs mt-2 opacity-70 text-[color:var(--brand-muted-text)]">{t('cod.internalExportHint')}</p>
                )}

                {error && <p className="mt-3 text-sm text-red-700 whitespace-pre-line">{error}</p>}
            </div>
        </section>
    )
}
