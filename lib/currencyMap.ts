// lib/currencyMap.ts
// 银行账户 ↔ 其本币的对照表。**全仓唯一允许写下币种代码的地方**
// (scripts/check-currency-literals.mjs 的唯一例外,理由写在那份名单里)。
// 对应数据库函数 bank_native_currency(code) —— 加银行账户时两边必须同改。
//
// 【本位币不在这里】本位币是数据,从 currencies.is_base 读,见 lib/currency.ts。
// 纯函数、无依赖,所以服务端与客户端组件都能引。
const BANK_BY_CURRENCY: Record<string, string> = { SGD: '1000', USD: '1010' }

export function bankAccountFor(currency: string): string {
    return BANK_BY_CURRENCY[currency] ?? '1010'
}

export function currencyOfBank(bankCode: string): string | undefined {
    return Object.entries(BANK_BY_CURRENCY).find(([, code]) => code === bankCode)?.[0]
}
