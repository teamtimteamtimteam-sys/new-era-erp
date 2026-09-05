import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import TopNav from "@/app/components/TopNav";
import Breadcrumbs from "@/app/components/nav/Breadcrumbs";
import IdleWatcher from "@/app/components/IdleWatcher";
import { I18nProvider } from "@/lib/i18n/client";
import { getLocale } from "@/lib/i18n/server";
import { isBareChromePath } from "@/lib/loginRoute";
import { getModuleAccess } from "@/lib/moduleAccess";
import { headers } from "next/headers";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "EVoltrya OS",
  description: "Lithium battery recycling ERP",
};

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const locale = await getLocale();

  // ══════════════════════════════════════════════════════════════════════════
  // 【应用外壳不套在「还没进系统」的那一屏上】(LOGIN-1-fu1,2026-09-02)
  //
  // 实测的缺陷:/login 顶上画着顶栏 —— 产品名、当前登录的邮箱、通知铃、
  // 语言切换、登出按钮,以及整条模块导航(供应商 / 采购 / 客户 / 物料 … 物流)。
  // **/login 是「任何人都还没进来」的那个状态**,它不该有导航、不该有通知、
  // 不该有登出、不该有模块清单。
  //
  // 【为什么以前会画出来】TopNav 自己【已经】写着「确立地没登录 → 不画」,
  // 所以对一个真正登出的人它本来就是空的。它之所以出现,是因为那个人
  // **其实是登录着的** —— 也就是同一次报告里的第二个缺陷。两个缺陷同一个根。
  // 但「因为不会发生,所以不用管」不是一条结构:认证【判断不出】时 TopNav 会画
  // 一条说明用的横幅,那一条在 /login 上同样不该出现;而重定向哪天回归了,
  // 外壳也不该跟着回来。所以两道都做:那边重定向,这里【结构性地排除】。
  //
  // pathname 由中间件放进 x-pathname(服务端组件拿不到当前路径 —— 没有这个 API)。
  // 判据 isPublicPath 与中间件放行用的是【同一个函数】,不是抄的第二份。
  //
  // ★★【FIX-1 item 1(2026-09-05):判据换成 isBareChromePath —— 而这【不是】
  //     同一个函数改了个名字】★★
  //
  // 这一行原本读 isPublicPath,而那个函数【同时】是中间件"放行不需要会话的路径"
  // 的判据。委托书说「/set-password 用 /login 那套机制」,而照字面做只有一步:
  // 往 PUBLIC_PATHS 里加一条。**那一步会顺手宣布设密码页不需要会话。**
  // 所以拆成两个判据(见 lib/loginRoute.ts 的抬头),这里读【外壳】那一个。
  //
  // 【机制一个字没改】仍然是 x-pathname + 一个布尔,仍然不是路由组 ——
  // 换的只是"哪些路径算数",而那正是本刀要改的东西。
  //
  // 【影响面】新加进来的只有 /set-password 一页。/welcome 照旧有外壳
  // (Tim 的裁定:那一页的人已经完成设置,只是还没被授权)。
  // 对登出状态的人屏幕上没有任何变化 —— TopNav 本来就返回 null。
  // ══════════════════════════════════════════════════════════════════════════
  const pathname = (await headers()).get("x-pathname") ?? "";
  const bare = isBareChromePath(pathname);

  // ★【NAV-CLEANUP-1 ⑤】面包屑的第一截与顶栏的高亮必须是【同一个答案】,
  //   而那个答案要知道"这个读者进得去哪些模块"。可进性只能在服务端算(要读库),
  //   所以在这里算一次,传给那个客户端组件。
  //   【为什么不在 Breadcrumbs 里自己算】它是 'use client';而且顶栏已经算过一次,
  //   getModuleAccess 走的是 React cache —— 同一次渲染里不会打第二次库。
  //   登录页那一侧(bare)不渲染面包屑,所以那里一次都不算。
  const openModuleIds = bare
    ? []
    : (await getModuleAccess()).filter((m) => m.allowed).map((m) => m.module.id);

  return (
    <html
      lang={locale}
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">
        <I18nProvider locale={locale}>
          {/* IDLE-DRAFT:空闲超时的浏览器那一半。挂在根布局,因为预警
              【必须出现在人真正所在的那一页上】,而不是某个他没在看的地方。
              它自己不渲染任何东西,除非真的到了要说话的时候。
              【登录页不挂它】:那里没有会话可以超时,而它要监视的「还有两分钟」
              在一张登录表单上没有意义。草稿的清理由 /login 自己的
              ClearRestrictedDrafts 负责,与这一个无关。 */}
          {!bare && <IdleWatcher />}
          {!bare && <TopNav />}
          {/* ★【CONV-6 ①:dock 删掉了 —— 这里从前是它与正文的那个 flex 行】★
              Tim 的裁定(2026-09-04):二级菜单已经足够直接、模块划分足够清楚,
              dock 只是把界面弄复杂、还吃掉屏幕面积。它【推翻】了 D1 的后半,
              也【推翻】了 UI-FIX-1 把它挪成左侧竖栏那一次补救 ——
              那一次修的是"它读起来像第三层菜单",而这一次答的是它该不该存在。
              于是外壳回到 dock 之前的形状:顶栏 → 面包屑 → 正文,没有中间那一层。 */}
          {!bare && <Breadcrumbs openModuleIds={openModuleIds} />}
          {children}
        </I18nProvider>
      </body>
    </html>
  );
}
