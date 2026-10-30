'use server'

// CONTRACT-ESIGN(Tim 2026-10-30 Q1 · Q3 · Q4 · Q5 · Q6 · Q9):签一份合同文件。
//   ① 重新输入密码(Q5):用这个人刚刚输入的密码【另开一个会话】(@supabase/supabase-js,不存、不刷新、不写 cookie)——
//      浏览器里那一个会话原样不动;后面每一步都用这个新会话,于是库在 contract_sign_begin 里从【这个令牌】的 amr 读到"5 分钟之内凭密码登录",
//      并把那一刻记在签过的那一行上(signing_password_verified_at)。新会话的用户必须就是浏览器里那个人。收尾一律 signOut({ scope: 'local' }) ——
//      只结束这一个新会话,不碰这个人别处的登录。
//   ② contract_sign_begin 判完(名单、读权、密码时刻、合同生效中、没签过、有样本、有印章、位置)才登记一行、给出路径;
//   ③ 取源文件、签字样本与印章 —— 三样都对着登记的 sha256 核一次(readStored);
//   ④ stampPdf 盖到选定的页与位置(Q6),印出名字、职衔、时刻与那一句(Q4),另存成新的一份 PDF;
//   ⑤ 传到登记的路径(只有这一行登记过的路径传得进),contract_file_finish 收下服务端算出的 sha256 —— 到这一步才算签了。
//   ②之后任何一步不过 → contract_file_abandon。
import { revalidatePath } from 'next/cache'
import { createClient as createPlainClient } from '@supabase/supabase-js'
import { createClient } from '@/lib/supabase/server'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { CONTRACT_FILES_BUCKET, SIGNING_ASSETS_BUCKET, readStored, sha256Hex, stampPdf, type Placement } from '@/lib/contractFiles'
import { localizeEsignError } from '../files/esignErrorCodes'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export type SignInput = {
    fileId: string
    password: string
    signature: Placement
    stamp: Placement | null
}

const refuse = (code: string) => refuseFromCoded(code, localizeEsignError)
const fraction = (v: unknown) => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1
const placementOk = (p: Placement | null) => !!p && Number.isInteger(p.page) && p.page >= 1 && fraction(p.x) && fraction(p.y)

export async function signContractFile(input: SignInput): Promise<ActionOutcome> {
    if (!UUID.test(input.fileId)) return refuse('CONTRACT_FILE_NOT_FOUND')
    if (!placementOk(input.signature) || (input.stamp !== null && !placementOk(input.stamp))) return refuse('CONTRACT_SIGN_PLACEMENT_INVALID')
    if (!input.password) return { ...(await refuse('CONTRACT_SIGN_PASSWORD_WRONG')), field: 'password' }

    const cookieClient = await createClient()
    const { data: me, error: meErr } = await cookieClient.auth.getUser()
    if (meErr || !me?.user?.email) return refuse('CONTRACT_SIGN_NOT_SIGNATORY')

    // ① 另开一个会话(不存、不刷新):这就是"重新输入密码"
    const fresh = createPlainClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
        auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    })
    const signIn = await fresh.auth.signInWithPassword({ email: me.user.email, password: input.password })
    if (signIn.error || !signIn.data.session || signIn.data.user?.id !== me.user.id) {
        if (signIn.data.session) await fresh.auth.signOut({ scope: 'local' })
        return { ...(await refuse('CONTRACT_SIGN_PASSWORD_WRONG')), field: 'password' }
    }

    let fileId: string | null = null
    try {
        // ② 库判完才登记
        const begin = await fresh.rpc('contract_sign_begin', {
            p_file_id: input.fileId,
            p_with_stamp: input.stamp !== null,
            p_signature_page: input.signature.page,
            p_signature_x: input.signature.x,
            p_signature_y: input.signature.y,
            p_stamp_page: input.stamp?.page ?? null,
            p_stamp_x: input.stamp?.x ?? null,
            p_stamp_y: input.stamp?.y ?? null,
        })
        if (begin.error) return refuseFromCoded(begin.error.message, localizeEsignError)
        const b = begin.data as {
            id: string; path: string; source_path: string; source_sha256: string
            specimen_path: string; specimen_sha256: string; stamp_path: string | null; stamp_sha256: string | null
            signer_name: string; signer_title: string
        }
        fileId = b.id
        const fail = async (code: string) => {
            await fresh.rpc('contract_file_abandon', { p_file_id: b.id })
            return refuse(code)
        }

        // ③ 三样字节,各自对着登记的哈希
        const source = await readStored(fresh, CONTRACT_FILES_BUCKET, b.source_path, b.source_sha256)
        if (!source.ok) return fail(source.code === 'HASH_MISMATCH' ? 'CONTRACT_FILE_HASH_MISMATCH' : 'CONTRACT_FILE_NOT_STORED')
        const specimen = await readStored(fresh, SIGNING_ASSETS_BUCKET, b.specimen_path, b.specimen_sha256)
        if (!specimen.ok) return fail(specimen.code === 'HASH_MISMATCH' ? 'CONTRACT_FILE_HASH_MISMATCH' : 'SIGNING_ASSET_NOT_STORED')
        let stampPng: Uint8Array | null = null
        if (b.stamp_path) {
            const st = await readStored(fresh, SIGNING_ASSETS_BUCKET, b.stamp_path, b.stamp_sha256)
            if (!st.ok) return fail(st.code === 'HASH_MISMATCH' ? 'CONTRACT_FILE_HASH_MISMATCH' : 'SIGNING_ASSET_NOT_STORED')
            stampPng = st.bytes
        }

        // ④ 盖章,另存一份
        const stamped = await stampPdf({
            source: source.bytes, specimenPng: specimen.bytes, stampPng,
            signature: input.signature, stamp: input.stamp,
            signerName: b.signer_name, signerTitle: b.signer_title, signedAt: new Date(),
        })
        if (!stamped.ok) return fail(stamped.code)

        // ⑤ 存下,交给库
        const up = await fresh.storage.from(CONTRACT_FILES_BUCKET).upload(b.path, stamped.bytes, { contentType: 'application/pdf', upsert: false })
        if (up.error) return fail('CONTRACT_FILE_UPLOAD_FAILED')
        const fin = await fresh.rpc('contract_file_finish', { p_file_id: b.id, p_sha256: sha256Hex(stamped.bytes) })
        if (fin.error) {
            await fresh.rpc('contract_file_abandon', { p_file_id: b.id })
            return refuseFromCoded(fin.error.message, localizeEsignError)
        }
        fileId = null
        revalidatePath('/contracts/[id]', 'page')
        revalidatePath('/contracts/[id]/sign', 'page')
        return { success: true }
    } catch (e) {
        if (fileId) await fresh.rpc('contract_file_abandon', { p_file_id: fileId })
        throw e
    } finally {
        await fresh.auth.signOut({ scope: 'local' })
    }
}
