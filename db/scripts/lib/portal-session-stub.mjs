// db/scripts/lib/portal-session-stub.mjs —— 本地取档证明替掉 '@/lib/portalSession' 用的那一个(MES-9b)。
// 答案由正在跑的那支证明挂在 globalThis.__PORTAL_SESSION__ 上(按它当前替谁跑路由);没有证明在跑时调到它就抛。
export async function isPortalSession() {
    if (typeof globalThis.__PORTAL_SESSION__ !== 'function') throw new Error('PORTAL_SESSION_STUB_NOT_INSTALLED — only a proof that installs globalThis.__PORTAL_SESSION__ may load this')
    return globalThis.__PORTAL_SESSION__()
}
export async function getSessionRole() { return (await isPortalSession()) ? 'supplier_portal' : 'authenticated' }
