# CONV-0 —— 拒绝态收敛,以及走查带回来的六件事(2026-09-03)

> **这一刀【没有转换任何页面】。** 它把共享的那几块收敛掉,并修好 Tim 走查
> 部署系统时找到的六处。证明见本文末尾「没有转换页面的证据」。

## ① 拒绝态:18 种画法 → 一种,外加两个尺度

### 落地前的实测(PAGE-0 量的,本刀复核)

| | 数 |
|---|---:|
| `common.restricted` 的 `.tsx` 渲染点 | **41 处 / 28 文件** |
| 包着它的 tag + className 去重后 | **18 种** |
| `<Refusal>`(BASE-1 建的唯一画法)采用 | **0** |
| 整页拒绝那块屏的**逐字副本** | **3 份**,而且**已经开始漂** |

### ★ 采用之前先问它够不够用 —— 三种它表达不出来

委托书要求:「若 41 个渲染点里有任何一个需要它表达不出来的东西,那是一条关于
这个组件的**发现**,而且现在发现比一百九十页依赖它之后再发现好。」照做了,
结果是三条:

| # | 表达不出来的形状 | 处置 |
|---|---|---|
| ① | **块级**拒绝:一句话 + 一句提示(+ 权限码)。`ChartCard` 的 restricted 分支、整页那个琥珀框都是这种。药丸是 inline `<span>`,装不下两行 | **新建 `<RefusalBlock>`**,并把 `<RefusalPage>` 建在它上面 —— 于是块的形状**只有一份定义,用在三个尺度上** |
| ② | **大号数字位**上的拒绝(实测一处 `text-3xl font-bold text-gray-300`):`text-xs` 的药丸放进 3xl 的位置像一枚走丢的标签 | **本刀不动**。那是页面级决定,而这一刀不转换页面。**已记入 `docs/forward-queue.md`** |
| ③ | 拒绝**后面跟一段小字证据**(`ActorName` 的 `unrecordedHint`、那截 uuid) | **证据留在药丸外面**。它是附在拒绝上的凭据,不是拒绝本身;AUDEL-2/3 是**刻意**让它可见的 |

### ★★ `ActorName` 的状态 ② 【不上】`<Refusal>` —— 这是本节最要紧的一条

`ActorName` 有四个状态,而它们**不是同一种东西**:

| 状态 | 它在说什么 | 上药丸? |
|---|---|:--:|
| ① 查得到 | 一个人的名字 | — |
| ② 「该账号未关联员工档案」/「这份档案已经不在了」 | **关于【数据】的一句断言** | **不** |
| ③ 「未记录」 | 没有人填过 | ✅ |
| ④ 「受限」 | **一次权限答复** | ✅ |

把 ② 也画成拒绝药丸,等于教读者「数据缺口」与「权限墙」是同一件事 ——
而这个仓库从 `lib/permissions.ts` 起、每一刀都在把这两件事分开。**统一不值这个价。**

### 两个尺度用两种底色,而它是【两种】不是十种

药丸 `--brand-accent`(淡),块级琥珀(重)。BASE-1 抬头反对的是**同一句话在
不同页面上分量不同**;这里分的不是页面,是两件事:药丸 = 一个**值**被扣下了,
这一页你看得见;块级 = **这个地方**你进不来,它取代了本该在这里的全部内容。
琥珀是那三份副本**本来就在用**的颜色,所以合并它们**一个像素都没动**。

### 三份副本合并:漂掉的那一处往哪边收

`moduleGuard` 那份有「回首页」,另外两份没有。**收到有链接那一边** ——
被挡在门外的人需要一条出去的路,而那两份不是决定不要,是抄的时候少抄了一行。
`data-access-denied="1"`(按角色可达性检查认「拒绝页」的机器标记)从此跟着组件走,
不再由三处各写一遍。

### ★ 14 个文件,以及每一个可见的变化

改了 2 个共享组件,14 个已上线文件的拒绝态当场收敛。

**union 的口径先说清**:14 = **import `MaskedValue` 的 8 个** ∪
**import `ActorName` 的 7 个**,两者相交于 `app/purchasing/orders/[id]/page.tsx`
(8 + 7 − 1 = 14)。BASE-1 说的那个数**逐字对得上**。

**走 `MaskedValue` 的 8 个**(`text-gray-400 italic` 一行灰斜体 → **带边小药丸**;
此前它与「没填」「—」几乎分不开,现在一眼看得出这是**一句答复**):

| 文件 | 被扣下的是什么数 |
|---|---|
| `app/purchasing/orders/page.tsx` | 采购单**列表**的金额列 ← **风险最高的一处,见走查 21.1** |
| `app/purchasing/orders/[id]/page.tsx` | 采购单详情(**同时也走 ActorName**) |
| `app/purchasing/orders/[id]/RetentionPanel.tsx` | 质保金 |
| `app/operation/processing/[id]/page.tsx` | 加工单 |
| `app/operation/processing/[id]/CostPanel.tsx` | 加工成本 |
| `app/inbound/[id]/edit/LandedCostPanel.tsx` | 到岸成本 |
| `app/inbound/[id]/edit/PricingPanel.tsx` | 计价 |
| `app/inbound/[id]/assays/[assayId]/page.tsx` | 化验计价 |

**走 `ActorName` 的 7 个**(③「未记录」与 ④「受限」→ 药丸;小字证据留在药丸外;
★ ②【原样不动,仍是普通灰字】★):

| 文件 | 那个「谁做的」是什么 |
|---|---|
| `app/settings/deleted/page.tsx` | 谁删的 —— **线上 16 行里 14 行是「未记录」,同屏看多种状态最好的位置** |
| `app/tasks/[id]/page.tsx` | 任务的负责人 / 变更人 |
| `app/tasks/[id]/ChangeHistory.tsx` | 变更历史(走 `space='employee'`) |
| `app/stocktakes/[id]/page.tsx` | 盘点的执行人 |
| `app/finance/invoices/[id]/page.tsx` | 开票人 |
| `app/components/audit/BatchAuditTrail.tsx` | 批次审计轨迹 |
| `app/purchasing/orders/[id]/page.tsx` | 采购单的经手人(**同时也走 MaskedValue**) |

**三页整页拒绝**(唯一可见变化:后两页**多了「回首页」**):
`app/components/moduleGuard.tsx`(178 处调用点)· `app/settings/guard.tsx` ·
`app/settings/import/page.tsx`

### 一处必须说明的闸门改动

`scripts/check-base-isolation.mjs` 守的是「BASE-1 建的组件**还没有人用**」。
CONV-0 正是采用它的那一刀,所以这道闸**必然变红** —— 实测确实红了,点名五处
import。按**脚本自己写着的办法**把 `'refusal'` 从 `GUARDED` 里拿掉。
**说清楚它之后守什么:对 refusal 它已经用完了**(一个被采用的组件不可能再满足
「没有人用」);接替它的是「拒绝态的画法只有一份实现」。清单上**剩下的 11 个
组件一个都没被采用**,这道闸继续守着它们。

---

## ②a 定价在工具菜单上出现了两次

**Tim 的裁定:菜单上只有「定价」一条,它底下什么都没有。** 公式 / 计价器 /
金属行情**不进菜单**,由 `/pricing` 那一页自己列出来。

* 删掉三条 `FUNCTIONS` 条目(注册表 84 → 81);
* `/pricing/metal-prices` 的守卫 `requireFunction(FN.metalPrices)` →
  `requireModule(MOD.pricing)`。**求的是同一个字符串** `module.pricing.view`;
  换的是判据从哪条注册表条目取。拒绝页标题因此从「金属价格」变成「定价」——
  Tim 明确接受:菜单不再提供这一页,报模块名才是那句真话;
* **没有给组加 `href`**。`ModuleBar` 那条分寸(「组是一个标题,不是一个去处」)
  原样保留 —— 这一刀做的是让定价**不再需要**第三级。

### 可达性:实测,不是断言

```
module.pricing.view   admin, auditor, finance, gm, procurement, sales   （11 个角色里的 6 个）
module.pricing.edit   admin, finance, gm, procurement, sales
搁浅检查              无 —— 持有任一 pricing 码的角色都持有 module.pricing.view
```

三页的**页面守卫**求的都是 `module.pricing.view`（逐个读过，不是从注册表推的）。
**这是一次导航改动，不是一次访问改动。**

`user_dock` 实测 1 行，没有人把这三条钉在 dock 上；三者也都不是
`DOCK_DEFAULT_CANDIDATES`。`npm run check:dock` 事后跑过：11 个角色最少 1 条。

### ★ 顺带修掉一处**本刀发现的真缺陷**

撤菜单的前提是「`/pricing` 替它们当入口」。**那个前提此前是假的**:
第三张卡指的是 `metal-prices/**bulk**`(录入),金属行情**列表**只挂在卡片下面
一个灰色小链接上。菜单一撤,那个灰链接会成为列表页**唯一**的门 ——
**那不是整理菜单,那是把一页藏起来。**

处置:**列表与录入各给一张卡**(四张卡)。两条理由,第二条是决定性的:

1. 旧注释那条道理今天仍成立:每日录入是本板块最高频的动作,不该降一级;
2. **只留录入那张卡,对一个真实角色是一张必然被拒的卡** —— auditor 持有
   `.view` 而**没有** `.edit`,而 bulk 由 `requireEditPermission` 把门。
   也就是说撤菜单之前,审计员看到的三张卡里有一张点进去必然是拒绝页,
   而他**真正读得了**的那一页藏在灰链接后面。

灰链接随之删掉:列表既然有卡,再留一条指向同一页的灰链接就是同一个去处的
第二个入口 —— 正是菜单那一侧关掉的形状。**一个新 messages 键都没加**:
`pricing.pricesCard` / `pricesDesc` 本来就在,是那张卡被改指 bulk 时留下的孤儿键。

### 本刀之后,读者怎么走到这三页

| 页面 | 路线 | 点击数 |
|---|---|:--:|
| `/pricing/formulas` | 工具 → 定价 → **公式卡** | 3 |
| `/pricing/calculator` | 工具 → 定价 → **计价器卡** | 3 |
| `/pricing/metal-prices` | 工具 → 定价 → **金属行情卡** | 3 |

另有两条**未受本刀影响**的既有入口:`/pricing/metal-prices/bulk` 有自己的卡,
以及首页那条「行情陈旧」待办(`app/page.tsx:115`)。

### 第三级现在是财务独有的

`TOOLS_GROUPS` / `MODULE_GROUPS.tools` **留着**(Tim 的指示),但再没有条目带
`tools.group.pricing`;`moduleAccess.ts` 的「空组不渲染」把它滤掉,工具画成平铺
四条,**屏幕上不留残迹**。TOOLS-1 把「哪个模块有第三级」从写死的财务 id 泛化成
一张表,**工具是这张表在财务之外的唯一使用者** —— 本刀之后它又只有一个住户。
记下来是因为「一个没有使用者的能力,是下一个人据以断定『这里已经接好了』的东西」。

### ★ 一处**闸门没有抓住**的连带损伤(本刀读 diff 时抓到的)

删掉注册表条目之后,`metal-prices` 从「注册表答得上名字的段」变成了**普通路径段**,
于是 `gen-deep-routes` 把它加进 `BREADCRUMB_SEGMENTS`,而 `breadcrumb.metal-prices`
**两个语言都没有**。服务端 `t()` 对缺失键**返回键本身**,所以那些深路由的面包屑
会印出字面量 `breadcrumb.metal-prices` —— 正是 `docs/machine-text-reaching-humans.md`
记的那一族。**已补上两句。**

**而 `check-i18n` 没有变红,尽管它的 MANIFEST 里白纸黑字写着这条前缀接真源。**
实测:往 `BREADCRUMB_SEGMENTS` 里注入一个 `'zzz-bogus-segment'`,`check-i18n`
**照样退出 0**。原因:它的动态前缀是从源码里 `t('前缀' + x)` / `` t(`前缀${x}`) ``
**扫出来的**,而面包屑的键在 `lib/navTrail.ts:155` 是拼进一个**对象字段**
(`key: \`breadcrumb.${...}\``),`t()` 是在 `Breadcrumbs.tsx` 里拿变量调的 ——
扫描器看不见这个前缀,于是 `MANIFEST['breadcrumb.']` 这条**从来没有被驱动过**。
它是一条**看起来上了膛、其实没有**的判据,正是本仓库反复付账的
「标签与判据问的不是同一件事」。**本刀不修它**(那是另一件事,而且该由 Tim 排),
**已记入 `docs/forward-queue.md`。**

---

## ②b 流水构成:条与数字用了两个分母

标签写 25.5%,条却**画满整条轨道** —— 条长的分母是**最大的那一类**,
百分比的分母是**合计**。两个基准,读者只看得见一个。

**选的基准:合计。** 条和数字都答同一个问题「占全部流水的多少」。
旧注释那条顾虑是真的(最大的一类约占 25%,这张图会变矮)—— **接受它。
一张矮而真的图,胜过一根满格的条标着 25.5%。**

**基准写在图上**,与 `/finance/receivables` 那张「条长是四个档位之和里的占比」
逐字同一种做法:

* EN `Bars are shares of all {total} movements added together. …`
* ZH `条长是全部 {total} 条流水里的占比。…`

---

## ②c 三张图都在拿数据库标识符当「来源」

走查点了两张,**实际是三张** —— `ChartCard` 只有三个调用点,三个都在印标识符:

| 图 | 此前印的 | 现在印的 |
|---|---|---|
| `/finance/receivables` | `ar_aging_asof(as_of)` | 还没收回来的款,按拖欠了多久分档。 |
| `/inventory/reports` | `inventory_movements.movement_type` | 建库至今的每一笔库存进出,按它是哪一种进出分类。 |
| **`/hr/org`**(走查未点名) | `employees_masked · departments` | 员工档案,以及他们各自属于哪个部门。 |

英文各自另写,**中文不是英文的直译**。

**字段名本身也换了**:「来源」/「Source」→ **「这张图画的是」/「What this shows」**,
并且**去掉了 `<code className="font-mono">` 包装** —— 一句人话套在机器字体里,
读起来仍然像机器输出;换了词却留着那身衣服等于只改了一半。

`ChartBasis.source` 的**类型注释也改了它问的问题**:从「读的哪一张表/视图/函数」
改成「用一句人话说,这张图画的是什么」。真源没有丢 —— 它仍然写在各张图自己的
文件抬头里,那是给下一个改这张图的人看的,本来就不该在纸面上。

---

## ②d 账龄 90+:条是红的,数字不是

**走查的说法需要更正一处,而更正之后缺陷更清楚。**
`AgingBars.tsx:52` **本来就**设了 `emphasis: b === 'b90_plus'`,`BarRows.tsx:70`
把那根条画成 `--brand-destructive-fill`。**条一直是强调色的。**
不红的是那一行的**数字**:汇总条里它是 `text-red-600`,图里是正文黑。
**同一个数在同一页上带着两种警戒等级,相距不过六英寸** —— 那才是缺陷。

**处置:让 `emphasis` 也管那个数字**(Tim 的 A)。用的是**条子自己那个颜色**,
不是另挑一个红:数字与它的条从此逐字节同色。

**量过**:`--brand-destructive-fill` `#B75B53` 对卡面 `#FFFFFF` = **4.53:1 ✓ AA**
(`text-xs` 属正文,门槛 4.5)。
`--brand-destructive` `#C0635A` —— token 表里写着「文字用」的那一个 —— 只有
**4.06:1**,**没有用它**。

**汇总条的 `text-red-600` 原样不动**,而这是量出来的决定不是遗漏:
汇总条底是 `bg-gray-50 #F9FAFB`,`text-red-600` 在它上面 **4.62:1 ✓**,
而 `--brand-destructive-fill` 只有 **4.34:1 ✗** —— 把汇总条也换成品牌色会**跌破 AA**。

### `BarRows` 是共享的 —— 组织架构图那边变了什么

**什么都没变。** `BarRows` 只有两个使用者:`AgingBars` 与 `MovementMixChart`,
而**组织架构图不用它**(它是 `OrgChart.tsx`,SVG 画的;它只共用 `ChartCard`)。
全仓库**只有 `AgingBars` 传 `emphasis`**,所以这处改动实际只影响一张图。
`/hr/org` 受本刀影响的是 **②c 那一条**(出处那一格),不是 ②d。

---

## ②e 银行在错误的分组里

**先判定它是什么,再决定它去哪** —— 委托书要求的顺序。

* `app/finance/bank/page.tsx` 自称**银行对账首页**,读 `bank_reconciliation_status`;
* 名下全部子路由:`statements/` · `import/` · `statements/[id]/reconcile/` ——
  **一条主数据维护路径都没有**;
* 银行**账户**主数据在这一页上不存在:全仓库引用 `bank_accounts` 的只有
  `app/finance/assets/page.tsx` 一处,账户本身是会计科目;
* 唯一不是对账的是页内 `TransferForm`(账户间调拨)—— 那是一笔**交易**,不是主数据。

**结论:不是「两件事共用一个入口」,不需要拆。** 整条搬到**期末**,判据一字未动。

---

## ②f 每一份对外单据脚下那一句「无需签章」

### 八份对外单据,以及各自那一句(请在发出去之前否决)

判据用的是仓库**自己已经有的**那一条(`ReportDocument.tsx` 抬头):
**这份东西离不离开这栋楼。**

| # | 单据 | 英文 | 中文 |
|---|---|---|---|
| 1 | 采购单 | This is a computer-generated purchase order and requires no signature. | 本采购单由系统生成,无需签章。 |
| 2 | 销售订单 | This is a computer-generated sales order and requires no signature. | 本销售订单由系统生成,无需签章。 |
| 3 | 报价单 | This is a computer-generated quotation and requires no signature. | 本报价单由系统生成,无需签章。 |
| 4 | 送货单 | This is a computer-generated delivery order and requires no signature. | 本送货单由系统生成,无需签章。 |
| 5 | 发票 | This is a computer-generated invoice and requires no signature. | 本发票由系统生成,无需签章。 |
| 6 | 贷项凭证 | This is a computer-generated credit note and requires no signature. | 本贷项凭证由系统生成,无需签章。 |
| 7 | 客户对账单 | This is a computer-generated statement of account and requires no signature. | 本对账单由系统生成,无需签章。 |
| 8 | 可追溯报告 | This is a computer-generated **report** and requires no signature. | 本**报告**由系统生成,无需签章。 |

**不印的:四张库存报表**(snapshot / ledger / safety / violations)——
它们不离开这栋楼。一张自己给自己看的表不需要声明它不用签字。

**中文不是英文的直译。** 直译会得到「本采购单是电脑生成的,不需要签名」——
那不是中文单据上会出现的句子。中文商业单据的定说是「由系统生成」+「无需签章」;
用**签章**而不是**签名**,因为中文语境里对应的是公章,不是手写名字。

**它什么都没说到审批。** 只说这张纸不需要签字,不说「它已被批准」——
后者必须系在真实的审批状态上,那是 Tim 没有裁的另一件事。

### ★★ 斜体做不到,而理由比「不好看」硬得多 ★★

委托书点名要确认字体真的有斜体面、而不是让渲染器伪造倾斜。**两件事都不成立,
而实测结论比源码阅读更硬:**

```
registered faces per family:
  Google Sans:  normal/bold — all fontStyle 'normal'
  Noto Sans SC: normal/bold — all fontStyle 'normal'

render attempts:
  upright (what we shipped)    RENDERED ok, 4276 bytes
  fontStyle:'italic'           THREW: Could not resolve font for Google Sans,
                                      fontWeight 400, fontStyle italic
```

`assets/fonts/` 只有四个文件,`fonts.ts:141` 把它们**全部**注册成
`fontStyle: 'normal'`。`@react-pdf/font` 的 `resolve()` 先按 `fontStyle` 精确过滤
(`node_modules/@react-pdf/font/lib/index.js:315`),过滤空了就**抛错**(同文件 `:341`)
—— 它**不退回正体,也不做合成倾斜**。也就是说写 `fontStyle:'italic'`
**不是「斜体没生效」,是这条 PDF 路由 500**。
(而且 Noto Sans SC 根本没有真正的斜体面,中文那一半无论如何是正的。)

**用什么代替:7.5pt + `BRAND.muted` + 正体 + 上留白 16pt** ——
斜体在这里要的是**语气**不是**倾斜**,而这正是这份单据**已经在用**的那个语气
(`docStyles.footerNote` 一模一样)。不为一句话建一条字体管线,
也不在 `check-pdf-font-stack` 那道闸上留一个永久的不对称。

### 位置:正文流末尾,印【一次】

`DocumentFooter` 是 `fixed` 的 —— 放进去会**每一页都印一遍**。一份五页的对账单上
重复五次「无需签章」读起来像系统在心虚。Tim 的裁定是「在总计与条款**之下**」,
那是正文的末尾。所以它印**一次**,在最后一页,**不挤占**各单据自己的页脚说明
(贷项凭证那句「这不是退款」等等一个字没动)。

### 一句话,一处来源

六份单据是**一律英文**的,它们**显式取英文那一份**
(`noSignatureEn()`,`app/components/pdf/noSignature.ts`);对账单与可追溯报告
**跟随界面语言**,走 `t('pdf.noSignature.*')`。
**句子只有一处**(`messages/{en,zh}.ts`)—— 让那六份各自硬写一句英文会造出
同一句话的第二份来源,而两份必然漂开。函数名里带 `En`,是要让读的人在调用点就
看见语言是被钉死的,而不是「忘了国际化」。

### 「少一份比一份都没有更坏」由**类型**保证,不靠记性

`ReportDocument` 的 `company`(= 对外)与 `noSignature` 绑成了一个联合类型:
**传 company 而忘了 noSignature 是编译期错误。** 实测有效 —— 改完类型之后
`app/output/[id]/traceability/pdf/route.tsx:49` 当场编译失败,直到把那一句传进去。
(与 `ChartCard` 把 `basis` 设成必填是同一种手法:说不出来就画不出来。)

---

## ②f 的纸面证据 —— 以及它【没有】证到的两件

`scripts/render-pdf-samples.mjs` 走真路由、带真会话、拿真数据,把单据落到磁盘上
(它**刻意不断言** —— 判据是那张纸)。本刀跑了一次,**11/12 出纸**,逐张看过:

* **采购单** —— 那一句在**总计与付款计划之下**、正文末尾、小号灰字**正体**,
  **只有一次**;底下 PDF-1 那条页脚说明与页码**一个字没动**(它没有被挤掉);
* **可追溯报告** —— 印的是「computer-generated **report**」,不是任何一种商业单据名,
  位置在既有那段「回收率是估算不是审定 KPI」之下;
* **四张库存报表** —— **都没有这一句**,也没有抬头。判据(离不离开这栋楼)成立。

**中文那八句【逐字符】查过覆盖**:`assets/fonts/coverage.json` 的 7290 个码位里
**一个都不缺**,所以不会出现豆腐块,也不会静默丢字
(PDF-1 栽过的那一次是 `上海金属回收有限公司` → `wÑ^Þ6 Plø`,HTTP 200 而没有一道门变红)。

### ★ 两件【没有证到】的,照直写出来 ★

1. **客户对账单没有出纸** —— 线上 `NO DATA`(一张对账单都还没开过)。
   它的那一句是**唯一一句走 `t()` 的**(跟随界面语言),
   **代码路径与另外七份一致,但那张纸没有人见过。** 走查 §21.7 第 7 条欠着。
2. **「多页时只印一次」没有被机器证过** —— 出纸的八份对外单据**全是一页**。
   `report-ledger` 确实是 3 页,但它是**内部**报表,本来就不印这一句。
   这一条的论据仍然只是**结构性的**(它在正文流里、不在 `fixed` 的 `DocumentFooter` 里),
   **而不是看过的**。走查 §21.7 第 2 条点名要拿一份多页的对账单或采购单确认。

**说清楚这两件,是因为「渲染成功」与「那张纸是对的」不是同一件事** ——
这正是 `render-pdf-samples.mjs` 抬头写着它自己不断言的理由。

---

## 没有转换页面的证据

改动只落在:2 个共享 UI 组件 + 3 处整页拒绝的调用点 + 2 个图表共享件 +
3 个图表调用点 + 8 份 PDF 单据与它们的共享件 + 注册表 + messages + 两支脚本。
**没有一页被套上模板、没有一张表换成 `DataTable`、没有一处外壳被替换。**
`scripts/check-base-isolation.mjs` 仍然断言:除 `/login` 那 4 处既有转换之外,
**11 个基础组件一个都没有被页面采用**。
