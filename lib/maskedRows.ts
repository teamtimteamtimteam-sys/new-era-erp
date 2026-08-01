// lib/maskedRows.ts
// 从遮蔽视图(<表>_masked)读回来的行,在类型上的两个事实:
//
//  1. 视图【没有 NOT NULL 约束】,所以 Supabase 生成的类型把【每一列】都标成可空 ——
//     包括 id、code 这种根本不会为空的列。这是视图的类型学噪音,不是业务含义。
//  2. 只有【被遮蔽的那几列】是真的会变成 null(当前登录者没有相应的 data.* 权限)。
//
// 于是分两种页面处理:
//
//  * 【会被遮蔽的页面】(进料、库存、加工、采购、薪酬……):敏感列保持可空,
//    渲染时用 <MaskedValue> 显示「受限」。不要 ?? 0 —— 0 是撒谎。
//
//  * 【不会被遮蔽的页面】(财务与定价):用下面的 unmasked<T>() 把行断言回基表行类型。
//    这样做是【有前提的】,前提今天成立并且被 fixture 量过:
//        能读 module.finance.view / module.pricing.view 的角色
//        (admin / finance / auditor)【全都持有 data.view_prices】,
//    所以这些页面上的敏感列永远不会是 null;它们改读遮蔽视图,单纯是因为
//    cut 2b 把基表的原始敏感列 SELECT 收回了。
//
//    【如果哪天授权变了】—— 比如给某个角色 module.finance.view 却不给
//    data.view_prices —— 这个断言就会开始撒谎。届时要改的地方就是调用这个函数的
//    那几处:把它们换成 <MaskedValue>。把断言集中在这里,就是为了让那次修改是
//    可搜索的、而不是散落在几十个 ?? 0 里。
export function unmasked<T>(row: unknown): T {
    return row as T
}

// 会被遮蔽的页面用这个:除了【列出来的那几列】之外,其余列恢复成基表的类型
// (视图带来的"人人可空"是类型噪音);被列出的列保持可空,因为它们【真的会】
// 因为权限不足而变成 null —— 渲染时交给 <MaskedValue> 显示「受限」。
//
//   maskedExcept<Tables<'inbound_batches'>, 'unit_price'>(rows)
//
// 读起来就是一句断言:"这一行和基表一样,只有 unit_price 可能被遮蔽"。
export type Maskable<T, K extends keyof T> = Omit<T, K> & { [P in K]: T[P] | null }

export function maskedExcept<T, K extends keyof T>(row: unknown): Maskable<T, K> {
    return row as Maskable<T, K>
}

export function maskedRows<T, K extends keyof T>(rows: unknown): Maskable<T, K>[] {
    return (rows ?? []) as Maskable<T, K>[]
}
