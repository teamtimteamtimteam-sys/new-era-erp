// app/tools/pricing/metal-prices/options.ts
// PROC-4:这里曾经放着【一份写死的七金属清单】—— 值、顺序、名字三件事都由它定,
// 16 个文件引用它,而它与库里那八条 CHECK 是同一份清单的第五个副本。
//
// **它没了。** 清单、顺序、名字现在全部来自 `substances` 那张字典,
// 由 `./substanceQuery` 读出来、按 props 传进各个表单。
// 加一种物质 = 加一行,不必改 app、不必发版 —— 那是把它做成字典的全部意义。
//
// 【这个文件留下来,是因为类型还有人用】而不是因为清单还有人用。
export type { Substance } from './substanceQuery'

/** 下拉/复选框的选项形状。
 *
 *  ~~【清单与顺序来自库,名字来自 i18n】labelKey 仍然是 'metals.<code>'~~
 *  ★ MES-6a-2(Step 0 Q30,Tim):【清单、顺序与名字都来自库】—— label 是字典自己的 name_en / name_zh(按读者语言),
 *  role 说它在商务上是什么(定价那几页只收 payable_metal,惩罚条款只收 penalty_element)。形状的定义在 lib/substances.ts。
 *
 *  isActive:能不能【新选】。展示用的名字不看它,选单看它(D5 的两个动词)。 */
export type { SubstanceOption as MetalOption } from '@/lib/substances'

/**
 * code → i18n 键。
 *
 * 【PROC-4 之后它【总是】给得出键,而这比从前更强,不是更弱】
 * 从前它在写死的七元素清单里找,找不到返回 null,调用方回退到显示原始 code ——
 * 那个回退是必要的,因为库里【可能】存着清单外的值(两份清单会漂开)。
 * 现在不会了:八张表的 metal 列都有外键指向 substances,所以【数据里出现的每一个码
 * 都在字典里】;而 check-i18n 的 metals. 判据读的就是字典的引导行,所以
 * 【字典里的每一个码都有 en 与 zh 两条翻译】,漏了一条 npm run build 当场点名。
 * 两头一夹,"找不到"这个分支从此不可达 —— 于是它不再是一个分支。
 */
export function metalLabelKey(value: string | null | undefined): string | null {
    return value ? 'metals.' + value : null
}
