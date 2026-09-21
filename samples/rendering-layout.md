# A clearer reading rhythm

A reading view should make **structure** easy to scan while keeping ordinary paragraphs comfortable. Inline `code` belongs on the same baseline as the surrounding text.

## A heading with `inline code` that stays readable when it wraps onto a second line

Headings need enough line height for two lines, with a predictable gap before the next paragraph. This sample compares typography, spacing, and alignment.

- A short list item
- A longer item that wraps naturally and keeps its continuation aligned with the first word rather than the bullet marker.
  - A nested item with its own consistent indent
  - Another nested item
- [x] A completed task
- [ ] A task that can still be checked

> A quotation with **emphasis** and a softly rounded rule.
>
> A second paragraph inside the same quotation.

```swift
struct Preview {
    let title: String
    let isReadable = true
}
```

## Tables keep their alignment

| Document | Status | Size |
| :--- | :---: | ---: |
| Short note | Ready | 12 |
| Longer document with a wrapped title | Ready | 1,024 |
| Unicode: café 日本語 🧪 | Review | 256 |

### Smaller headings still form a hierarchy

Inline math remains available: $E = mc^2$. Footnotes still belong to the reading experience.[^note]

#### Extra authored blank lines remain intentional

A paragraph before two blank lines.


A paragraph after two blank lines.

## Right-to-left content

<div dir="rtl">

هذه فقرة لاختبار المحاذاة والمسافات بين السطور.

- العنصر الأول
- العنصر الثاني

> اقتباس لاختبار موضع الخط الجانبي.

</div>

[^note]: This note uses our existing Markdown pipeline.
