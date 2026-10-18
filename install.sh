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
#   --port N --bind ADDR      Docker: the map's port (8090) and address (0.0.0.0; 127.0.0.1 for this host only)
#   --dir DIR                 Docker: where the stack lives (/opt/vtm, or ~/vtm without root)
#   --namespace NS            Kubernetes: the namespace (vtm)
#   --expose KIND             Kubernetes: nodeport (default), loadbalancer, ingress=<host>, none
#   --set key=value           Kubernetes: a value of the chart (e.g. storage.className=fast), repeatable
#   --check                   only check what the map would see here, install nothing
#   --uninstall               remove VTM (and its data) from here
#   --yes                     never ask: take the defaults
# POSIX sh: no bash needed.
set -eu

VTM_IMAGES=${VTM_IMAGES:-ghcr.io/snemesh}
VTM_CHART=${VTM_CHART:-oci://ghcr.io/snemesh/charts/vtm}
HELM_VERSION=${HELM_VERSION:-v3.18.4}
version=${VTM_VERSION:-latest}
version_given='' sets='' # sets: the --set values, one per line
platform='' port='' bind='' dir='' ns=vtm expose=nodeport action=install yes=''

say() { printf '%s\n' "$*"; }
# The help is text of its own: with `curl … | sh` there is no file to read it from.
usage() {
  cat <<'HELP'
VTM installer: the live 3D map of a Docker host or a Kubernetes cluster. https://snemesh.github.io/vtm-install/
  curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sh -s -- [options]
  --docker | --kubernetes   which one, when both are here
  --version X               a release (0.3.0); default the newest build
  --port N --bind ADDR      Docker: the map's port (8090) and address (0.0.0.0; 127.0.0.1 = this host only)
  --dir DIR                 Docker: where the stack lives (/opt/vtm, or ~/vtm without root)
  --namespace NS            Kubernetes: the namespace (vtm)
  --expose KIND             Kubernetes: nodeport (default), loadbalancer, ingress=<host>, none
  --set key=value           Kubernetes: a value of the chart, e.g. storage.className=fast (repeatable)
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
    "$d/vtm.sh" up
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

docker_uninstall() {
  docker_ready
  d=$(docker_dir)
  [ -x "$d/vtm.sh" ] || die "в $d нет VTM (другая папка: --dir)"
  a=$(ask "Удалить VTM и все его данные (метрики, логи, трассы) из $d? [y/N]") || a=${yes:+y}
  case "$a" in y | Y | д | Д | yes) "$d/vtm.sh" uninstall ;; *) say "Ничего не удалено." ;; esac
}

# ---------- Kubernetes ----------
helm_cmd() {
  if has helm; then echo helm; return; fi
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

kube_limits='' kube_cidrs='' kube_ephemeral=''
kube_check() {
  ctx=$(kubectl config current-context 2>/dev/null || echo '?')
  say "Кластер: $ctx"
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

# A value of the installed release, by its last key (empty when there is no release or it does not set it).
kube_release_value() {
  [ -n "${helm:-}" ] || return 0
  "$helm" get values vtm --namespace "$ns" -a -o json 2>/dev/null | tr -d ' \n' | sed -n "s/.*\"$1\":\([a-z0-9]*\).*/\1/p" | head -n 1
}

# The installed release's storage class and sizes, as --set values (storage.sizes.loki=50Gi), one per line.
kube_release_storage() {
  [ -n "${helm:-}" ] || return 0
  st=$("$helm" get values vtm --namespace "$ns" -a -o json 2>/dev/null | tr -d ' \n' \
    | sed -n 's/.*"storage":{\("className"[^}]*}\).*/\1/p' | head -n 1)
  [ -n "$st" ] || return 0
  c=$(printf '%s' "$st" | sed -n 's/.*"className":"\([^"]*\)".*/\1/p')
  [ -z "$c" ] || echo "storage.className=$c"
  printf '%s' "$st" | sed -n 's/.*"sizes":{\([^}]*\)}.*/\1/p' | tr ',' '\n' \
    | sed -n 's/^"\([a-z0-9-]*\)":"\([0-9A-Za-z.]*\)"$/storage.sizes.\1=\2/p'
}

kube_install() {
  helm=$(helm_cmd)
  kube_check
  # The namespace, labelled so that the cluster's Pod Security lets Beyla, Alloy and node-exporter in (they
  # read the servers: host network and processes, kernel tracing; «baseline» or «restricted» refuse them),
  # and marked as VTM's, so that uninstall removes only a namespace VTM made.
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    kubectl create namespace "$ns" >/dev/null
    kubectl label namespace "$ns" app.kubernetes.io/managed-by=vtm-install >/dev/null
  fi
  kubectl label namespace "$ns" --overwrite pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged >/dev/null \
    || die "не удалось разрешить привилегированные поды в namespace $ns (нужны права администратора)"
  # No helm --wait: it would wait for a load balancer's address that some clusters never give. The pods are
  # waited for below, the address after that.
  set -- upgrade --install vtm "$VTM_CHART" --namespace "$ns" --timeout 10m
  # The installed release's disks (class, sizes) stay as they are: a StatefulSet's disks cannot change.
  for kv in $(kube_release_storage); do set -- "$@" --set "$kv"; done
  # latest: the newest chart, the main branch's builds included (they are pre-releases of the next
  # version, 1.2.4-main.N, newer than the release 1.2.3); a version: exactly that release.
  if [ "$version" = latest ]; then set -- "$@" --devel; else set -- "$@" --version "$version" --set "image.tag=$version"; fi
  if [ -n "$kube_ephemeral" ]; then set -- "$@" --set storage.ephemeral=true; else set -- "$@" --set storage.ephemeral=false; fi
  set -- "$@" --set "image.registry=$VTM_IMAGES"
  # The default networks and those of this cluster: an address in them is inside the cluster.
  set -- "$@" --set "beyla.cidrs={10.42.0.0/16,10.43.0.0/16,10.244.0.0/16,10.96.0.0/12${kube_cidrs:+,$kube_cidrs}}"
  # What the check found, as a JSON list (the lines have no quotes of their own).
  [ -z "$kube_limits" ] || set -- "$@" --set-json "hostLimits=[\"$(printf '%s' "$kube_limits" | sed 's/;/","/g')\"]"
  case "$expose" in
    nodeport) set -- "$@" --set map.service.type=NodePort ;;
    loadbalancer) set -- "$@" --set map.service.type=LoadBalancer ;;
    none) set -- "$@" --set map.service.type=ClusterIP ;;
    ingress=*) set -- "$@" --set map.service.type=ClusterIP --set map.ingress.enabled=true --set "map.ingress.host=${expose#ingress=}" ;;
    *) die "--expose: nodeport, loadbalancer, ingress=<host> или none" ;;
  esac
  # The --set given to the installer, last: they win.
  old_ifs=$IFS
  IFS='
'
  for kv in $sets; do set -- "$@" --set "$kv"; done
  IFS=$old_ifs
  say "Ставлю VTM в namespace $ns (образы и стек, до 10 минут)…"
  "$helm" "$@" >/dev/null || die "helm не поставил VTM. Если прошлая установка оборвалась на полпути: $helm rollback vtm -n $ns — и снова"
  for w in $(kubectl -n "$ns" get deploy,sts,ds -l app.kubernetes.io/part-of=vtm -o name); do
    if ! kubectl -n "$ns" rollout status "$w" --timeout=10m >/dev/null 2>&1; then
      kubectl -n "$ns" get pods -o wide >&2
      die "не поднялось: $w (поды — выше; подробнее: kubectl -n $ns describe $w)"
    fi
  done
  pass=$(kubectl -n "$ns" get secret vtm-auth -o jsonpath='{.data.MAP_PASSWORD}' | base64 -d)
  say ""
  case "$expose" in
    nodeport)
      nodeport=$(kubectl -n "$ns" get svc vtm-map -o jsonpath='{.spec.ports[0].nodePort}')
      addr=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="ExternalIP")].address}{"\n"}{end}' | sed '/^$/d' | head -n 1)
      if [ -n "$addr" ]; then
        say "VTM работает:  http://$addr:$nodeport/   (порт $nodeport на любом сервере кластера)"
        say "Не открывается — облачный файрвол закрывает порты 30000–32767: откройте $nodeport или поставьте с --expose loadbalancer."
      else
        addr=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        say "VTM работает:  http://$addr:$nodeport/ — это внутренний адрес сервера, он открывается только из сети кластера."
        say "С этой машины:  kubectl -n $ns port-forward svc/vtm-map 8090:80 → http://127.0.0.1:8090/   (снаружи — --expose loadbalancer)"
      fi
      ;;
    loadbalancer)
      i=0 lb=''
      while [ $i -lt 30 ] && [ -z "$lb" ]; do
        lb=$(kubectl -n "$ns" get svc vtm-map -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')
        [ -n "$lb" ] || sleep 4
        i=$((i + 1))
      done
      if [ -n "$lb" ]; then
        say "VTM работает:  http://$lb/"
      else
        say "VTM работает, но балансировщик за 2 минуты не дал адреса (в кластере его может не быть)."
        say "Пока: kubectl -n $ns port-forward svc/vtm-map 8090:80 → http://127.0.0.1:8090/   Адрес позже: kubectl -n $ns get svc vtm-map"
      fi
      ;;
    ingress=*) say "VTM работает:  http://${expose#ingress=}/   (пока имя не ведёт на ingress-контроллер кластера — kubectl -n $ns port-forward svc/vtm-map 8090:80)" ;;
    none) say "VTM работает внутри кластера: kubectl -n $ns port-forward svc/vtm-map 8090:80 → http://127.0.0.1:8090/" ;;
  esac
  say "Пароль:        $pass"
  say "Карта наполнится за две-три минуты. Обновить: запустите установщик ещё раз; удалить: --uninstall."
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
  kubernetes:uninstall) kube_uninstall ;;
esac
