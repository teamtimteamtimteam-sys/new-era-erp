'use server'

import { parseCounterparty } from '@/app/components/finance/counterpartyOptions'
// 开支登记:表单 → rpc record_expense(校验、无缝编号、自动分录一个事务)。
// paid → 借费用科目/贷银行;unpaid → 借费用科目/贷 2000 应付(成为 AP 单据)。
// 科目/供应商/期间锁等校验在 DB 内,错误码本地化后展示;成功跳开支详情。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeExpenseError } from '../../expenseErrorCodes'

export type CreateExpenseState = { error?: string }

export async function createExpense(
    _prevState: CreateExpenseState,
    formData: FormData
): Promise<CreateExpenseState> {
    const t = await getTranslations()

    const expenseDate = String(formData.get('expense_date') ?? '').trim()
    const accountCodeRaw = String(formData.get('account_code') ?? '').trim()
    const amountRaw = String(formData.get('amount') ?? '').trim()
    const currency = String(formData.get('currency') ?? await getBaseCurrency())
    const paymentStatus = formData.get('payment_status') === 'paid' ? 'paid' : 'unpaid'
    const bank = String(formData.get('bank_account') ?? '').trim()
    // PAYEE-1b:一个字段同时带来"哪一种"与"哪一个" —— 两者不可能不一致。
    const counterparty = parseCounterparty(String(formData.get('counterparty') ?? '').trim())
    const payeeName = String(formData.get('payee_name') ?? '').trim()
    const notes = String(formData.get('notes') ?? '').trim()
    // FIN-22:资本分支 —— capital 勾上时科目固定 1500,组 p_asset;
    // 服务端(record_expense)双向校验 1500 ↔ p_asset,这里只组装。
    const isCapital = formData.get('capital') === 'on'
    const assetDescription = String(formData.get('asset_description') ?? '').trim()
    const assetCategory = String(formData.get('asset_category') ?? 'equipment').trim()
    const assetInService = String(formData.get('asset_in_service_date') ?? '').trim()
    const assetLifeRaw = String(formData.get('asset_life_months') ?? '').trim()
    const assetResidualRaw = String(formData.get('asset_residual') ?? '').trim()

    // 前置校验(与 DB 二道防线一致,先给友好错误)
    if (!expenseDate || Number.isNaN(Date.parse(expenseDate))) {
        return { error: t('finance.errDate') }
    }
    if (!isCapital && !accountCodeRaw) {
        return { error: t('expense.errors.ACCOUNT_NOT_FOUND', { 0: '?' }) }
    }
    const amount = Number(amountRaw)
    if (!amountRaw || Number.isNaN(amount) || amount <= 0) {
        return { error: t('expense.errors.AMOUNT_INVALID') }
    }
    if (paymentStatus === 'unpaid' && !counterparty) {
        // 服务端也会拒(COUNTERPARTY_REQUIRED_FOR_UNPAID),这里只是早一步说人话
        return { error: t('expense.errors.COUNTERPARTY_REQUIRED_FOR_UNPAID') }
    }
    // ── EQP-1c-c:资本支出的两扇门,【由表单明说,不由这里推断】─────────────
    // capital_mode 是人选的(见表单里那两句话)。**不要从"assetId 填没填"倒推** ——
    // 一个推断出来的模式是一个没有人选过的模式,而选错的代价不对称:
    // 把"给旧机器加钱"错走成"买新机器",会多出一张【撤不回来】的资产卡。
    const capitalMode = String(formData.get('capital_mode') ?? 'new')
    const isAppend = isCapital && capitalMode === 'existing'
    const assetIdRaw = String(formData.get('asset_id') ?? '').trim()
    const poLineIdRaw = String(formData.get('purchase_order_line_id') ?? '').trim()

    let assetPayload: Record<string, string | number> | undefined
    if (isAppend) {
        // 【追加模式:p_asset 只带 asset_id】record_expense 按这一个键分支
        //  (v_append_id := p_asset->>'asset_id')。出生字段一个都不送 ——
        //  它们属于【卡】,不属于这笔支出,而表单在这个模式下也不再显示它们。
        if (!assetIdRaw) return { error: t('expense.errors.ASSET_NOT_FOUND', { 0: '?' }) }
        assetPayload = { asset_id: assetIdRaw }
    } else if (isCapital) {
        if (!assetDescription) return { error: t('expense.errors.ASSET_DESCRIPTION_REQUIRED') }
        const life = Number(assetLifeRaw)
        if (!assetLifeRaw || Number.isNaN(life) || life <= 0 || !Number.isInteger(life)) {
            return { error: t('expense.errors.ASSET_LIFE_INVALID', { 0: assetLifeRaw || '?' }) }
        }
        assetPayload = {
            description: assetDescription,
            category: assetCategory,
            useful_life_months: life,
            ...(assetInService ? { in_service_date: assetInService } : {}),
            ...(assetResidualRaw ? { residual_base: Number(assetResidualRaw) } : {}),
        }
    }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('record_expense', {
        p_expense_date: expenseDate,
        p_account_code: isCapital ? '1500' : accountCodeRaw,
        p_amount: amount,
        p_currency: currency,
        // FIN-0:不传汇率 —— 外币按费用日行方卖出价自动估值,当天缺牌价 DB 直接拒
        p_payment_status: paymentStatus,
        p_bank_account: paymentStatus === 'paid' ? bank || undefined : undefined,
        // 【二选一,原样传给库】库里那条 CHECK 要的就是恰好一个非空。
        p_supplier_id: paymentStatus === 'unpaid' && counterparty?.kind === 'supplier'
            ? counterparty.id : undefined,
        p_employee_id: paymentStatus === 'unpaid' && counterparty?.kind === 'employee'
            ? counterparty.id : undefined,
        p_payee_name: payeeName || undefined,
        p_notes: notes || undefined,
        p_asset: assetPayload,
        // EQP-1b-ii 的那一列,终于有了门。【可选】—— 没有采购单就买断一台机器是
        // 合法的,record_expense 也允许(那一列可空)。只在追加模式下可能有值:
        // 新建模式那一笔【不可能】带它(行上的 asset_id 是外键,资产得先存在),
        // 而 record_expense 对那种组合按名拒(EXPENSE_CREATES_ASSET)。
        ...(isAppend && poLineIdRaw ? { p_purchase_order_line: poLineIdRaw } : {}),
    })

    if (error) {
        return { error: await localizeExpenseError(error.message) }
    }

    const expenseId = (data as { expense_id?: string } | null)?.expense_id

    revalidatePath('/finance')
    revalidatePath('/finance/journal')
    revalidatePath('/finance/payables')
    revalidatePath('/finance/expenses')

    if (expenseId) {
        redirect(`/finance/expenses/${expenseId}`)
    }
    redirect('/finance/expenses')
}
