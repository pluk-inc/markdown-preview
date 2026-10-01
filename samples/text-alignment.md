# Text alignment

Use **Settings → Reading → Text & layout → Text alignment** to try Automatic, Left, Center, Right, and Justified. Automatic keeps the existing document alignment. This sample includes paragraphs, quotes, lists, right-to-left text, code, tables, and explicit HTML alignment.

A long paragraph makes justification easier to inspect. With Justified selected, the words should extend to both edges of the text column, while the final line stays naturally aligned. Resize the window or change Content width to compare a narrow reading column with a wider page. Changing alignment should update this document immediately, without changing its Markdown source or the formatting of code and tables.

> This quotation follows the selected prose alignment. Its border and indentation remain in place while the words align within the quotation.

- A list item also follows the selected alignment.

  ```text
  Code nested inside a list keeps its spacing.
      This line is indented.
  ```

مرحبا بالعالم. هذه فقرة عربية لاختبار اتجاه القراءة والمحاذاة. في الوضع التلقائي تبقى محاذاة النص إلى اليمين.

| Left | Center | Right |
| :--- | :----: | ----: |
| One | Two | Three |

```swift
func greet() {
    print("Code keeps its indentation.")
}
```

<p align="center">This HTML paragraph stays centered.</p>

<center><p>This legacy HTML paragraph also stays centered.</p></center>

<div align="right"><p>This HTML paragraph stays right-aligned.</p></div>

## Source line breaks

This ordinary source newline
follows the Strict line breaks preference.

This explicit Markdown break stays visible.  
This is the next line.
