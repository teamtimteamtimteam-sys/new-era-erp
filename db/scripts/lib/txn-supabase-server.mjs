// db/scripts/lib/txn-supabase-server.mjs —— 线上证明替掉 '@/lib/supabase/server' 用的那一个(MES-7a-1)。
// 客户端本身由正在跑的那支证明挂在 globalThis.__TXN_CLIENT__ 上:它把 .from / .rpc 变成【那笔开着的事务里】以一次性账号身份跑的 SQL,
//   .storage 是真的 Storage API。本文件只是一个转接口 —— 它自己不连任何东西;没有证明在跑时调到它就抛。
export async function createClient() {
    if (typeof globalThis.__TXN_CLIENT__ !== 'function') throw new Error('TXN_CLIENT_NOT_INSTALLED — only a live proof that installs globalThis.__TXN_CLIENT__ may load this')
    return globalThis.__TXN_CLIENT__()
}
