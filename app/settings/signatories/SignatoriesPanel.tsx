'use client'

// CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 Q3 · Q7):设置 · 合同签署人的浏览器那一半 —— 名单(加 · 移出)与公司印章(上传一张新的)。
//   拒绝由库出、就地说成人话;移出要确认(它不作废这个人签过的,Q7 —— 确认框里照直说)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { Input } from '@/app/components/ui/input'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/app/components/ui/select'
import { addSignatory, removeSignatory, uploadCompanyStamp } from './actions'

export type SignatoryView = { id: string; name: string; code: string; title: string; hasSpecimen: boolean; addedLine: string; removedLine: string | null }
export type EmployeeOption = { id: string; label: string }
export type StampView = { id: string; current: boolean; sha256: string; line: string }

export default function SignatoriesPanel({ active, removed, candidates, stampUri, stamps }: {
    active: SignatoryView[]; removed: SignatoryView[]; candidates: EmployeeOption[]; stampUri: string | null; stamps: StampView[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [employee, setEmployee] = useState('')
    const [title, setTitle] = useState('')
    const [stampFile, setStampFile] = useState<File | null>(null)

    function run(subject: string, headline: string, fn: () => Promise<{ error?: string; detail?: string }>, after?: () => void) {
        start(async () => {
            const r = await fn()
            if (r?.error) {
                showActionMessage({ subject, headline, body: r.error, detail: r.detail })
                return
            }
            after?.()
            router.refresh()
        })
    }

    return (
        <div className="space-y-8">
            <section className="space-y-3" aria-label={t('signatories.listTitle')}>
                <h2 className="mb-1">{t('signatories.listTitle')}</h2>
                {active.length === 0 ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]" data-signatories-empty="1">{t('signatories.none')}</p>
                ) : (
                    <ul className="divide-y divide-[color:var(--brand-border)] border-y border-[color:var(--brand-border)]">
                        {active.map((s) => (
                            <li key={s.id} className="py-3 flex flex-wrap items-center gap-x-4 gap-y-1" data-signatory={s.code}>
                                <span className="font-medium">{s.name}</span>
                                <span className="text-sm font-mono">{s.code}</span>
                                <span className="text-sm">{s.title}</span>
                                <span className={s.hasSpecimen ? 'text-sm' : 'text-sm font-medium text-amber-900'}>
                                    {s.hasSpecimen ? t('signatories.hasSpecimen') : t('signatories.noSpecimen')}
                                </span>
                                <span className="text-xs text-[color:var(--brand-muted-text)] w-full">{s.addedLine}</span>
                                <ConfirmButton
                                    subject={s.name}
                                    title={t('signatories.removeConfirm')}
                                    body={t('signatories.removeBody')}
                                    confirmLabel={t('signatories.remove')}
                                    tier="reversal"
                                    triggerVariant="outline"
                                    disabled={pending}
                                    onConfirm={() => run(s.name, t('signatories.notChanged'), () => removeSignatory(s.id))}
                                >
                                    {t('signatories.remove')}
                                </ConfirmButton>
                            </li>
                        ))}
                    </ul>
                )}

                <div className="space-y-2 max-w-xl" data-signatory-add="1">
                    <p className="text-sm font-medium">{t('signatories.addTitle')}</p>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('signatories.addHint')}</p>
                    <div className="flex flex-wrap items-end gap-2">
                        <div className="min-w-0 flex-1 basis-64">
                            <Select value={employee} onValueChange={setEmployee}>
                                <SelectTrigger aria-label={t('signatories.employee')} className="w-full max-w-full" data-signatory-employee="1">
                                    <SelectValue placeholder={t('signatories.employeePlaceholder')} />
                                </SelectTrigger>
                                <SelectContent>
                                    {candidates.map((e) => <SelectItem key={e.id} value={e.id}>{e.label}</SelectItem>)}
                                </SelectContent>
                            </Select>
                        </div>
                        <div className="min-w-0 flex-1 basis-48">
                            <Input aria-label={t('signatories.jobTitle')} placeholder={t('signatories.jobTitlePlaceholder')} value={title}
                                   onChange={(e) => setTitle(e.currentTarget.value)} data-signatory-title="1" />
                        </div>
                        <Button type="button" disabled={pending || !employee || !title.trim()} data-signatory-add-button="1"
                                onClick={() => run(t('signatories.addTitle'), t('signatories.notChanged'), () => addSignatory(employee, title),
                                                   () => { setEmployee(''); setTitle('') })}>
                            {t('signatories.add')}
                        </Button>
                    </div>
                    {candidates.length === 0 && <p className="text-xs text-[color:var(--brand-muted-text)]">{t('signatories.noCandidates')}</p>}
                </div>

                {removed.length > 0 && (
                    <details className="text-sm">
                        <summary className="cursor-pointer">{t('signatories.removedTitle', { n: removed.length })}</summary>
                        <ul className="mt-2 space-y-1">
                            {removed.map((s) => (
                                <li key={s.id} className="text-[color:var(--brand-muted-text)]">
                                    {s.name} ({s.code}) · {s.title} · {s.addedLine} · {s.removedLine}
                                </li>
                            ))}
                        </ul>
                    </details>
                )}
            </section>

            <section className="space-y-3" aria-label={t('signatories.stampTitle')}>
                <h2 className="mb-1">{t('signatories.stampTitle')}</h2>
                <p className="text-sm text-[color:var(--brand-muted-text)] max-w-3xl">{t('signatories.stampIntro')}</p>
                {stampUri ? (
                    // eslint-disable-next-line @next/next/no-img-element -- 随页面送来的 data: 图
                    <img src={stampUri} alt={t('signatories.stampAlt')} className="h-32 w-32 object-contain border border-[color:var(--brand-border)] bg-white p-1" data-stamp-current="1" />
                ) : (
                    <p className="text-sm font-medium" data-stamp-none="1">{t('signatories.noStamp')}</p>
                )}
                <div className="flex flex-wrap items-center gap-2">
                    <input type="file" accept="image/png,image/jpeg" className="text-sm max-w-full" data-stamp-input="1"
                           onChange={(e) => setStampFile(e.currentTarget.files?.[0] ?? null)} />
                    <Button type="button" variant="outline" disabled={pending || !stampFile} data-stamp-upload="1"
                            onClick={() => {
                                const fd = new FormData()
                                if (stampFile) fd.set('stamp', stampFile)
                                run(t('signatories.stampTitle'), t('signatories.stampNotChanged'), () => uploadCompanyStamp(fd), () => setStampFile(null))
                            }}>
                        {stampUri ? t('signatories.stampReplace') : t('signatories.stampUpload')}
                    </Button>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('signatories.stampHint')}</p>
                {stamps.length > 0 && (
                    <ul className="space-y-1 text-xs text-[color:var(--brand-muted-text)]">
                        {stamps.map((s) => (
                            <li key={s.id}>
                                {s.current ? t('signatories.stampCurrent') : t('signatories.stampReplaced')} · {s.line} ·{' '}
                                <span className="font-mono break-all">{s.sha256}</span>
                            </li>
                        ))}
                    </ul>
                )}
            </section>
        </div>
    )
}
