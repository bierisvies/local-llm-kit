// Stops programs the agent launched from the project folder when a session turn ends.
// Leftover GUI apps (games, test builds) hold GPU/VRAM and slow the local model server down.
// Only executables located inside the session's project directory are stopped,
// so user apps (browsers, Discord, editors) are never touched.
import { execFileSync } from "node:child_process"

const log = (msg) => console.error(`[cleanup-apps] ${msg}`)

const killScript = (dir) => `
$dir = [IO.Path]::GetFullPath('${dir.replace(/'/g, "''")}').TrimEnd('\\') + '\\'
if ($dir.Length -lt 12) { exit }  # refuse drive roots and very short paths
Get-CimInstance Win32_Process | Where-Object {
  $_.ExecutablePath -and $_.ExecutablePath.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  "stopped $($_.Name) ($($_.ProcessId))"
}`

// Synchronous on purpose: the cleanup must finish even when the host shuts down right after the turn.
const cleanup = (dir) => {
  try {
    const out = execFileSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", killScript(dir)],
      { windowsHide: true, encoding: "utf8", timeout: 30000 }).trim()
    if (out) log(`${dir}: ${out.split(/\s*\n\s*/).join("; ")}`)
  } catch (e) {
    log(`${dir}: error ${e.message}`)
  }
}

export default {
  id: "cleanup-apps",
  setup(ctx) {
    const controller = new AbortController()
    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        const type = event?.type ?? ""
        // v2 emits session.execution.{succeeded,failed,cancelled,...} when a turn ends.
        if (!type.startsWith("session.execution.") || type.endsWith(".started")) continue
        const dir = event.location?.directory ?? event.properties?.directory ?? ctx.location?.directory
        if (dir) cleanup(dir)
      }
    })().catch((e) => log(`subscription ended: ${e?.stack ?? e}`))
    return () => controller.abort()
  },
}
