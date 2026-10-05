# Change notes

A change people using Escale will notice adds one note here, so two pull
requests never edit the same lines of [CHANGELOG.md](../CHANGELOG.md). Tests,
tooling and documentation need none.

- **Name:** lowercase words and dashes, like `reading-line-page.md`.
- **Content:** one paragraph, the sentence as it will read in the changelog,
  without a list marker. Say what the person sees, in English. End with the
  issue when there is one, like `(#12)`.
- **Highlight:** a change people will notice first opens with a header. `highlight`
  is a short title (60 characters at most); `plain` says the same in everyday
  words, without the product's own names. A release keeps at most five.

  ```
  ---
  highlight: Bearings finds by words
  plain: Type a few words of a page's name or address and it is found.
  ---
  The exact sentence for the changelog (#12).
  ```

Run `./changelog check` to validate the notes; `./changelog` lists them.
The maintainer gathers them into `CHANGELOG.md` at each release.
