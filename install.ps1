<#
.SYNOPSIS
Instala as skills de code review .NET para o Claude Code.

.DESCRIPTION
Por padrao cria junctions de ~/.claude/skills para este clone, de forma que
"git pull" atualize as skills sem reinstalar. Junction nao exige privilegio de
administrador, ao contrario de link simbolico.

.PARAMETER Mode
junction (padrao) aponta para o clone. copy cria copias independentes.

.PARAMETER ProjectPath
Instala em <ProjectPath>\.claude\skills em vez do perfil do usuario, para
versionar as skills junto com um projeto especifico.

.PARAMETER Force
Substitui instalacao existente sem perguntar.

.EXAMPLE
.\install.ps1
.EXAMPLE
.\install.ps1 -Mode copy
.EXAMPLE
.\install.ps1 -ProjectPath C:\src\MinhaApi
#>
[CmdletBinding()]
param(
    [ValidateSet('junction', 'copy')]
    [string]$Mode = 'junction',
    [string]$ProjectPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$skills = @('designpatterns', 'designpatterns-legacy')

foreach ($s in $skills) {
    if (-not (Test-Path (Join-Path $repoRoot "$s\SKILL.md"))) {
        throw "Nao encontrei $s\SKILL.md em $repoRoot. Rode este script de dentro do clone."
    }
}

if ($ProjectPath) {
    if (-not (Test-Path $ProjectPath)) { throw "Caminho do projeto nao existe: $ProjectPath" }
    $target = Join-Path (Resolve-Path $ProjectPath) '.claude\skills'
    $scopeLabel = "projeto em $ProjectPath"
} else {
    $target = Join-Path $env:USERPROFILE '.claude\skills'
    $scopeLabel = 'perfil do usuario'
}

if (-not (Test-Path $target)) {
    New-Item -ItemType Directory -Path $target -Force | Out-Null
}

Write-Host ""
Write-Host "Instalando em: $target" -ForegroundColor Cyan
Write-Host "Escopo       : $scopeLabel"
Write-Host "Modo         : $Mode"
Write-Host ""

foreach ($s in $skills) {
    $src = Join-Path $repoRoot $s
    $dst = Join-Path $target $s

    if (Test-Path $dst) {
        $item = Get-Item $dst -Force
        $isLink = $item.LinkType -in @('Junction', 'SymbolicLink')
        $kind = if ($isLink) { "link para $($item.Target)" } else { 'pasta' }

        if (-not $Force) {
            $answer = Read-Host "  '$s' ja existe ($kind). Substituir? [s/N]"
            if ($answer -notmatch '^[sSyY]') {
                Write-Host "  $s : mantido como estava" -ForegroundColor Yellow
                continue
            }
        }

        # Remove-Item em junction apaga o link, nao o conteudo apontado.
        if ($isLink) {
            [System.IO.Directory]::Delete($dst, $false)
        } else {
            Remove-Item $dst -Recurse -Force
        }
    }

    if ($Mode -eq 'junction') {
        New-Item -ItemType Junction -Path $dst -Target $src | Out-Null
        Write-Host "  $s : junction -> $src" -ForegroundColor Green
    } else {
        Copy-Item $src $dst -Recurse
        Write-Host "  $s : copiado" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Pronto. Abra o Claude Code e peca um review, ou use /designpatterns." -ForegroundColor Cyan
if ($Mode -eq 'junction') {
    Write-Host "Como foi por junction, 'git pull' neste clone atualiza as skills." -ForegroundColor DarkGray
}
Write-Host ""
