'use server'

// app/suppliers/[id]/edit/portalActions.ts
// ════════════════════════════════════════════════════════════════════════════
// MES-9a(2026-10-19,MES-0 Q87 · MES-9 Step 0 Q5 · Q6 · Q8 · Q20,Tim):供应商门户账号 —— 开、撤销、应请求匿名化。
// ════════════════════════════════════════════════════════════════════════════
// 【开】与员工账号同一条路(app/settings/accounts/accountActions.ts,C-1):service role 建 auth 账号,初始密码当面交、
//   user_metadata.must_change_password(中间件把人扣在 /set-password 直到换掉)、email_confirm(没有邮件服务)。
//   另外两件员工账号没有的:app_metadata.supplier_portal = true(用户自己改不了 —— 中间件靠它认出一个令牌没带门户角色的门户账号,Q11);
//   以及链接 —— portal_user_create_link 以【按按钮的人自己的会话】写(action.manage_portal_users 在库里查,判据都在那支函数里)。
//   链接写不进去 → 这个号不留:删掉,并说清楚删没删成(PRE-ACCOUNT-1 那一课,与员工账号的 undo 同一个形状)。
// 【撤销】portal_user_revoke(链接撤销 + 删会话 = 全局登出,下一次调用就拒)→ 再经 auth.admin 封禁(换不了新令牌)。
//   封禁失败时说出来:链接已撤销、会话已删、门户已经拒它 —— 只是它还登录得进来看那一句拒绝。
// 【匿名化】portal_contact_anonymise(联系人与它在变更记录里的影像)→ 再经 auth.admin 把登录邮箱换成一个不指向任何人的地址。
// ★★【密码只走一个方向:表单 → 这里 → Supabase】★★ 不进 URL、不进日志、不进任何错误分支的回显。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { createAdminClient } from '@/lib/supabase/admin'
import { can } from '@/lib/permissions'
import { getTranslations } from '@/lib/i18n/server'
import { MIN_PASSWORD_LENGTH } from '@/lib/passwordPolicy'
import { localizePortalError } from '@/app/portal/portalErrorCodes'

export type PortalActionState = { error?: string; success?: boolean; email?: string; note?: string }

const CODE = 'action.manage_portal_users'
const BAN_FOREVER = '876000h' // 与员工账号停用同一个值:Supabase 的 ban_duration 只收时长

export async function createPortalAccount(form: { supplierId: string; contactId: string; password: string }): Promise<PortalActionState> {
    const t = await getTranslations()
    if (!(await can(CODE))) return { error: t('permissions.errDenied') }
    if ((form.password ?? '').length < MIN_PASSWORD_LENGTH) {
        return { error: t('permissions.errPasswordTooShort', { 0: String(MIN_PASSWORD_LENGTH) }) }
    }
    const supabase = await createClient()
    // 联系人与它的邮箱:读者自己的会话(module.suppliers.view)。判据(属于这家、有邮箱、没被占)在库里再判一次。
    const { data: contact, error: cErr } = await supabase.from('counterparty_contacts')
        .select('id, email, supplier_id').eq('id', form.contactId).eq('supplier_id', form.supplierId).is('deleted_at', null).maybeSingle()
    if (cErr) return { error: (await localizePortalError(cErr.message)).text }
    const email = (contact?.email ?? '').trim().toLowerCase()
    if (!contact) return { error: t('portal.errors.PORTAL_CONTACT_NOT_OF_SUPPLIER') }
    if (!email) return { error: t('portal.errors.PORTAL_CONTACT_NO_EMAIL') }

    let admin
    try {
        admin = createAdminClient()
    } catch (e) {
        return { error: e instanceof Error ? e.message : String(e) }
    }
    const { data, error } = await admin.auth.admin.createUser({
        email,
        password: form.password,
        email_confirm: true,
        user_metadata: { must_change_password: true },
        app_metadata: { supplier_portal: true },
    })
    if (error) return { error: t('portal.errCreateAuth', { 0: error.message }) }
    const userId = data?.user?.id
    if (!userId) return { error: t('permissions.errCreateNoUser') }

    const { error: linkErr } = await supabase.rpc('portal_user_create_link', {
        p_user_id: userId, p_supplier_id: form.supplierId, p_contact_id: form.contactId,
    })
    if (linkErr) {
        const reason = (await localizePortalError(linkErr.message)).text
        const { error: delErr } = await admin.auth.admin.deleteUser(userId)
        if (delErr) return { error: t('portal.errCreateRolledBackFailed', { 0: reason, 1: delErr.message, 2: email }) }
        return { error: t('portal.errCreateRolledBack', { 0: reason }) }
    }
    revalidatePath(`/suppliers/${form.supplierId}/edit`)
    return { success: true, email }
}

export async function revokePortalAccount(form: { supplierId: string; linkId: string; reason: string }): Promise<PortalActionState> {
    const t = await getTranslations()
    if (!(await can(CODE))) return { error: t('permissions.errDenied') }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('portal_user_revoke', { p_link_id: form.linkId, p_reason: form.reason })
    if (error) return { error: (await localizePortalError(error.message)).text }
    const userId = (data as { user_id?: string } | null)?.user_id
    let admin
    try {
        admin = createAdminClient()
    } catch (e) {
        return { error: t('portal.errBanFailed', { 0: e instanceof Error ? e.message : String(e) }) }
    }
    if (!userId) return { error: t('portal.errBanFailed', { 0: 'no account id returned' }) }
    const { error: banErr } = await admin.auth.admin.updateUserById(userId, { ban_duration: BAN_FOREVER })
    revalidatePath(`/suppliers/${form.supplierId}/edit`)
    if (banErr) return { error: t('portal.errBanFailed', { 0: banErr.message }) }
    return { success: true }
}

export async function anonymisePortalContact(form: { supplierId: string; linkId: string }): Promise<PortalActionState> {
    const t = await getTranslations()
    if (!(await can(CODE))) return { error: t('permissions.errDenied') }
    const supabase = await createClient()
    const { data: link, error: lErr } = await supabase.from('supplier_portal_accounts')
        .select('user_id').eq('id', form.linkId).maybeSingle()
    if (lErr) return { error: (await localizePortalError(lErr.message)).text }
    if (!link?.user_id) return { error: t('portal.errors.PORTAL_LINK_NOT_FOUND') }
    const { error } = await supabase.rpc('portal_contact_anonymise', { p_link_id: form.linkId })
    if (error) return { error: (await localizePortalError(error.message)).text }
    let admin
    try {
        admin = createAdminClient()
    } catch (e) {
        return { error: t('portal.errAnonymiseEmailFailed', { 0: e instanceof Error ? e.message : String(e) }) }
    }
    // 一个不指向任何人的登录地址(.invalid 是保留的顶级域,永远解析不到)。账号 id 与它的记录都留着(Q20)。
    const { error: emailErr } = await admin.auth.admin.updateUserById(link.user_id, {
        email: `anonymised-${link.user_id.slice(0, 8)}@portal.invalid`, email_confirm: true,
    })
    revalidatePath(`/suppliers/${form.supplierId}/edit`)
    if (emailErr) return { error: t('portal.errAnonymiseEmailFailed', { 0: emailErr.message }) }
    return { success: true }
}
