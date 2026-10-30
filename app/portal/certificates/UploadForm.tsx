'use client'

// app/portal/certificates/UploadForm.tsx
// GOLIVE-2 第 9 行:门户交证书的【浏览器那一半】—— 字节从浏览器直传私有桶 portal-uploads,不经过 Vercel 的函数
//   (那里的请求体上限 4.5 MB 曾让「每份不超过 10 MB」成为一句假话)。顺序与报销收据(app/me/uploadClaimReceipt.ts)相同:
//   ① 按文件头认类型(lib/sniffFileType;认不出交 application/octet-stream,让库按名拒)—— 不信浏览器报的类型与扩展名;
//   ② beginSubmission:库按 V39 判类型与大小,过了才登记一行 uploading、给出路径 —— 拒了一个字节都不传;
//   ③ 以这个门户会话自己的令牌把文件传进那条路径(存储策略只放行这一行登记过的路径;桶自己再拦一道 10 MB · PDF / JPEG / PNG);
//   ④ finishSubmission:服务端从存储里读回文件头再认一次、库再比一次大小与类型 → 一份等审核的申请;③ 或 ④ 失败 → 那一行收回(abandon)。
//   结果仍然落回 /portal/certificates?submitted=1 或 ?error=<码>[&p=<参数>] —— 页面把码说成人话(portal.errors.*),与原来的路由同一套。
//   表单的那几个字段由页面(服务端)画好交进来,这里只接管"提交"那一下。
import { useState, type FormEvent, type ReactNode } from 'react'
import { createClient } from '@/lib/supabase/client'
import { sniffFileType } from '@/lib/sniffFileType'
import { abandonSubmission, beginSubmission, finishSubmission, type PortalUploadResult } from './actions'

export default function UploadForm({ children, busyText }: { children: ReactNode; busyText: string }) {
    const [busy, setBusy] = useState(false)

    function land(r: { error?: string; p?: string } | null) {
        const q = new URLSearchParams()
        if (!r) q.set('submitted', '1')
        else { q.set('error', r.error ?? 'UPLOAD_FAILED'); if (r.p) q.set('p', r.p) }
        // 一次整页导航(不是 router.push + refresh:refresh 会把还没落地的那一次 push 打断 —— GOLIVE-2 线上证明量到的:
        //   ?submitted=1 的 RSC 请求 ERR_ABORTED,人停在一张空表单上,看不到「已交」也看不到「太大」)
        window.location.assign(`/portal/certificates?${q.toString()}`)
    }

    async function onSubmit(e: FormEvent<HTMLFormElement>) {
        e.preventDefault()
        if (busy) return
        const form = new FormData(e.currentTarget)
        const file = form.get('file')
        if (!(file instanceof File) || file.size === 0) return land({ error: 'NO_FILE' })
        setBusy(true)
        try {
            const head = new Uint8Array(await file.slice(0, 16).arrayBuffer())
            const type = sniffFileType(head) ?? 'application/octet-stream'
            const str = (k: string) => { const v = form.get(k); return typeof v === 'string' ? v : null }
            const slot: PortalUploadResult = await beginSubmission({
                certType: str('cert_type') ?? '', certNo: str('cert_no'), validFrom: str('valid_from'), validUntil: str('valid_until'),
                fileName: file.name || 'certificate', fileType: type, fileSize: file.size,
            })
            if (slot.error || !slot.id || !slot.path) return land(slot.error ? slot : { error: 'UPLOAD_FAILED' })
            const up = await createClient().storage.from('portal-uploads').upload(slot.path, file, { contentType: type, upsert: false })
            if (up.error) {
                await abandonSubmission(slot.id)
                return land({ error: 'UPLOAD_FAILED' })
            }
            const done = await finishSubmission({ id: slot.id, path: slot.path, fileType: type })
            return land(done.error ? done : null)
        } catch {
            return land({ error: 'UPLOAD_FAILED' })
        } finally {
            setBusy(false)
        }
    }

    return (
        <form onSubmit={onSubmit} className="space-y-3" data-form="portal-upload" data-upload-path="direct" aria-busy={busy}>
            {children}
            {busy && <p className="text-sm" role="status" data-upload-busy="1">{busyText}</p>}
        </form>
    )
}
