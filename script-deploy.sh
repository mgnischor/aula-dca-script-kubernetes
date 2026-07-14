#!/usr/bin/env bash
# =============================================================================
# Kubernetes Single-Node Setup (kubeadm) + Helm — Ubuntu Server
# Testado em: Ubuntu 22.04 LTS / 24.04 LTS
# Uso: sudo bash script-deploy.sh
#
# Este script detecta e corrige automaticamente os problemas mais comuns:
#   • CRI plugin desabilitado no containerd
#   • SystemdCgroup incorreto
#   • Swap ativa (incluindo zram/zswap)
#   • Módulos de kernel ausentes (overlay, br_netfilter)
#   • Portas ocupadas (6443, 2379, 2380, 10250, 10257, 10259)
#   • Instalação prévia do Kubernetes (reset automático)
#   • iptables legacy vs nftables
#   • Problemas de cgroup v1/v2
#   • IP do node não resolvido corretamente
#   • Falhas de preflight do kubeadm (retry com auto-correção)
#
# Desenvolvido por Miguel Nischor
# miguel@nischor.com.br
# =============================================================================

# ── Cores (DEVE vir antes de set -u e do trap) ────────────────────────────────
RED='\033[0;31m' ; GREEN='\033[0;32m' ; YELLOW='\033[1;33m'
CYAN='\033[0;36m' ; BOLD='\033[1m' ; RESET='\033[0m'

# ── Log (DEVE vir antes do trap) ──────────────────────────────────────────────
LOG_FILE="/var/log/k8s-setup.log"
mkdir -p "$(dirname "$LOG_FILE")"
echo "=== k8s-setup iniciado em $(date) ===" > "$LOG_FILE"

# ── Funções de output (DEVEM vir antes do trap) ───────────────────────────────
info() { echo -e "${CYAN}[INFO]${RESET} $*" | tee -a "$LOG_FILE" ; }
success() { echo -e "${GREEN}[OK]${RESET} $*" | tee -a "$LOG_FILE" ; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*" | tee -a "$LOG_FILE" ; }
fix() { echo -e "${YELLOW}[FIX]${RESET} $*" | tee -a "$LOG_FILE" ; }
error() { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE" ; exit 1 ; }
section() {
echo -e "\n${BOLD}${CYAN}════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
echo -e "${BOLD}${CYAN} $*${RESET}" | tee -a "$LOG_FILE"
echo -e "${BOLD}${CYAN}════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
}

# ── Ativa modo estrito APÓS as variáveis essenciais estarem definidas ─────────
set -Euo pipefail

# ── Trap global para erros ────────────────────────────────────────────────────
on_error() {
echo -e "\n${RED}[FATAL]${RESET} Erro na linha $1: $2"
echo -e "${RED}[FATAL]${RESET} Log completo em: ${LOG_FILE}"
echo -e "${YELLOW}[DICA]${RESET} Para reiniciar do zero: sudo kubeadm reset -f && sudo bash $0"
exit 1
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# ── Variáveis configuráveis ───────────────────────────────────────────────────
K8S_VERSION="1.36.2"         # Versão minor do Kubernetes
POD_CIDR="192.168.16.0/16"   # CIDR dos pods (Flannel padrão)
CNI_PLUGIN="flannel"         # flannel | calico
HELM_VERSION="4.2.3"         # Versão do Helm
NODE_NAME="${HOSTNAME}"
CONTAINERD_SOCK="unix:///var/run/containerd/containerd.sock"
KUBECONFIG_PATH="/etc/kubernetes/admin.conf"
MAX_RETRIES=3
NODE_IP=""

# Usuário alvo para kubeconfig
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# FUNÇÕES UTILITÁRIAS
# =============================================================================

# Executa um comando com retry automático
retry() {
local n=0
local cmd="$*"
until [[ $n -ge $MAX_RETRIES ]] ; do
    if eval "$cmd" >>"$LOG_FILE" 2>&1 ; then
        return 0
    fi
    n=$((n + 1))
    warn "Tentativa $n/$MAX_RETRIES falhou: $cmd"
    sleep $((n * 3))
done
error "Todos os $MAX_RETRIES tentativas falharam: $cmd"
}

# Aguarda um serviço systemd ficar ativo
wait_service() {
local svc="$1"
local timeout="${2:-60}"
local elapsed=0
info "Aguardando serviço: $svc"
until systemctl is-active "$svc" &>/dev/null ; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [[ $elapsed -ge $timeout ]] ; then
        journalctl -u "$svc" -n 30 --no-pager >>"$LOG_FILE" 2>&1 || true
        error "Serviço '$svc' não ficou ativo em ${timeout}s — veja $LOG_FILE"
    fi
done
success "Serviço $svc ativo"
}

# =============================================================================
# FUNÇÕES DE DIAGNÓSTICO E CORREÇÃO AUTOMÁTICA
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Detecta e corrige todos os problemas conhecidos do containerd
# ─────────────────────────────────────────────────────────────────────────────
fix_containerd() {
local config="/etc/containerd/config.toml"
local changed=0

info "Verificando configuração do containerd..."

# Problema 1: arquivo ausente ou vazio — gera config completa
if [[ ! -s "$config" ]] ; then
fix "config.toml ausente ou vazio — gerando configuração padrão completa"
containerd config default > "$config"
changed=1
fi

# Problema 2: CRI plugin explicitamente desabilitado
# Ocorre quando containerd.io é instalado pela 1ª vez no Ubuntu sem config manual
if grep -qE 'disabled_plugins\s*=\s*\[.*"cri".*\]' "$config" ; then
fix "CRI plugin desabilitado (disabled_plugins = [\"cri\"]) — removendo linha"
sed -i '/disabled_plugins/d' "$config"
changed=1
fi

# Problema 3: disabled_plugins parcialmente configurado (ex: ["io.containerd.grpc.v1.cri"])
if grep -qE 'disabled_plugins.*io\.containerd' "$config" ; then
fix "Plugins desabilitados de forma incompatível — removendo entrada"
sed -i '/disabled_plugins/d' "$config"
changed=1
fi

# Problema 4: SystemdCgroup = false (necessário para cgroup v2 + systemd)
if grep -q 'SystemdCgroup = false' "$config" ; then
fix "SystemdCgroup = false — corrigindo para true"
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$config"
changed=1
fi

# Problema 5: seção CRI ausente (config incompleta/antiga)
if ! grep -q '"io.containerd.grpc.v1.cri"' "$config" && \
! grep -q 'io\.containerd\.grpc\.v1\.cri' "$config" ; then
fix "Seção CRI ausente — regenerando config completa do zero"
containerd config default > "$config"
sed -i '/disabled_plugins/d' "$config"
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$config"
changed=1
fi

if [[ $changed -eq 1 ]] ; then
fix "Reiniciando containerd após correções de configuração"
systemctl daemon-reload
systemctl restart containerd
sleep 4
fi

# Aguarda socket aparecer
local timeout=30 elapsed=0
until [[ -S /var/run/containerd/containerd.sock ]] ; do
    sleep 2
    elapsed=$((elapsed + 2))
    [[ $elapsed -ge $timeout ]] && \
    error "Socket /var/run/containerd/containerd.sock não apareceu após ${timeout}s"
done

# Valida CRI via crictl (disponível após instalar kubelet/kubeadm)
if command -v crictl &>/dev/null ; then
    if ! crictl --runtime-endpoint "$CONTAINERD_SOCK" version >>"$LOG_FILE" 2>&1 ; then
    fix "CRI ainda não responde — forçando rebuild completo da config"
    systemctl stop containerd
    containerd config default > "$config"
    sed -i '/disabled_plugins/d' "$config"
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$config"
    systemctl start containerd
    sleep 6
    if ! crictl --runtime-endpoint "$CONTAINERD_SOCK" version >>"$LOG_FILE" 2>&1 ; then
        journalctl -u containerd -n 40 --no-pager >>"$LOG_FILE" 2>&1 || true
        error "containerd CRI continua sem responder. Veja: $LOG_FILE"
    fi
fi
success "containerd CRI validado via crictl"
else
success "containerd configurado (crictl será validado após instalar kubelet)"
fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Detecta e corrige conflito iptables vs nftables
# ─────────────────────────────────────────────────────────────────────────────
fix_iptables() {
info "Verificando backend do iptables..."

# Instala iptables-legacy se necessário
if ! command -v iptables-legacy &>/dev/null ; then
fix "iptables-legacy não encontrado — instalando"
apt-get install -y -qq iptables 2>>"$LOG_FILE"
fi

# Ubuntu 22.04+ usa nftables por padrão; kubeadm/kube-proxy precisam do legacy
local current
current=$(update-alternatives --query iptables 2>/dev/null \
 | grep "^Value:" | awk '{print $2}' || echo "")

if echo "$current" | grep -qi "nft" ; then
fix "iptables aponta para nftables ($current) — redirecionando para legacy"
update-alternatives --set iptables /usr/sbin/iptables-legacy >>"$LOG_FILE" 2>&1 || true
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >>"$LOG_FILE" 2>&1 || true
success "iptables redirecionado para legacy"
elif echo "$current" | grep -qi "legacy" ; then
    success "iptables já usa backend legacy"
    else
    # Tenta forçar de qualquer forma
    update-alternatives --set iptables /usr/sbin/iptables-legacy >>"$LOG_FILE" 2>&1 || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >>"$LOG_FILE" 2>&1 || true
    success "iptables legacy definido como padrão"
fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Verifica e libera portas necessárias para o Kubernetes
# ─────────────────────────────────────────────────────────────────────────────
fix_ports() {
# Portas do control-plane + kubelet
local ports=(6443 2379 2380 10250 10257 10259)
info "Verificando portas: ${ports[*]}"

for port in "${ports[@]}" ; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} " ; then
        local pid
        pid=$(ss -tlnp 2>/dev/null | grep ":${port} " | \
        grep -oP 'pid=\K[0-9]+' | head -1 || echo "")

        if [[ -n "$pid" ]] ; then
            local pname
            pname=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "desconhecido")

            if echo "$pname" | grep -qiE 'kube|etcd|apiserver|controller|scheduler' ; then
            fix "Porta $port ocupada por processo Kubernetes anterior '$pname' (pid=$pid) — encerrando"
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
            else
            warn "Porta $port ocupada por '$pname' (pid=$pid) — pode causar conflito no kubeadm"
        fi
    fi
fi
done
success "Verificação de portas concluída"
}

# ─────────────────────────────────────────────────────────────────────────────
# Reset completo de instalação anterior do Kubernetes
# ─────────────────────────────────────────────────────────────────────────────
reset_if_exists() {
local need_reset=0

[[ -f /etc/kubernetes/admin.conf ]] && need_reset=1
[[ -d /etc/kubernetes/manifests ]] && need_reset=1
systemctl is-active kubelet &>/dev/null && need_reset=1

if [[ $need_reset -eq 1 ]] ; then
fix "Instalação anterior detectada — executando reset completo"

kubeadm reset -f >>"$LOG_FILE" 2>&1 || true
systemctl stop kubelet 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true

# Remove diretórios de estado
rm -rf /etc/kubernetes \
/var/lib/etcd \
/var/lib/kubelet \
/etc/cni/net.d \
/var/lib/cni \
/var/run/kubernetes \
"$TARGET_HOME/.kube" \
/root/.kube

# Limpa regras de iptables residuais
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t filter -F 2>/dev/null || true
iptables -X 2>/dev/null || true
ipvsadm --clear 2>/dev/null || true

# Remove interfaces de rede virtuais criadas pelo CNI
for iface in cni0 flannel.1 tunl0 ; do
    if ip link show "$iface" &>/dev/null ; then
    fix "Removendo interface residual: $iface"
    ip link set "$iface" down 2>/dev/null || true
    ip link delete "$iface" 2>/dev/null || true
fi
done

systemctl start containerd 2>/dev/null || true
sleep 3
success "Reset completo — ambiente limpo"
else
success "Nenhuma instalação anterior encontrada"
fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Verifica e configura cgroup
# ─────────────────────────────────────────────────────────────────────────────
fix_cgroup() {
info "Verificando cgroup..."

if [[ -f /sys/fs/cgroup/cgroup.controllers ]] ; then
    info "Cgroup v2 detectado"

    # Garante accounting habilitado no systemd para cgroup v2
    local cfg="/etc/systemd/system.conf.d/k8s-cgroup.conf"
    if [[ ! -f "$cfg" ]] ; then
    fix "Habilitando accounting do systemd para cgroup v2"
    mkdir -p /etc/systemd/system.conf.d/
    cat > "$cfg" << 'EOF'
[Manager]
DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes
DefaultTasksAccounting=yes
EOF
    systemctl daemon-reexec >>"$LOG_FILE" 2>&1 || true
fi
success "Cgroup v2 configurado"
else
info "Cgroup v1 detectado"
success "Cgroup v1 — configuração padrão compatível"
fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Descobre o IP correto do node para o apiserver
# ─────────────────────────────────────────────────────────────────────────────
detect_node_ip() {
local iface
iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)

if [[ -n "$iface" ]] ; then
    NODE_IP=$(ip -4 addr show "$iface" 2>/dev/null \
     | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "")
fi

if [[ -z "$NODE_IP" ]] ; then
    NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
fi

if [[ -n "$NODE_IP" ]] ; then
    info "IP do node detectado: $NODE_IP (interface: ${iface:-auto})"
    else
    warn "Não foi possível detectar o IP do node — kubeadm escolherá automaticamente"
fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Executa kubeadm init com auto-retry e diagnóstico de falhas preflight
# ─────────────────────────────────────────────────────────────────────────────
run_kubeadm_init() {
local extra_args=""
[[ -n "$NODE_IP" ]] && extra_args="--apiserver-advertise-address=${NODE_IP}"

local init_cmd="kubeadm init \
--pod-network-cidr=${POD_CIDR} \
--node-name=${NODE_NAME} \
--kubernetes-version=stable-${K8S_VERSION} \
--cri-socket=${CONTAINERD_SOCK} \
--ignore-preflight-errors=NumCPU,Mem \
${extra_args}"

info "Comando: $init_cmd"

local attempt=0
while [[ $attempt -lt $MAX_RETRIES ]] ; do
    attempt=$((attempt + 1))
    info "Tentativa $attempt/$MAX_RETRIES de inicialização do cluster"

    # Executa e captura saída
    if eval "$init_cmd" 2>&1 | tee -a "$LOG_FILE" ; then
        success "Cluster inicializado na tentativa $attempt"
        return 0
    fi

    # Analisa últimas linhas do log para auto-correção dirigida
    local tail_log
    tail_log=$(tail -50 "$LOG_FILE")

    # Erro: CRI v1 runtime não implementado / socket inválido
    if echo "$tail_log" | grep -qE "CRI v1 runtime API|unknown service runtime|Unimplemented" ; then
    fix "[tentativa $attempt] Erro de CRI detectado — reconfigurando containerd"
fix_containerd
sleep 5
continue
fi

# Erro: socket do containerd não encontrado / recusado
if echo "$tail_log" | grep -qE "no such file or directory.*containerd|connection refused.*containerd|socket.*containerd" ; then
fix "[tentativa $attempt] Socket do containerd inacessível — reiniciando serviço"
systemctl restart containerd
sleep 6
continue
fi

# Erro: porta já em uso
if echo "$tail_log" | grep -qE "address already in use|port.*already.*use|bind.*failed" ; then
fix "[tentativa $attempt] Porta em uso — limpando processos conflitantes"
fix_ports
sleep 4
continue
fi

# Erro: swap ativa
if echo "$tail_log" | grep -q "\[ERROR Swap\]" ; then
fix "[tentativa $attempt] Swap ainda detectada — forçando desativação"
swapoff -a
sleep 2
continue
fi

# Erro: br_netfilter / sysctl de bridge
if echo "$tail_log" | grep -qE "bridge-nf-call|br_netfilter|sysctl.*net.bridge" ; then
fix "[tentativa $attempt] Módulo br_netfilter ou sysctl ausente — recarregando"
modprobe br_netfilter
sysctl -w net.bridge.bridge-nf-call-iptables=1 >>"$LOG_FILE" 2>&1 || true
sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >>"$LOG_FILE" 2>&1 || true
sleep 2
continue
fi

# Erro: kubelet em estado anterior / lock
if echo "$tail_log" | grep -qE "kubelet.*already running|/var/lib/kubelet.*exist|lock.*kubelet" ; then
fix "[tentativa $attempt] Estado anterior do kubelet — limpando"
systemctl stop kubelet 2>/dev/null || true
rm -rf /var/lib/kubelet /etc/kubernetes 2>/dev/null || true
sleep 3
continue
fi

# Erro: timeout pull de imagens ou rede
if echo "$tail_log" | grep -qE "failed to pull image|timeout|context deadline exceeded|TLS handshake" ; then
fix "[tentativa $attempt] Problema de rede/timeout — aguardando 20s"
sleep 20
continue
fi

# Erro: /etc/kubernetes/manifests já existe de reset incompleto
if echo "$tail_log" | grep -qE "manifests.*already exist|\[config/images\].*already pulled" ; then
fix "[tentativa $attempt] Artefatos de init anterior — limpando diretórios"
rm -rf /etc/kubernetes /var/lib/etcd 2>/dev/null || true
sleep 3
continue
fi

# Erro: FileAvailable -- manifests
if echo "$tail_log" | grep -q "FileAvailable" ; then
fix "[tentativa $attempt] Arquivos de manifests em conflito — removendo"
rm -f /etc/kubernetes/manifests/*.yaml 2>/dev/null || true
sleep 2
continue
fi

warn "Erro não identificado na tentativa $attempt — aguardando antes de retentar"
[[ $attempt -ge $MAX_RETRIES ]] && \
error "kubeadm init falhou após $MAX_RETRIES tentativas. Veja: $LOG_FILE"
sleep 8
done
}

# =============================================================================
# INÍCIO DA INSTALAÇÃO
# =============================================================================

section "Verificações Iniciais"

[[ $EUID -ne 0 ]] && error "Execute com: sudo bash $0"

OS_ID=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
OS_VER=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
[[ "$OS_ID" != "ubuntu" ]] && error "Apenas Ubuntu é suportado. Detectado: $OS_ID"
info "Sistema: Ubuntu $OS_VER"

ARCH=$(uname -m)
case "$ARCH" in
x86_64)  DEB_ARCH="amd64" ;;
aarch64) DEB_ARCH="arm64" ;;
*) error "Arquitetura não suportada: $ARCH" ;;
esac
info "Arquitetura: $ARCH ($DEB_ARCH)"

CPU_COUNT=$(nproc)
TOTAL_RAM=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
info "CPUs: $CPU_COUNT | RAM: ${TOTAL_RAM} MB"
[[ $CPU_COUNT -lt 2 ]] && warn "Recomendado mínimo 2 CPUs (preflight ignorado via --ignore-preflight-errors)"
[[ $TOTAL_RAM -lt 1700 ]] && warn "Recomendado mínimo 2 GB de RAM"

# Conectividade
if ! ping -c 1 -W 5 8.8.8.8 &>/dev/null && ! ping -c 1 -W 5 1.1.1.1 &>/dev/null ; then
    error "Sem conectividade com a internet. Verifique a rede."
fi
success "Conectividade OK"

# IP do node
detect_node_ip

# ── Reset de instalação anterior ──────────────────────────────────────────────
section "Verificando Instalação Anterior"
reset_if_exists

# ── Swap ──────────────────────────────────────────────────────────────────────
section "Desabilitando Swap"

swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab

# zswap
if [[ -f /sys/module/zswap/parameters/enabled ]] ; then
    echo 0 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
fix "zswap desabilitado"
fi

# zram (Ubuntu 22.04+)
for zram_svc in $(systemctl list-units --type=service --all \
 | grep -oE 'systemd-zram[^ ]+' || true) ; do
    if systemctl is-active --quiet "$zram_svc" 2>/dev/null ; then
    fix "zram detectado ($zram_svc) — desabilitando"
    systemctl stop "$zram_svc" 2>/dev/null || true
    systemctl disable "$zram_svc" 2>/dev/null || true
fi
done

SWAP_TOTAL=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
if [[ "$SWAP_TOTAL" -ne 0 ]] ; then
    warn "Swap ainda reportada ($SWAP_TOTAL kB) — kubeadm usará --ignore-preflight-errors=Swap"
    else
    success "Swap completamente desabilitada"
fi

# ── Módulos de kernel ─────────────────────────────────────────────────────────
section "Configurando Módulos de Kernel"

cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF

for mod in overlay br_netfilter ; do
    if lsmod | grep -q "^${mod}[[:space:]]" ; then
        success "Módulo já carregado: $mod"
        else
        info "Carregando módulo: $mod"
        if ! modprobe "$mod" >>"$LOG_FILE" 2>&1 ; then
            error "Falha ao carregar módulo $mod — o kernel suporta containers?"
        fi
        success "Módulo carregado: $mod"
    fi
done

# ── sysctl ────────────────────────────────────────────────────────────────────
section "Configurando sysctl"

cat > /etc/sysctl.d/99-k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system >>"$LOG_FILE" 2>&1

# Valida cada parâmetro individualmente
for param in \
net.bridge.bridge-nf-call-iptables \
net.bridge.bridge-nf-call-ip6tables \
net.ipv4.ip_forward ; do
    val=$(sysctl -n "$param" 2>/dev/null || echo "0")
    if [[ "$val" != "1" ]] ; then
    fix "Parâmetro $param = $val — aplicando manualmente"
    sysctl -w "${param}=1" >>"$LOG_FILE" 2>&1 \
     || warn "Não foi possível definir $param — pode causar problemas de rede nos pods"
fi
done
success "sysctl validado"

# ── cgroup ────────────────────────────────────────────────────────────────────
section "Configurando Cgroup"
fix_cgroup

# ── iptables ─────────────────────────────────────────────────────────────────
# (fix_iptables precisa de apt, chamado após instalar dependências)

# ── Dependências ─────────────────────────────────────────────────────────────
section "Instalando Dependências"

retry "apt-get update -qq"
apt-get install -y -qq \
apt-transport-https \
ca-certificates \
curl \
gnupg \
lsb-release \
jq \
wget \
socat \
conntrack \
ipset \
ipvsadm \
bash-completion \
iptables \
2>>"$LOG_FILE"

success "Dependências instaladas"

# Corrige iptables após instalar o pacote
fix_iptables

# ── containerd ────────────────────────────────────────────────────────────────
section "Instalando containerd"

install -m 0755 -d /etc/apt/keyrings

retry "curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
 | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
 > /etc/apt/sources.list.d/docker.list

retry "apt-get update -qq"
apt-get install -y -qq containerd.io 2>>"$LOG_FILE"

# Corrige a config ANTES de iniciar
fix_containerd

wait_service containerd 30
success "containerd instalado, configurado e operacional"

# Configura crictl para usar containerd
cat > /etc/crictl.yaml << EOF
runtime-endpoint: ${CONTAINERD_SOCK}
image-endpoint: ${CONTAINERD_SOCK}
timeout: 15
debug: false
EOF

# ── kubeadm, kubelet, kubectl ─────────────────────────────────────────────────
section "Instalando kubeadm, kubelet, kubectl (v${K8S_VERSION})"

retry "curl -fsSL \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key \
 | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
 > /etc/apt/sources.list.d/kubernetes.list

retry "apt-get update -qq"
apt-get install -y -qq kubelet kubeadm kubectl 2>>"$LOG_FILE"
apt-mark hold kubelet kubeadm kubectl

for bin in kubelet kubeadm kubectl ; do
    command -v "$bin" &>/dev/null || error "$bin não foi instalado corretamente"
done

systemctl enable kubelet

# Agora valida containerd CRI com crictl disponível
fix_containerd

success "kubeadm, kubelet, kubectl instalados e travados"

# ── Portas ────────────────────────────────────────────────────────────────────
section "Verificando Portas"
fix_ports

# ── Pull de imagens ───────────────────────────────────────────────────────────
section "Baixando Imagens do Control Plane"
info "Pré-download das imagens (melhora a confiabilidade do init)..."

kubeadm config images pull \
--kubernetes-version "stable-${K8S_VERSION}" \
--cri-socket "${CONTAINERD_SOCK}" \
2>&1 | tee -a "$LOG_FILE" | \
grep -E '\[.*\]|error|Error|warning|Warning' | \
while IFS= read -r line ; do info "$line" ; done || {
warn "Pré-download de imagens falhou — kubeadm init tentará novamente"
}

# ── kubeadm init ─────────────────────────────────────────────────────────────
section "Inicializando o Cluster Kubernetes"
run_kubeadm_init

# ── kubeconfig ────────────────────────────────────────────────────────────────
section "Configurando kubeconfig"

export KUBECONFIG="$KUBECONFIG_PATH"

mkdir -p "$TARGET_HOME/.kube"
cp -f "$KUBECONFIG_PATH" "$TARGET_HOME/.kube/config"
chown "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$TARGET_HOME/.kube/config"
chmod 600 "$TARGET_HOME/.kube/config"

# Para root também
mkdir -p /root/.kube
cp -f "$KUBECONFIG_PATH" /root/.kube/config
chmod 600 /root/.kube/config

# Valida comunicação com o API server
info "Aguardando API server responder..."
elapsed=0
until kubectl cluster-info >>"$LOG_FILE" 2>&1 ; do
    sleep 3
    elapsed=$((elapsed + 3))
    [[ $elapsed -ge 60 ]] && error "API server não respondeu em 60s — veja $LOG_FILE"
done
success "kubeconfig configurado em $TARGET_HOME/.kube/config"

# ── Taint control-plane ───────────────────────────────────────────────────────
section "Removendo Taint do Control Plane (single-node)"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- \
 >>"$LOG_FILE" 2>&1 || true
success "Taint removido — node pode executar workloads"

# ── CNI ───────────────────────────────────────────────────────────────────────
section "Instalando CNI: ${CNI_PLUGIN}"

case "$CNI_PLUGIN" in
flannel)
retry "kubectl apply -f \
https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
success "Flannel instalado"
;;
calico)
retry "kubectl create -f \
https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml"
sleep 5
retry "kubectl create -f \
https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml"
success "Calico instalado"
;;
*)
warn "CNI desconhecido: '$CNI_PLUGIN' — ignorado" ;;
esac

# ── Helm ──────────────────────────────────────────────────────────────────────
section "Instalando Helm v${HELM_VERSION}"

HELM_TARBALL="helm-v${HELM_VERSION}-linux-${DEB_ARCH}.tar.gz"
cd /tmp
retry "curl -fsSL https://get.helm.sh/${HELM_TARBALL} -o ${HELM_TARBALL}"
tar -xzf "$HELM_TARBALL" >>"$LOG_FILE" 2>&1
mv -f "linux-${DEB_ARCH}/helm" /usr/local/bin/helm
chmod +x /usr/local/bin/helm
rm -rf "linux-${DEB_ARCH}" "$HELM_TARBALL"
cd - > /dev/null

helm version >>"$LOG_FILE" 2>&1 || error "Helm instalado mas não executa corretamente"
helm completion bash > /etc/bash_completion.d/helm 2>/dev/null || true
success "Helm $(helm version --short) instalado"

# ── Autocompleção e aliases ───────────────────────────────────────────────────
section "Configurando Autocompleção e Aliases"

kubectl completion bash > /etc/bash_completion.d/kubectl 2>/dev/null || true

BASHRC_BLOCK='
# ── Kubernetes ──────────────────────────────────────
alias k=kubectl
complete -o default -F __start_kubectl k
source <(kubectl completion bash) 2>/dev/null || true
source <(helm completion bash) 2>/dev/null || true
export KUBECONFIG="$HOME/.kube/config"
# ────────────────────────────────────────────────────
'
if ! grep -q '__start_kubectl' "$TARGET_HOME/.bashrc" 2>/dev/null ; then
    echo "$BASHRC_BLOCK" >> "$TARGET_HOME/.bashrc"
fi
if [[ "$TARGET_USER" != "root" ]] && ! grep -q '__start_kubectl' /root/.bashrc 2>/dev/null ; then
    echo "$BASHRC_BLOCK" >> /root/.bashrc
fi
success "Autocompleção configurada"

# ── StorageClass local-path ───────────────────────────────────────────────────
section "Instalando StorageClass local-path"

retry "kubectl apply -f \
https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"

kubectl patch storageclass local-path \
-p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
 >>"$LOG_FILE" 2>&1 \
 || warn "StorageClass já é padrão ou patch falhou (não crítico)"

success "StorageClass 'local-path' instalada e definida como padrão"

# ── Aguarda node Ready ────────────────────────────────────────────────────────
section "Aguardando Node Ficar Ready"

info "CNI pode demorar 60–120s para inicializar..."
TIMEOUT=240 ; INTERVAL=5 ; ELAPSED=0

while true ; do
    STATUS=$(kubectl get node "$NODE_NAME" \
    --no-headers \
    -o custom-columns=STATUS:.status.conditions[-1].type \
    2>/dev/null || echo "Aguardando")

    if [[ "$STATUS" == "Ready" ]] ; then
        echo ""
        success "Node '${NODE_NAME}' está Ready!"
        break
    fi

    if [[ $ELAPSED -ge $TIMEOUT ]] ; then
        echo ""
        warn "Timeout aguardando Ready. Coletando diagnóstico..."
        {
        echo "=== kubectl describe node ==="
        kubectl describe node "$NODE_NAME" 2>/dev/null
        echo "=== kubectl get pods -A ==="
        kubectl get pods -A 2>/dev/null
        echo "=== journalctl kubelet (últimas 40 linhas) ==="
        journalctl -u kubelet -n 40 --no-pager 2>/dev/null
        } >>"$LOG_FILE"
        warn "O cluster foi criado mas o node ainda não está Ready."
        warn "Verifique: kubectl get nodes && kubectl get pods -A"
        break
    fi

    echo -ne "\r${YELLOW}[WAIT]${RESET} Status: ${STATUS} — ${ELAPSED}s/${TIMEOUT}s "
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

# ── Sumário Final ─────────────────────────────────────────────────────────────
section "✅ Instalação Concluída"

KUBECTL_VER=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "N/A")
KUBEADM_VER=$(kubeadm version -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "N/A")
SERVER_VER=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "N/A")
CONTAINERD_VER=$(containerd --version 2>/dev/null | awk '{print $3}' || echo "N/A")
HELM_VER=$(helm version --short 2>/dev/null || echo "N/A")

echo ""
echo -e " ${BOLD}Versões instaladas:${RESET}"
printf " %-14s %s\n" "kubectl:" "$KUBECTL_VER"
printf " %-14s %s\n" "kubeadm:" "$KUBEADM_VER"
printf " %-14s %s\n" "Servidor:" "$SERVER_VER"
printf " %-14s %s\n" "containerd:" "$CONTAINERD_VER"
printf " %-14s %s\n" "Helm:" "$HELM_VER"
echo ""
echo -e " ${BOLD}Nodes:${RESET}"
kubectl get nodes -o wide 2>/dev/null || true
echo ""
echo -e " ${BOLD}Pods do sistema:${RESET}"
kubectl get pods -A 2>/dev/null || true
echo ""
echo -e " ${BOLD}StorageClass:${RESET}"
kubectl get storageclass 2>/dev/null || true
echo ""
echo -e " ${BOLD}Comandos úteis:${RESET}"
echo -e " • ${CYAN}kubectl get nodes -o wide${RESET}"
echo -e " • ${CYAN}kubectl get pods -A${RESET}"
echo -e " • ${CYAN}kubectl cluster-info${RESET}"
echo -e " • ${CYAN}helm repo add bitnami https://charts.bitnami.com/bitnami${RESET}"
echo -e " • ${CYAN}journalctl -u kubelet -f${RESET} (logs em tempo real)"
echo ""
echo -e " ${YELLOW}Execute 'source ~/.bashrc' para ativar aliases e autocompleção.${RESET}"
echo ""
echo -e " ${GREEN}Log completo salvo em: $LOG_FILE${RESET}"
echo ""
