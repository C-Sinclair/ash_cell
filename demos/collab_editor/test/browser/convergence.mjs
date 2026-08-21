// The claim that cannot be tested from Elixir: two people typing into the same
// paragraph at the same time, in real browsers, lose nothing.
//
// This is the test that decided the design. An earlier version of this demo
// synced whole blocks with last-writer-wins resolution, which passed every Elixir
// test and still lost keystrokes here — the failure only exists once two real
// editors are typing at once. Run it against a running server:
//
//     mix phx.server
//     npm --prefix assets install          # playwright is a devDependency there
//     node --experimental-default-type=module test/browser/convergence.mjs
//
// or simply `mix browser.test`, which does the last line for you.
//
// Exits non-zero on failure, so it can go in CI behind a running server.
import {createRequire} from "node:module"

// Playwright lives in assets/node_modules, where the rest of the JS toolchain is.
const {chromium} = createRequire(import.meta.url)("../../assets/node_modules/playwright")

const BASE = process.env.BASE_URL || "http://127.0.0.1:4000"
const CHARS = 30

const failures = []
const check = (label, ok, detail = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${label}${detail ? " — " + detail : ""}`)
  if (!ok) failures.push(label)
}

const browser = await chromium.launch()

const openDocument = async (url) => {
  const page = await browser.newPage()
  const errors = []
  page.on("pageerror", (e) => errors.push(String(e).split("\n")[0]))
  page.on("console", (m) => m.type() === "error" && errors.push(m.text().slice(0, 200)))
  await page.goto(url)
  await page.waitForSelector('#editor[contenteditable="true"]')
  await page.waitForTimeout(1000)
  return {page, errors}
}

// A fresh document, so the assertions can be exact.
const first = await browser.newPage()
await first.goto(BASE)
await first.fill('input[name="title"]', "Browser convergence check")
await first.press('input[name="title"]', "Enter")
await first.waitForURL(/\/docs\//)
const url = first.url()
await first.close()

const a = await openDocument(url)
const b = await openDocument(url)

// Both tabs type into the same paragraph simultaneously. No debouncing, no turns.
await a.page.click("#editor")
await b.page.click("#editor")
await Promise.all([
  a.page.keyboard.type("a".repeat(CHARS), {delay: 25}),
  b.page.keyboard.type("b".repeat(CHARS), {delay: 25})
])
await new Promise((r) => setTimeout(r, 3000))

const textA = (await a.page.textContent("#editor")).trim()
const textB = (await b.page.textContent("#editor")).trim()
const count = (text, char) => [...text].filter((c) => c === char).length

check("both tabs converge on the same text", textA === textB, `${textA.length} chars`)
check(
  "no keystrokes lost",
  count(textA, "a") === CHARS && count(textA, "b") === CHARS,
  `${count(textA, "a")} a + ${count(textA, "b")} b of ${CHARS} each`
)
check("no javascript errors", a.errors.length === 0 && b.errors.length === 0, [...a.errors, ...b.errors].join("; "))

// Remote carets are drawn from awareness, which is relayed and never stored.
const cursors = await b.page.evaluate(() => ({
  attached: !!window.__collab.binding.cursorsContainer?.isConnected,
  carets: window.__collab.binding.cursorsContainer?.childElementCount ?? 0,
  peers: window.__collab.awareness.getStates().size
}))
check("the other caret is rendered", cursors.attached && cursors.carets > 0, JSON.stringify(cursors))

// Compaction happens under two live editors.
const pendingBefore = await a.page.textContent("body")
await a.page.click('button:has-text("Compact the log")')
await new Promise((r) => setTimeout(r, 1500))
const merged = /Merged (\d+) updates/.exec(await a.page.textContent("body"))
check("compaction merged the log", merged !== null && Number(merged[1]) > 0, merged?.[0] || "no report")
check("the log was outstanding beforehand", /\d+ updates/.test(pendingBefore))

await a.page.click("#editor")
await a.page.keyboard.press("End")
await a.page.keyboard.type("-after", {delay: 25})
await new Promise((r) => setTimeout(r, 2500))
check(
  "editing still propagates after compaction",
  (await b.page.textContent("#editor")).includes("-after")
)

// A tab that was never here reads the compacted snapshot out of the cell.
const c = await openDocument(url)
const textC = (await c.page.textContent("#editor")).trim()
check(
  "a fresh tab loads the compacted document",
  textC === (await a.page.textContent("#editor")).trim(),
  `${textC.length} chars`
)
check("no errors on the fresh tab", c.errors.length === 0, c.errors.join("; "))

await browser.close()

if (failures.length > 0) {
  console.error(`\n${failures.length} failed: ${failures.join(", ")}`)
  process.exit(1)
}
console.log("\nall checks passed")
