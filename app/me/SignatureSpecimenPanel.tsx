'use client'

// CONTRACT-ESIGN(Tim 2026-10-30 Q4):/me 上「我的签名」—— 只给签署人名单上的人。在框里画一次自己的签名(手指、笔或鼠标),存下;
//   签合同时盖上去的就是这一张。换一张时旧的留在历史里。admin 替别人设不了 —— 这一块只画给本人。
import { useEffect, useRef, useState } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { showActionMessage } from '@/app/components/ui/action-message'
import { saveSignatureSpecimen } from './signatureActions'

export default function SignatureSpecimenPanel({ currentUri, title }: { currentUri: string | null; title: string }) {
    const t = useTranslations()
    const router = useRouter()
    const ref = useRef<HTMLCanvasElement | null>(null)
    const drawing = useRef(false)
    const [dirty, setDirty] = useState(false)
    const [busy, setBusy] = useState(false)

    useEffect(() => {
        const c = ref.current
        if (!c) return
        const ratio = window.devicePixelRatio || 1
        c.width = c.clientWidth * ratio
        c.height = c.clientHeight * ratio
        const ctx = c.getContext('2d')
        if (!ctx) return
        ctx.scale(ratio, ratio)
        ctx.lineWidth = 2.5
        ctx.lineCap = 'round'
        ctx.lineJoin = 'round'
        ctx.strokeStyle = '#111827'
    }, [])

    const at = (e: React.PointerEvent<HTMLCanvasElement>) => {
        const r = e.currentTarget.getBoundingClientRect()
        return { x: e.clientX - r.left, y: e.clientY - r.top }
    }
    function down(e: React.PointerEvent<HTMLCanvasElement>) {
        const ctx = e.currentTarget.getContext('2d')
        if (!ctx) return
        e.currentTarget.setPointerCapture(e.pointerId)
        drawing.current = true
        const p = at(e)
        ctx.beginPath()
        ctx.moveTo(p.x, p.y)
    }
    function move(e: React.PointerEvent<HTMLCanvasElement>) {
        if (!drawing.current) return
        const ctx = e.currentTarget.getContext('2d')
        if (!ctx) return
        const p = at(e)
        ctx.lineTo(p.x, p.y)
        ctx.stroke()
        setDirty(true)
    }
    function up() { drawing.current = false }
    function clear() {
        const c = ref.current
        c?.getContext('2d')?.clearRect(0, 0, c.width, c.height)
        setDirty(false)
    }
    async function save() {
        if (!ref.current || !dirty) return
        setBusy(true)
        try {
            const r = await saveSignatureSpecimen(ref.current.toDataURL('image/png'))
            if (r.error) {
                showActionMessage({ subject: t('signature.title'), headline: t('signature.notSaved'), body: r.error, detail: r.detail })
                return
            }
            clear()
            router.refresh()
        } finally {
            setBusy(false)
        }
    }

    return (
        <section id="signature" className="space-y-2 mb-8 max-w-xl" aria-label={t('signature.title')} data-signature-panel="1">
            <h2 className="mb-1">{t('signature.title')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)]">{t('signature.intro', { title })}</p>
            {currentUri ? (
                <div className="space-y-1">
                    <p className="text-sm">{t('signature.current')}</p>
                    {/* eslint-disable-next-line @next/next/no-img-element -- 一张随页面送来的 data: 图,不经图片优化 */}
                    <img src={currentUri} alt={t('signature.currentAlt')} className="max-h-24 max-w-full border border-[color:var(--brand-border)] bg-white p-1" data-signature-current="1" />
                </div>
            ) : (
                <p className="text-sm font-medium" data-signature-none="1">{t('signature.none')}</p>
            )}
            <canvas
                ref={ref}
                className="block w-full h-40 border border-dashed border-[color:var(--brand-muted-text)] bg-white touch-none"
                onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerLeave={up}
                aria-label={t('signature.padLabel')} data-signature-pad="1"
            />
            <div className="flex flex-wrap gap-2">
                <Button type="button" variant="outline" onClick={clear} disabled={!dirty || busy}>{t('signature.clear')}</Button>
                <Button type="button" onClick={save} disabled={!dirty || busy} data-signature-save="1">
                    {currentUri ? t('signature.replace') : t('signature.save')}
                </Button>
            </div>
        </section>
    )
}
