'use client'

// app/components/scan/ScanField.tsx
// MES-3b(2026-10-07,MES-0 Q28;MES-3b Step 0 Q18–Q20 · Q26,Tim):【一个扫码框】—— 每一处扫码(收货的库位、/inventory/scan、
//   投料的每一行、预留、发货核对)都是它。
//   ① 扫码枪(keyboard wedge):它把一串字"敲"进这个框,再补一个回车。回车在这里被拦下(不让它提交外面那张表单),
//      然后去问 resolve_scan_code。手敲也是同一条路 —— 对一个页面来说,扫码枪与手敲一模一样(scan_events 记 keyboard)。
//   ② 摄像头:只在浏览器自带 BarcodeDetector 的地方出现(Android 上的 Chrome);iOS Safari 没有它 → 不出现这颗按钮,
//      用扫码枪或手敲(Q26:不加任何解码库,Q28 照旧)。认 QR 与 Code 128。
//   ③ 认身份只有服务器一处(resolve_scan_code):四种写法(编号 · /b/… · /loc/… · 旧标签的编辑页地址)、
//      四种结果(found · restricted · unknown · unreadable)。看不见的人拿不到 id,这里只说"那是什么、要哪个码"。
//   ④ accept:这个框要哪几种东西;认出来的是别的种类 → 说出来,不交给页面。
import { useEffect, useRef, useState, useSyncExternalStore, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { CONTROL_TOUCH, CONTROL_INPUT } from '@/app/components/ui/control-style'
import { Button } from '@/app/components/ui/button'
import { resolveScan, type ScanContext, type ScanKind, type ScanMethod, type ScanResult } from './actions'

// BarcodeDetector 不在 TypeScript 的 DOM 库里(它只在 Chromium 系有)—— 这里只描述用到的那一点。
type Detector = { detect: (src: HTMLVideoElement) => Promise<{ rawValue: string }[]> }
type DetectorCtor = new (opts: { formats: string[] }) => Detector
function detectorCtor(): DetectorCtor | null {
    const w = window as Window & { BarcodeDetector?: DetectorCtor }
    return typeof w.BarcodeDetector === 'function' ? w.BarcodeDetector : null
}

const noSubscribe = () => () => {}

export default function ScanField({ context, accept, onFound, label, compact = false, autoFocus = false, testId }: {
    context: ScanContext
    accept: ScanKind[]
    onFound: (r: ScanResult) => void
    label?: string
    compact?: boolean
    autoFocus?: boolean
    testId?: string
}) {
    const t = useTranslations()
    const [value, setValue] = useState('')
    const [msg, setMsg] = useState<{ tone: 'ok' | 'warn'; text: string } | null>(null)
    const [cameraOn, setCameraOn] = useState(false)
    const [isPending, startTransition] = useTransition()
    const video = useRef<HTMLVideoElement>(null)
    const stream = useRef<MediaStream | null>(null)

    // 服务端那一刻没有 window:服务端快照说"没有",浏览器快照问一次 —— 两边先一致(水合),不在 effect 里 setState
    const canCamera = useSyncExternalStore(noSubscribe,
        () => detectorCtor() !== null && !!navigator.mediaDevices?.getUserMedia, () => false)
    useEffect(() => () => stopCamera(), [])

    const kindName = (k: ScanKind | null) =>
        k === 'inbound_batch' ? t('scan.kind.inboundBatch') : k === 'output_batch' ? t('scan.kind.outputBatch')
        : k === 'storage_location' ? t('scan.kind.location') : '—'

    function submit(raw: string, method: ScanMethod) {
        if (raw.trim() === '') return
        startTransition(async () => {
            let r: ScanResult
            try {
                r = await resolveScan(raw, context, method)
            } catch {
                setMsg({ tone: 'warn', text: t('scan.failed') })
                return
            }
            const code = r.code ?? raw.trim()
            if (r.outcome === 'found' && r.kind && accept.includes(r.kind)) {
                if (r.kind === 'storage_location' && r.is_active === false) {
                    setMsg({ tone: 'warn', text: t('scan.inactive', { code }) })
                    return
                }
                setMsg({ tone: 'ok', text: t('scan.found', { code, kind: kindName(r.kind) }) })
                setValue('')
                onFound(r)
            } else if ((r.outcome === 'found' || r.outcome === 'restricted') && r.kind && !accept.includes(r.kind)) {
                setMsg({ tone: 'warn', text: t('scan.wrongKind', { code, kind: kindName(r.kind), want: accept.map(kindName).join(' / ') }) })
            } else if (r.outcome === 'restricted') {
                setMsg({ tone: 'warn', text: t('scan.restricted', { code, kind: kindName(r.kind), needs: r.needs ?? '' }) })
            } else if (r.outcome === 'unknown') {
                setMsg({ tone: 'warn', text: t('scan.unknown', { code }) })
            } else {
                setMsg({ tone: 'warn', text: t('scan.unreadable') })
            }
        })
    }

    function stopCamera() {
        stream.current?.getTracks().forEach((tr) => tr.stop())
        stream.current = null
        setCameraOn(false)
    }

    async function startCamera() {
        const Ctor = detectorCtor()
        if (!Ctor) return
        try {
            const s = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } })
            stream.current = s
            setCameraOn(true)
            const v = video.current
            if (!v) return
            v.srcObject = s
            await v.play()
            const detector = new Ctor({ formats: ['qr_code', 'code_128'] })
            const tick = async () => {
                if (!stream.current) return
                try {
                    const found = await detector.detect(v)
                    if (found.length > 0 && found[0].rawValue) {
                        const raw = found[0].rawValue
                        stopCamera()
                        submit(raw, 'camera')
                        return
                    }
                } catch { /* 一帧认不出来不是一次失败;下一帧再认 */ }
                setTimeout(tick, 250)
            }
            tick()
        } catch (e) {
            stopCamera()
            setMsg({ tone: 'warn', text: t('scan.cameraFailed', { reason: e instanceof Error ? e.name : String(e) }) })
        }
    }

    return (
        <div className={compact ? '' : 'mb-3'} data-scan-field={context} data-testid={testId}>
            {label && <label className="block mb-1">{label}</label>}
            <div className="flex flex-wrap items-center gap-2">
                <input
                    value={value}
                    onChange={(e) => setValue(e.target.value)}
                    onKeyDown={(e) => {
                        // 扫码枪打完一串补一个回车:拦下它,不让它提交外面那张表单
                        if (e.key === 'Enter') { e.preventDefault(); submit(value, 'keyboard') }
                    }}
                    autoFocus={autoFocus}
                    autoComplete="off" autoCapitalize="characters" spellCheck={false} enterKeyHint="go"
                    placeholder={t('scan.placeholder')}
                    aria-label={label ?? t('scan.placeholder')}
                    className={compact ? `${CONTROL_INPUT} flex-1 min-w-0` : `${CONTROL_TOUCH} flex-1 min-w-0 px-3 py-3 text-base min-h-[48px]`}
                    data-scan-input
                />
                <Button type="button" variant="secondary" size={compact ? undefined : 'touch'}
                        disabled={isPending || value.trim() === ''} onClick={() => submit(value, 'keyboard')}>
                    {t('scan.lookup')}
                </Button>
                {canCamera && (
                    <Button type="button" variant="secondary" size={compact ? undefined : 'touch'}
                            onClick={() => (cameraOn ? stopCamera() : startCamera())} data-scan-camera>
                        {cameraOn ? t('scan.cameraStop') : t('scan.camera')}
                    </Button>
                )}
            </div>
            {/* 一直在 DOM 里(只是藏着):开摄像头那一刻就要拿得到它,不能等下一次渲染 */}
            <video ref={video} className={cameraOn ? 'mt-2 w-full max-w-sm rounded border border-gray-300' : 'hidden'} muted playsInline />
            {msg && (
                <p className={`text-sm mt-1 ${msg.tone === 'ok' ? 'text-[color:var(--brand-muted-text)]' : 'text-amber-700'}`}
                   data-scan-outcome={msg.tone} role="status">{msg.text}</p>
            )}
        </div>
    )
}
