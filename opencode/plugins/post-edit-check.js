// After every edit/write, runs the project's fast checker and appends the result to the tool output the model sees.
// Replaces LSP diagnostics (OpenCode v2 doesn't run LSP). A prompt rule alone was not followed reliably:
// the model renamed a field, got "Edited (1 replacement)" back, and stopped with another file broken.
import { execFile } from "node:child_process"
import { existsSync, readdirSync } from "node:fs"
import { dirname, extname, join, resolve } from "node:path"

const MAX_LINES = 30
const TIMEOUT_MS = 120_000

// Walk up from the edited file to the project root looking for a marker file.
function findUp(start, stop, test) {
  let dir = start
  while (true) {
    if (test(dir)) return dir
    const parent = dirname(dir)
    if (parent === dir || !dir.toLowerCase().startsWith(stop.toLowerCase())) return null
    dir = parent
  }
}

function checkerFor(file, root) {
  const ext = extname(file).toLowerCase()
  const dir = dirname(file)
  if ([".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".vue", ".svelte"].includes(ext)) {
    const proj = findUp(dir, root, (d) => existsSync(join(d, "tsconfig.json")))
    const tsc = proj && findUp(proj, root, (d) => existsSync(join(d, "node_modules", "typescript", "bin", "tsc")))
    if (proj && tsc) return { name: "tsc", cmd: process.execPath.endsWith("node.exe") ? process.execPath : "node",
      args: [join(tsc, "node_modules", "typescript", "bin", "tsc"), "--noEmit", "--pretty", "false", "-p", proj], cwd: proj }
  }
  if (ext === ".py") return { name: "python", cmd: "python", args: ["-m", "ruff", "check", "--output-format", "concise", file], cwd: dir, fallback: { cmd: "python", args: ["-m", "py_compile", file] } }
  if (ext === ".cs") {
    const proj = findUp(dir, root, (d) => readdirSync(d).some((f) => f.endsWith(".csproj")))
    if (proj) return { name: "dotnet build", cmd: "dotnet", args: ["build", "--no-restore", "-nologo", "-v", "q", "-clp:NoSummary;ErrorsOnly"], cwd: proj }
  }
  if (ext === ".rs") {
    const proj = findUp(dir, root, (d) => existsSync(join(d, "Cargo.toml")))
    if (proj) return { name: "cargo check", cmd: "cargo", args: ["check", "-q", "--message-format", "short"], cwd: proj }
  }
  if (ext === ".go") {
    const proj = findUp(dir, root, (d) => existsSync(join(d, "go.mod")))
    if (proj) return { name: "go vet", cmd: "go", args: ["vet", "./..."], cwd: proj }
  }
  return null
}

const run = (cmd, args, cwd) =>
  new Promise((done) =>
    execFile(cmd, args, { cwd, timeout: TIMEOUT_MS, windowsHide: true, maxBuffer: 8 << 20 }, (err, stdout, stderr) =>
      done({ code: err ? (err.code ?? 1) : 0, missing: err?.code === "ENOENT", out: `${stdout}\n${stderr}`.trim() })))

async function check(file, root) {
  const c = checkerFor(file, root)
  if (!c) return null
  let r = await run(c.cmd, c.args, c.cwd)
  if (c.fallback && (r.missing || /No module named ruff/.test(r.out))) r = await run(c.fallback.cmd, c.fallback.args, c.cwd)
  if (r.missing) return null
  if (r.code === 0) return `[post-edit check: ${c.name}] clean`
  const lines = r.out.split(/\r?\n/).filter((l) => l.trim())
  const shown = lines.slice(0, MAX_LINES).join("\n")
  const more = lines.length > MAX_LINES ? `\n... ${lines.length - MAX_LINES} more lines` : ""
  return `[post-edit check: ${c.name}] FAILED — fix these before continuing (they may be in other files):\n${shown}${more}`
}

export default {
  id: "post-edit-check",
  async setup(ctx) {
    const root = resolve(ctx.location?.directory ?? process.cwd())
    await ctx.tool.hook("execute.after", async (event) => {
      if (event.status !== "completed" || !["edit", "write"].includes(event.tool)) return
      const path = event.input?.path ?? event.input?.filePath
      if (!path) return
      try {
        const note = await check(resolve(root, path), root)
        if (note && Array.isArray(event.result?.content)) event.result.content.push({ type: "text", text: note })
      } catch (e) {
        console.error(`[post-edit-check] ${e?.stack ?? e}`)
      }
    })
  },
}
