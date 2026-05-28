# Chrome Memory Saver and `--autoConnect` Memo

Date: 2026-05-29

なので原因はかなり高確度で Chrome の Memory Saver による discarded/sleeping tab です。省エネというより、Chrome ではたぶん「メモリセーバー」で inactive tab が discard されていたやつですね。6個という数も、こちらで詰まっていた target 数と一致しています。

Follow-up design note: before using `chrome-devtools-mcp --autoConnect` against the user's normal Chrome profile, Lorelei should run a lightweight Chrome health check. If `browser.pages()` or per-target page initialization hangs, Lorelei should wake only the affected discarded/sleeping tabs or surface a debug hint instead of blindly reloading every tab.

Implementation note: Lorelei now runs a best-effort Chrome preflight before App Server desktop actions whose prompts mention Chrome, browser, or ChatGPT. The preflight talks directly to Chrome's remote debugging WebSocket, probes page targets with a short CDP attach/detach timeout, and activates only targets that fail the probe so discarded tabs are woken before `chrome-devtools-mcp --autoConnect` enumerates pages.

Explicit non-Chrome browser prompts such as Safari or Firefox skip this Chrome-specific preflight unless they also mention Chrome or ChatGPT.
