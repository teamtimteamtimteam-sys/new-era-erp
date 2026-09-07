'use server'

// MANUAL-FIX-2:合同登记簿的【创建入口】。
//
// ★★【本刀建的是门,不是屋子】★★(委托书 3.8 的围栏)
//   建得出一份合同,仅此而已。**没有**修订、**没有**创建之后的状态流转、
//   **没有**单据挂接、**没有**计价集成。围栏是 Tim 定的,不是省事。
//
// ★★【状态可以在创建时选,而这是 Tim 的裁定(T3)】★★
//   它是一个【插入字段】,不是一次状态流转 —— 围栏挡的是流转。
//   而它非有不可的理由是实测出来的:**`db/functions` 里没有任何一支写
//   `contracts.status`**(2026-09-07 实测,零处)。所以创建时给的状态就是它
//   这辈子的状态。若只能建成 draft,而 link_document_to_contract 又要求
//   active,那么这扇门通向的是一间谁也进不去的屋子。
//
// ★【写入的门【不是】这一页的门】/contracts 由 module.suppliers.view 把着(读),
//   而 INSERT 策略要的是【归属那一侧】的 edit:买方合同要 module.suppliers.edit,
//   卖方合同要 module.customers.edit。**哪一个,取决于对手方选了谁** ——
//   所以应用侧【判不了】,只能让策略回答,再把那句 42501 翻译成人话。
//   (T4:挡住持客户编辑权的人、或把只有查看权的人领进一张必被拒的表单,
//    两者都比让策略作答更坏。)
import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { localizeContractError } from '../contractErrorCodes'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

export type CreateContractState = {
    error?: string
    fieldErrors?: Record<string, string>
}

const KINDS = ['supply', 'offtake', 'framework', 'service', 'other']
// 创建时【只】开放这两个:draft 与 active。suspended / expired / terminated 是
// 一份【活过一段时间】的合同才会到达的状态,把它们摆在创建表单上,等于请人
// 建一份一出生就已经终止的合同 —— 而且没有任何路径能把它改回来。
const CREATABLE_STATUSES = ['draft', 'active']

export async function createContract(
    _prevState: CreateContractState,
    formData: FormData
): Promise<CreateContractState> {
    const t = await getTranslations()

    // ── 取字段 ─────────────────────────────────────────────────────────────
    // 对手方是【一个】字段,值带前缀 —— 于是"恰好一边"在表单这一层就是结构性的,
    // 而不是靠两个下拉框互相提防。数据库那条 num_nonnulls = 1 仍然是真正的守卫。
    const counterparty = ((formData.get('counterparty') as string) || '').trim()
    const kind = ((formData.get('kind') as string) || '').trim()
    const title = ((formData.get('title') as string) || '').trim()
    const effective_from = ((formData.get('effective_from') as string) || '').trim()
    const effective_to = ((formData.get('effective_to') as string) || '').trim() || null
    const signed_on = ((formData.get('signed_on') as string) || '').trim() || null
    const currency = ((formData.get('currency') as string) || '').trim() || null
    const incoterm = ((formData.get('incoterm') as string) || '').trim() || null
    const document_ref = ((formData.get('document_ref') as string) || '').trim() || null
    const notes = ((formData.get('notes') as string) || '').trim() || null
    const status = ((formData.get('status') as string) || '').trim()
    const ptdRaw = ((formData.get('payment_terms_days') as string) || '').trim()

    // ── 校验:每一条都对着一条真实的约束,而且【先在这里拒】,
    //    因为字段旁边那句话才是人读得到的位置 ─────────────────────────────
    const fieldErrors: Record<string, string> = {}

    let customer_id: string | null = null
    let supplier_id: string | null = null
    if (counterparty.startsWith('supplier:')) {
        supplier_id = counterparty.slice('supplier:'.length) || null
    } else if (counterparty.startsWith('customer:')) {
        customer_id = counterparty.slice('customer:'.length) || null
    }
    // 「两边都有」在表单上画不出来,但直接 POST 画得出来 —— 所以判据写成
    // 与数据库那条 CHECK 同一句话,而不是"下拉框选了没有"。
    if ((customer_id === null) === (supplier_id === null)) {
        fieldErrors.counterparty = t('contracts.errors.CONTRACT_COUNTERPARTY_REQUIRED')
    }
    if (!KINDS.includes(kind)) fieldErrors.kind = t('contracts.errors.CONTRACT_KIND_INVALID')
    if (!title) fieldErrors.title = t('contracts.errors.CONTRACT_TITLE_REQUIRED')
    if (!effective_from) {
        fieldErrors.effective_from = t('contracts.errors.CONTRACT_EFFECTIVE_FROM_REQUIRED')
    }
    // 【无固定期限不是"忘了填"】—— 空就是空,只有【填了而且更早】才是错。
    if (effective_to && effective_from && effective_to < effective_from) {
        fieldErrors.effective_to = t('contracts.errors.CONTRACT_PERIOD_ORDER')
    }
    let payment_terms_days: number | null = null
    if (ptdRaw !== '') {
        const n = Number(ptdRaw)
        if (!Number.isInteger(n) || n < 0 || n > 365) {
            fieldErrors.payment_terms_days = t('contracts.errors.CONTRACT_PAYMENT_TERMS_INVALID')
        } else {
            payment_terms_days = n
        }
    }
    if (!CREATABLE_STATUSES.includes(status)) {
        fieldErrors.status = t('contracts.errors.CONTRACT_STATUS_INVALID')
    }

    if (Object.keys(fieldErrors).length > 0) return { fieldErrors }

    // ── 写入 ───────────────────────────────────────────────────────────────
    const supabase = await createClient()
    const { data, error } = await supabase
        .from('contracts')
        .insert({
            customer_id,
            supplier_id,
            kind,
            title,
            effective_from,
            effective_to,
            signed_on,
            status,
            currency,
            incoterm,
            payment_terms_days,
            document_ref,
            notes,
            // code 不传,由 trg_contracts_code 取号(CON-YYYY-NNNN)
            // side 不传,它是生成列,写它会被 PostgreSQL 直接拒绝
        } as InsertRow<'contracts'>)
        .select('id')
        .single()

    if (error) {
        // ★ 绝不把 42501 或约束名摔到人脸上 —— MANUAL-FIX-1 修的正是这一族。
        return { error: await localizeContractError(error.message) }
    }

    revalidatePath('/contracts')
    // 详情页今天不存在(围栏:本刀不建),所以回登记簿 —— 新建那一行就在表里。
    void data
    redirect('/contracts')
}
