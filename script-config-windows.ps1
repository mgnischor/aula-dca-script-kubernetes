#Requires -Version 5.1
# =============================================================================
# Kubernetes — Configuração do kubectl local (Windows)
# Conecta o kubectl do Windows a um cluster remoto provisionado via script-deploy.sh
#
# Pré-requisitos:
#   • kubectl   — https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/
#   • OpenSSH   — nativo no Windows 10 1809+ / Windows 11
#                 (ou PuTTY: pscp no PATH)
#
# Testado em: Windows 10 22H2 / Windows 11 23H2
#
# Uso:
#   .\script-config-windows.ps1
#
# Se necessário liberar a execução de scripts:
#   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
#
# Desenvolvido por Miguel Nischor
# miguel@nischor.com.br
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# FUNÇÕES DE OUTPUT
# =============================================================================

function Write-Banner {
    Write-Host ''
    Write-Host '════════════════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host '  Kubernetes — Configuracao do kubectl (Windows)   ' -ForegroundColor Cyan
    Write-Host '════════════════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host '──────────────────────────────────────────────────' -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host '──────────────────────────────────────────────────' -ForegroundColor Cyan
}

function Write-Info([string]$Msg)    { Write-Host "[INFO]  $Msg" -ForegroundColor Cyan    }
function Write-Ok([string]$Msg)      { Write-Host "[OK]    $Msg" -ForegroundColor Green   }
function Write-Warn([string]$Msg)    { Write-Host "[AVISO] $Msg" -ForegroundColor Yellow  }
function Write-Err([string]$Msg)     { Write-Host "[ERRO]  $Msg" -ForegroundColor Red     }

# =============================================================================
# VERIFICAÇÃO DE PRÉ-REQUISITOS
# =============================================================================

function Test-Prereqs {
    Write-Info 'Verificando pré-requisitos...'

    # ── kubectl ──────────────────────────────────────────────────────────────
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-Err 'kubectl não encontrado no PATH.'
        Write-Host '        Instale via: winget install Kubernetes.kubectl' -ForegroundColor Yellow
        Write-Host '        Ou baixe em: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/' -ForegroundColor Yellow
        exit 1
    }
    Write-Ok "kubectl $(kubectl version --client --short 2>$null) encontrado."

    # ── Cliente SCP ──────────────────────────────────────────────────────────
    if (Get-Command scp -ErrorAction SilentlyContinue) {
        $script:ScpBin = 'scp'
        Write-Ok 'OpenSSH (scp) encontrado.'
        return
    }
    if (Get-Command pscp -ErrorAction SilentlyContinue) {
        $script:ScpBin = 'pscp'
        Write-Ok 'PuTTY (pscp) encontrado.'
        return
    }

    Write-Err 'Nenhum cliente SSH/SCP encontrado no PATH.'
    Write-Host '        Opções:' -ForegroundColor Yellow
    Write-Host '          1) Habilite o OpenSSH: Configurações > Apps > Recursos Opcionais > OpenSSH Client' -ForegroundColor Yellow
    Write-Host '          2) winget install PuTTY.PuTTY' -ForegroundColor Yellow
    exit 1
}

# =============================================================================
# COLETA DE INFORMAÇÕES
# =============================================================================

function Get-ClusterInfo {
    Write-Section 'Informações do servidor remoto'

    # ── IP / hostname ─────────────────────────────────────────────────────────
    do {
        $script:RemoteHost = (Read-Host '  IP ou hostname do servidor Kubernetes (control-plane)').Trim()
        if (-not $script:RemoteHost) { Write-Warn 'O endereço do servidor é obrigatório.' }
    } while (-not $script:RemoteHost)

    # ── Porta SSH ─────────────────────────────────────────────────────────────
    $portInput = (Read-Host '  Porta SSH [22]').Trim()
    $script:SshPort = if ($portInput) { $portInput } else { '22' }

    # ── Usuário SSH ───────────────────────────────────────────────────────────
    $userInput = (Read-Host '  Usuário SSH [ubuntu]').Trim()
    $script:SshUser = if ($userInput) { $userInput } else { 'ubuntu' }

    # ── Chave SSH (opcional) ──────────────────────────────────────────────────
    $keyInput = (Read-Host '  Caminho da chave SSH privada (Enter para usar senha)').Trim()
    $script:SshKey = $keyInput

    # ── Nome do contexto ──────────────────────────────────────────────────────
    $ctxInput = (Read-Host '  Nome do contexto kubectl [k8s-remote]').Trim()
    $script:ContextName = if ($ctxInput) { $ctxInput } else { 'k8s-remote' }

    # ── Porta da API Kubernetes ───────────────────────────────────────────────
    $apiInput = (Read-Host '  Porta da API Kubernetes [6443]').Trim()
    $script:ApiPort = if ($apiInput) { $apiInput } else { '6443' }

    # ── Resumo ────────────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host '  Resumo da configuração:' -ForegroundColor Cyan
    Write-Host "    Servidor  : $script:RemoteHost"
    Write-Host "    Porta SSH : $script:SshPort"
    Write-Host "    Usuário   : $script:SshUser"
    Write-Host "    Chave SSH : $(if ($script:SshKey) { $script:SshKey } else { '(senha interativa)' })"
    Write-Host "    Contexto  : $script:ContextName"
    Write-Host "    API port  : $script:ApiPort"
    Write-Host ''

    $confirm = (Read-Host '  Confirmar? [S/n]').Trim()
    if ($confirm -ieq 'n') {
        Write-Warn 'Operação cancelada.'
        exit 0
    }
}

# =============================================================================
# DOWNLOAD DO KUBECONFIG VIA SCP
# =============================================================================

function Get-RemoteKubeconfig {
    Write-Section 'Baixando kubeconfig do servidor remoto'

    $script:TmpKubeconfig = Join-Path $env:TEMP "k8s-remote-config-$([System.IO.Path]::GetRandomFileName()).yaml"

    Write-Info "Conectando a $script:SshUser@$script:RemoteHost`:$script:SshPort ..."

    # ── Monta argumentos comuns ───────────────────────────────────────────────
    $scpArgs = [System.Collections.Generic.List[string]]::new()

    if ($script:ScpBin -eq 'scp') {
        $scpArgs.AddRange([string[]]@('-o', 'StrictHostKeyChecking=accept-new', '-P', $script:SshPort))
        if ($script:SshKey) {
            if (Test-Path $script:SshKey) {
                $scpArgs.AddRange([string[]]@('-i', $script:SshKey))
            } else {
                Write-Warn 'Arquivo de chave não encontrado; usando autenticação por senha.'
            }
        }
        $scpArgs.Add("$script:SshUser@${script:RemoteHost}:~/.kube/config")
        $scpArgs.Add($script:TmpKubeconfig)

    } else {
        # pscp usa -P maiúsculo e -i para chave .ppk
        $scpArgs.AddRange([string[]]@('-P', $script:SshPort))
        if ($script:SshKey -and (Test-Path $script:SshKey)) {
            $scpArgs.AddRange([string[]]@('-i', $script:SshKey))
        }
        $scpArgs.Add("$script:SshUser@${script:RemoteHost}:~/.kube/config")
        $scpArgs.Add($script:TmpKubeconfig)
    }

    & $script:ScpBin @scpArgs

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $script:TmpKubeconfig)) {
        Write-Err 'Falha ao baixar o kubeconfig.'
        Write-Host '        Verifique: IP, porta SSH, usuário e permissões no servidor.' -ForegroundColor Yellow
        Write-Host '        O script-deploy.sh copia o kubeconfig para ~/.kube/config do usuário.' -ForegroundColor Yellow
        exit 1
    }

    Write-Ok 'kubeconfig baixado com sucesso.'
}

# =============================================================================
# PATCH: SUBSTITUI O ENDEREÇO DO SERVER
# =============================================================================

function Update-ServerAddress {
    Write-Section 'Ajustando endereço do servidor no kubeconfig'

    $script:PatchedKubeconfig = Join-Path $env:TEMP "k8s-remote-config-patched-$([System.IO.Path]::GetRandomFileName()).yaml"

    $content = Get-Content -Raw -Path $script:TmpKubeconfig

    $oldServer = ($content | Select-String -Pattern '(?m)^\s*server:\s*https://[^\r\n]+').Matches.Value.Trim()
    $newServer  = "https://${script:RemoteHost}:$script:ApiPort"

    $patched = $content -replace '(?m)^(\s*server:\s*)https://[^\r\n]+', "`${1}$newServer"
    Set-Content -Path $script:PatchedKubeconfig -Value $patched -NoNewline

    if ($oldServer) {
        Write-Info "Servidor original : $oldServer"
        Write-Info "Servidor ajustado : server: $newServer"
    } else {
        Write-Warn 'Campo server não localizado — arquivo mantido como baixado.'
    }

    Write-Ok 'Endereço do servidor ajustado.'
}

# =============================================================================
# INSTALAÇÃO DO KUBECONFIG LOCAL
# =============================================================================

function Install-Kubeconfig {
    Write-Section 'Instalando kubeconfig local'

    $kubeDir    = Join-Path $env:USERPROFILE '.kube'
    $kubeConfig = Join-Path $kubeDir 'config'

    # ── Cria diretório .kube se não existir ───────────────────────────────────
    if (-not (Test-Path $kubeDir)) {
        New-Item -ItemType Directory -Path $kubeDir | Out-Null
        Write-Info "Diretório $kubeDir criado."
    }

    # ── Backup do config existente ────────────────────────────────────────────
    if (Test-Path $kubeConfig) {
        $timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupFile = Join-Path $kubeDir "config.bak-$timestamp"
        Copy-Item -Path $kubeConfig -Destination $backupFile
        Write-Info "Backup do config anterior salvo em: $backupFile"
    }

    # ── Estratégia: merge ou overwrite ────────────────────────────────────────
    $merge = $true
    if (Test-Path $kubeConfig) {
        $mergeInput = (Read-Host '  Já existe um kubeconfig local. Mesclar com o existente? [S/n]').Trim()
        $merge = $mergeInput -ine 'n'
    }

    if (-not $merge) {
        Copy-Item -Path $script:PatchedKubeconfig -Destination $kubeConfig -Force
        Write-Ok "kubeconfig substituído em $kubeConfig."
    } else {
        Write-Info 'Mesclando configurações...'

        $mergedFile = Join-Path $env:TEMP "k8s-merged-$([System.IO.Path]::GetRandomFileName()).yaml"

        if (Test-Path $kubeConfig) {
            $env:KUBECONFIG = "$script:PatchedKubeconfig;$kubeConfig"
        } else {
            $env:KUBECONFIG = $script:PatchedKubeconfig
        }

        try {
            kubectl config view --raw | Set-Content -Path $mergedFile
            Copy-Item -Path $mergedFile -Destination $kubeConfig -Force
            Remove-Item $mergedFile -ErrorAction SilentlyContinue
            Write-Ok "kubeconfig mesclado em $kubeConfig."
        } catch {
            Write-Warn 'Merge falhou; sobrescrevendo o config existente.'
            Copy-Item -Path $script:PatchedKubeconfig -Destination $kubeConfig -Force
        } finally {
            Remove-Item Env:\KUBECONFIG -ErrorAction SilentlyContinue
        }
    }

    # ── Define permissões restritas no arquivo ────────────────────────────────
    try {
        $acl = Get-Acl $kubeConfig
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl', 'Allow'
        )
        $acl.AddAccessRule($rule)
        Set-Acl -Path $kubeConfig -AclObject $acl
    } catch {
        Write-Warn 'Não foi possível restringir permissões do arquivo (não crítico).'
    }

    # ── Renomeia o contexto para o nome escolhido ─────────────────────────────
    Write-Info "Ajustando nome do contexto para: $script:ContextName ..."
    $contexts = kubectl config get-contexts --no-headers -o name 2>$null |
                Where-Object { $_ -match 'kubernetes' }
    foreach ($ctx in $contexts) {
        if ($ctx -ne $script:ContextName) {
            kubectl config rename-context $ctx $script:ContextName 2>$null | Out-Null
        }
    }

    # ── Define o contexto ativo ───────────────────────────────────────────────
    kubectl config use-context $script:ContextName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Contexto ativo definido como: $script:ContextName."
    } else {
        Write-Warn 'Não foi possível definir o contexto ativo (pode já estar correto).'
    }

    # ── Limpeza dos temporários ───────────────────────────────────────────────
    Remove-Item $script:TmpKubeconfig      -ErrorAction SilentlyContinue
    Remove-Item $script:PatchedKubeconfig  -ErrorAction SilentlyContinue
}

# =============================================================================
# TESTE DE CONEXÃO
# =============================================================================

function Test-ClusterConnection {
    Write-Section 'Testando conexão com o cluster'

    Write-Info 'Executando: kubectl cluster-info'
    kubectl cluster-info

    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Warn "Não foi possível conectar ao cluster agora."
        Write-Host '        Possíveis causas:' -ForegroundColor Yellow
        Write-Host "          - Firewall bloqueando a porta $script:ApiPort para $script:RemoteHost" -ForegroundColor Yellow
        Write-Host '          - Certificado do cluster não inclui o IP externo (verifique SANs)' -ForegroundColor Yellow
        Write-Host '          - Cluster ainda não pronto (aguarde e tente: kubectl get nodes)' -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host '  Nós do cluster:' -ForegroundColor Cyan
    kubectl get nodes -o wide
}

# =============================================================================
# RESUMO FINAL
# =============================================================================

function Write-Summary {
    Write-Host ''
    Write-Host '════════════════════════════════════════════════════' -ForegroundColor Green
    Write-Host '  Configuração concluída!'                           -ForegroundColor Green
    Write-Host '════════════════════════════════════════════════════' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Próximos passos:' -ForegroundColor Cyan
    Write-Host '    kubectl get nodes -o wide                       # Lista os nós'
    Write-Host '    kubectl get pods -A                             # Lista todos os pods'
    Write-Host '    kubectl config get-contexts                     # Lista contextos disponíveis'
    Write-Host "    kubectl config use-context $script:ContextName  # Muda o contexto ativo"
    Write-Host ''
    Write-Host '  kubeconfig salvo em:' -ForegroundColor Cyan
    Write-Host "    $env:USERPROFILE\.kube\config"
    Write-Host ''
}

# =============================================================================
# MAIN
# =============================================================================

# Inicializa variáveis de script
$script:ScpBin        = ''
$script:RemoteHost    = ''
$script:SshPort       = '22'
$script:SshUser       = 'ubuntu'
$script:SshKey        = ''
$script:ContextName   = 'k8s-remote'
$script:ApiPort       = '6443'
$script:TmpKubeconfig = ''
$script:PatchedKubeconfig = ''

Write-Banner
Test-Prereqs
Get-ClusterInfo
Get-RemoteKubeconfig
Update-ServerAddress
Install-Kubeconfig
Test-ClusterConnection
Write-Summary

Read-Host 'Pressione Enter para sair'
