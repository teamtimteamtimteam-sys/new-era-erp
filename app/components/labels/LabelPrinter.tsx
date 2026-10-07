'use client'

// app/components/labels/LabelPrinter.tsx
// MES-3b(2026-10-07,MES-0 Q40;MES-3b Step 0 Q5–Q10,Tim):打印页的那一块 —— 预览、模板(A6 / A5)、份数、补印理由、打印。
//   ① 预览:页面一打开就画(label_print_preview 的数据 + 选中的模板),什么都不写。换模板只换纸与危险品那一行,不问服务器。
//   ② 打印:先 record_label_print 记下这一次(拒绝在函数里:补印没理由、份数不对……),拿【记下来的那一份】画标签,
//      再在一个不显示的 iframe 里调 print() —— 印出去的与记下来的是同一份数据(Q8)。
//      记下的是"发去打印了":浏览器不告诉页面纸出没出来,这一句写在按钮下面。
//   ③ 二维码在浏览器里生成:短链接 <域名>/b/<批号>(库位 /loc/),域名只有浏览器知道(Q9)。
//   ④ 补印:以前印过(不论哪个模板)→ 理由必填;按钮在理由空着时禁用,并说为什么 —— 服务端也照样按名拒(两道)。
import { useEffect, useRef, useState, useTransition } from 'react'
import QRCode from 'qrcode'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { buildLabelDocument, labelQrUrl } from './labelHtml'
import { printLabel, type LabelContext, type LabelKind, type LabelTemplateInfo } from './actions'

export default function LabelPrinter({ kind, id, initial, templates, locale }: {
    kind: LabelKind
    id: string
    initial: LabelContext
    templates: LabelTemplateInfo[]
    locale: string
}) {
    const t = useTranslations()
    const [ctx, setCtx] = useState<LabelContext>(initial)
    const [tpl, setTpl] = useState(initial.template.code)
    const [copies, setCopies] = useState('1')
    const [reason, setReason] = useState('')
    const [qr, setQr] = useState('')
    const [error, setError] = useState('')
    const [issued, setIssued] = useState<{ no: number; reprint: boolean } | null>(null)
    const [isPending, startTransition] = useTransition()
    const printFrame = useRef<HTMLIFrameElement>(null)

    const template = templates.find((x) => x.code === tpl) ?? ctx.template
    const tplName = (x: LabelTemplateInfo) => (locale === 'zh' ? x.name_zh : x.name_en)

    // 二维码:浏览器里才知道自己的域名
    useEffect(() => {
        let alive = true
        QRCode.toDataURL(labelQrUrl(window.location.origin, ctx.qr_path), { width: 480, margin: 1 })
            .then((u: string) => { if (alive) setQr(u) })
        return () => { alive = false }
    }, [ctx.qr_path])

    const preview = qr ? buildLabelDocument({ data: ctx.data, qrDataUrl: qr, pageSize: template.page_size, showDg: template.show_dg, copies: 1 }) : ''
    const copiesN = Number(copies)
    const copiesOk = copies.trim() !== '' && Number.isInteger(copiesN) && copiesN >= 1
    const blocked = !qr ? t('labels.print.preparing')
        : !copiesOk ? t('labels.print.copiesInvalid')
        : ctx.next_is_reprint && reason.trim() === '' ? t('labels.print.reasonRequired')
        : null

    function go() {
        setError('')
        startTransition(async () => {
            const res = await printLabel(kind, id, tpl, copies, ctx.next_is_reprint ? reason : '')
            if (res.error || !res.ctx) { setError(res.error ?? t('common.errUnexpected', { code: 'label' })); return }
            const done = res.ctx
            const html = buildLabelDocument({ data: done.data, qrDataUrl: qr, pageSize: done.template.page_size,
                                              showDg: done.template.show_dg, copies: done.copies ?? copiesN })
            const f = printFrame.current
            if (f) {
                f.onload = () => { f.contentWindow?.focus(); f.contentWindow?.print() }
                f.srcdoc = html
            }
            setIssued({ no: done.print_no ?? done.prints_so_far, reprint: !!done.is_reprint })
            setCtx({ ...done })
            setReason('')
        })
    }

    const aspect = template.page_size === 'A5' ? '210 / 148' : '148 / 105'
    return (
        <div className="max-w-3xl" data-label-printer={kind}>
            <div className="flex flex-wrap items-end gap-3 mb-3">
                <div>
                    <label className="block mb-1">{t('labels.print.template')}</label>
                    <select value={tpl} onChange={(e) => setTpl(e.target.value)} className={CONTROL_SELECT} data-label-template>
                        {templates.map((x) => <option key={x.code} value={x.code}>{tplName(x)}</option>)}
                    </select>
                </div>
                <div className="w-28">
                    <label className="block mb-1">{t('labels.print.copies')}</label>
                    <input type="number" min="1" step="1" inputMode="numeric" value={copies}
                           onChange={(e) => setCopies(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                </div>
            </div>
            {ctx.next_is_reprint && (
                <div className="mb-3">
                    <label className="block mb-1">{t('labels.print.reason')}</label>
                    <textarea value={reason} onChange={(e) => setReason(e.target.value)} rows={2}
                              className={`${CONTROL_INPUT} w-full`} data-label-reason />
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                        {t('labels.print.reprintNotice', { n: String(ctx.prints_so_far) })}
                    </p>
                </div>
            )}
            {ctx.data.kind !== 'storage_location' && ctx.data.dg_missing && template.show_dg && (
                <p className="text-sm text-amber-700 mb-2" data-label-dg-missing>{t('labels.print.dgMissing')}</p>
            )}
            {error && <p className="text-sm text-red-600 mb-2" role="alert">{error}</p>}
            <div className="flex flex-wrap items-center gap-3 mb-1">
                <Button type="button" onClick={go} disabled={isPending || blocked !== null} data-label-print-button>
                    {isPending ? t('labels.print.recording') : ctx.next_is_reprint ? t('labels.print.reprintAction') : t('labels.print.action')}
                </Button>
                {issued && (
                    <span className="text-sm" data-label-issued={issued.no}>
                        {issued.reprint ? t('labels.print.issuedReprint', { n: String(issued.no) }) : t('labels.print.issued', { n: String(issued.no) })}
                    </span>
                )}
            </div>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-4">{blocked ?? t('labels.print.consequence')}</p>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-1">
                {t('labels.print.previewTitle', { size: template.page_size })}
            </p>
            <div className="w-full max-w-xl border border-gray-200 bg-gray-50" style={{ aspectRatio: aspect }}>
                {preview && (
                    <iframe title={t('labels.print.previewTitle', { size: template.page_size })} srcDoc={preview}
                            className="w-full h-full" data-label-preview={template.page_size}
                            onLoad={(e) => {
                                // 预览缩到框里(A5 在手机上也看得全);打印用的那一份不缩 —— 它按 @page 的毫米印
                                const f = e.currentTarget
                                const d = f.contentDocument
                                const el = d?.querySelector('.label') as HTMLElement | null
                                if (d && el) d.body.style.setProperty('zoom', String(Math.min(1, f.clientWidth / (el.offsetWidth + 24))))
                            }} />
                )}
            </div>
            {/* 打印用的那一份:屏幕外、零尺寸(不是 display:none —— 有的浏览器不肯打印一个不显示的框),记下来之后才写进去、才打印 */}
            <iframe ref={printFrame} title="print" aria-hidden="true" tabIndex={-1}
                    style={{ position: 'fixed', right: 0, bottom: 0, width: 0, height: 0, border: 0 }} />
        </div>
    )
}
