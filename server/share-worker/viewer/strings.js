// The share page's own text, in the app's languages. The reader's browser
// languages pick one; English is the fallback.

const STRINGS = {
  en: {
    brand: "Shared with Markdown Preview",
    download: "Download .md",
    downloadShort: ".md",
    open: "Open in Markdown Preview",
    openShort: "Open in App",
    footer: "This document is encrypted. Only people with the link can read it, and the server cannot.",
    getApp: "Get Markdown Preview",
    untitled: "Shared document",
    image: "Image",
    hiddenImageOne: "1 image from the web is hidden, to keep this page private.",
    hiddenImageMany: "{count} images from the web are hidden, to keep this page private.",
    incomplete: "This link is incomplete. Ask the sender to copy it again; the part after # is the key.",
    password: "This link is protected with a password, which this page cannot open yet. Open it in Markdown Preview.",
    gone: "This link has expired, or sharing was stopped.",
    damaged: "This link is damaged, or it does not match the shared document.",
    unavailable: "The shared document could not be loaded. Try again later.",
  },
  ja: {
    brand: "Markdown Preview で共有",
    download: ".md をダウンロード",
    downloadShort: ".md",
    open: "Markdown Preview で開く",
    openShort: "アプリで開く",
    footer: "この書類は暗号化されています。リンクを知っている人だけが読むことができ、サーバは読むことができません。",
    getApp: "Markdown Preview を入手",
    untitled: "共有された書類",
    image: "画像",
    hiddenImageOne: "このページのプライバシーを守るため、Web 上の画像 1 件を非表示にしています。",
    hiddenImageMany: "このページのプライバシーを守るため、Web 上の画像 {count} 件を非表示にしています。",
    incomplete: "このリンクは不完全です。送信者にもう一度コピーしてもらってください。# 以降の部分がキーです。",
    password: "このリンクはパスワードで保護されており、このページではまだ開けません。Markdown Preview で開いてください。",
    gone: "このリンクは有効期限が切れたか、共有が停止されました。",
    damaged: "このリンクは壊れているか、共有された書類と一致しません。",
    unavailable: "共有された書類を読み込めませんでした。しばらくしてからもう一度お試しください。",
  },
  "zh-Hans": {
    brand: "通过 Markdown Preview 共享",
    download: "下载 .md",
    downloadShort: ".md",
    open: "在 Markdown Preview 中打开",
    openShort: "在应用中打开",
    footer: "此文稿已加密。只有拥有链接的人才能阅读，服务器无法阅读。",
    getApp: "获取 Markdown Preview",
    untitled: "共享的文稿",
    image: "图像",
    hiddenImageOne: "为保护此页面的隐私，已隐藏 1 张来自网络的图像。",
    hiddenImageMany: "为保护此页面的隐私，已隐藏 {count} 张来自网络的图像。",
    incomplete: "此链接不完整。请让发送者重新拷贝；# 之后的部分是密钥。",
    password: "此链接受密码保护，此页面暂时无法打开。请在 Markdown Preview 中打开。",
    gone: "此链接已过期，或已停止共享。",
    damaged: "此链接已损坏，或与共享的文稿不符。",
    unavailable: "无法载入共享的文稿。请稍后再试。",
  },
  pl: {
    brand: "Udostępniono w Markdown Preview",
    download: "Pobierz .md",
    downloadShort: ".md",
    open: "Otwórz w Markdown Preview",
    openShort: "Otwórz w aplikacji",
    footer: "Ten dokument jest zaszyfrowany. Mogą go przeczytać tylko osoby, które mają link, a serwer nie może.",
    getApp: "Pobierz Markdown Preview",
    untitled: "Udostępniony dokument",
    image: "Obraz",
    hiddenImageOne: "1 obraz z internetu jest ukryty, aby ta strona pozostała prywatna.",
    hiddenImageMany: "Obrazy z internetu ({count}) są ukryte, aby ta strona pozostała prywatna.",
    incomplete: "Ten link jest niekompletny. Poproś nadawcę, aby skopiował go ponownie; część po # to klucz.",
    password: "Ten link jest chroniony hasłem, którego ta strona nie może jeszcze otworzyć. Otwórz go w Markdown Preview.",
    gone: "Ten link wygasł lub udostępnianie zostało zatrzymane.",
    damaged: "Ten link jest uszkodzony lub nie pasuje do udostępnionego dokumentu.",
    unavailable: "Nie można załadować udostępnionego dokumentu. Spróbuj ponownie później.",
  },
  fa: {
    brand: "اشتراک‌گذاری‌شده با Markdown Preview",
    download: "دانلود .md",
    downloadShort: ".md",
    open: "باز کردن در Markdown Preview",
    openShort: "باز کردن در برنامه",
    footer: "این سند رمزگذاری شده است. فقط افرادی که پیوند را دارند می‌توانند آن را بخوانند و سرور نمی‌تواند.",
    getApp: "دریافت Markdown Preview",
    untitled: "سند اشتراک‌گذاری‌شده",
    image: "تصویر",
    hiddenImageOne: "برای حفظ حریم خصوصی این صفحه، ۱ تصویر از وب پنهان شده است.",
    hiddenImageMany: "برای حفظ حریم خصوصی این صفحه، {count} تصویر از وب پنهان شده است.",
    incomplete: "این پیوند ناقص است. از فرستنده بخواهید آن را دوباره کپی کند؛ بخش بعد از # کلید است.",
    password: "این پیوند با گذرواژه محافظت شده است و این صفحه هنوز نمی‌تواند آن را باز کند. آن را در Markdown Preview باز کنید.",
    gone: "این پیوند منقضی شده یا اشتراک‌گذاری آن متوقف شده است.",
    damaged: "این پیوند آسیب دیده است یا با سند اشتراک‌گذاری‌شده مطابقت ندارد.",
    unavailable: "سند اشتراک‌گذاری‌شده بارگذاری نشد. بعداً دوباره امتحان کنید.",
  },
};

/** The best match for the browser's languages, e.g. "zh-CN" → "zh-Hans". */
export function pickLanguage(languages) {
  for (const tag of languages) {
    const lower = tag.toLowerCase();
    if (lower.startsWith("zh")) {
      // Traditional Chinese has no translation; fall through to English.
      if (/^zh-(hant|tw|hk|mo)/.test(lower)) continue;
      return "zh-Hans";
    }
    const base = lower.split("-")[0];
    if (base in STRINGS) return base;
  }
  return "en";
}

export function strings(language) {
  return STRINGS[language] ?? STRINGS.en;
}

export const LANGUAGES = Object.keys(STRINGS);
