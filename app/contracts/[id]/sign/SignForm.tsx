'use client'

// CONTRACT-ESIGN(Tim 2026-10-30 Q4 · Q5 · Q6):签字页的浏览器那一半 ——
//   ① 用 pdf.js 一页一页画出那份未签文件(取的是存下的字节:/contracts/[id]/files/[fileId],同源、带会话、服务端核过哈希);
//   ② 签名默认在最后一页右下角(Q6);点「放签名」或「放印章」之后在页面上点一下,框就落在那里 —— 框的大小与盖章时一样
//      (lib/contractSignLayout.ts,预览与服务端读的是同一份数);
//   ③ 重新输入密码(Q5),签。签成了整页跳回合同页(不用 router.push + refresh:GOLIVE-2 量到 refresh 会打断那一次跳转)。
import { useCallback, useEffect, useRef, useState, type MouseEvent } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { Input } from '@/app/components/ui/input'
import { showActionMessage } from '@/app/components/ui/action-message'
import { DEFAULT_SIGNATURE_AT, DEFAULT_STAMP_AT, SIGNATURE_WIDTH_OF_PAGE, STAMP_WIDTH_OF_PAGE } from '@/lib/contractSignLayout'
import { signContractFile } from './actions'

type Pos = { page: number; x: number; y: number }
type PdfDoc = { numPages: number; getPage: (n: number) => Promise<PdfPage> }
type PdfPage = {
    getViewport: (o: { scale: number }) => { width: number; height: number }
    render: (o: { canvas: HTMLCanvasElement; canvasContext: CanvasRenderingContext2D; viewport: { width: number; height: number } }) => { promise: Promise<void>; cancel: () => void }
}

export default function SignForm({ contractId, contractCode, fileId, fileName, pdfHref, specimenUri, stampUri }: {
    contractId: string; contractCode: string; fileId: string; fileName: string; pdfHref: string
    specimenUri: string; stampUri: string | null; locale: string
}) {
    const t = useTranslations()
    const canvasRef = useRef<HTMLCanvasElement | null>(null)
    const boxRef = useRef<HTMLDivElement | null>(null)
    const [doc, setDoc] = useState<PdfDoc | null>(null)
    const [loadError, setLoadError] = useState(false)
    const [page, setPage] = useState(1)
    const [aspect, setAspect] = useState(1.414)
    const [sig, setSig] = useState<Pos | null>(null)
    const [useStamp, setUseStamp] = useState(false)
    const [stamp, setStamp] = useState<Pos | null>(null)
    const [placing, setPlacing] = useState<'signature' | 'stamp'>('signature')
    const [password, setPassword] = useState('')
    const [busy, setBusy] = useState(false)
    const [sigAspect, setSigAspect] = useState(0.35)
    const [stampAspect, setStampAspect] = useState(1)

    // ① 打开 PDF(pdf.js 只在浏览器里用,按需加载)
    useEffect(() => {
        let cancelled = false
        ;(async () => {
            try {
                const pdfjs = await import('pdfjs-dist')
                pdfjs.GlobalWorkerOptions.workerSrc = new URL('pdfjs-dist/build/pdf.worker.min.mjs', import.meta.url).toString()
                const d = (await pdfjs.getDocument({ url: pdfHref, withCredentials: true }).promise) as unknown as PdfDoc
                if (cancelled) return
                setDoc(d)
                setPage(d.numPages)
                setSig({ page: d.numPages, ...DEFAULT_SIGNATURE_AT })
                setStamp({ page: d.numPages, ...DEFAULT_STAMP_AT })
            } catch {
                if (!cancelled) setLoadError(true)
            }
        })()
        return () => { cancelled = true }
    }, [pdfHref])

    // 两张图自己的宽高比(框的高度按它算,与服务端 stampPdf 同一条)
    useEffect(() => {
        const a = new Image(); a.onload = () => setSigAspect(a.naturalHeight / a.naturalWidth || 0.35); a.src = specimenUri
        if (stampUri) { const b = new Image(); b.onload = () => setStampAspect(b.naturalHeight / b.naturalWidth || 1); b.src = stampUri }
    }, [specimenUri, stampUri])

    // ② 画当前那一页,宽度跟着容器
    const draw = useCallback(async () => {
        if (!doc || !canvasRef.current || !boxRef.current) return
        const p = await doc.getPage(page)
        const base = p.getViewport({ scale: 1 })
        const width = boxRef.current.clientWidth
        const vp = p.getViewport({ scale: (width / base.width) * (window.devicePixelRatio || 1) })
        const canvas = canvasRef.current
        canvas.width = Math.floor(vp.width)
        canvas.height = Math.floor(vp.height)
        setAspect(base.height / base.width)
        const ctx = canvas.getContext('2d')
        if (!ctx) return
        await p.render({ canvas, canvasContext: ctx, viewport: vp }).promise
    }, [doc, page])
    useEffect(() => { draw() }, [draw])
    useEffect(() => {
        const onResize = () => { draw() }
        window.addEventListener('resize', onResize)
        return () => window.removeEventListener('resize', onResize)
    }, [draw])

    function place(e: MouseEvent<HTMLDivElement>) {
        const r = e.currentTarget.getBoundingClientRect()
        const pos = { page, x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)) }
        if (placing === 'stamp') setStamp(pos)
        else setSig(pos)
    }

    async function submit() {
        if (!sig || busy) return
        setBusy(true)
        try {
            const r = await signContractFile({ fileId, password, signature: sig, stamp: useStamp && stampUri ? stamp : null })
            if (r.error) {
                showActionMessage({ subject: contractCode, headline: t('contractSign.notSigned'), body: r.error, detail: r.detail })
                return
            }
            window.location.assign(`/contracts/${contractId}`)
        } finally {
            setBusy(false)
            setPassword('')
        }
    }

    const overlay = (pos: Pos | null, uri: string, widthOfPage: number, imgAspect: number, kind: string) =>
        pos && pos.page === page ? (
            // eslint-disable-next-line @next/next/no-img-element -- 随页面送来的 data: 图,只做预览的框
            <img
                src={uri} alt="" aria-hidden="true" data-overlay={kind}
                className="absolute pointer-events-none outline outline-1 outline-dashed outline-[color:var(--brand-muted-text)]"
                style={{
                    left: `${(pos.x - widthOfPage / 2) * 100}%`,
                    top: `${(pos.y - (widthOfPage * imgAspect) / aspect / 2) * 100}%`,
                    width: `${widthOfPage * 100}%`,
                }}
            />
        ) : null

    if (loadError) return <p className="text-sm" role="alert">{t('contractSign.loadFailed')}</p>

    return (
        <div className="space-y-4" data-sign-form={contractCode}>
            <p className="text-sm">{t('contractSign.file', { name: fileName })}</p>
            <div className="flex flex-wrap items-center gap-2">
                <Button type="button" variant="outline" disabled={!doc || page <= 1} onClick={() => setPage((p) => p - 1)}>{t('contractSign.prevPage')}</Button>
                <span className="text-sm" data-sign-page={page}>{doc ? t('contractSign.pageOf', { page, pages: doc.numPages }) : t('contractSign.loading')}</span>
                <Button type="button" variant="outline" disabled={!doc || page >= (doc?.numPages ?? 1)} onClick={() => setPage((p) => p + 1)}>{t('contractSign.nextPage')}</Button>
            </div>
            <div className="flex flex-wrap items-center gap-3" role="radiogroup" aria-label={t('contractSign.placing')}>
                <span className="text-sm">{t('contractSign.placing')}</span>
                <Button type="button" variant={placing === 'signature' ? 'default' : 'outline'} aria-pressed={placing === 'signature'}
                        onClick={() => setPlacing('signature')} data-place="signature">{t('contractSign.placeSignature')}</Button>
                {stampUri ? (
                    <>
                        <label className="inline-flex items-center gap-2 text-sm">
                            <input type="checkbox" checked={useStamp} onChange={(e) => { setUseStamp(e.currentTarget.checked); if (e.currentTarget.checked) setPlacing('stamp') }}
                                   data-use-stamp="1" />
                            {t('contractSign.useStamp')}
                        </label>
                        <Button type="button" variant={placing === 'stamp' ? 'default' : 'outline'} aria-pressed={placing === 'stamp'} disabled={!useStamp}
                                onClick={() => setPlacing('stamp')} data-place="stamp">{t('contractSign.placeStamp')}</Button>
                    </>
                ) : (
                    <span className="text-xs text-[color:var(--brand-muted-text)]">{t('contractSign.noStamp')}</span>
                )}
            </div>
            <p className="text-xs text-[color:var(--brand-muted-text)]">
                {t('contractSign.where', { sigPage: sig?.page ?? '—', stampPage: useStamp && stamp ? stamp.page : '—' })}
            </p>
            <div ref={boxRef} className="relative w-full max-w-3xl border border-[color:var(--brand-border)] bg-white cursor-crosshair select-none"
                 onClick={place} data-sign-canvas="1">
                <canvas ref={canvasRef} className="block w-full h-auto" />
                {overlay(sig, specimenUri, SIGNATURE_WIDTH_OF_PAGE, sigAspect, 'signature')}
                {useStamp && stampUri && overlay(stamp, stampUri, STAMP_WIDTH_OF_PAGE, stampAspect, 'stamp')}
            </div>
            <div className="space-y-1 max-w-sm">
                <label htmlFor="sign-password" className="text-sm font-medium">{t('contractSign.password')}</label>
                <Input id="sign-password" type="password" autoComplete="current-password" value={password}
                       onChange={(e) => setPassword(e.currentTarget.value)} data-sign-password="1" />
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('contractSign.passwordHint')}</p>
            </div>
            <Button type="button" disabled={!doc || !sig || !password || busy} onClick={submit} data-sign-submit="1">
                {busy ? t('contractSign.signing') : t('contractSign.sign')}
            </Button>
        </div>
    )
}
