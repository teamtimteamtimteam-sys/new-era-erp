# POLISH-1 —— 交回报告(round 3;2026-09-13)

> ### ★ 屏幕上变了什么,一句话
> **组织架构图的七张卡片里那十四段字居中了;`/finance/cash-forecast` 上全树唯一一个真的贴着上一块的小节标题拿到了 32px 的气口;
> 二十八条给人看的句子里的表名 / 列名 / 库函数名 / 一条测试路径 / 十七条路由路径变成了人话;日历那条横幅的双句号没了;
> 而 `<DataTable>` 那个行展开箭头(每视口 480 颗)走进了共享档位 —— 渲染高度逐颗逐字未变。**

> ### ★★★ 这一轮存在的理由:**round 2 的裁定段点了十六件,它的 §3 提交清单点了九件,差的七件【没有做】** ★★★
> 那七件在 round 2 的裁定里**没有 R 号**,于是不在它的提交清单里,**那一轮正确地没有去动它们**。
> ☞ **遗漏在委托书里,不在活里。** 本轮关它们。

---

## 0 · 先读这五条

1. ★★★ **本轮有【三处】停手,而它们停的是同一件事的两种形状:共享 `<Button>` 复刻不出一个已经存在的几何。**
   * **item q(48px)** —— 九个档位是 **24 / 28 / 32 / 36**(外加 `h-auto` 与四个方钮档),★ **没有 48px**。
     裁定原话:「**如果没有一档是 48px,停下来把档位报出来,不要发明一档。**」
   * **分页那一对(30px)** —— 同一张表里 ★ **也没有 30px**。
   * ★★ **排序表头钮(21.42px)—— 这一颗【转过去了、量了、又按回来了】**,而它的停手理由**与上面两条不同**:
     不是「缺一档」,是**共享层的基础串里有 `border border-transparent`**,上下各 1px → **21.42 → 23.42px(+2)**,
     左右各 1px 压窄可用宽 → **三个长表头折成两行(→ 44.84px)**,**表头行 42.42 → 65.84px**。
   ☞ ★★★ **最后那一条的射程远超这一颗:任何一个 `border-width: 0` 的裸控件转到共享 Button 上,都要付这 2px。**
   **`BTN-TRIGGER-1` 那 33 处裸触发钮继承这个数** —— 那一刀开工前先读本文 §8.2。
2. ★★ **item y 的诚实结果是【0 次屏幕改动】,而那是把三条裁定应用下去之后的结果,不是没做。**
   20 个站点逐个在**今天这棵树**上读过(3 处行号已漂,按内容重新定位)、逐个给了判词:
   **4 个已经就在标准上**(§4.4 / §4.4a —— ★ 判据是把 token **解析到值**,不是读 class 名)·
   **6 枚状态片**(§4.4a 的 S3 豁免明写「不必再判第二遍」)·
   **6 个的颜色由容器 / 状态表达式拥有**(同一条豁免判据)·
   **3 个要一条【round 2 那三条裁定都没有覆盖】的裁定** · **1 个半件挂 Tim 名下**(S5 禁止换标签)。
   ★ **4 + 6 + 6 + 3 + 1 = 20,分母对得上,一条都没有静默跳过** —— 逐条见 §5。
3. ★★ **round 1 在 item x 上报过的那个零,本轮复现了它【为什么】是零,并且换了量法。**
   round 1 用 `previousElementSibling` 量气口,而全树 **69%** 的标题是容器的**第一个孩子** ——
   那一支返回 `null`,它们整批从分母里消失,于是报出「0 个气口 ≤4px」= 读起来像「已经修好了」。
   ★ **本轮的分母是 121(desktop)/ 119(phone),与 FONT-3 的「约 120」吻合;round 1 那一支看见 37。**
4. ★★ **item t 的卡片是 SVG。** 一个 `text-center` 类在它们身上**什么都不会发生**(`text-align` 不作用于 SVG 文本节点)。
   改的是 `x` 与 `textAnchor` **两样**,而且**两段文字都改** —— 实测 `x` 从 `10` 变成 `84`(= `BOX_W / 2`)、
   `text-anchor` 从 `start` 变成 `middle`,**十四段字的左右留白从 `10 / 82–137` 变成两边逐段相等**。
   ★ **判据是【两边留白相等】,不是【x 变了】** —— 只改 `x` 会把字整块推到右边,比改前更坏。
5. ★ **item z⑦ 今天在屏幕上看不到**(BUGFIX-1a 修掉 `container_no` 之后,`/tools/calendar` 不再出那条横幅),
   **所以这一件的验收是【字符串层面】的,不是一次目视确认** —— 照直说,别把它写成后者。

---
## 1 · §3 的清单 vs 真的改了什么 —— **R17–R24 逐条 DONE / NOT DONE**

> ★ **委托书 §3 的要求逐字照办:「BEFORE COMMITTING, walk R17-R24 one by one against what you actually
> changed, and state DONE or NOT DONE for each with its evidence. Anything you cannot mark DONE is NOT DONE。」**
> ☞ 下面这张表就是那一遍,而它**排在提交之前写的**。

| 裁定 | 状态 | 证据 |
|---|---|---|
| **R17** item q · Cancel Stocktake 要 48px | ⛔ **NOT DONE —— 按裁定停手** | 九个档位里没有 48px(最高 36px)。裁定原话:「If no existing step is 48px, STOP and report what the steps are rather than inventing one.」★ 档位表 + 那一对的改前高度(48 / 32px,两个视口)见 §2;登记 `known-issues.md · POLISH1R3-NO-48PX-BUTTON-STEP`、spec §2A.1 就地补记 |
| **R18** item t · 组织图卡片文字居中 | ✅ **DONE** | `OrgChart.tsx` 的两段 `<text>`:`x` `10 → 84`、`textAnchor` `start → middle`。实测 14 段字左右留白从 `10 / 82–137` 变成两边相等 —— §3 |
| **R19** item x · 小节标题的气口 | ✅ **DONE** | `ForecastGrid.tsx` 外层 `<div>` 补 `mb-8`。那一个 h2 的气口 `0.00 → 32.00px`,两个视口;★ **分母改前 121 / 119、改后 121 / 119** —— §4 |
| **R20** item r · 开发者黑话那一半 | ✅ **DONE** | 16 处 snake_case:**改 11 · 留 5(权限码,带在案理由)**;17 条真路由**全部**换成导航上的页面名;4 处 `/kg` 是单位、是扫描器误报。**逐条带判词** —— §6;文档落点 `machine-text-reaching-humans.md` 形态三 |
| **R21** item y · FONT-2 的 20 个站点 | ✅ **DONE(判词全给,屏幕改动 0)** | ★ **实测的 split 不是「20」也不是「12」** —— 逐个站点的今天状态见 §5。★ **屏幕上 0 处改动,而那是把三条裁定应用下去的结果**:能覆盖的都落在「已经在标准上 / 状态色留着」。**2 处要一条没人做过的裁定,点名了是哪一条。** |
| **R22** item z⑦ · 双句号 | ✅ **DONE** | 键 `calendar.sourceFailed`,en + zh 各一处,**把 `{list}` 挪到句末**(不是删那个句号 —— 理由见 §7)。`known-issues.md` 那一条改判 CLOSED |
| **R23** 继承的 ① · DataTable 的裸 `<button>` | ⚠ **1 / 4 DONE,3 按裁定停手** | ✅ **展开箭头**(**28×28px**,每视口 **480 颗** —— 四个里唯一铺在全树上的)逐颗逐字段比过,高度一个都没动。<br>⛔ **排序表头钮:转过去了,量到 21.42 → 23.42px(5 格)/ 44.84px(3 格折行)、表头行 42.42 → 65.84px,按裁定【按回原样】。**<br>⛔ 分页那一对(**30px**):档位里没有 30。<br>★ 逐颗读数、病因与比对见 §8 |
| **R24** round 2 的收尾行 | ✅ **DONE** | `docs/handbacks/POLISH-1.md` 与队列 POLISH-1 抬头各加一格:`9283420…` **Deployment SUCCESS**,★ 并**明写它是一份转述、不是这台机器的一次测量** |

### ⛔ 本轮【没有做】的,逐条点名(免得再从清单里漏第二次)

| 件 | 为什么 |
|---|---|
| **R17** item q 的那次改动 | ★ **裁定自己要求停手**(没有 48px 档)。**不是漏掉,是照着停手条款走的。** 它现在等**一次裁定**,不是等一把刀 |
| **R23** 的分页那一对 | 同上(没有 30px 档)。★ **与 item q 是同一次裁定** |
| item y 里 2 处 | `RequiredMetalsPanel.tsx:67` · `notifications/page.tsx:80` —— 它们要的是「100 处 `text-gray-600` 要不要归到 token 上」那条裁定,而 ★ **实测换过去会【降低】对比度 2.73**(§5) |
| item y 里 `alert.tsx:55` | ⚠ **ALERT-2b 的封闭文件,谁都不许碰。** ★ 而本轮顺手验证了它**本来就是对的**:`text-muted-foreground` 解析成 `--brand-muted-text`,与 §4.4a 的横幅标准一致 —— **就算能碰也不用改** |
| item y 里 `inbound/receive/done/[id]` 那一处 | `<div>` → `<h3>` 那一半**挂 Tim 名下**(S5 禁止换标签);字族与字重 FONT-3 已经做掉 |
| `/finance/page.tsx:206` 那处 4.06:1 | ★ **本轮量到、没改**:它是一枚**状态色**(按 S3 豁免该留),同时**过不了 AA**。「状态色过不了 AA 时怎么办」round 2 只对日历那三枚色片裁过(R13),没有裁成通则。登记 `POLISH1R3-DESTRUCTIVE-AS-TEXT-4-06` |
| z① · z①-b · z② z③ z④ z⑤ z⑥ z⑧ · 接手的 ② ③ ④ ⑤ · o p s u v w | ★ **不在本轮的七件里。** 本轮的范围是委托书 §2 的 R17–R24,一件不多一件不少 |

---
## 2 · R17 · item q —— **停手,而档位表就是判词**

**走查看到的:** `/stocktakes/[id]` 底部那条粘性操作栏上,「Cancel Stocktake」比「Review & Post」矮。

### 2.1 那一对,实测(两个视口逐字相同)

| 按钮 | 元素 | `data-size` | `data-variant` | ★ **渲染高度** | `min-height` | 字号 |
|---|---|---|---|--:|---|--:|
| **Review & Post** | `a[data-slot=button]` | `default` | `default` | ★ **48px** | `48px`(调用点手写的 `min-h-[48px]`) | 16px |
| **Cancel Stocktake** | `button` | `default` | `destructive` | ★ **32px** | `auto` | 14px |

容器是 `<div className="flex gap-3">`;`/stocktakes/[id]` 是**动态路由**,
`survey-controls.mjs` 按构造走不到它 —— 本轮的探针加了一个 `--urls=` 口子,
用一张 `status='open'` 的盘点单(`ST-2026-0082`)把它量到了。

### 2.2 ★★ 九个档位,逐个 —— **没有 48px**

| 档 | 类 | 高度 |
|---|---|--:|
| `xs` | `h-6` | 24px |
| `sm` | `h-7` | 28px |
| `default` | `h-8` | **32px** |
| `lg` | `h-9` | 36px |
| `inline` | `h-auto` | 随内容 |
| `icon` | `size-8` | 32px |
| `icon-xs` | `size-6` | 24px |
| `icon-sm` | `size-7` | 28px |
| `icon-lg` | `size-9` | 36px |

☞ ★★ **最高的一档是 36px。48px 不在表里。**

### 2.3 ★★★ 而这件事的真相比「缺一档」更值一行:**E6 那 48px 从来不是一个档位**

spec §2A.1 的 E6(收货与盘点两页的触控档)名下有 **11 处 `min-h-[48px]`** ——
★ **十一次手写**,分布在 6 颗按钮与 9 个输入框上(那一节自己早就逐处列过)。
☞ 所以「Review & Post」那 48px **本身就是一次手写**。走查看到的不是「一颗按钮掉了档」,
是 **E6 这条例外从立起来那天起就没有任何档位承载它**。

**它要的下一步(两条,都超出 item q 的范围):**
① 给共享 Button 加一个触控档(`h-12` = 48px),再把那 6 颗手写的转过去 —— 「库里缺这个能力,就先把能力加进库」的形状(§八(b));
② 或者裁定「E6 就是手写的」,并把 Cancel Stocktake 也手写成 `min-h-[48px]` —— ★ **但那与 item q 明文禁止的「不许手写高度」直接冲突。**

### 2.4 ★ 队列还要的那一遍:**「把收货与盘点其余各页同样成对的按钮找一遍」**

★ **找过了,而且是按【形状】找的,不是按名字:** 全树凡是一个容器下面挂着两颗以上按钮的地方,
逐个容器把每一颗的高度读出来。

| | 个数 |
|---|--:|
| 这样的容器(两个视口各自) | **105** |
| ★ 其中**高度不一致、且其中一颗 ≥44px** 的 | ★ **1** |

☞ ★ **那一个就是走查点到的这一个。没有第二处。**
`/inbound/receive/done/[id]` 那一对**两颗都是** `min-h-[48px]`(一致);
`CountList` · `ReceiveForm` · `StocktakeQuickCount` 那几颗是**整宽单钮**,没有兄弟可比。
**所以「不要只改 Tim 点到的那一颗」这条要求,在这一件上的答案是:只有那一颗。**

---
## 3 · R18 · item t —— **组织图卡片文字居中,而它是 SVG**

### 3.1 ★★ 为什么一个 class 改不动它

`app/components/charts/OrgChart.tsx` 的 `NodeBox` 画的是 **SVG**:一张 `<rect>` 加**两段 `<text>`**。
★ **SVG 文本的水平位置由 `x` 与 `text-anchor` 定,`text-align` 对它【不起作用】。**
☞ 所以「加一个 `text-center`」在这里**什么都不会发生**,而且它的失败方式是**一个安静的零**:
代码里多了一个类,屏幕上一个像素都没动,而任何按 className 记账的检查都会说「改了」。

### 3.2 ★ 两样一起改,而且**两段字都改**

| | 改前 | 改后 |
|---|---|---|
| 名字那一段(13px) | `x="10"` · `text-anchor: start`(默认) | ★ `x={BOX_W / 2}` = **`x="84"`** · `textAnchor="middle"` |
| 编号那一段(10px) | `x="10"` · `text-anchor: start` | ★ **同上** |

★ **只居中名字会让编号那一行仍然靠左** —— 那比两行都靠左更难看,也不是走查要的东西。

### 3.3 ★★ 实测:`/hr/org` desktop,**7 张卡 × 2 段字 = 14 段,逐段**

| | 改前 | 改后 |
|---|---|---|
| `x` 属性 | `10`(14/14) | ★ **`84`**(14/14) |
| `text-anchor` | `start`(14/14) | ★ **`middle`**(14/14) |
| 卡片宽 | 168px | 168px(不变) |
| ★ **左留白 / 右留白** | ★ **`10` / `82–137`**(靠左,右边空一大块) | ★★ **两边逐段相等** —— `57.01/57.01` · `46.09/46.09` · `69.52/69.52` · `46.08/46.08` · `63.65/63.65` · `45.91/45.91` · `60.39/60.39` · `46.72/46.72` · `73.52/73.52` · `46.30/46.30` · `67.86/67.86` · `46.20/46.20` · `64.49/64.49` · `25.07/25.07` |
| ★ 会不会溢出卡片 | — | ★ **不会:最宽那一段字 117.86px < 168px**(而名字本来就 `.slice(0, 20)`) |

☞ ★ **判据是【两边留白相等】,不是【x 变了】。** 一个只检查 `x` 的断言会被
「`x` 改了而 `textAnchor` 没改」骗过去 —— 那种改法会把字**整块推到右边**,比改前更坏。
**两个属性一起量,才是「居中」这句话。**

⚠ **phone 上量不到这一块**:那一半是 `md:hidden` 的缩进列表,SVG 树 `hidden md:block`
(读数里 `boxW: 0`)。★ **两种渲染是刻意的**(文件抬头写着理由:脏数据在两边都要看得见),
**而列表那一半的文字本来就不需要居中** —— 它是一份大纲,靠缩进表达层级。

---

## 4 · R19 · item x —— **气口,而 round 1 那个零是怎么来的**

### 4.1 ★★★ 先说量法,因为 round 1 的教训在量法里,不在结论里

round 1 报过「**0 个标题的气口 ≤4px**」,读起来像「已经修好了」。★ **机制:**
它用 `previousElementSibling` 量气口,而**全树 69% 的标题是它容器的【第一个孩子】** ——
那一支返回 `null`,于是**它们整批从分母里消失**,剩下的那些确实都有气口。

★ **本轮的量法(三件一起读,每一个标题都有读数):**
① 它自己的 computed `margin-top`;② 它容器的 `padding-top`(**只在它是第一个孩子时才计入** —— 不然那个值不作用于它);
③ ★ **它相对于【真的在它上面那个东西】的渲染偏移** —— 顺着「前一个兄弟 → 没有就上到父亲、再看父亲的前一个兄弟」一路找,
**于是第一个孩子也有得比**;并且把「找到的那个兄弟其实在它**旁边**而不是上面」(并排分栏)**标出来**。

### 4.2 ★★ 分母,改前与改后 —— **委托书要求的那一行,而且是【同一批路由】上比的**

> ★ **两趟的路由集合不一样**(改后那一趟多量了 `/brand-sampler`)。
> ☞ **所以下面限定在【两趟都走到的那 142 条】上比** —— 否则「分母变大」会被读成「标题变多」,
> 而那正是这一族反复付账的那种数。

| | desktop 改前 | desktop 改后 | phone 改前 | phone 改后 |
|---|--:|--:|--:|--:|
| 共同路由 | **142** | **142** | **142** | **142** |
| ★ **`<h2>` 的分母** | ★ **121** | ★ **121** | ★ **121** | ★ **121** |
| 其中容器的第一个孩子 | **84**(69%) | **84** | **84**(69%) | **84** |
| ★ **有气口读数的** | ★ **121 / 121** | ★ **121 / 121** | ★ **121 / 121** | ★ **121 / 121** |
| 气口 最小 / p25 / **中位** / p75 / 最大 | −202 / 24 / **32** / 33 / 49 | −202 / 24 / **32** / 33 / 49 | −235 / 24 / **32** / 34 / 49 | −235 / 24 / **32** / 34 / 49 |
| 气口 ≤4px | **6** | **5** | **3** | **2** |
| ★★ 其中**不是并排分栏**的(= 真的贴着上一块) | ★ **1** | ★★ **0** | ★ **1** | ★★ **0** |
| ★★ **逐个 h2 比气口,变了几个** | — | ★★★ **1** | — | ★★★ **1** |

☞ ★★ **121 与 FONT-3 的「每个视口约 120 个」吻合;round 1 那一支看见 37。**
**委托书的判据「分母不是约 120 就是仪器坏了」——本轮的仪器过了这一条,而且改前改后逐字相同。**

☞ ★★★ **全树 121 个 `<h2>` 里,气口变了的【恰好一个】,就是要修的那一个:**
`/finance/cash-forecast` 的「Recurring costs and known one-offs」**0 → 32**。
**别的 120 个一个像素都没动** —— 这是「改一块的下边距会不会顺带推到别处」那个问题的答案,
而它是量出来的,不是推的。

### 4.3 ★ 气口 ≤4px 的那几个,逐个 —— **而 FONT-3 的结论复现了**

**改前:desktop 6 个 / phone 3 个**(FONT-3 报的正是 6 / 3)。

| 路由 | 标题 | 气口 | 并排分栏? |
|---|---|--:|---|
| `/finance/bank` | `1010 Bank – USD` | −202 | ✅ 是 |
| ★ `/finance/cash-forecast` | ★ **`Recurring costs and known one-offs`** | ★ **0** | ⛔ **不是 —— 它真的贴着上一块** |
| `/tools/pricing` | `Calculator` | −93 | ✅ 是 |
| `/tools/pricing` | `Metal prices` | −93 | ✅ 是 |
| `/tools/tasks` | `In Progress (1)` | −167 / −235 | ✅ 是 |
| `/tools/tasks` | `Done (1)` | −167 / −235 | ✅ 是 |

☞ ★ **负数那几个是标题坐在上一块的【旁边】,不是下面** —— 本轮的量具把这件事**标出来**(`sideBySide`),
而不是让读它的人去猜为什么会有 −202px 的「气口」。
★★ **全树唯一一个真正贴着上一块的 `<h2>`,两个视口都指向同一个:`/finance/cash-forecast`。**

### 4.4 ★ 修法与改后读数

**修的不是标题,是它上面那一块:** `app/finance/cash-forecast/ForecastGrid.tsx` 的外层 `<div>` 补 `mb-8`。

★ **为什么是这一条(队列写下的第二个选项,而它带着读数):**
那一页的**页级兄弟**是 `<p className="mb-4">` · `<ForecastGrid>` · `<RecurringLines>`(`section.mb-8`)· `<h2 className="mb-2">`
—— ★ **只有 ForecastGrid 那一块没有下边距。** 补上它,那一页的块间节奏就一致了;
而给标题挂一个一次性的 `mt-8` 只是**在下游堵一个上游的洞**。

| | 改前 | 改后 |
|---|---|---|
| 那个 `<h2>` 的气口 | ★ **0.00px** | ★ **32.00px**(两个视口) |
| 它自己的 `margin-top` | `0px` | `0px`(**没有碰标题**) |
| 它容器的 `padding-top` | `0px` | `0px` |
| ★ **它上面那一块的 class** | ★ **`""`**(空) | ★ **`mb-8`** |
| 同页另一个 `<h2>`(`Frozen forecasts`) | 32 | **32**(不变) |
| ★ 32 是从哪儿来的 | — | ★ **全树 121 个 h2 气口的【中位数】就是 32** —— 不是挑的,是量到的 |

---

## 5 · R21 · item y —— **20 个站点,逐个判词,而 split 是量出来的**

### 5.1 ★ 先把 split 说准:委托书写「20」、队列写「12」,**两个都不是今天的状态**

★ **本轮逐个站点在【今天这棵树】上读过**(按内容定位,不照抄行号 —— 其中 3 处的行号已经漂了:
`finance/invoices/[id]` 551 → **557**、`purchasing/orders/[id]` 839/842 → **850/853**、
`inbound/receive/done/[id]` 82 → **86**)。

| 今天的状态 | 个数 | 是哪几个 |
|---|--:|---|
| ★ **已经就在标准上**(读 token 实测,不是读 class 串) | **4** | `card.tsx:11` `:38` `:51` · `alert.tsx:55` |
| ★ **状态 / 含义片 —— §4.4a 的 S3 豁免明写「不必再判第二遍」** | **6** | `InvoicesTable.tsx:46` · `hr/reviews/[id]:137` · `hr/reviews/cycles:132` · `my-reviews/[id]:80` · `purchasing/orders/OrdersTable.tsx:44` · `me/page.tsx:346` |
| ★ **颜色由【容器 / 状态表达式】拥有,而那正是同一条豁免判据的答案** | **6** | `BarRows.tsx:87` · `finance/page.tsx:206` · `finance/invoices/[id]:557` · `purchasing/orders/[id]:850` `:853` · `SalePanel.tsx:369` |
| ★ **要一条 round 2 三条裁定【都没有覆盖】的裁定** | **3** | `hr/kpi/page.tsx:168`(琥珀横幅没有标准)· `RequiredMetalsPanel.tsx:67` · `notifications/page.tsx:80`(两处 raw 灰) |
| ★ **半件挂 Tim 名下(S5 禁止换标签)** | **1** | `inbound/receive/done/[id]:86` |
| **合计** | **20** | ★ **分母对得上** |

> ### ☞ **屏幕上的改动:0 处。而这是把三条裁定应用下去的【结果】,不是没做。**
> FONT-2 在每一处留下的问题都是同一句:「**这个 className 是算出来的,而颜色来自旁边那个表达式 —— 这颗颜色归谁?**」
> ★ round 2 那三条裁定回答的正是「归谁」,而它们给出的答案在 16 个站点上是
> **「归状态 / 归容器 / 它已经是标准」—— 三种答案都以【不动】收尾。**
> ☞ **一条把「判词」与「编辑」混为一谈的验收标准,会逼出一次没有人裁定过的改动。** 本轮不做那件事。

### 5.2 ★ 那 4 个库站点 —— **不是「看起来对」,是 token 解析实测吻合 §4.4 / §4.4a**

| 站点 | 它的 class | 解析到 | spec 写的 | 判词 |
|---|---|---|---|---|
| `card.tsx:11`(`Card`) | `text-sm text-card-foreground` | `--color-card-foreground` = **`--brand-text` #182B4B** | §4.4:卡片正文 `#182B4B` | ✅ **就在标准上** |
| `card.tsx:38`(`CardTitle`) | `text-base leading-snug font-medium`(无字色,继承上面那一条) | 16 / 500 / 22 / `#182B4B` | §4.4:`CardTitle` **16 / 500 / 22 / #182B4B** | ✅ **MEASURED 标准,FONT-3 已判过「不改」** |
| `card.tsx:51`(`CardDescription`) | `text-sm text-muted-foreground` | `--color-muted-foreground` = **`--brand-muted-text` #62738C** | §4.4:`CardDescription` **14 / 400 / 20 / #62738C** | ✅ **就在标准上** |
| `alert.tsx:55`(`AlertDescription`) | `text-sm text-muted-foreground` | 同上 `#62738C` | §4.4a 的横幅形状;`OrgChart` 那一行注释也写着 `AlertDescription` 会把字染成次级色 | ✅ **就在标准上** —— ⚠ **而它是 ALERT-2b 的封闭文件,本来也不许碰。★ 两件事同时成立:不许碰,而且不用改。** |

★ **这一格的方法值一行:** 判据**不是**读 `text-muted-foreground` 这个 class 名,是**顺着
`app/brand-tokens.css` 把它解析到值**(`--color-muted-foreground: var(--brand-muted-text)`)。
☞ 「class 名看起来像次级色」与「它真的是 spec 那个值」是两条断言,而只有后一条能结案。

### 5.3 ★ 那 6 枚状态片 —— 逐个确认它编码的是【状态】,而不是装饰

| 站点 | 颜色从哪儿来 | 它在说什么 |
|---|---|---|
| `InvoicesTable.tsx:46` | 兄弟表达式 `cls`(`bg-green-100 text-green-800` / `bg-amber-100 text-amber-800` / `bg-gray-200 text-gray-700`) | 付款状态 |
| `hr/reviews/[id]:137` · `hr/reviews/cycles:132` · `my-reviews/[id]:80` | `statusPillClass(...)` | 评估周期状态 |
| `purchasing/orders/OrdersTable.tsx:44` | 兄弟表达式 `cls` | 采购单状态 |
| `me/page.tsx:346` | `expiryState(...).cls` | 工作证快到期 / 已过期 |

☞ **§4.4a 的判据逐字照用:「这个颜色在说『这是一条通知』,还是在说『这一行是哪一类』?
说『哪一类』的,留着。下一刀不必再把这几处判一遍。」** ★ 六处全部说的是「哪一类」→ **留。**
⚠ **并且 §4.4a 的豁免名单里已经写着 `InvoicesTable.tsx:67`** —— 与这里的 `:46` 是**同一支状态片函数**,
☞ **round 2 那条裁定已经直接覆盖了它,不是类推。**

### 5.4 ★ 那 6 个「颜色归容器 / 归状态表达式」的 —— 同一条判据的另一面

| 站点 | 它今天的颜色 | 判词 |
|---|---|---|
| `BarRows.tsx:87` | 内联 `color: r.emphasis ? var(--brand-destructive-fill) : var(--brand-text)` | ✅ **一枚强调色,而且【它自己那几行注释就把对比度算过了】**:`#B75B53` 对卡面 `#FFFFFF` = **4.53:1 ✓**。留 |
| `finance/page.tsx:206` | 内联 `color: 未解释差额 === 0 ? var(--brand-muted-text) : var(--brand-destructive)` | ⚠ **留,但报一条缺陷**:`--brand-destructive` **#C0635A** 白底 **4.059:1 ✗**(AA 要 4.5)。见 §5.6 |
| `finance/invoices/[id]:557` | 自己**没有字色**,继承 `<ul className="text-sm">` → 页面正文色 | ✅ **那就是对的答案**:它是一份已签发版本清单,不是一句旁注。留 |
| `purchasing/orders/[id]:850` `:853` | 同上,继承正文色 | ✅ **数量的变化是修订行的【内容】,不是旁注** —— 把它降成次级色会把它读成注脚。留(FONT-2 自己也是这么标的) |
| `SalePanel.tsx:369` | `block text-xs opacity-70` —— 已经被 opacity 降过一次 | ✅ **再加一层次级色是【复合降级】。** 留 |

### 5.5 ★ 那 3 个真的**还缺一条裁定**的 —— **点名它缺哪一条**

| 站点 | 它是什么 | ★ 它缺的是哪一条裁定 |
|---|---|---|
| `hr/kpi/page.tsx:168` | 一个岗位编号,坐在**琥珀色**缺员横幅里(`border-l-4 border-amber-500 bg-amber-50`) | ★ **「提示 / 警告横幅」的琥珀档没有标准。** round 2 的 R12 裁的是**蓝**(而答案是「不需要一个 info 蓝」),**一个字都没有裁琥珀**。☞ 与 `z⑤`(日历小片)/ `z⑥`(info 蓝)/ `u`(日历横幅)同一族。⚠ 顺带:这条横幅是**手搓的**,`known-issues.md · POLISH1-HANDROLLED-BANNERS` 已在册 |
| `RequiredMetalsPanel.tsx:67` | `initial.length === 0 ? 'text-gray-600 italic' : 'font-medium'` | ★ **「100 处 `text-gray-600` 要不要归到 `--brand-muted-text`」那条裁定。** ★★ **而顺手换过去是错的,量过:** `#4B5563` 白底 **7.557:1** → `#62738C` 白底 **4.827:1**,★ **是一次【降低】对比度 2.73 的替换** —— 与队列第七节记着的 `text-blue-600 → text-primary` 同一个形状 |
| `notifications/page.tsx:80` | `isUnread ? 'text-sm font-medium' : 'text-sm text-gray-600'` | 同上。★ 两处的灰**都在说一个状态**(「还没选」/「已读」),按 S3 该留;要动就得**连那 100 处一起裁,而且先把次级色本身压深** |

### 5.6 ⚠ 一条本轮**量到而没改**的缺陷,照直登记

`app/finance/page.tsx:206` 用 `--brand-destructive` 当**字色**。本轮自算(与 spec §4.4a 的 R8 逐字吻合):

| 颜色 | on `#FFFFFF` | on `--brand-bg #F1F9FE` |
|---|--:|--:|
| `--brand-destructive` **#C0635A** | ★ **4.059 ✗** | 3.812 ✗ |
| `--brand-destructive-fill` **#B75B53** | **4.531 ✓** | 4.255 |
| `--brand-destructive-text` **#AA4F48** | **5.356 ✓** | 5.030 ✓ |

★ **它为什么活到今天:颜色写在 `style={{ }}` 里,任何 className 扫描器按构造看不见它**
(AGENTS.md,FONT-1 为这一条付过账)。★ **而同一棵树上 `BarRows.tsx:82-86` 的注释早就把这个数写下来了,
并明写「这里不能用它」** —— 一处知道、另一处不知道。
☞ **为什么本轮不改:** 它同时是一枚**状态色**(S3 说留)和一处**不合规**(AA 说改)。
「状态色过不了 AA 时听谁的」round 2 只对日历那三枚色片裁过(R13:动底、不动字),**没有裁成通则。**
★ 而**这个总体本轮没有量**(内联 `style` 里拿 `--brand-destructive` 当字色的一共几处?)——
item y 的射程是那 20 个站点,不是这个总体。**说白,别高估这一格。**
登记:`known-issues.md · POLISH1R3-DESTRUCTIVE-AS-TEXT-4-06`。

---
## 6 · R20 · item r —— **黑话那一半,逐个站点带判词**

> ★ **分母没有重量**(委托书允许):round 1 已经量好,文件在 `/tmp/polish1/jargon-sweep.txt`,
> 本轮开工时先确认它**还在**。分母:`messages/en.ts` 的叶子字符串值 **6722** 条。

| | 命中 | 处置 |
|---|--:|---|
| snake_case 标识符 | **16** | ★ **改 11 · 留 5** |
| 路由路径 | **21 条命中** | ★ **17 条是真路由 → 全部改掉**;**4 条是 `{ccy}/kg`** —— `/kg` 是**单位**,扫描器自己的误报,**留** |

### 6.1 ★★ 留下的 5 处 —— **它们是【权限码】,而印出来是一条在案的设计**

| 键 | 那一串 |
|---|---|
| `common.dataClassDeniedHint` | `data.view_prices` |
| `reports.snapshot.priceRestrictedNote` | `data.view_prices` |
| `auditTrail.seam.amount_restricted` | `data.view_prices` |
| `import.deniedHint` | `action.bulk_import` |
| `permissions.deniedHint` | `action.manage_permissions` |

☞ ★ **理由(一行):`PermissionGate` 【刻意】把权限码印到人眼前,好让当事人能对管理员说出他缺的到底是哪一个。**
那一条的实测代价写在 `docs/handbacks/PERM-CODE-1-round2.md` §2.3:改判之前屏幕上印的是**他已经持有的那个码** ——
「一句指着他早就有的权限的话」。
★ **所以这一族的判据不是「长得像 snake_case 就改」,是「这一串【人要不要拿它去做事】」。**
一个码要被人念给管理员听 → **它是人话的一部分**;一个表名没有任何人要拿它做事 → **它是黑话。**

### 6.2 ★ 改掉的 11 处,逐条

| 键 | 改前那一串 | 改后 | 它是什么 |
|---|---|---|---|
| `dict.deactivateNotDelete` | `is_active` | `the Active / Deactivated status` / 「「状态」那一栏(启用 / 已停用)」 | 列名 —— ★ **而这一页自己把它画成「状态」列**(`dict.col.isActive`),值就是 `Active` / `Deactivated`:**人话早就在同一个词典里** |
| `reminders.basis` | `(from item_date)` | `(taken from the date on the item itself)` / 「(从这一条自己那个日期起算)」 | 列名 |
| `reports.snapshot.ageingNote` | `(aging_bucket)` | `the single definition the database keeps for ageing` / 「库里唯一那份账龄定义」 | 库里的定义名 |
| `converter.grade.sources` | `(assay_result_metals.content_pct)` | **整串删掉** | 表.列 —— ★ 句子本来已经说了「records assay content in PERCENT everywhere」,那串**没有多告诉人任何事** |
| `converter.basis.sources` | `sale_settlement_compute` · `convert_weight_basis` · `convert_grade_basis` | `settlement itself` · `the very routine settlement runs` / 「结算自己」·「结算跑的那一套」 | 三个库函数名 |
| `assay.impactInBaseAt` | `(tt_sell, {date})` | `(TT sell, {date})` | ★ **它有屏幕上的名字**:`fx.kind.tt_sell` = `TT sell (bank sells the foreign currency)` |
| `finance.fxLookup.missing` | `tt_buy` · `tt_sell` · `record_payment` | `TT buy` · `TT sell` · `the same rule the payment itself is valued by` | 两个有屏幕名字 + 一个库函数名 |
| `auditTrail.seam.polymorphic_source` | `source_type` | `the source type` / 「【来源类型】」 | 列名 |
| `finance.gstSwitch.rateLivesElsewhere` | `tax_rates` · `finance_settings.gst_rate_pct` | `the tax-rate history` · `the single rate this page used to carry` / 「税率历史」·「这一页从前带的那一个单一税率」 | 表名 + 表.列 |
| `finance.errors.SYSTEM_START_NOT_SET` | `system_start_date is not set` | `The system start date is not set` / 「系统启用日期未设置」 | ★ **同一棵树另外两处早就写着人话**(`dashboard.systemStart` · `hr.…system_start_not_set`)—— 这是同一件事的**第三种写法** |
| `finance.fxPage.je70Assured` | `source_type "revaluation"` · ★ **`db/fixtures/133 arm C`** | `recorded as a revaluation` · `the system's own test suite` | ★★ **后一串是【仓库里的一条测试路径】印在了用户屏幕上。** |

### 6.3 ★ 那 17 条路由 —— **页面名【不是手抄的】**

★ **名字从 `lib/modules.ts` 的 `navKey` 取,再用 `messages/{en,zh}.ts` 解出来**(一次性脚本 `navnames.mjs`)。
☞ **手抄一份页面名就是仓库里第二份会漂的定义** —— 导航改了名,这些句子就开始说谎,而没有任何闸会红。

| 键 | 改掉的路径 → 页面名 |
|---|---|
| `financeOverview.periodSpans` | `/finance/close` → **Close / 月结** · `/finance/month-end` → **Month-end hub / 月结枢纽** |
| `financeOverview.reconSpans` | `/finance/trial-balance` → **Trial Balance / 试算平衡** · `/finance/receivables` → **Receivables / 应收** · `/finance/payables` → **Payables / 应付** |
| `financeOverview.netSpans` | 同上两条 |
| `hrOverview.headcountSpans` | `/hr/employees` → **Employees / 员工** · `/hr/departments` → **Departments / 部门** |
| `hrOverview.cycleSpans` | `/hr/attendance` → **Attendance / 考勤** · `/hr/payroll` → **Payroll / 薪资** |
| `hrOverview.salarySpans` | 同上两条 |
| `operationOverview.planSpans` | `/operation/orders` → **Work orders / 工单** · `/operation/processing` → **Processing runs / 加工单** |
| `operationOverview.wipSpans` | `/output` → **Output / 产出** · `/operation/wip` → **Work in progress / 在制品** |
| `purchasingOverview.inFlightSpans` | `/purchasing/orders` → **Purchase orders / 采购单** · `/inbound` → **Inbound / 进料** · `/finance/payables` → **Payables / 应付** |
| `purchasingOverview.contractSpans` | `/contracts` → **Contracts / 合同** · `/purchasing/orders` → 同上 |
| `logisticsOverview.milestoneSpans` | `/logistics/containers` → **Containers / 集装箱** · `/logistics/lanes` → **Lanes and document checklists / 航段与单据清单** |
| `salesOverview.pipelineSpans` | `/sales/quotes` → **Quotations / 报价** · `/sales/orders` → **Orders / 订单** · `/finance/invoices` → **Invoices / 发票** |
| `salesOverview.creditSpans` | `/sales/customers` → **Customers / 客户** · `/finance/receivables` → 同上 |
| `statements.errors.COMPANY_PROFILE_INCOMPLETE` | `Fill it in at /finance/company.` → `Fill it in on the Company page.` |
| `invoice.issueBlockedProfile` | `at /finance/company first` → `on the Company page first` |
| `invoice.errors.INV_PROFILE_INCOMPLETE` | `at /finance/company before issuing` → `on the Company page before issuing` |
| `finance.rowCostNoRate` | `Enter it at /finance/fx.` → `Enter it on the FX Rates page.` |

### 6.4 ⚠ 两件顺带的,照直说

1. ★ **这一族【没有闸】。** 没有任何检查在问「`messages/*.ts` 的值里有没有表名 / 列名 / 路由路径」——
   本轮是**手工普查 + 一支一次性脚本**。☞ 要立一道闸,判据**不能只认形状**:
   **那 5 个权限码按形状全部命中,而它们是对的。** 一道只认形状的闸会把一条在案的设计判成缺陷。
2. ★ **一处中文导航名撞车(不修,登记):** `finance.subnav.close` 与 `finance.subnav.monthEnd`
   **两条子导航的 zh 值都是「月结」**。本轮的 zh 改写因此用了「月结」与「月结枢纽」
   (`dashboard.monthEnd`,词典里已有)把它们分开 —— ★ **但那两条导航项本身仍然同名**,
   而那是导航的事,不是这一句文案的事。

---
## 7 · R22 · item z⑦ —— 双句号,**一个键、两种语言**

| | |
|---|---|
| **键** | `calendar.sourceFailed` |
| **改前 en** | `One or more sources could not be read, so this month is INCOMPLETE: {list}. This is not the same as "nothing scheduled".` |
| **改后 en** | `One or more sources could not be read, so this month is INCOMPLETE — this is not the same as "nothing scheduled". {list}` |
| **改前 zh** | `有来源读不到,所以这个月是【不完整】的:{list}。这与"没有安排"不是一回事。` |
| **改后 zh** | `有来源读不到,所以这个月是【不完整】的 —— 这与"没有安排"不是一回事。{list}` |

### ★★ 为什么**不是**把模板那个句号删掉 —— 这是本条唯一值得留下来的一句

`{list}` 装的是 `fallbackForRawError()` 的产物,而它**有三种形态**:
① 生码的兜底句(**自带句号**)· ② 数据库报错的兜底句(**自带句号**)· ③ ★ **数据库自己的人话句子 ——
`lib/machine-text.ts` 按 Tim 的裁定【原样留着】,它的标点【不受控】。**

☞ **删掉模板那个句号只治好前两种:第三种会和后半句连成一句。**
★ **把 `{list}` 挪到句末,三种形态一次全治** —— 它后面不再有任何模板标点可以撞上。
☞ 这是「**一个只治了它自己走过的那条路的修法**」那一族的又一例,而这一次它**在修的时候就被看见了**,
不是在下一刀的报告里。

⚠ **它今天在屏幕上看不到**(BUGFIX-1a 修掉 `container_no` 之后 `/tools/calendar` 不再出这条横幅)。
★ **所以这一件的验收是【字符串层面】的,不是渲染层面的** —— 照直说,别把它写成一次目视确认。
要看它得自己造一次失败(或按 `data-calendar-failures="1"` 那个把手找)。
★ 而 `u`(那条横幅**浅蓝底 + 红字**)与它是**同一条横幅**,队列写着「一起改」——
⚠ **`u` 不在本轮的七件里,所以本轮只改了措辞,没有动配色。** 那一半仍然开着。

---
## 8 · R23 · 继承的 ① —— **`<DataTable>` 的四个裸 `<button>`:转了 1 个,停了 3 个**

> ### ★★★ 开场先把一个数改正:队列写着「三档高度 **20/28/30px** 没有被重量过」
> **量过了,而三个数里有一个是错的。**
>
> | 控件 | ★ **实测高度** | 它在树上渲染几个 | 它的消费者 |
> |---|--:|--:|---|
> | 排序表头钮(`canSort && !serverSort`) | ★ **21.42px**(不是 20) | ★ **0**(141 静态路由 × 2 视口) | ★★ **只有 `/brand-sampler`** —— `sorting={{ mode: 'client' }}` 全仓库 **1 个**调用点(`Base1.tsx:105`) |
> | 行展开箭头 | **28 × 28px** | ★ **每个视口 480 颗** | **全树**(phone 上 28px,desktop 上 `sm:hidden` 高 0) |
> | 分页「上一页 / 下一页」 | **30px** | **2** | ★★ **只有 `/brand-sampler`** —— `pageSize=` 全仓库 **1 个**调用点(`Base1.tsx:107`) |
>
> ★ **另有 27 个**「排序表头」渲染的是 `serverSort` 那一支的 **`<a>`**(h=21.42),**它不是裸 `<button>`**,不在这一件的射程里。
> ☞ ★★ **于是这一件的形状要说准:四个代码点里,三个的唯一消费者是 `/brand-sampler`,而那正是停止条件 (e) 的对象。**
> **只有展开箭头真的铺在全树上。**

### 8.1 ✅ 转过去的那一颗:行展开箭头

**`variant="ghost"` + `size="icon-sm"`** —— ★ `icon-sm` 就是 `size-7` = **28 × 28px**,与它今天手写的 `h-7 w-7` **逐字同一个几何**。
`size-*` 在 `box-sizing: border-box` 下把边框算在里面,所以共享层那条 1px 透明边框**不会**把它顶大(实测:高宽都没动)。

★ **调用点按回原样的四条类,每一条都拦一次【看得见的】变化:**

| 按回去的 | 它拦的是什么 |
|---|---|
| `${TABLE_TEXT}`(`text-[15px]`) | 基础串是 `text-sm`(14px)。★ 不按回去,那个 `›` 会缩一号 |
| `font-normal` | 基础串是 `font-medium`。★ **实测字重 400 → 500**(箭头会变粗)—— 高度不受影响,但它是一次没人要求过的变化,按回去 |
| `flex` | 共享层是 `inline-flex`。★ **一个行内级盒子坐在行盒上,底下会多出一截 leading,把它所在的 `<td>` 顶高** —— 而行高是停止条件 (c) 的触发器 |
| `type="button"` | ★★ **共享 `<Button>` 不设默认 `type`**,而 `<button>` 在 `<form>` 里默认是 **submit**。丢掉它是一次**功能回归**,而没有任何一道闸会红 |

### 8.2 ⛔ 停掉的那三颗,各自的理由 —— **而排序钮那一颗是【试过之后被测量拦下来的】**

#### (a) 排序表头钮 —— ★★ **转过去了,量了,然后按回来了**

| | 改前 | ★ 转过去之后(实测) |
|---|--:|--:|
| 高度(5 格) | **21.42px** | ★ **23.42px（+2.00)** |
| 高度(3 格,折成两行) | **21.42px** | ★ **44.84px（+23.42)** |
| 宽度 | 49.5 – 95.02 | 51.5 – 90.59 |
| `border-width` | **0px** | ★ **1px** |
| ★ **表头行高 `cellH`** | **42.42px** | ★★ **65.84px（+23.42)** |

★★ **病因查清了,而它不是谁写错了一个类 —— 它是共享层的一条基础声明:**
`buttonVariants` 的基础串里有 **`border border-transparent`**。
上下各一条 1px → **+2px**;左右各一条把可用宽压窄 2px → **三个长表头折行**。
☞ ★★★ **这一条的射程远超这一颗:【任何一个 `border-width: 0` 的裸控件转到共享 Button 上,都要付这 2px】。**
下一刀要转 `BTN-TRIGGER-1` 那 33 处裸触发钮时,这就是它要先知道的那个数。

★ **为什么不用 `border-0` 把它压回去:** 那会是**第五条**按回原样的类(字号 · 字重 · 折行 · 内边距 · 边框),
而到那一步「走共享组件」剩下的实质近于零 —— **每一条都是在调用点手写几何**,
与同一轮 item q 明文禁止的事同形。裁定给的处置是「**报出差值,不要接受它**」,照办。

#### (b)(c) 分页那一对 —— **档位表里没有 30px**

九个档位是 **24 / 28 / 32 / 36**(`h-6`/`h-7`/`h-8`/`h-9`),外加 `h-auto` 与四个方钮档。
★ **没有 30。** 形状上配得上分页钮的是 `secondary`(透明底 + 描边 + 400 字重),它只能给 **28(−2px)** 或 **32(+2px)**。
⚠ 用 `size="inline"` 再把 `px-2.5 py-1` 写回调用点**能**凑出 30 —— **没有这么做**:
`inline` 那一档的文档原话是「**一个不是盒子的按钮**」,而分页钮**是**盒子(底 + 描边);
而且那同样是在调用点手写几何。

### 8.3 ★ 那 480 颗展开箭头的证明 —— **逐颗,不是按集合**

成员 id = `视口|路由|种类|第几张表|第几个|左内边距`,比 **14 个字段**
(`h w fs fw pt pb pl pr lh disp radius bw cellH rowH`)。
★ **分母自己是一条断言:基线看见多少颗,改后就必须看见同样多颗;少一颗,比对器说「我瞎了」并退 2。**
☞ 读数见 §9 的判词表。

### 8.4 ⚠ 一道闸当场咬住了这次改动 —— **而它咬得对**

`scripts/check-datatable-footer.mjs` 把 `data-table.tsx` 在沙箱里转译着跑,
它的依赖有一张 `STUBS` / `REAL` 表。新加的 `@/app/components/ui/button` **两张表里都没有**,于是它**当场抛**:

```
Error: check-datatable-footer:没有为 @/app/components/ui/button 准备桩 —— 量具自己不完整。
```

☞ ★ **这正是那张表该有的行为:它没有猜,它说了自己不完整。**
★ 处置是把 `button.tsx` 放进 **`REAL`**(真的载进来),**不是**桩掉它 ——
理由与 `table-style.ts` / `control-style.ts` 那两条**逐字相同**:
**本支靠读【渲染出来的标记】数格子,桩掉它就是自己编一份按钮,再拿它证明标记是对的。**
改完单跑:`FOOTER_OWN_EXIT=0`。

---
## 9 · 停止条件 §4,逐条 —— **参照点是 `.survey-out/polish1-after`(round 2 的改后读数)**

**分母:141 条静态路由 × 2 视口,外加 2 条 `--urls` 接进来的(`/stocktakes/[id]` 与 `/brand-sampler`)。
基线每个视口 102 张表;本轮 109 张(多的 7 张来自那两条多量的路由)。**

| 条 | 判据 | desktop | phone |
|---|---|--:|--:|
| **(a)** | 390px 上整页溢出为 0 的路由**升到 0 以上** | ★ **0** | ★ **0** |
| **(b)** | 已经溢出的那几条**长大** | ★ **0** | ★ **0**(5 条逐条列在下面) |
| **(c)** | 不横滚的表**开始横滚** | ★ **0** | ★ **0** |
| **(c)** | 已横滚的表**多出范围** | ★ **0** | ★ **0** |
| — | (参考)滚动范围**变小**的表 | 0 | 0 |
| **(d)** | S2 关掉的五份输出**逐字节未变** | ✓ | ✓ |
| **(e)** | `/brand-sampler` 的读数变了 | ★ **0** | ★ **0** |
| — | ★ **基线有而本轮没有对手的表 / 路由** | ★ **0 / 0** | ★ **0 / 0** |

### ★ (b) —— 那 5 条已经溢出的路由,逐条(phone)

| 路由 | 基线 | 本轮 |
|---|--:|--:|
| `/finance/freight/new` | 27 | **27** |
| `/operation/processing/new` | 177 | **177** |
| `/purchasing/payment-terms/new` | 143 | **143** |
| ★ `/sales/orders/new`(委托书点名「已知修不好,不许去修」) | 8 | **8** |
| `/tools/pricing/metal-prices/bulk` | 24 | **24** |

☞ **一条都没长大,也一条都没去动。**

### ★ (d) —— 逐个文件核过,不是假设

`control-style.ts` · `input.tsx` · `textarea.tsx` · `globals.css` · `table-style.ts`
—— **`git diff` 逐个文件 0 行**。
★ R23 改的是 `data-table.tsx`(**不在那五份里**),而「它有没有推动行高」不靠推理:
**480 颗展开箭头 × 2 视口逐颗比过,`h` / `cellH` / `rowH` 一个都没变**(见 §9.2)。

### 9.1 ★★ (e) —— `/brand-sampler`,**逐个成员逐个字段**,而分母自己是一条断言

```
desktop:  totalElements 916 → 916 · tableCount 7 → 7 · docScrollW 1440 → 1440
          控件成员 46 → 46 · 表成员 7 → 7
phone:    totalElements 916 → 916 · tableCount 7 → 7 · docScrollW 390 → 390
          控件成员 46 → 46 · 表成员 7 → 7
★ 字段比对 3072 次 · 不同 0 处 · 量具自称瞎了 0 处        SAMPLER_E_OWN_EXIT=0
```

★ **916 与委托书给的那个数逐字相同** —— 而这一格是**本轮唯一一个「分母对上了才说话」的地方**:
比对器在成员数少于基线时**退 2 并说「我瞎了」**,不会说「干净」。

### 9.2 ★★ R23 的逐颗证明 —— **14364 次字段比对**

成员 id = `视口|路由|种类|第几张表|第几个|左内边距`,比 **14 个字段**。

```
desktop:  DataTable 控件成员 513 → 528   phone: 513 → 528
★ 字段比对 14364 次 · 量具自称瞎了 0 处                    DTC_OWN_EXIT=0
```

★ **多出来的那 15 个 × 2 是 `/brand-sampler`**(改前那一趟的主跑没有走它 —— 它的改前读数在
`before-repair` 那一份里,§9.1 已经逐字段比过了)。

★★★ **真正的判词:`h` · `w` · `cellH` · `rowH` · `fs` · `pt/pb/pl/pr` · `lh` · `disp` · `radius`
—— 一个都没有变。** 变的只有两样,而两样都**不是几何**:

| 字段 | 变了几处 | 值 | 判词 |
|---|--:|---|---|
| `expand.bw` | **463 / 480** | `0px → 1px` | ★ 共享层基础串里的 `border border-transparent`。**`size-7` 是 border-box,那 1px 画在 28px 里面** —— 所以 `h`/`w`/`cellH`/`rowH` 全部逐字未变(上面那一行就是证据)。**报告,不停手。** |
| `expand.fw` | ★ **1 / 480** | `500 → 400` | ★ `/finance/revaluation` 有**一格**的 `<td>` 带着 500,那颗裸按钮此前**继承**了它。<br>★★ **而这正是为什么调用点写了 `font-normal`:** 不写它,共享层的 `font-medium` 会把**另外 479 颗**从 400 推到 500。☞ **1 处变化换掉 479 处** —— 照直记,不是「没有变化」。 |

### ⚠ 不停手、但必须报出来的三件

1. ★ **`expand.bw` 那 463 处**(上表)—— 一条透明边框,几何为零,但它**在 DOM 里是真的**。
2. ★ **`expand.fw` 那 1 处** —— `/finance/revaluation` 的箭头从 500 变 400,**比改前细一档**。
3. ★★ **探针在 phone 上卡死过一条路由,两趟都是 `/finance/expenses`** ——
   而 `FONT2-PROBE-WEDGE-390` 记着「每跑一趟大约卡死一条,**而卡的不是同一条**」。
   ☞ **两趟同一条,值得怀疑是不是这一刀造成的,所以【单独复量了它】:**
   `--only=/finance/expenses,/finance/fx/bulk`(陪跑读数丢弃)→ ★ **`RUN_EXIT=0`,一次都没卡**,
   两个视口都量到。**于是它是那条已知的抖动,不是这一刀的后果** —— 而这句话是量出来的,不是猜的。
   ★ 改前那一趟卡的是 `/purchasing`,同样单独复量后合并(`before-repair`)。
   **两次合并都只并【卡住的那一条】,陪跑路由的读数丢掉不用。**

---
## 10 · 每一条命令,以及**它自己打出来的那一行退出码**

> ★ 每一个判词都是**脚本自己**打出来的那一行,不是启动器的状态 ——
> 长活一律走 `db/run_detached.sh`(`AGENTS.md`:启动器的退出码冒充脚本的退出码,这个仓库犯过五次)。

| # | 干什么 | 判词 |
|---|---|---|
| 1 | 量具自检(3 条路由 × 2 视口,含一条 `[id]`) | `RUN_EXIT=2` —— ⚠ **那个 2 是「这一跑不是一次完整普查」**(「住在表格里的控件 ≥ 1」那条**总体**断言,而我只走了 3 条没有表内控件的路由)。★ **读数有效,退出码说的是它该说的那件事** |
| 2 | **改前全量读数** `--mode=drift`,141 × 2 + 1 条 `[id]` | ★ **`RUN_EXIT=0`**,覆盖断言 **15** 条 |
| 3 | 改前**修补** `--only=/purchasing,/finance/fx/bulk` + `--urls=/brand-sampler` | ★ **`RUN_EXIT=0`**(`/purchasing` @ phone 撞 `FONT2-PROBE-WEDGE-390`;陪跑读数丢弃) |
| 4 | `npx tsc --noEmit`(改动途中 4 次) | **0 / 0 / 0 / 0** —— ★ 其中**第一次是红的**:我自己在一句英文里留了个**没有转义的单引号**(`the system's`),当场改掉并**把整轮新增的行全扫了一遍**(裸单引号:0) |
| 5 | `npm run build`(第一次) | ⛔ **`RUN_EXIT=1`** —— ★ **`check-datatable-footer` 当场说「没有为 `@/app/components/ui/button` 准备桩 —— 量具自己不完整」。它咬得对。** 见 §8.4 |
| 6 | `npm run build`(补好依赖表之后) | ★ **`RUN_EXIT=0`** |
| 7 | **改后全量读数(带排序钮转换)** 141 × 2 + 2 | ★ **`RUN_EXIT=0`** —— ☞ **这一趟量出了排序钮 +2px / +23.42px,于是那一颗被按回原样** |
| 8 | `npx tsc --noEmit`(按回原样之后 ×2) | **0 / 0** |
| 9 | **`npm run build`**(最终状态) | ★ **`RUN_EXIT=0`** —— 26 条静态检查 + `next build` |
| 10 | ★ **最终全量读数** `--mode=drift`,141 × 2 + 2 | ★ **`RUN_EXIT=0`**,覆盖断言 **15** 条 |
| 11 | 最终**修补** `--only=/finance/expenses,/finance/fx/bulk` | ★ **`RUN_EXIT=0`** —— **一次都没卡**(见 §9 那三件的第 3 条) |
| 12 | **停止条件 (a)(b)(c)** 比对器 | ★ **`STOPRULE_ABC_OWN_EXIT=0`** —— 踩到 0 处,量具自称瞎了 0 处 |
| 13 | **停止条件 (e)** `/brand-sampler` 逐成员逐字段 | ★ **`SAMPLER_E_OWN_EXIT=0`** —— **3072 次比对,不同 0 处** |
| 14 | **R23 逐颗** DataTable 控件比对 | ★ **`DTC_OWN_EXIT=0`** —— **14364 次比对**,`h`/`cellH`/`rowH` 变 0 处 |
| 15 | **`python3 db/gate.py`** | ★ **`GATE_OWN_EXIT=0`** —— wall-clock **363s**;三个判词全绿(可重建性 · 镜像 vs 线上 · 行为断言 **197** 支 fixture)+ 匿名面(基线 327 条);**注入自检两格都变红** |
| 16 | **`node scripts/smoke-routes.mjs`** | ★ **`SMOKE_OWN_EXIT=0`** —— **248 ok · 6 skipped(没数据)· 0 FAILED**(229 条路由 + 19 项专门探针,含一条 signed-out `/login` 探针);计时 223 条,合计 **848.0s**,中位 3546 ms |

> ⚠ **第 1 行与第 5 行留着不删,它们是读数:**
> 一次**说清楚自己不完整**的普查,和一道**当场说自己不完整**的闸,
> 都比一句干干净净的绿有用 —— 这一轮两样各遇到一次。

### ★ 破窗 —— **这一刀没有开窗,而这句话有证据**

`git diff` 本轮改动 **`db/` 下 0 个文件** —— **一条迁移都没有**。
☞ 所以不存在「旧代码 + 新库」那个窗口。**这一行不是空着,是量过之后为零。**

---
## 11 · 下一刀开工前要知道的

1. ★★★ **本轮交出去的是【一次裁定】,不是两件活:**
   `POLISH1R3-NO-48PX-BUTTON-STEP`(item q)与 `POLISH1R3-DATATABLE-PAGER-NO-STEP`(继承的 ① 的三分之二)
   问的是**同一个问题:共享 `<Button>` 的档位表要不要为两个【已经存在的几何】多开档(48px 与 30px)。**
   ☞ **不要分开裁。** 一起裁才看得见「这张表到底该覆盖多少种真实几何」。
2. ★★★ **给 `BTN-TRIGGER-1` 的一个数,现在就可以拿去用:**
   共享层基础串里的 `border border-transparent` 让**任何 `border-width: 0` 的裸控件**在转换时
   **长高 2px**(上下各 1px),并**压窄可用宽 2px**(左右各 1px,长文字会因此折行)。
   ★ 本轮实测:排序表头钮 **21.42 → 23.42px**,三个长表头折行后 **44.84px**,表头行 **42.42 → 65.84px**。
   ☞ **那 33 处裸触发钮开工前先按这个数预期**,而不是转完再发现。
   ★ 反过来,**方钮档(`size-*`)不受影响** —— `size-7` 是 border-box,1px 画在 28px 里面(本轮 480 颗逐颗证过)。
3. ★★ **item y 的 20 个站点【今天全部有判词】,不要再判第三遍。**
   §5 那张表就是名单。★ **其中 3 个在等裁定,而那三条裁定各不相同**:
   琥珀横幅的标准(与 `z⑤ z⑥ u` 同族)· 那 100 处 `text-gray-600` 的归属 · `<div>` → `<h3>`(Tim / S5)。
4. ★★ **一条本轮量到、没修、而且【它的总体没有被量过】的缺陷:**
   `finance/page.tsx:206` 拿 `--brand-destructive`(#C0635A)当字色,白底 **4.059:1 ✗**。
   ☞ **要修它先量总体:内联 `style` 里拿这个 token 当字色的一共几处?** 本轮**没有量**,说白,别高估 §5.6。
5. ★ **`u` 与 `z⑦` 是同一条横幅,而本轮只做了措辞那一半。** 配色那一半仍然开着 ——
   队列写着「两条一起裁」,而本轮**没有资格**去裁配色(它不在这七件里)。
6. ⚠ ★★ **这一轮又写了一支一次性探针,而这已经是第三次了。**
   round 1 写过一支(`/tmp/polish1/probe.mjs`)· FONT-1 与 INPUT-3 各写过一支 · 本轮又写了一支。
   ★ 本轮那一支量的是 `survey-controls.mjs` **今天看不见**的四样东西:
   **标题的上方气口**(而且是**第一个孩子也看得见**的那种量法)· **SVG `<text>` 的 `x` 与 `text-anchor`** ·
   **`<DataTable>` 自己那几个控件的渲染高度** · **「一个容器里两颗以上按钮」的高度是否一致**。
   ★ 它**没有进仓库**(本轮无权给量具加字段 —— 那会动 `--mode=compare` 的成员签名,
   而队列里「给 `survey-controls.mjs` 加 colW 读数」那一条早就写明**那是要拿退出码换的决定**)。
   ☞ **建议单独立一条**:这四样里至少**标题气口**与**成对按钮的高度**值得进仓库 ——
   ★ **今天它们【一条回归闸都没有】**:下一刀把某个标题的气口改掉、或者把一对按钮改成不等高,
   **在册的每一条判据都是绿的。** 这与 round 2 给 `colW` 写下的理由**逐字相同**。

---

## 12 · 这一轮买到的教训

### 12.1 ★★★ 一个【验收标准】可以逼出一次没有人裁定过的改动

委托书 §2 写着「**Each is DONE only when it is visible on screen**」。
★ 而 item y 的诚实答案是 **0 次屏幕改动** —— 20 个站点里,三条裁定够得着的那 16 个
**本来就在标准上**,或者**颜色归状态、按 S3 该留**。
☞ 如果把那句话读成「必须改点什么才算做完」,唯一的出路是**去改那 2 处等着裁定的**,
而那正是「在错的刀里裁一道没有人裁过的题」—— 这个仓库反复付账的那件事。
★ **处置:把「判词」与「编辑」分开报。** §1 那张表对 item y 写的是
「**判词全给,屏幕改动 0**」,而不是一个含混的 ✅。

### 12.2 ★★★ 一次改动可以【被自己的验收判据拦下来】,而那是这一轮最值钱的一格

排序表头钮**转过去了、量了、又按回来了**。
★ 如果 R23 只写「把裸 `<button>` 换成 `<Button>`」,它会**照样上线**,
而屏幕上那张表的表头行**高 23px** —— 而且**没有任何一道在册的闸会红**
(行高闸看的是表体行,不是表头;`/brand-sampler` 不在 141 条静态路由里)。
☞ **拦住它的是委托书里那半句「而且要逐颗测量证明」。**
★★ 而它顺带**买到了一个可迁移的数**:那 2px 的病因是共享层的一条基础声明,
**下一刀的 33 处裸触发钮继承它** —— 一次被拦下的改动,产出了比改动本身更有用的东西。

### 12.3 ★★ 一个【分母】能抓到的东西,错误日志抓不到

round 1 在 item x 上报过「0 个标题气口 ≤4px」。**那一行里没有错误、没有异常、退出码是 0。**
★ 抓到它的是**分母**:FONT-3 说每个视口约 120 个 `<h2>`,而 round 1 那一支只看见 **37**。
☞ 本轮的量法把「每一个标题都必须有读数」写成一条**断言**
(`有 declared 读数的标题 ↔ 量到的标题`,注入 `--blind` 时会红),
**而不是靠下一个人再去数一遍分母。**
★ 同一条法则在这一轮**又兑现了一次**:`/brand-sampler` 的比对器在成员数少于基线时
**退 2 并说「我瞎了」**,不说「干净」。

### 12.4 ★★ 一道闸说「量具自己不完整」,比它说「通过」有用

`check-datatable-footer.mjs` 在 `data-table.tsx` 多了一个 import 的那一刻**当场抛**,
点名那个 import,并说**量具自己不完整**。
☞ 它**没有猜**(比如默默桩成一个空组件、然后照样报绿)。
★ 而处置的判据也是现成的:把它放进 `REAL` 而不是 `STUBS` ——
理由与那张表里 `table-style.ts` / `control-style.ts` 那两条**逐字相同**。
**一张写清楚了自己为什么这么分的依赖表,替下一个人做完了这个决定。**

### 12.5 ★ 一次「同一条路由卡了两趟」的怀疑,要用一次复量收场,不是用一句推测

phone 上 `/finance/expenses` **连着两趟卡死**,而 `FONT2-PROBE-WEDGE-390` 记着「卡的不是同一条」。
☞ **两趟同一条,看起来像这一刀造成的。** 处置不是解释它,是**单独复量**:
`--only=/finance/expenses,/finance/fx/bulk` → **`RUN_EXIT=0`,一次都没卡,两个视口都量到。**
★ **于是「它是那条已知的抖动」这句话是量出来的。** 改前那一趟卡的是 `/purchasing`,同样处置。
