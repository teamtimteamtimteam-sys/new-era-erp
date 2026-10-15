// scripts/pdf-routes/i18n-server.mjs —— check-pdf-routes.mjs 替掉 '@/lib/i18n/server' 的那一份(真的那一份要 next/headers 的请求上下文)。
//   路由的拒绝句子在这里说成 "<键> <参数>" —— 断言比的是【码】,不是措辞(措辞由 check-i18n 管)。
export async function getTranslations() {
    return (key, params) => (params && Object.keys(params).length ? `${key} ${JSON.stringify(params)}` : key)
}
export async function getLocale() { return 'en' }
