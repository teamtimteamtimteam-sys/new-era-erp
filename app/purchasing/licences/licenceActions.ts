'use server'

// CMPL-1:公司自家执照的写入口。
//
// 【为什么是直连 + RLS,而不是一支 RPC】company_compliance 上没有任何跨表不变量要
// 在一笔事务里守住,把关的是它自己的 RLS(module.suppliers.edit)与表上的 CHECK。
// 一支 RPC 只会是 INSERT 的一层转写。
//
// 【权限码沿用这张表【已有】的那两个,不新造】company_compliance 的 RLS 从 CMP-1
// 起就是 select=module.suppliers.view / write=module.suppliers.edit,理由写在
// docs/compliance-scoping.md §C:合规没有自己的模块,而资质的读者与供应商资质
// 是同一批人。**为一张已经有门的表再铸一个码,就是"谁能看"的第二份定义。**
//
// ★【样本值一个都不许进来】★ Tim 给的两张 NEA 执照属于另一家公司,是【样本】。
//   本文件没有任何默认值、示例值或占位符 —— 空表单就是空的,由人一格一格录。

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeLicenceError } from './licenceErrorCodes'

export type LicenceInput = {
    id?: string
    cert_type_code: string
    cert_no: string
    issuing_body: string
    status: string
    issue_date: string
    valid_from: string
    valid_until: string
    approved_storage_limit_tonnes: string
    scope: string
    notes: string
}

// 【空字符串永不喂给库】'' 与 NULL 是两件事,而一个空格子的意思是【没录】。
const orNull = (v: string) => (v.trim() === '' ? null : v.trim())
const numOrNull = (v: string) => (v.trim() === '' ? null : Number(v))

export async function saveLicence(input: LicenceInput) {
    const supabase = await createClient()
    // 接住 auth 的 error —— 丢掉它,「认证够不着」与「这个人没登录」走同一条分支
    // (判据与实测表在 lib/supabase/middleware.ts 的抬头)。
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError) {
        return { error: await localizeLicenceError('LICENCE_AUTH_UNAVAILABLE') }
    }

    if (orNull(input.cert_type_code) === null) {
        return { error: await localizeLicenceError('LICENCE_KIND_REQUIRED') }
    }

    const row = {
        cert_type_code: input.cert_type_code.trim(),
        cert_no: orNull(input.cert_no),
        issuing_body: orNull(input.issuing_body),
        status: orNull(input.status),
        issue_date: orNull(input.issue_date),
        valid_from: orNull(input.valid_from),
        valid_until: orNull(input.valid_until),
        // ★ 留空【不表示"没有上限"】,表示【没有人录过上限】——
        //   而读到 NULL 的那道判据会【拒绝作判断】,绝不放行(R2)。
        approved_storage_limit_tonnes: numOrNull(input.approved_storage_limit_tonnes),
        scope: orNull(input.scope),
        notes: orNull(input.notes),
        updated_by: user?.id ?? null,
    }

    const { error } = input.id
        ? await supabase.from('company_compliance').update(row).eq('id', input.id)
        : await supabase.from('company_compliance').insert({ ...row, created_by: user?.id ?? null })

    if (error) return { error: await localizeLicenceError(error.message) }

    revalidatePath('/finance/company')
    return { success: true }
}

export async function softDeleteLicence(id: string) {
    const supabase = await createClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError) {
        return { error: await localizeLicenceError('LICENCE_AUTH_UNAVAILABLE') }
    }
    const { error } = await supabase
        .from('company_compliance')
        .update({ deleted_at: new Date().toISOString(), updated_by: user?.id ?? null })
        .eq('id', id)
        .is('deleted_at', null)
    if (error) return { error: await localizeLicenceError(error.message) }
    revalidatePath('/finance/company')
    return { success: true }
}
