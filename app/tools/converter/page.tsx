// app/tools/converter/page.tsx — 单位换算器(TOOLS-1 ④)。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【这一页承载着一条产品保证 —— 改它的判据之前先读这段】★★
// 它的注册表判据【刻意】是恒真的(lib/modules.ts 的 /tools/converter),
// 因为 lib/dock.ts 的默认候选靠一条"任何人都进得去"的条目来兑现 Tim 的 4c:
// **新同事第一次登录时 dock 不能是空的。**
// 实测:关掉这一条,employee 角色(即将到岗的六位同事拿到的那个)的默认 dock
// 变成 0 条。`npm run check:dock` 会为此变红。
//
// 【业务单位,不是通用换算器】Tim 的裁定:不做长度/温度/体积 ——
// 手机上就有,他不会用系统里的那个。这里只做这家公司真的在算的三样。
//
// 【三档各自的出处,分开标 —— 这是一个给人【核对】用的工具,所以出处要在屏幕上】
//   · 吨/公斤/磅 :公吨=1000kg 是系统自己在用的(lib/valuation.ts 的 /1000,
//                 一条算钱的路径);而【磅全仓库没有任何定义】,所以用 SI 的
//                 精确值 0.45359237,并把这件事印在屏幕上。
//   · 品位       :1% ≡ 10000 g/t 是【定义性恒等式】,不是谁的约定;
//                 而且系统内部一律用百分比记含量,g/t 这一档只服务读化验单的人。
//   · 湿转干     :**调数据库**(convert_weight_basis / convert_grade_basis),
//                 与结算是同一份实现。取整 4 位的出处是 sale_settlement_compute。
// ════════════════════════════════════════════════════════════════════════════
import { getTranslations } from '@/lib/i18n/server'
import ConverterForm from './ConverterForm'

export default async function ConverterPage() {
    // 【没有 requireModule】—— 这一页刻意对任何登录用户开放(见抬头)。
    // 它不读任何业务数据:输入是使用者自己敲进去的数。
    const t = await getTranslations()
    return (
        <div className="p-6 max-w-3xl">
            <h1 className="text-2xl font-semibold mb-1">{t('converter.title')}</h1>
            <p className="text-sm mb-6" style={{ color: 'var(--brand-muted-text)' }}>
                {t('converter.intro')}
            </p>
            <ConverterForm />
        </div>
    )
}
