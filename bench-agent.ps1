<#
.SYNOPSIS
  Checks the OpenCode agent setup (system prompt rules + tools) on this machine. ~5-10 min.
  1. Tools: the model must see Context7 and Playwright and use them.
  2. Rules: a rename that breaks another file must be fixed by the model itself (type-check rule).
#>
$ErrorActionPreference = 'Stop'
$work = Join-Path $env:TEMP "agent-bench-$(Get-Random)"
New-Item -ItemType Directory -Force "$work\src" | Out-Null
Set-Location $work
$fail = @()

Write-Host '1/2 tools (Context7 + Playwright)...'
$out = opencode run --auto "Use the context7 tool to find the React docs for useEffect and give one sentence about it. Then use the playwright browser tool to open https://example.com and report the page title." 2>$null | Out-String
if ($out -notmatch 'Example Domain') { $fail += 'Playwright tool did not work' }
if ($out -notmatch '(?i)effect') { $fail += 'Context7 answer missing' }

Write-Host '2/2 rules (type-check after edit)...'
'{ "name": "t", "private": true, "type": "module", "scripts": { "typecheck": "tsc --noEmit" }, "devDependencies": { "typescript": "^5" } }' | Set-Content package.json
'{ "compilerOptions": { "strict": true, "target": "ES2022", "module": "ESNext", "moduleResolution": "bundler", "noEmit": true }, "include": ["src"] }' | Set-Content tsconfig.json
"export interface User { id: number; name: string }`nexport const makeUser = (id: number, name: string): User => ({ id, name });" | Set-Content src/user.ts
"import { makeUser } from './user.js';`nconsole.log(makeUser(1, 'Ann').name.toUpperCase());" | Set-Content src/main.ts
git init -q; npm install --silent *> $null
opencode run --auto "In src/user.ts rename the User field 'name' to 'fullName'." 2>$null | Out-Null
npx tsc --noEmit *> $null
if ($LASTEXITCODE -ne 0) { $fail += 'model left a type error in another file (type-check rule not followed)' }

Set-Location $env:TEMP; Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
if ($fail) { Write-Host "FAIL: $($fail -join '; ')" -ForegroundColor Red; exit 1 }
Write-Host 'PASS' -ForegroundColor Green
