#!/usr/bin/env bash
# =============================================================================
# Kubernetes Worker Node — Join Script
# Testado em: Ubuntu 22.04 LTS / 24.04 LTS
#
# Uso (cole o comando gerado pelo kubeadm init do controller):
#
#   sudo bash script-join.sh \
#     --endpoint 192.168.1.10:6443 \
#     --token    abcdef.0123456789abcdef \
#     --hash     sha256:abc123...
#
# Ou passando o comando completo do kubeadm como string única:
#
#   sudo bash script-join.sh \
#     "kubeadm join 192.168.1.10:6443 --token abcdef.0123456789abcdef \
#      --discovery-token-ca-cert-hash sha256:abc123..."
#
# Para gerar um novo token no controller (caso o atual tenha expirado):
#   kubeadm token create --print-join-command
#
# Desenvolvido por Miguel Nischor
# miguel@nischor.com.br
# =============================================================================

# ── Cores e log (ANTES de set -u e trap) ─────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

LOG_FILE="/var/log/k8s-join.log"
mkdir -p "$(dirname "$LOG_FILE")"
echo "=== k8s-join iniciado em $(date) ===" > "$LOG_FILE"

info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
fix()     { echo -e "${YELLOW}[FIX]${RESET}   $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE"; exit 1; }
section() {
  echo -e "\n${BOLD}${CYAN}════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}  $*${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
}

# ── Modo estrito e trap (APÓS variáveis essenciais) ───────────────────────────
set -Euo pipefail

on_error() {
  echo -e "\n${RED}[FATAL]${RESET} Erro na linha $1: $2"
  echo -e "${RED}[FATAL]${RESET} Log completo em: ${LOG_FILE}"
  echo -e "${YELLOW}[DICA]${RESET}  Para tentar novamente: sudo kubeadm reset -f && sudo bash $0 <args>"
  exit 1
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# ── Variáveis configuráveis ───────────────────────────────────────────────────
K8S_VERSION="1.35"
CONTAINERD_SOCK="unix:///var/run/containerd/containerd.sock"
MAX_RETRIES=3
ENDPOINT=""
JOIN_TOKEN=""
CERT_HASH=""

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# PARSE DE ARGUMENTOS
# =============================================================================

usage() {
  echo ""
  echo -e "  ${BOLD}Uso (flags individuais):${RESET}"
  echo -e "    sudo bash $0 --endpoint <host:porta> --token <token> --hash <sha256:...>"
  echo ""
  echo -e "  ${BOLD}Uso (comando completo do kubeadm):${RESET}"
  echo -e "    sudo bash $0 \"kubeadm join 192.168.1.10:6443 --token abc... --discovery-token-ca-cert-hash sha256:...\""
  echo ""
  echo -e "  ${BOLD}Para gerar o comando no controller:${RESET}"
  echo -e "    ${CYAN}kubeadm token create --print-join-command${RESET}"
  echo ""
  exit 1
}

[[ $# -eq 0 ]] && { error "Nenhum argumento fornecido."; usage; }

# Detecta se é um comando kubeadm completo passado como string única
if [[ "$1" == kubeadm* ]] || [[ "$1" == *"kubeadm join"* ]]; then
  FULL_CMD="$1"

  # Extrai endpoint (primeiro argumento após "join")
  ENDPOINT=$(echo "$FULL_CMD" | grep -oP 'join\s+\K[^\s]+')

  # Extrai token
  JOIN_TOKEN=$(echo "$FULL_CMD" | grep -oP '(?<=--token\s)[^\s]+')

  # Extrai hash
  CERT_HASH=$(echo "$FULL_CMD" | grep -oP '(?<=--discovery-token-ca-cert-hash\s)[^\s]+')
else
  # Parse de flags individuais
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --endpoint|-e) ENDPOINT="$2";    shift 2 ;;
      --token|-t)    JOIN_TOKEN="$2";  shift 2 ;;
      --hash|-H)     CERT_HASH="$2";   shift 2 ;;
      --k8s-version) K8S_VERSION="$2"; shift 2 ;;
      --help|-h)     usage ;;
      *) warn "Argumento desconhecido: $1"; shift ;;
    esac
  done
fi

# Valida que os três parâmetros obrigatórios foram obtidos
[[ -z "$ENDPOINT"    ]] && { error "Endpoint do controller não fornecido.";  usage; }
[[ -z "$JOIN_TOKEN"  ]] && { error "Token de join não fornecido.";           usage; }
[[ -z "$CERT_HASH"   ]] && { error "Hash do certificado não fornecido.";    usage; }

# Valida formato do endpoint
if ! echo "$ENDPOINT" | grep -qP '^\S+:\d+$'; then
  error "Formato de endpoint inválido: '$ENDPOINT'. Esperado: host:porta (ex: 192.168.1.10:6443)"
fi

# Valida formato do token
if ! echo "$JOIN_TOKEN" | grep -qP '^[a-z0-9]{6}\.[a-z0-9]{16}$'; then
  warn "Formato de token inusual: '$JOIN_TOKEN'. Formato esperado: xxxxxx.xxxxxxxxxxxxxxxx"
fi

# Valida formato do hash
if ! echo "$CERT_HASH" | grep -qP '^sha256:[a-f0-9]{64}$'; then
  error "Formato de hash inválido: '$CERT_HASH'. Esperado: sha256:<64 hex chars>"
fi

# =============================================================================
# FUNÇÕES DE DIAGNÓSTICO E CORREÇÃO AUTOMÁTICA
# =============================================================================

retry() {
  local n=0
  local cmd="$*"
  until [[ $n -ge $MAX_RETRIES ]]; do
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then return 0; fi
    n=$((n + 1))
    warn "Tentativa $n/$MAX_RETRIES falhou: $cmd"
    sleep $((n * 3))
  done
  error "Todas as $MAX_RETRIES tentativas falharam: $cmd"
}

wait_service() {
  local svc="$1" timeout="${2:-60}" elapsed=0
  info "Aguardando serviço: $svc"
  until systemctl is-active "$svc" &>/dev/null; do
    sleep 2; elapsed=$((elapsed + 2))
    if [[ $elapsed -ge $timeout ]]; then
      journalctl -u "$svc" -n 30 --no-pager >> "$LOG_FILE" 2>&1 || true
      error "Serviço '$svc' não ficou ativo em ${timeout}s — veja $LOG_FILE"
    fi
  done
  success "Serviço $svc ativo"
}

# ─────────────────────────────────────────────────────────────────────────────
fix_containerd() {
  local config="/etc/containerd/config.toml"
  local changed=0

  info "Verificando configuração do containerd..."

  [[ ! -s "$config" ]] && {
    fix "config.toml ausente/vazio — gerando configuração padrão"
    containerd config default > "$config"; changed=1
  }

  grep -qE 'disabled_plugins\s*=\s*\[.*"cri".*\]' "$config" && {
    fix "CRI plugin desabilitado — removendo disabled_plugins"
    sed -i '/disabled_plugins/d' "$config"; changed=1
  }

  grep -qE 'disabled_plugins.*io\.containerd' "$config" && {
    fix "Plugins desabilitados de forma incompatível — removendo"
    sed -i '/disabled_plugins/d' "$config"; changed=1
  }

  grep -q 'SystemdCgroup = false' "$config" && {
    fix "SystemdCgroup = false — corrigindo para true"
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$config"; changed=1
  }

  grep -qE '"io.containerd.grpc.v1.cri"|io\.containerd\.grpc\.v1\.cri' "$config" || {
    fix "Seção CRI ausente — regenerando config completa"
    containerd config default > "$config"
    sed -i '/disabled_plugins/d' "$config"
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$config"
    changed=1
  }

  [[ $changed -eq 1 ]] && {
    fix "Reiniciando containerd após correções"
    systemctl daemon-reload
    systemctl restart containerd
    sleep 4
  }

  local elapsed=0
  until [[ -S /var/run/containerd/containerd.sock ]]; do
    sleep 2; elapsed=$((elapsed + 2))
    [[ $elapsed -ge 30 ]] && error "Socket do containerd não apareceu após 30s"
  done

  if command -v crictl &>/dev/null; then
    if ! crictl --runtime-endpoint "$CONTAINERD_SOCK" version >> "$LOG_FILE" 2>&1; then
      fix "CRI não responde — rebuild completo da config"
      systemctl stop containerd
      containerd config default > "$config"
      sed -i '/disabled_plugins/d' "$config"
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$config"
      systemctl start containerd
      sleep 6
      crictl --runtime-endpoint "$CONTAINERD_SOCK" version >> "$LOG_FILE" 2>&1 \
        || error "containerd CRI continua sem responder. Veja: journalctl -u containerd"
    fi
    success "containerd CRI validado via crictl"
  else
    success "containerd configurado"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
fix_iptables() {
  info "Verificando backend do iptables..."
  local current
  current=$(update-alternatives --query iptables 2>/dev/null \
    | grep "^Value:" | awk '{print $2}' || echo "")

  if echo "$current" | grep -qi "nft"; then
    fix "iptables em modo nftables — redirecionando para legacy"
    update-alternatives --set iptables  /usr/sbin/iptables-legacy  >> "$LOG_FILE" 2>&1 || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >> "$LOG_FILE" 2>&1 || true
    success "iptables legacy ativado"
  else
    update-alternatives --set iptables  /usr/sbin/iptables-legacy  >> "$LOG_FILE" 2>&1 || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >> "$LOG_FILE" 2>&1 || true
    success "iptables OK"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
fix_ports() {
  # Porta necessária no worker: apenas kubelet (10250)
  local ports=(10250 10256)
  info "Verificando portas: ${ports[*]}"
  for port in "${ports[@]}"; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      local pid
      pid=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1 || echo "")
      if [[ -n "$pid" ]]; then
        local pname
        pname=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "desconhecido")
        if echo "$pname" | grep -qiE 'kube|proxy'; then
          fix "Porta $port ocupada por '$pname' (pid=$pid) — encerrando"
          kill -9 "$pid" 2>/dev/null || true; sleep 1
        else
          warn "Porta $port ocupada por '$pname' — pode causar conflito"
        fi
      fi
    fi
  done
  success "Portas verificadas"
}

# ─────────────────────────────────────────────────────────────────────────────
fix_cgroup() {
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    info "Cgroup v2 detectado"
    local cfg="/etc/systemd/system.conf.d/k8s-cgroup.conf"
    if [[ ! -f "$cfg" ]]; then
      fix "Habilitando accounting do systemd para cgroup v2"
      mkdir -p /etc/systemd/system.conf.d/
      cat > "$cfg" <<'EOF'
[Manager]
DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes
DefaultTasksAccounting=yes
EOF
      systemctl daemon-reexec >> "$LOG_FILE" 2>&1 || true
    fi
    success "Cgroup v2 configurado"
  else
    success "Cgroup v1 — configuração padrão compatível"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
reset_if_exists() {
  local need_reset=0
  [[ -f /etc/kubernetes/kubelet.conf ]]    && need_reset=1
  [[ -d /etc/kubernetes/pki ]]             && need_reset=1
  systemctl is-active kubelet &>/dev/null  && need_reset=1

  if [[ $need_reset -eq 1 ]]; then
    fix "Node já associado a um cluster — executando reset"
    kubeadm reset -f >> "$LOG_FILE" 2>&1 || true
    systemctl stop kubelet 2>/dev/null || true

    rm -rf /etc/kubernetes /var/lib/kubelet /etc/cni/net.d \
           /var/lib/cni /var/run/kubernetes

    iptables -F            2>/dev/null || true
    iptables -t nat    -F  2>/dev/null || true
    iptables -t mangle -F  2>/dev/null || true
    iptables -X            2>/dev/null || true
    ipvsadm --clear        2>/dev/null || true

    for iface in cni0 flannel.1 tunl0; do
      if ip link show "$iface" &>/dev/null; then
        ip link set "$iface" down 2>/dev/null || true
        ip link delete "$iface"   2>/dev/null || true
      fi
    done
    success "Reset concluído"
  else
    success "Nenhuma instalação anterior encontrada"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Testa conectividade com o controller antes de prosseguir
# ─────────────────────────────────────────────────────────────────────────────
check_controller_reachable() {
  local host port
  host=$(echo "$ENDPOINT" | cut -d: -f1)
  port=$(echo "$ENDPOINT" | cut -d: -f2)

  info "Testando conectividade com o controller ($host:$port)..."

  # Ping
  if ! ping -c 2 -W 3 "$host" >> "$LOG_FILE" 2>&1; then
    warn "Ping para $host falhou — host pode bloquear ICMP, tentando TCP..."
  fi

  # Conexão TCP na porta do API server
  if ! timeout 5 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
    error "Não foi possível conectar ao controller em $host:$port\n\
       Verifique:\n\
       1. O controller está rodando:  systemctl status kubelet\n\
       2. A porta está aberta:        ss -tlnp | grep $port\n\
       3. Firewall permite a conexão: ufw status\n\
       4. O endereço está correto:    $ENDPOINT"
  fi

  success "Controller acessível em $ENDPOINT"
}

# ─────────────────────────────────────────────────────────────────────────────
# kubeadm join com retry e auto-correção de erros conhecidos
# ─────────────────────────────────────────────────────────────────────────────
run_kubeadm_join() {
  local join_cmd="kubeadm join ${ENDPOINT} \
    --token ${JOIN_TOKEN} \
    --discovery-token-ca-cert-hash ${CERT_HASH} \
    --cri-socket ${CONTAINERD_SOCK} \
    --ignore-preflight-errors=NumCPU,Mem"

  info "Comando: $join_cmd"

  local attempt=0
  while [[ $attempt -lt $MAX_RETRIES ]]; do
    attempt=$((attempt + 1))
    info "Tentativa $attempt/$MAX_RETRIES de join ao cluster"

    if eval "$join_cmd" 2>&1 | tee -a "$LOG_FILE"; then
      success "Join realizado com sucesso na tentativa $attempt"
      return 0
    fi

    local tail_log
    tail_log=$(tail -50 "$LOG_FILE")

    # ── CRI indisponível ──
    if echo "$tail_log" | grep -qE "CRI v1 runtime API|unknown service runtime|Unimplemented"; then
      fix "[tentativa $attempt] Erro de CRI — reconfigurando containerd"
      fix_containerd; sleep 5; continue
    fi

    # ── Socket do containerd ──
    if echo "$tail_log" | grep -qE "no such file.*containerd|connection refused.*containerd"; then
      fix "[tentativa $attempt] Socket do containerd inacessível — reiniciando"
      systemctl restart containerd; sleep 6; continue
    fi

    # ── Token expirado ou inválido ──
    if echo "$tail_log" | grep -qE "token.*invalid|token.*expired|unauthorized|Unauthorized"; then
      error "Token inválido ou expirado.\n\
       Gere um novo no controller com:\n\
       ${CYAN}kubeadm token create --print-join-command${RESET}"
    fi

    # ── Controller inacessível ──
    if echo "$tail_log" | grep -qE "connection refused.*${ENDPOINT%:*}|dial tcp.*${ENDPOINT%:*}|no route to host"; then
      fix "[tentativa $attempt] Falha de conexão com controller — aguardando 15s"
      sleep 15; continue
    fi

    # ── Swap ativa ──
    if echo "$tail_log" | grep -q "\[ERROR Swap\]"; then
      fix "[tentativa $attempt] Swap detectada — forçando desativação"
      swapoff -a; sleep 2; continue
    fi

    # ── br_netfilter / sysctl ──
    if echo "$tail_log" | grep -qE "bridge-nf-call|br_netfilter"; then
      fix "[tentativa $attempt] Módulo br_netfilter — recarregando"
      modprobe br_netfilter
      sysctl -w net.bridge.bridge-nf-call-iptables=1 >> "$LOG_FILE" 2>&1 || true
      sleep 2; continue
    fi

    # ── Porta em uso ──
    if echo "$tail_log" | grep -qE "address already in use|port.*in use"; then
      fix "[tentativa $attempt] Porta em uso — limpando"
      fix_ports; sleep 3; continue
    fi

    # ── Kubelet com estado anterior ──
    if echo "$tail_log" | grep -qE "kubelet.*already running|/var/lib/kubelet.*exist"; then
      fix "[tentativa $attempt] Estado anterior do kubelet — resetando"
      kubeadm reset -f >> "$LOG_FILE" 2>&1 || true
      rm -rf /etc/kubernetes /var/lib/kubelet; sleep 3; continue
    fi

    # ── Timeout / TLS ──
    if echo "$tail_log" | grep -qE "timeout|context deadline exceeded|TLS"; then
      fix "[tentativa $attempt] Timeout/TLS — aguardando 20s"
      sleep 20; continue
    fi

    # ── Hash incorreto ──
    if echo "$tail_log" | grep -qE "cluster CA.*does not match|ca-cert-hash"; then
      error "O hash do certificado não corresponde ao controller.\n\
       Obtenha o hash correto com:\n\
       ${CYAN}openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \\\n\
         openssl rsa -pubin -outform der 2>/dev/null | \\\n\
         openssl dgst -sha256 -hex | sed 's/^.* /sha256:/'${RESET}"
    fi

    warn "Erro não identificado na tentativa $attempt"
    [[ $attempt -ge $MAX_RETRIES ]] && \
      error "kubeadm join falhou após $MAX_RETRIES tentativas. Veja: $LOG_FILE"
    sleep 8
  done
}

# =============================================================================
# INÍCIO DO SCRIPT
# =============================================================================

section "Parâmetros Recebidos"
info "Controller : $ENDPOINT"
info "Token      : ${JOIN_TOKEN:0:6}.****************"   # Não loga o token completo
info "Cert Hash  : ${CERT_HASH:0:16}..."
info "K8s Version: $K8S_VERSION"

section "Verificações Iniciais"

[[ $EUID -ne 0 ]] && error "Execute com: sudo bash $0 <args>"

OS_ID=$(grep  "^ID="         /etc/os-release | cut -d= -f2 | tr -d '"')
OS_VER=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
[[ "$OS_ID" != "ubuntu" ]] && error "Apenas Ubuntu é suportado. Detectado: $OS_ID"
info "Sistema: Ubuntu $OS_VER"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  DEB_ARCH="amd64" ;;
  aarch64) DEB_ARCH="arm64" ;;
  *)       error "Arquitetura não suportada: $ARCH" ;;
esac
info "Arquitetura: $ARCH ($DEB_ARCH)"

CPU_COUNT=$(nproc)
TOTAL_RAM=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
info "CPUs: $CPU_COUNT | RAM: ${TOTAL_RAM} MB"
[[ $CPU_COUNT -lt 2 ]] && warn "Recomendado mínimo 2 CPUs"
[[ $TOTAL_RAM -lt 1700 ]] && warn "Recomendado mínimo 2 GB de RAM"

if ! ping -c 1 -W 5 8.8.8.8 &>/dev/null && ! ping -c 1 -W 5 1.1.1.1 &>/dev/null; then
  error "Sem conectividade com a internet."
fi
success "Conectividade com internet OK"

# Testa acesso ao controller antes de instalar qualquer coisa
check_controller_reachable

# ── Reset de instalação anterior ──────────────────────────────────────────────
section "Verificando Instalação Anterior"
reset_if_exists

# ── Swap ──────────────────────────────────────────────────────────────────────
section "Desabilitando Swap"
swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab
echo 0 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
for zram_svc in $(systemctl list-units --type=service --all \
    | grep -oE 'systemd-zram[^ ]+' || true); do
  systemctl is-active --quiet "$zram_svc" 2>/dev/null && {
    fix "zram detectado ($zram_svc) — desabilitando"
    systemctl stop    "$zram_svc" 2>/dev/null || true
    systemctl disable "$zram_svc" 2>/dev/null || true
  }
done
SWAP_TOTAL=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
[[ "$SWAP_TOTAL" -ne 0 ]] \
  && warn "Swap ainda reportada — kubeadm usará --ignore-preflight-errors=Swap" \
  || success "Swap desabilitada"

# ── Módulos de kernel ─────────────────────────────────────────────────────────
section "Configurando Módulos de Kernel"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
for mod in overlay br_netfilter; do
  if lsmod | grep -q "^${mod}[[:space:]]"; then
    success "Módulo já carregado: $mod"
  else
    modprobe "$mod" >> "$LOG_FILE" 2>&1 || error "Falha ao carregar módulo: $mod"
    success "Módulo carregado: $mod"
  fi
done

# ── sysctl ────────────────────────────────────────────────────────────────────
section "Configurando sysctl"
cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >> "$LOG_FILE" 2>&1
for param in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
  val=$(sysctl -n "$param" 2>/dev/null || echo "0")
  [[ "$val" != "1" ]] && {
    fix "Parâmetro $param=$val — forçando"
    sysctl -w "${param}=1" >> "$LOG_FILE" 2>&1 || warn "Não foi possível definir $param"
  }
done
success "sysctl validado"

# ── cgroup ────────────────────────────────────────────────────────────────────
section "Configurando Cgroup"
fix_cgroup

# ── Dependências ─────────────────────────────────────────────────────────────
section "Instalando Dependências"
retry "apt-get update -qq"
apt-get install -y -qq \
  apt-transport-https ca-certificates curl gnupg lsb-release \
  jq wget socat conntrack ipset ipvsadm bash-completion iptables \
  2>> "$LOG_FILE"
success "Dependências instaladas"

# ── iptables ─────────────────────────────────────────────────────────────────
section "Configurando iptables"
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
apt-get install -y -qq containerd.io 2>> "$LOG_FILE"
fix_containerd
wait_service containerd 30
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: ${CONTAINERD_SOCK}
image-endpoint:   ${CONTAINERD_SOCK}
timeout: 15
debug:   false
EOF
success "containerd instalado e configurado"

# ── kubeadm, kubelet, kubectl ─────────────────────────────────────────────────
section "Instalando kubeadm, kubelet, kubectl (v${K8S_VERSION})"
retry "curl -fsSL \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
retry "apt-get update -qq"
apt-get install -y -qq kubelet kubeadm kubectl 2>> "$LOG_FILE"
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
for bin in kubelet kubeadm kubectl; do
  command -v "$bin" &>/dev/null || error "$bin não instalado corretamente"
done

# Valida CRI com crictl agora disponível
fix_containerd
success "kubeadm, kubelet, kubectl instalados e travados"

# ── Portas ────────────────────────────────────────────────────────────────────
section "Verificando Portas"
fix_ports

# ── kubeadm join ─────────────────────────────────────────────────────────────
section "Entrando no Cluster Kubernetes"
run_kubeadm_join

# ── Verifica status do kubelet ────────────────────────────────────────────────
section "Verificando Status do kubelet"
sleep 5
if ! systemctl is-active kubelet &>/dev/null; then
  warn "kubelet não está ativo após o join — coletando logs"
  journalctl -u kubelet -n 50 --no-pager >> "$LOG_FILE" 2>&1 || true
  warn "Verifique: journalctl -u kubelet -f"
else
  success "kubelet ativo e rodando"
fi

# ── Sumário Final ─────────────────────────────────────────────────────────────
section "✅ Worker Node Adicionado ao Cluster"

KUBELET_VER=$(kubelet --version 2>/dev/null | awk '{print $2}' || echo "N/A")
KUBEADM_VER=$(kubeadm version -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "N/A")
CONTAINERD_VER=$(containerd --version 2>/dev/null | awk '{print $3}' || echo "N/A")
NODE_IP_SHOW=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")

echo ""
echo -e "  ${BOLD}Versões instaladas:${RESET}"
printf  "  %-14s %s\n" "kubelet:"    "$KUBELET_VER"
printf  "  %-14s %s\n" "kubeadm:"    "$KUBEADM_VER"
printf  "  %-14s %s\n" "containerd:" "$CONTAINERD_VER"
echo ""
echo -e "  ${BOLD}Este node:${RESET}"
printf  "  %-14s %s\n" "Hostname:"   "$(hostname)"
printf  "  %-14s %s\n" "IP:"         "$NODE_IP_SHOW"
printf  "  %-14s %s\n" "Controller:" "$ENDPOINT"
echo ""
echo -e "  ${BOLD}Para confirmar no controller:${RESET}"
echo -e "  ${CYAN}kubectl get nodes -o wide${RESET}"
echo ""
echo -e "  ${BOLD}Logs do kubelet neste node:${RESET}"
echo -e "  ${CYAN}journalctl -u kubelet -f${RESET}"
echo ""
echo -e "  ${GREEN}Log completo salvo em: $LOG_FILE${RESET}"
echo ""
