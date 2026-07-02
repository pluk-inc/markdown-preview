# Long Footnote Jump Test

Use this file to test whether footnote refserences jump to the footnote section
and whether backlinks return to the original reference on a long page.

## Section 1

This opening section has the first footnote reference.[^first] Clicking it
should jump near the bottom of the document.

Lorem ipsum dolor sit amet, consectetur adipiscing elit. Integer posuere erat a
ante venenatis dapibus posuere velit aliquet. Donec ullamcorper nulla non metus
auctor fringilla.

Curabitur blandit tempus porttitor. Maecenas faucibus mollis interdum. Etiam
porta sem malesuada magna mollis euismod. Vestibulum id ligula porta felis
euismod semper.

## Section 2

This section intentionally has no footnotes. It gives the page enough height to
make anchor jumps obvious.

- Item one has enough text to wrap on narrower windows and make the page taller.
- Item two should remain ordinary Markdown content.
- Item three gives the list a little more vertical weight.

Sed posuere consectetur est at lobortis. Aenean lacinia bibendum nulla sed
consectetur. Cras justo odio, dapibus ac facilisis in, egestas eget quam.

## Section 3

A second footnote appears here.[^middle] After clicking it, use the backlink in
the footnote section to confirm it returns to this exact part of the page.

```swift
let literalFootnoteMarker = "[^middle]"
print(literalFootnoteMarker)
```

The marker inside the code block above should not become a footnote link.

Praesent commodo cursus magna, vel scelerisque nisl consectetur et. Morbi leo
risus, porta ac consectetur ac, vestibulum at eros.

## Section 4

More filler content follows. Scroll position should move clearly when you click
footnote links from this document.

Donec sed odio dui. Nulla vitae elit libero, a pharetra augue. Integer posuere
erat a ante venenatis dapibus posuere velit aliquet.

Vivamus sagittis lacus vel augue laoreet rutrum faucibus dolor auctor. Fusce
dapibus, tellus ac cursus commodo, tortor mauris condimentum nibh.

## Section 5

This section references the same footnote twice.[^repeat-long] The first backlink
should return here, and the second backlink should return to the next paragraph.

Here is the second reference to the same footnote.[^repeat-long] It should create
a second inline backlink in the footnote definition.

`[^repeat-long]` inside inline code should stay literal.

## Section 6

This is another spacer section.

1. Ordered list item one.
2. Ordered list item two.
3. Ordered list item three.
4. Ordered list item four.

Phasellus viverra nulla ut metus varius laoreet. Quisque rutrum. Aenean
imperdiet. Etiam ultricies nisi vel augue.

## Section 7

A multiline footnote reference lives here.[^multi-long] Its definition includes
multiple paragraphs and a nested list.

Aliquam lorem ante, dapibus in, viverra quis, feugiat a, tellus. Phasellus
viverra nulla ut metus varius laoreet. Quisque rutrum.

## Section 8

More text to make the page long enough for jump testing.

Nam quam nunc, blandit vel, luctus pulvinar, hendrerit id, lorem. Maecenas nec
odio et ante tincidunt tempus. Donec vitae sapien ut libero venenatis faucibus.

Nullam quis ante. Etiam sit amet orci eget eros faucibus tincidunt. Duis leo.
Sed fringilla mauris sit amet nibh.

## Section 9

One final footnote appears near the end of the body.[^near-end] This should still
jump down, but the scroll distance will be shorter than the first reference.

Donec sodales sagittis magna. Sed consequat, leo eget bibendum sodales, augue
velit cursus nunc, quis gravida magna mi a libero.

## Section 10

End of the long body. The footnote section should appear below this paragraph.

Click each backlink arrow in the footnotes and confirm it returns to the matching
reference location.

[^first]: First footnote. Use the backlink to confirm the page jumps back to
    Section 1.

[^middle]: Middle footnote with **bold text** and a [link](https://md-preview.app).

[^repeat-long]: Repeated footnote. This should show two backlinks inline at the
    end of this definition.

[^multi-long]: Multiline footnote first paragraph.

    Second paragraph in the same footnote.

    - Nested bullet one.
    - Nested bullet two with inline math: $a^2 + b^2 = c^2$.

[^near-end]: Footnote referenced near the end of the document.
