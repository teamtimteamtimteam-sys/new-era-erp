// app/loc/[code]/page.tsx
// MES-3b(2026-10-07,MES-3b Step 0 Q4 · Q9):库位标签二维码里的短链接 —— 按库位号认,按读者的码分(ShortLinkScreen)。
//   【没有 requireModule】理由同 /b/[code]:看不见的人也要被告知那是什么、要哪个码。
import ShortLinkScreen from '@/app/components/scan/ShortLinkScreen'

export default async function LocationShortLinkPage({ params }: { params: Promise<{ code: string }> }) {
    const { code } = await params
    return <ShortLinkScreen prefix="loc" code={code} />
}
