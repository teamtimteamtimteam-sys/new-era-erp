// scripts/pdf-routes/fake-supabase.mjs —— check-pdf-routes.mjs 的假客户端(替掉 '@/lib/supabase/server')。
// MES-7a-1(F11):路由的行为在 TypeScript 里,SQL fixture 够不着;这里给路由一个【记账】的客户端:表是内存里的几行,
//   rpc 由当前样例给出答案并记下每一次调用(谁被调了、调了几次),存储桶是一个 Map(上传、下载、删除都记下)。
//   它【不连任何库、不碰网】—— 一次跑不会在任何地方留下任何东西。每一个样例开头由 check-pdf-routes.mjs 重设 globalThis.__PDF_FAKE__。
function rowsOf(table) {
    const f = globalThis.__PDF_FAKE__
    return (f.tables[table] ?? []).map((r) => ({ ...r }))
}

class Query {
    constructor(table) { this.table = table; this.filters = []; this.single = null; this.isDelete = false }
    select() { return this }
    eq(c, v) { this.filters.push((r) => r[c] === v); return this }
    neq(c, v) { this.filters.push((r) => r[c] !== v); return this }
    is(c, v) { this.filters.push((r) => (r[c] ?? null) === v); return this }
    in(c, vs) { this.filters.push((r) => vs.includes(r[c])); return this }
    order() { return this }
    limit() { return this }
    maybeSingle() { this.single = 'maybe'; return this }
    single_() { this.single = 'one'; return this }
    then(res, rej) {
        globalThis.__PDF_FAKE__.reads.push(this.table)
        const rows = rowsOf(this.table).filter((r) => this.filters.every((f) => f(r)))
        const out = this.single === 'maybe' ? { data: rows[0] ?? null, error: null } : { data: rows, error: null }
        return Promise.resolve(out).then(res, rej)
    }
}

export async function createClient() {
    const f = globalThis.__PDF_FAKE__
    return {
        from: (table) => new Query(table),
        rpc: async (name, args) => {
            f.calls.push({ name, args })
            const h = f.rpc[name]
            if (!h) return { data: null, error: { message: `FAKE_RPC_NOT_STUBBED|${name}` } }
            try { return { data: await h(args), error: null } } catch (e) { return { data: null, error: { message: e.message } } }
        },
        storage: {
            from: (bucket) => ({
                upload: async (path, buf) => {
                    f.uploads.push({ bucket, path })
                    f.store.set(`${bucket}/${path}`, Buffer.from(buf))
                    return { data: { path }, error: null }
                },
                download: async (path) => {
                    const b = f.store.get(`${bucket}/${path}`)
                    if (!b) return { data: null, error: { message: 'not found' } }
                    return { data: new Blob([b]), error: null }
                },
                remove: async (paths) => {
                    for (const p of paths) { f.removed.push(`${bucket}/${p}`); f.store.delete(`${bucket}/${p}`) }
                    return { data: [], error: null }
                },
            }),
        },
    }
}
