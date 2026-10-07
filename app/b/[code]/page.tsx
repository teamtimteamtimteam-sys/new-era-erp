// app/b/[code]/page.tsx
// MES-3b(2026-10-07,MES-0 Q29;MES-3b Step 0 Q9):批次标签二维码里的短链接 —— 按批号认,按读者的码分(ShortLinkScreen)。
//   【没有 requireModule】这一页本身谁都能打开(登录之后):它要做的正是告诉一个看不见那一批的人"那是什么、要哪个码"。
import ShortLinkScreen from '@/app/components/scan/ShortLinkScreen'

export default async function BatchShortLinkPage({ params }: { params: Promise<{ code: string }> }) {
    const { code } = await params
    return <ShortLinkScreen prefix="b" code={code} />
}
