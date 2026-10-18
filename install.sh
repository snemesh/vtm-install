#!/bin/sh
# VTM installer: the live 3D map of your infrastructure, on whatever runs it — a Docker host or a
# Kubernetes cluster. It finds which one is here, checks it, installs the published images and prints the
# map's address and password.
#
#   curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sh
#   curl -fsSL …/install.sh | sh -s -- --kubernetes --expose loadbalancer
#
# Options (all optional):
#   --docker | --kubernetes   which one, when both are here (otherwise it asks, or takes the only one)
#   --version X               a release (0.3.0); default latest
#   --port N --bind ADDR      Docker: the map's port (8090) and address (127.0.0.1: this host only; 0.0.0.0 the network)
#   --dir DIR                 Docker: where the stack lives (/opt/vtm, or ~/vtm without root)
#   --namespace NS            Kubernetes: the namespace (vtm)
#   --expose KIND             Kubernetes: none (default: port-forward), nodeport, loadbalancer,
#                             ingress=<host|auto>; a re-run without it keeps how the installed map is reached
#   --set key=value           Kubernetes: a value of the chart (e.g. storage.className=fast), repeatable
#   --https [auto|internal|off]  HTTPS for the map: auto = Let's Encrypt (Docker: the host's --domain or
#                             <address>.sslip.io; Kubernetes: the ingress, through cert-manager), internal =
#                             a certificate of its own (the browser warns once), off; kept on later runs
#   --domain NAME             the map's name for HTTPS (Docker; in Kubernetes: --expose ingress=NAME)
#   --limit part=size         a part's memory limit (beyla=3Gi), repeatable; kept on later runs
#   --status                  what runs: memory of every part against its limit, restarts, the address
#   --check                   only check what the map would see here, install nothing
#   --uninstall               remove VTM (and its data) from here
#   --yes                     never ask: take the defaults
# POSIX sh: no bash needed.
set -eu

VTM_IMAGES=${VTM_IMAGES:-ghcr.io/snemesh}
VTM_CHART=${VTM_CHART:-oci://ghcr.io/snemesh/charts/vtm}
HELM_VERSION=${HELM_VERSION:-v3.18.4}
version=${VTM_VERSION:-latest}
version_given='' sets='' limits='' # sets: the --set values, one per line; limits: part=size, space-separated
platform='' port='' bind='' dir='' ns=vtm expose='' action=install yes=''
https='' domain=''

say() { printf '%s\n' "$*"; }
# The help is text of its own: with `curl … | sh` there is no file to read it from.
usage() {
  cat <<'HELP'
VTM installer: the live 3D map of a Docker host or a Kubernetes cluster. https://snemesh.github.io/vtm-install/
  curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sh -s -- [options]
  --docker | --kubernetes   which one, when both are here
  --version X               a release (0.3.0); default the newest build
  --port N --bind ADDR      Docker: the map's port (8090) and address (127.0.0.1 = this host only, default; 0.0.0.0 = the network)
  --dir DIR                 Docker: where the stack lives (/opt/vtm, or ~/vtm without root)
  --namespace NS            Kubernetes: the namespace (vtm)
  --expose KIND             Kubernetes: none (default: kubectl port-forward), nodeport, loadbalancer,
                            ingress=<host|auto> (a re-run without it keeps the installed one)
  --set key=value           Kubernetes: a value of the chart, e.g. storage.className=fast (repeatable)
  --https [auto|internal|off]  HTTPS for the map: auto = Let's Encrypt (Docker: --domain or <IP>.sslip.io;
                            Kubernetes: the ingress via cert-manager), internal = own certificate, off
  --domain NAME             Docker: the map's domain for HTTPS
  --limit part=size         memory limit of a part, e.g. beyla=3Gi (repeatable; kept on later runs)
  --status                  memory of every part against its limit, restarts, the map's address
  --check                   only check what the map would see here
  --uninstall               remove VTM and its data
  --yes                     never ask
HELP
}
warn() { printf 'VTM: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --docker) platform=docker ;;
    --kubernetes | --k8s) platform=kubernetes ;;
    --version) version=${2:?--version needs a value}; version_given=1; shift ;;
    --port) port=${2:?--port needs a value}; shift ;;
    --bind) bind=${2:?--bind needs a value}; shift ;;
    --dir) dir=${2:?--dir needs a value}; shift ;;
    --namespace) ns=${2:?--namespace needs a value}; shift ;;
    --expose) expose=${2:?--expose needs a value}; shift ;;
    --set) sets="$sets${2:?--set needs key=value}
"; shift ;;
    --limit) limits="$limits ${2:?--limit needs part=size}"; shift ;;
    --https)
      https=auto
      case "${2:-}" in auto | on | internal | self-signed | off) https=$2; shift ;; esac
      ;;
    --domain) domain=${2:?--domain needs a name}; shift ;;
    --status) action=status ;;
    --check) action=check ;;
    --uninstall) action=uninstall ;;
    --yes | -y) yes=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "не знаю параметра $1 (есть --help)" ;;
  esac
  shift
done
version=${version#v}

# A question through the terminal (stdin is this script when it comes through a pipe).
ask() {
  if [ -n "$yes" ] || ! { [ -r /dev/tty ] && : < /dev/tty; } 2>/dev/null; then return 1; fi
  printf '%s ' "$1" > /dev/tty
  read -r answer < /dev/tty || return 1
  printf '%s' "$answer"
}

# ---------- what is here ----------
docker_here() { has docker && docker info >/dev/null 2>&1; }
# A cluster: a kube context is set, its API server answers with its version, and it is ready for
# traffic (/readyz says ok). Without a kubeconfig kubectl falls back to localhost:8080, where any web
# server (a project's nginx) answers /readyz; a starting API server gives its version before it is ready.
kube_here() {
  has kubectl && kubectl config current-context >/dev/null 2>&1 \
    && kubectl version -o json --request-timeout=5s 2>/dev/null | grep -q '"serverVersion"' \
    && [ "$(kubectl get --raw /readyz --request-timeout=5s 2>/dev/null)" = ok ]
}

pick_platform() {
  [ -n "$platform" ] && return
  d='' k=''
  docker_here && d=1
  kube_here && k=1
  if [ -n "$d" ] && [ -n "$k" ]; then
    ctx=$(kubectl config current-context 2>/dev/null || echo '?')
    say "Здесь есть и Docker, и доступ к кластеру Kubernetes ($ctx)."
    a=$(ask "Что показывать на карте: [d] контейнеры этого Docker-хоста или [k] кластер $ctx? [d/k]") || die "есть и Docker, и Kubernetes: укажите --docker или --kubernetes"
    case "$a" in k | K | к | К) platform=kubernetes ;; *) platform=docker ;; esac
  elif [ -n "$k" ]; then
    platform=kubernetes
  elif [ -n "$d" ]; then
    platform=docker
  elif has docker; then
    die "Docker установлен, но не отвечает этому пользователю: запустите от root (sudo sh) или добавьте пользователя в группу docker."
  elif has kubectl; then
    die "kubectl не достучался до кластера: проверьте kubectl config current-context и доступ к API."
  else
    die "здесь нет ни Docker, ни доступа к Kubernetes (kubectl). VTM ставится на Docker-хост или в кластер."
  fi
}

# ---------- Docker ----------
docker_dir() {
  [ -n "$dir" ] && { echo "$dir"; return; }
  if [ "$(id -u)" = 0 ]; then echo /opt/vtm; else echo "$HOME/vtm"; fi
}

# A folder's path with symlinks and . resolved (as given when it does not exist yet).
canon() { if [ -d "$1" ]; then (cd "$1" && pwd -P); else echo "$1"; fi; }

docker_ready() {
  has docker || die "Docker не установлен."
  docker info >/dev/null 2>&1 || die "Docker не отвечает этому пользователю: запустите от root (… | sudo sh) или добавьте пользователя в группу docker."
}

# The image, with Docker's own words when it cannot be had (no access, no such version, no such platform).
docker_pull() {
  [ -z "${VTM_NO_PULL:-}" ] || return 0
  if ! out=$(docker pull -q "$1" 2>&1); then
    die "не удалось скачать $1: $(printf '%s' "$out" | tail -n 1)"
  fi
}

docker_install() {
  docker_ready
  d=$(docker_dir)
  # A re-run without --version keeps the version the installation has (its .env), stack files included.
  if [ -z "$version_given" ] && [ -f "$d/.env" ]; then
    pinned=$(sed -n 's/^VTM_VERSION=//p' "$d/.env" | tail -n 1)
    [ -z "$pinned" ] || version=$pinned
  fi
  image="$VTM_IMAGES/vtm-collector:$version"
  say "VTM на Docker-хосте: $d, образы $VTM_IMAGES ($version)."
  # The folder is VTM's own: an existing folder with other things in it is not used (uninstall deletes the
  # folder). .vtm marks a folder VTM made.
  # (An installation made before the mark: its own vtm.sh and compose.yml of the project «vtm».)
  if [ -d "$d" ] && [ ! -f "$d/.vtm" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ] \
    && ! { [ -f "$d/vtm.sh" ] && grep -q '^name: vtm$' "$d/compose.yml" 2>/dev/null; }; then
    die "в $d уже есть другие файлы: VTM ставится в свою, пустую папку (укажите другую: --dir)."
  fi
  # One VTM per host: another folder's stack is updated there, not doubled here (vtm.sh checks it too).
  # Paths compared as the filesystem has them (a relative or symlinked --dir is the same folder).
  other=''
  for w in $(docker ps -a --filter label=com.docker.compose.project=vtm --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | sort -u); do
    [ "$(canon "$w")" = "$(canon "$d")" ] || { other=$w; break; }
  done
  [ -z "$other" ] || die "на этом сервере уже работает VTM ($other): второй не ставится. Обновить его: --dir $other; удалить: --dir $other --uninstall."
  docker_pull "$image"
  # The stack's files come out of the image (/bundle/docker): .env (passwords, settings) and a map.config.json
  # of the installation's own stay as they are.
  mkdir -p "$d" && : > "$d/.vtm"
  tmp=$(mktemp -d)
  id=$(docker create "$image")
  docker cp "$id:/bundle/docker/." "$tmp/" >/dev/null
  docker rm "$id" >/dev/null
  [ -f "$d/map.config.json" ] && rm -f "$tmp/map.config.json"
  rm -f "$tmp/.env" "$tmp/up.sh" "$tmp/down.sh" "$tmp/compose.dev.yml" "$tmp/map.Dockerfile"
  cp -R "$tmp/." "$d/"
  rm -rf "$tmp"
  chmod +x "$d/vtm.sh" "$d/beyla-config.sh"
  # What is asked this time (a version given with --version, port, address) changes an installation made
  # before; a re-run without --version keeps the version it has.
  VTM_VERSION_SET=${version_given:+$version} VTM_PORT_SET=$port VTM_BIND_SET=$bind VTM_IMAGES=$VTM_IMAGES \
    VTM_LIMITS_SET=$limits VTM_HTTPS_SET=$https VTM_DOMAIN_SET=$domain "$d/vtm.sh" up
}

docker_check() {
  docker_ready
  d=$(mktemp -d)
  image="$VTM_IMAGES/vtm-collector:$version"
  docker_pull "$image"
  id=$(docker create "$image") && docker cp "$id:/bundle/docker/vtm.sh" "$d/" >/dev/null && docker rm "$id" >/dev/null
  VTM_PORT_SET=$port sh "$d/vtm.sh" check
  rm -rf "$d"
}

docker_status() {
  docker_ready
  d=$(docker_dir)
  [ -x "$d/vtm.sh" ] || die "в $d нет VTM (другая папка: --dir)"
  "$d/vtm.sh" status
}

docker_uninstall() {
  docker_ready
  d=$(docker_dir)
  [ -x "$d/vtm.sh" ] || die "в $d нет VTM (другая папка: --dir)"
  a=$(ask "Удалить VTM и все его данные (метрики, логи, трассы) из $d? [y/N]") || a=${yes:+y}
  case "$a" in y | Y | д | Д | yes) "$d/vtm.sh" uninstall ;; *) say "Ничего не удалено." ;; esac
}

# ---------- Kubernetes ----------
helm_cmd() {
  # Helm 3.14 or newer: --reset-then-reuse-values keeps what earlier runs set (limits, names, storage).
  if has helm; then
    hv=$(helm version --template '{{.Version}}' 2>/dev/null | tr -d v)
    hmaj=$(echo "$hv" | cut -d. -f1) hmin=$(echo "$hv" | cut -d. -f2)
    if [ "${hmaj:-0}" -gt 3 ] 2>/dev/null || { [ "${hmaj:-0}" -eq 3 ] && [ "${hmin:-0}" -ge 14 ]; } 2>/dev/null; then echo helm; return; fi
    say "helm $hv старше 3.14: для установки беру свежий во временную папку." >&2
  fi
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$(uname -m)" in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) die "нет helm, и для $(uname -m) его не скачать: поставьте helm сами" ;; esac
  # A folder of its own each time (mktemp -d: only this user can write there), and the archive checked
  # against the checksum Helm publishes next to it, before anything of it runs.
  hdir=$(mktemp -d "${TMPDIR:-/tmp}/vtm-helm.XXXXXX") # removed at the end (cleanup below)
  tgz="helm-$HELM_VERSION-$os-$arch.tar.gz"
  say "Нет helm: скачиваю $HELM_VERSION во временную папку (только для установки)." >&2
  if ! curl -fsSL -o "$hdir/$tgz" "https://get.helm.sh/$tgz" || ! curl -fsSL -o "$hdir/$tgz.sha256sum" "https://get.helm.sh/$tgz.sha256sum"; then
    die "не удалось скачать helm: поставьте его сами (https://helm.sh/docs/intro/install/)"
  fi
  want=$(awk '{print $1}' "$hdir/$tgz.sha256sum")
  if has sha256sum; then got=$(sha256sum "$hdir/$tgz" | awk '{print $1}'); else got=$(shasum -a 256 "$hdir/$tgz" | awk '{print $1}'); fi
  if [ -z "$want" ] || [ "$want" != "$got" ]; then die "контрольная сумма helm не совпала: архив не использован"; fi
  tar -xzf "$hdir/$tgz" -C "$hdir" "$os-$arch/helm" && chmod 700 "$hdir/$os-$arch/helm"
  echo "$hdir/$os-$arch/helm"
}

# Another VTM in the cluster: the namespaces of VTM's DaemonSets other than this one. One VTM per cluster
# (a second would draw every app twice and its Beyla would fight the first for port 9400 on the servers).
kube_other_vtm() {
  kubectl get daemonset -A -l app.kubernetes.io/part-of=vtm -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null \
    | sort -u | grep -vx "$ns" || true
}

kube_limits='' kube_cidrs='' kube_ephemeral='' kube_nodeport=''
kube_check() {
  ctx=$(kubectl config current-context 2>/dev/null || echo '?')
  say "Кластер: $ctx"
  other=$(kube_other_vtm | head -n 1)
  [ -z "$other" ] || die "в кластере уже работает VTM (namespace $other): второй не ставится — он показывал бы всё дважды и спорил бы с первым за порт 9400 на серверах. Обновить тот: --namespace $other; удалить его: --namespace $other --uninstall."
  # Port 9400 of the servers (Beyla's metrics, host network): taken by another program in the cluster?
  taken=$(kubectl get pods -A -o go-template='{{range .items}}{{$n := printf "%s/%s" .metadata.namespace .metadata.name}}{{$h := .spec.hostNetwork}}{{range .spec.containers}}{{range .ports}}{{if or (eq (print .hostPort) "9400") (and $h (eq (print .containerPort) "9400"))}}{{$n}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}' 2>/dev/null | grep -v "^$ns/" | head -n 1 || true)
  [ -z "$taken" ] || die "порт 9400 на серверах занят подом $taken; Beyla VTM слушает этот порт в сети сервера и не запустится."
  # NodePort 30890 of the map: taken by a service other than VTM's own? Then the cluster picks a free one.
  kube_nodeport=''
  if { [ "$expose" = nodeport ] || { [ -z "$expose" ] && [ "$(kube_release_expose)" = nodeport ]; }; } && kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{range .spec.ports[*]} {.nodePort}{end}{"\n"}{end}' 2>/dev/null \
    | grep -v "^$ns/vtm-map " | grep -q ' 30890\( \|$\)'; then
    kube_nodeport=0
  fi
  errs=''
  for r in clusterroles clusterrolebindings daemonsets namespaces; do
    kubectl auth can-i create "$r" -A >/dev/null 2>&1 || errs="$errs $r"
  done
  [ -z "$errs" ] || die "не хватает прав (нужен администратор кластера): нельзя создать$errs"
  # Every server: its kernel (Beyla, eBPF: 5.8 and newer) and architecture.
  old=''
  for n in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.nodeInfo.kernelVersion}={.status.nodeInfo.architecture}{"\n"}{end}'); do
    name=${n%%=*} rest=${n#*=} kernel=${rest%%=*} arch=${rest#*=}
    major=$(echo "$kernel" | cut -d. -f1) minor=$(echo "$kernel" | cut -d. -f2 | tr -dc 0-9)
    # The pods are kept off other servers (node affinity): their apps are not on the map.
    case "$arch" in amd64 | arm64) ;; *) kube_limits="${kube_limits:+$kube_limits;}сервер $name ($arch): образов VTM для него нет, его приложения не видны" ;; esac
    case "$kernel" in 10.0.*) continue ;; esac # a Windows server (VTM stays off it, counted below)
    if [ "$major" -lt 5 ] || { [ "$major" -eq 5 ] && [ "${minor:-0}" -lt 8 ]; }; then old="$old $name ($kernel)"; fi
  done
  [ -z "$old" ] || kube_limits="${kube_limits:+$kube_limits;}ядро старше 5.8 на серверах:$old — трафик и запросы их приложений не видны"
  win=$(kubectl get nodes -l kubernetes.io/os=windows -o name 2>/dev/null | wc -l | tr -d ' ')
  [ "$win" = 0 ] || kube_limits="${kube_limits:+$kube_limits;}серверов Windows: $win — VTM на них не работает, их приложения не видны"
  # Disks for the stores: the cluster's default StorageClass; without one, emptyDir. An installed release
  # keeps the form it has: a StatefulSet's disks cannot change in place, and the upgrade would fail.
  kube_ephemeral=''
  prev=$(kube_release_value ephemeral || true)
  if [ -n "$prev" ]; then
    [ "$prev" = true ] && kube_ephemeral=1
  elif printf '%s' "$sets" | grep -q '^storage\.className='; then
    :
  elif ! kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null | grep -qx true; then
    kube_ephemeral=1
    kube_limits="${kube_limits:+$kube_limits;}в кластере нет StorageClass по умолчанию: метрики, логи и трассы хранятся до перезапуска их пода (свой класс при новой установке: --set storage.className=…)"
  fi
  [ -n "$kube_ephemeral" ] || kube_storage_check
  kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1 \
    || kube_limits="${kube_limits:+$kube_limits;}в кластере нет metrics-server: память и процессор приложений не видны"
  # The cluster's own networks: the pods' (from the servers) and the services' (around the API's address).
  for c in $(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.podCIDR}{"\n"}{end}' 2>/dev/null | sort -u); do
    kube_cidrs="${kube_cidrs:+$kube_cidrs,}$c"
  done
  # The services' range around the API's address: /16 inside the private ranges; else /20 (a /16 around
  # GKE's 34.118.224.0/20 would call public addresses «inside»).
  svc=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  case "$svc" in
    10.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | 192.168.*) kube_cidrs="${kube_cidrs:+$kube_cidrs,}$(echo "$svc" | cut -d. -f1-2).0.0/16" ;;
    *.*.*.*) a3=$(echo "$svc" | cut -d. -f3); kube_cidrs="${kube_cidrs:+$kube_cidrs,}$(echo "$svc" | cut -d. -f1-2).$((a3 / 16 * 16)).0/20" ;;
  esac
  # The servers' own addresses: pods with hostNetwork speak from them.
  for ip in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null | sort -u); do
    case "$ip" in *.*.*.*) kube_cidrs="${kube_cidrs:+$kube_cidrs,}$ip/32" ;; esac
  done
  if [ -n "$kube_limits" ]; then
    say "Проверка кластера: карта будет видеть не всё —"
    printf '%s\n' "$kube_limits" | tr ';' '\n' | sed 's/^/  - /'
  else
    say "Проверка кластера: права есть, ядра серверов подходят. Видны ли запросы (kprobes), карта скажет сама после установки."
  fi
}

# The stores' disks will be made: the class chosen (storage.className, else the cluster's default) has a
# working provisioner. A class of a cloud's old in-tree plugin (EKS's gp2: kubernetes.io/aws-ebs) makes
# disks only through that cloud's CSI driver since Kubernetes 1.23; without the driver the claims stay
# Pending forever — stop before installing, with the ways out.
kube_storage_check() {
  printf '%s' "$sets" | grep -qx 'storage\.ephemeral=true' && return 0
  cls=$(printf '%s' "$sets" | sed -n 's/^storage\.className=//p' | tail -n 1)
  [ -n "$cls" ] || cls=$(kube_release_class)
  [ -n "$cls" ] || cls=$(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class} {.metadata.name}{"\n"}{end}' 2>/dev/null | sed -n 's/^true //p' | head -n 1)
  [ -n "$cls" ] || return 0
  prov=$(kubectl get storageclass "$cls" -o jsonpath='{.provisioner}' 2>/dev/null) \
    || die "StorageClass $cls нет в кластере (есть: $(kubectl get storageclass -o name 2>/dev/null | sed 's|.*/||' | tr '\n' ' '))"
  case "$prov" in
    kubernetes.io/aws-ebs | ebs.csi.aws.com) drv=ebs.csi.aws.com ;;
    kubernetes.io/gce-pd | pd.csi.storage.gke.io) drv=pd.csi.storage.gke.io ;;
    kubernetes.io/azure-disk | disk.csi.azure.com) drv=disk.csi.azure.com ;;
    kubernetes.io/azure-file | file.csi.azure.com) drv=file.csi.azure.com ;;
    kubernetes.io/cinder | cinder.csi.openstack.org) drv=cinder.csi.openstack.org ;;
    kubernetes.io/vsphere-volume | csi.vsphere.vmware.com) drv=csi.vsphere.vmware.com ;;
    *) return 0 ;;
  esac
  minor=$(kubectl version -o json 2>/dev/null | tr -d ' \n' | sed -n 's/.*"serverVersion":{[^}]*"minor":"\([0-9]*\).*/\1/p')
  case "$prov" in kubernetes.io/*) [ "${minor:-99}" -ge 23 ] 2>/dev/null || return 0 ;; esac
  kubectl get csidriver "$drv" >/dev/null 2>&1 && return 0
  others=$(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}={.provisioner}{"\n"}{end}' 2>/dev/null | grep -v "^$cls=" | sed 's/=.*//' | tr '\n' ' ')
  warn "диски для метрик, логов и трасс не создадутся: StorageClass $cls ($prov) работает только через CSI-драйвер $drv, а его в кластере нет."
  warn "Выход — один из трёх, потом запустите установщик снова:"
  case "$drv" in
    ebs.csi.aws.com) warn "  1) поставить драйвер EBS (EKS): aws eks create-addon --cluster-name <кластер> --addon-name aws-ebs-csi-driver --service-account-role-arn <роль с AmazonEBSCSIDriverPolicy> — пошагово: https://snemesh.github.io/vtm-install/agent.md#disks" ;;
    *) warn "  1) поставить в кластер CSI-драйвер $drv (документация вашего облака)" ;;
  esac
  warn "  2) взять другой класс, который создаёт диски: --set storage.className=<класс>${others:+ (есть: $others)}"
  die "  3) хранить без дисков: --set storage.ephemeral=true (метрики, логи и трассы пропадут при перезапуске их пода)"
}

# The installed release's StorageClass (empty when there is none or it uses the default).
kube_release_class() {
  [ -n "${helm:-}" ] || return 0
  # The storage's own className (map.ingress has one too); Helm writes the keys sorted, className first.
  "$helm" get values vtm --namespace "$ns" -o json 2>/dev/null | tr -d ' \n' | sed -n 's/.*"storage":{"className":"\([^"]*\)".*/\1/p' | head -n 1
}

# The stores' claims get disks: at most two minutes (then the cluster's own reason, and the ways out), so a
# class that cannot make disks is told at once, not after the ten minutes of the rollout.
kube_wait_disks() {
  [ -z "$kube_ephemeral" ] || return 0
  printf '%s' "$sets" | grep -qx 'storage\.ephemeral=true' && return 0
  i=0
  while [ $i -lt 24 ]; do
    pending=$(kubectl -n "$ns" get pvc -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null | awk '$2 != "Bound" {print $1}')
    [ -n "$pending" ] || return 0
    sleep 5; i=$((i + 1))
  done
  first=$(echo "$pending" | head -n 1)
  why=$(kubectl -n "$ns" get events --field-selector "involvedObject.name=$first" --sort-by=.lastTimestamp -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | tail -n 1)
  warn "за две минуты не создались диски: $(echo "$pending" | tr '\n' ' ')"
  [ -z "$why" ] || warn "кластер говорит: $why"
  warn "Удалите незаконченную установку (--uninstall) и поставьте снова с одним из вариантов:"
  warn "  --set storage.className=<класс, который создаёт диски>   (классы: kubectl get storageclass)"
  die "  --set storage.ephemeral=true   (без дисков: данные пропадут при перезапуске пода хранилища)"
}

# A value of the installed release, by its last key (empty when there is no release or it does not set it).
kube_release_value() {
  [ -n "${helm:-}" ] || return 0
  "$helm" get values vtm --namespace "$ns" -a -o json 2>/dev/null | tr -d ' \n' | sed -n "s/.*\"$1\":\([a-z0-9]*\).*/\1/p" | head -n 1
}


# The parts of VTM in the cluster (resources.<part> in the chart).
kube_parts='map telemetry-mcp telemetry-live victoria-metrics loki alloy tempo gate-http gate-otlp guard guard-init node-exporter blackbox-exporter beyla'
# A size in Kubernetes' form: 3g, 3G, 3Gi → 3Gi; 512m, 512M, 512Mi → 512Mi (whole numbers).
kube_size() {
  case "$1" in
    *[0-9][Gg]i | *[0-9][Gg]) n=${1%i}; n=${n%?}; u=Gi ;;
    *[0-9][Mm]i | *[0-9][Mm]) n=${1%i}; n=${n%?}; u=Mi ;;
    *) return 1 ;;
  esac
  case "$n" in '' | *[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ] || return 1
  echo "$n$u"
}
kube_limit_sets() {
  for kv in $(echo "$limits" | tr ',' ' '); do
    p=${kv%%=*} v=${kv#*=}
    case " $kube_parts " in *" $p "*) ;; *) die "--limit: нет такой части VTM: $p (есть: $kube_parts)" ;; esac
    sz=$(kube_size "$v") || die "--limit $kv: нужен размер вида 512Mi, 3Gi"
    echo "resources.$p.limits.memory=$sz"
    # The map's resources were map.resources before: an old override of it gives way to this one.
    [ "$p" != map ] || echo "map.resources=null"
  done
}

# How the map is reached, read from the cluster (the Ingress vtm-map, else the Service's type).
kube_address() {
  host=$(kubectl -n "$ns" get ingress vtm-map -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)
  if [ -n "$host" ]; then
    scheme=http
    [ -z "$(kubectl -n "$ns" get ingress vtm-map -o jsonpath='{.spec.tls[0].hosts[0]}' 2>/dev/null)" ] || scheme=https
    say "VTM работает:  $scheme://$host/   (пока имя не ведёт на ingress-контроллер кластера — kubectl -n $ns port-forward svc/vtm-map 8090:80)"
    return
  fi
  case "$(kubectl -n "$ns" get svc vtm-map -o jsonpath='{.spec.type}' 2>/dev/null)" in
    NodePort)
      nodeport=$(kubectl -n "$ns" get svc vtm-map -o jsonpath='{.spec.ports[0].nodePort}')
      addr=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="ExternalIP")].address}{"\n"}{end}' | sed '/^$/d' | head -n 1)
      if [ -n "$addr" ]; then
        say "VTM работает:  http://$addr:$nodeport/   (порт $nodeport на любом сервере кластера)"
        say "Не открывается — облачный файрвол закрывает порты 30000–32767: откройте $nodeport или поставьте с --expose loadbalancer."
      else
        addr=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        if is_private "$addr"; then
          say "VTM работает:  http://$addr:$nodeport/ — это внутренний адрес сервера, он открывается только из сети кластера."
          say "С этой машины:  kubectl -n $ns port-forward svc/vtm-map 8090:80 → http://127.0.0.1:8090/   (снаружи — --expose loadbalancer)"
        else
          say "VTM работает:  http://$addr:$nodeport/   (порт $nodeport на любом сервере кластера)"
        fi
      fi
      say "Это HTTP: для HTTPS — --expose ingress=<имя> --https (или ingress=auto)."
      ;;
    LoadBalancer)
      i=0 lb=''
      while [ $i -lt 30 ] && [ -z "$lb" ]; do
        lb=$(kubectl -n "$ns" get svc vtm-map -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')
        [ -n "$lb" ] || sleep 4
        i=$((i + 1))
      done
      if [ -n "$lb" ]; then
        say "VTM работает:  http://$lb/   (HTTP; для HTTPS — --expose ingress=<имя> --https)"
      else
        say "VTM работает, но балансировщик за 2 минуты не дал адреса (в кластере его может не быть)."
        say "Пока: kubectl -n $ns port-forward svc/vtm-map 8090:80 → http://127.0.0.1:8090/   Адрес позже: kubectl -n $ns get svc vtm-map"
      fi
      ;;
    *)
      say "VTM работает внутри кластера. Открыть: kubectl -n $ns port-forward svc/vtm-map 8090:80, затем http://127.0.0.1:8090/"
      say "Открыть в сеть по HTTPS: --expose ingress=<домен> --https (или ingress=auto)."
      ;;
  esac
}

is_private() {
  case "$1" in 10.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | 192.168.* | 127.* | 100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].* | *:*) return 0 ;; esac
  return 1
}

# The public address the cluster's ingress controller is reached at: a load balancer's (a Service on
# port 443), else a server's external address, else a server's own address when it is public.
kube_ingress_address() {
  # The controller's own Service (Traefik, ingress-nginx, HAProxy, Contour/Envoy, Kong, Istio's gateway):
  # another load balancer of the cluster on 443 is not where the ingress is.
  a=$(kubectl get svc -A -o go-template='{{range .items}}{{if eq .spec.type "LoadBalancer"}}{{.metadata.name}} {{index .metadata.labels "app.kubernetes.io/name"}} {{range .status.loadBalancer.ingress}}{{.ip}}{{end}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
    | grep -Ei '^[^ ]*(traefik|ingress-nginx|ingress-controller|haproxy|envoy|contour|kong|istio-ingressgateway)' \
    | awk '{print $NF}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
  [ -n "$a" ] || a=$(kubectl get svc -A -o go-template='{{range .items}}{{if eq .spec.type "LoadBalancer"}}{{index .metadata.labels "app.kubernetes.io/name"}} {{range .status.loadBalancer.ingress}}{{.ip}}{{end}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
    | grep -Ei '^(traefik|ingress-nginx|rke2-ingress-nginx|haproxy-ingress|contour|envoy|kong|istio-ingressgateway) ' \
    | awk '{print $NF}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
  [ -n "$a" ] || a=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="ExternalIP")].address}{"\n"}{end}' 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)
  if [ -z "$a" ]; then
    for ip in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null); do
      is_private "$ip" || { a=$ip; break; }
    done
  fi
  echo "$a"
}

# Memory of every container of VTM now against its limit, restarts and why the last one ended (OOMKilled:
# the limit is too low), and the map's address.
kube_status() {
  kubectl get namespace "$ns" >/dev/null 2>&1 || die "в кластере нет namespace $ns (VTM в другом: --namespace)"
  kubectl -n "$ns" get pods -o wide
  say ""
  kube_address
  say ""
  # Init containers too (Beyla's guard-init): one that is killed holds Beyla back.
  lims=$(kubectl -n "$ns" get pods -o go-template='{{range .items}}{{$p := .metadata.name}}{{range .spec.initContainers}}{{$p}} {{.name}} {{with .resources.limits}}{{or .memory "-"}}{{else}}-{{end}}{{"\n"}}{{end}}{{range .spec.containers}}{{$p}} {{.name}} {{with .resources.limits}}{{or .memory "-"}}{{else}}-{{end}}{{"\n"}}{{end}}{{end}}')
  sts=$(kubectl -n "$ns" get pods -o go-template='{{range .items}}{{$p := .metadata.name}}{{range .status.initContainerStatuses}}{{$p}} {{.name}} {{.restartCount}} {{with .lastState.terminated}}{{.reason}}{{else}}{{with .state.terminated}}{{if ne .reason "Completed"}}{{.reason}}{{else}}-{{end}}{{else}}-{{end}}{{end}}{{"\n"}}{{end}}{{range .status.containerStatuses}}{{$p}} {{.name}} {{.restartCount}} {{with .lastState.terminated}}{{.reason}}{{else}}-{{end}}{{"\n"}}{{end}}{{end}}')
  top=$(kubectl -n "$ns" top pods --containers --no-headers 2>/dev/null || true)
  [ -n "$top" ] || say "(нет metrics-server: память сейчас не видна, видны лимиты и перезапуски)"
  say "Память VTM (сейчас / лимит):"
  printf '%s\n--\n%s\n--\n%s\n' "$lims" "$sts" "$top" | awk '
    function mi(q) { if (q ~ /Gi$/) return q * 1024; if (q ~ /Mi$/) return q + 0; if (q ~ /Ki$/) return q / 1024;
      if (q ~ /G$/) return q * 953.7; if (q ~ /M$/) return q * 0.9537; return q / 1048576 }
    /^--$/ { part++; next }
    part == 0 && NF == 3 { lim[$1" "$2] = $3; order[++n] = $1" "$2 }
    part == 1 && NF == 4 { rs[$1" "$2] = $3; why[$1" "$2] = $4 }
    part == 2 && NF == 4 { use[$1" "$2] = $4 }
    END { for (i = 1; i <= n; i++) { k = order[i]; split(k, a, " "); u = use[k]; l = lim[k]; note = ""
        if (why[k] == "OOMKilled") note = " — убит за нехватку памяти: поднимите лимит (--limit " a[2] "=…)"
        else if (u != "" && l != "-" && mi(u) >= 0.8 * mi(l)) note = sprintf(" — близко к лимиту (%d%%): поднимите примерно в 1,5 раза", 100 * mi(u) / mi(l))
        if (rs[k] > 0) note = note " (перезапусков: " rs[k] ")"
        printf "  %-18s %-34s %s / %s%s\n", a[2], a[1], (u == "" ? "—" : u), l, note } }'
}

# How the installed release opens the map, as an --expose value (empty: no release).
kube_release_expose() {
  [ -n "${helm:-}" ] || return 0
  v=$("$helm" get values vtm --namespace "$ns" -a -o json 2>/dev/null | tr -d ' \n') || return 0
  [ -n "$v" ] || return 0
  t=$(printf '%s' "$v" | sed -n 's/.*"service":{[^}]*"type":"\([A-Za-z]*\)".*/\1/p' | head -n 1)
  h=$(printf '%s' "$v" | sed -n 's/.*"ingress":{.*"enabled":true.*"host":"\([^"]*\)".*/\1/p' | head -n 1)
  case "$t" in
    NodePort) echo nodeport ;;
    LoadBalancer) echo loadbalancer ;;
    ClusterIP) if [ -n "$h" ]; then echo "ingress=$h"; else echo none; fi ;;
  esac
}

kube_install() {
  helm=$(helm_cmd)
  kube_check
  # The namespace, labelled so that the cluster's Pod Security lets Beyla, Alloy and node-exporter in (they
  # read the servers: host network and processes, kernel tracing; «baseline» or «restricted» refuse them),
  # and marked as VTM's, so that uninstall removes only a namespace VTM made. A namespace of the cluster's
  # own is never used: the label would let every pod there run privileged, on the server's processes and
  # disks (only one that already holds VTM's release, from an installer before the mark, is kept).
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    kubectl create namespace "$ns" >/dev/null
    kubectl label namespace "$ns" app.kubernetes.io/managed-by=vtm-install >/dev/null
  elif [ "$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" != vtm-install ] \
    && ! "$helm" status vtm --namespace "$ns" >/dev/null 2>&1; then
    die "namespace $ns уже есть и создан не VTM. VTM ставится в свой namespace: в нём разрешены привилегированные поды, и в чужом это разрешение получили бы все. Укажите новый, которого ещё нет: --namespace vtm-map"
  fi
  kubectl label namespace "$ns" --overwrite pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged >/dev/null \
    || die "не удалось разрешить привилегированные поды в namespace $ns (нужны права администратора)"
  # No helm --wait: it would wait for a load balancer's address that some clusters never give. The pods are
  # waited for below, the address after that.
  # --reset-then-reuse-values: what earlier runs set stays (memory limits, the map's names, the disks' class
  # and sizes — a StatefulSet's disks cannot change), on the new chart's defaults; this run's values win.
  set -- upgrade --install vtm "$VTM_CHART" --namespace "$ns" --timeout 10m --reset-then-reuse-values
  # latest: the newest chart, the main branch's builds included (they are pre-releases of the next
  # version, 1.2.4-main.N, newer than the release 1.2.3); a version: exactly that release.
  if [ "$version" = latest ]; then set -- "$@" --devel --set image.tag=; else set -- "$@" --version "$version" --set "image.tag=$version"; fi
  if [ -n "$kube_ephemeral" ]; then set -- "$@" --set storage.ephemeral=true; else set -- "$@" --set storage.ephemeral=false; fi
  set -- "$@" --set "image.registry=$VTM_IMAGES"
  # The default networks and those of this cluster: an address in them is inside the cluster.
  set -- "$@" --set "beyla.cidrs={10.42.0.0/16,10.43.0.0/16,10.244.0.0/16,10.96.0.0/12${kube_cidrs:+,$kube_cidrs}}"
  # What the check found, as a JSON list (the lines have no quotes of their own).
  if [ -n "$kube_limits" ]; then
    set -- "$@" --set-json "hostLimits=[\"$(printf '%s' "$kube_limits" | sed 's/;/","/g')\"]"
  else
    set -- "$@" --set-json 'hostLimits=[]'
  fi
  for kv in $(kube_limit_sets); do set -- "$@" --set "$kv"; done
  # How the map is reached: what was asked; else what the installed release has (a re-run changes
  # nothing); else inside the cluster only (port-forward): the map's password and the error lines of every
  # app should not cross a network unasked.
  [ -n "$expose" ] || expose=$(kube_release_expose)
  [ -n "$expose" ] || expose=none
  # HTTPS in the cluster is the ingress's: its controller ends TLS, cert-manager (when there is one) gets
  # the certificate. ingress=auto: <the controller's address>.sslip.io, a name that leads to it.
  if [ -n "$https" ] && [ "$https" != off ]; then
    case "$expose" in
      ingress=*) ;;
      *) die "HTTPS в Kubernetes — через ingress кластера: --expose ingress=<имя> (или ingress=auto: <адрес>.sslip.io) вместе с --https" ;;
    esac
  fi
  if [ "$expose" = ingress=auto ]; then
    ip=$(kube_ingress_address)
    [ -n "$ip" ] || die "не нашёл публичного адреса ingress-контроллера для ingress=auto: укажите имя — --expose ingress=<имя>"
    expose="ingress=$(echo "$ip" | tr . -).sslip.io"
  fi
  case "$https" in
    off) set -- "$@" --set map.ingress.tls=false --set map.ingress.clusterIssuer= ;;
    internal) set -- "$@" --set map.ingress.tls=true --set map.ingress.clusterIssuer= ;;
    auto | on)
      set -- "$@" --set map.ingress.tls=true
      issuer=$(printf '%s' "$sets" | sed -n 's/^map\.ingress\.clusterIssuer=//p' | tail -n 1)
      if [ -z "$issuer" ]; then
        issuers=$(kubectl get clusterissuers.cert-manager.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
        # The production one of Let's Encrypt when there are several (not its staging).
        issuer=$(echo "$issuers" | grep -i prod | head -n 1)
        [ -n "$issuer" ] || issuer=$(echo "$issuers" | grep -vi staging | head -n 1)
      fi
      if [ -n "$issuer" ]; then
        set -- "$@" --set "map.ingress.clusterIssuer=$issuer"
        say "HTTPS: сертификат выпустит cert-manager (ClusterIssuer $issuer)."
      else
        set -- "$@" --set map.ingress.clusterIssuer=
        warn "в кластере нет cert-manager (ClusterIssuer): HTTPS будет с сертификатом ingress-контроллера, браузер предупредит. Настоящий сертификат — поставьте cert-manager и запустите установщик снова."
      fi
      ;;
  esac
  case "$expose" in
    nodeport)
      set -- "$@" --set map.service.type=NodePort --set map.ingress.enabled=false
      # 30890 belongs to another service: the cluster gives a free port (printed below).
      [ -z "$kube_nodeport" ] || set -- "$@" --set map.service.nodePort=0
      ;;
    loadbalancer) set -- "$@" --set map.service.type=LoadBalancer --set map.ingress.enabled=false ;;
    none) set -- "$@" --set map.service.type=ClusterIP --set map.ingress.enabled=false ;;
    ingress=*) set -- "$@" --set map.service.type=ClusterIP --set map.ingress.enabled=true --set "map.ingress.host=${expose#ingress=}" ;;
    *) die "--expose: nodeport, loadbalancer, ingress=<host|auto> или none" ;;
  esac
  # The --set given to the installer, last: they win.
  old_ifs=$IFS
  IFS='
'
  for kv in $sets; do set -- "$@" --set "$kv"; done
  IFS=$old_ifs
  say "Ставлю VTM в namespace $ns (образы и стек, до 10 минут)…"
  "$helm" "$@" >/dev/null || die "helm не поставил VTM. Если прошлая установка оборвалась на полпути: $helm rollback vtm -n $ns — и снова"
  kube_wait_disks
  for w in $(kubectl -n "$ns" get deploy,sts,ds -l app.kubernetes.io/part-of=vtm -o name); do
    if ! kubectl -n "$ns" rollout status "$w" --timeout=10m >/dev/null 2>&1; then
      kubectl -n "$ns" get pods -o wide >&2
      die "не поднялось: $w (поды — выше; подробнее: kubectl -n $ns describe $w)"
    fi
  done
  pass=$(kubectl -n "$ns" get secret vtm-auth -o jsonpath='{.data.MAP_PASSWORD}' | base64 -d)
  say ""
  kube_address
  # The password only on a terminal: from a script (CI, an agent) it would stay in their logs.
  if [ -t 1 ]; then say "Пароль:        $pass"; else say "Пароль:        kubectl -n $ns get secret vtm-auth -o jsonpath='{.data.MAP_PASSWORD}' | base64 -d"; fi
  say "Карта наполнится за две-три минуты. Память и перезапуски: --status; лимит памяти: --limit beyla=3Gi."
  say "Обновить: запустите установщик ещё раз (настройки сохраняются); удалить: --uninstall."
}

kube_uninstall() {
  a=$(ask "Удалить VTM из кластера $(kubectl config current-context) (namespace $ns и все его данные)? [y/N]") || a=${yes:+y}
  case "$a" in
    y | Y | д | Д | yes)
      helm=$(helm_cmd)
      "$helm" uninstall vtm --namespace "$ns" --wait --timeout 5m >/dev/null || true
      kubectl -n "$ns" delete secret vtm-auth --ignore-not-found >/dev/null
      # The namespace goes only when VTM made it; a namespace of the user's keeps its other things.
      if [ "$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" = vtm-install ]; then
        kubectl delete namespace "$ns" --timeout=5m >/dev/null || warn "namespace $ns ещё удаляется: kubectl get namespace $ns"
      fi
      say "VTM удалён из кластера (на серверах осталась только папка состояния /var/lib/vtm-alloy)."
      ;;
    *) say "Ничего не удалено." ;;
  esac
}

# The helm this run downloaded (helm_cmd runs in a subshell, so the folder is found by its name).
cleanup() { [ -z "${helm:-}" ] || case "$helm" in */vtm-helm.*/*) rm -rf "${helm%/*/*}" ;; esac; }
trap cleanup EXIT

pick_platform
case "$platform:$action" in
  docker:install) docker_install ;;
  docker:check) docker_check ;;
  docker:uninstall) docker_uninstall ;;
  kubernetes:install) kube_install ;;
  kubernetes:check) kube_check ;;
  docker:status) docker_status ;;
  kubernetes:status) kube_status ;;
  kubernetes:uninstall) kube_uninstall ;;
esac
