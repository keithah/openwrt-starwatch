# Vendored browser modules

Starwatch serves these files from its own embedded filesystem. They must never
be replaced with CDN imports: the router and browser may both be offline.

| Package | Version | Upstream distribution | License |
|---|---:|---|---|
| Preact | 10.27.2 | `preact/dist/preact.module.js` | MIT (`LICENSE-preact`) |
| htm | 3.1.1 | `htm/dist/htm.module.js` | Apache-2.0 (`LICENSE-htm`) |
| uPlot | 1.6.32 | `uplot/dist/uPlot.esm.js`, `uplot/dist/uPlot.min.css` | MIT (`LICENSE-uPlot`) |

To update, download the exact distribution files from the pinned package
release, replace the corresponding files here, inspect imports for external
package or URL references, run the Go/static-serving tests, and exercise
`../test.html` in a browser.
