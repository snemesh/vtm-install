# Install VTM — instructions for an AI coding agent

You were given this file and asked to set up VTM for the user's project. VTM is a live 3D map of
infrastructure: it discovers servers, apps, databases and sites on a Docker host or in a Kubernetes
cluster, measures traffic and requests between them (Grafana Beyla, eBPF), and serves the map behind a
password. Follow these steps in order. They are written so you can do the whole job yourself; ask the
user only where a step says so.

Installer: `https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh` (POSIX sh; read it
before running if your policy asks you to review remote scripts). Human page:
https://snemesh.github.io/vtm-install/

## 0. Ground rules

- VTM only reads the target: the Docker socket or the Kubernetes API, container logs, and network
  traffic via eBPF. It never edits the user's project files, images, manifests or Compose files. Do not
  edit them either.
- Installing on a **production** server or cluster is the user's call. If the target looks like
  production (a public server, a cluster named prod/production, real traffic), say so and get a yes
  before step 3. A local machine, a dev/staging box or an explicit "do it" counts as a yes.
- Never print the map password into files you commit. Give it to the user in chat only.

## 1. Find out where the project runs

Look at the repository you are in and decide which target the user means:

| Evidence in the repo | Target | Where to run the installer |
|---|---|---|
| `compose.yml`, `compose.yaml`, `docker-compose.yml`, deploy scripts that `ssh` to a host and run `docker compose` | Docker host | on that host (over SSH), or on this machine if the project runs here |
| Helm charts, k8s manifests, kustomize, `kubectl` in CI | Kubernetes | on any machine where `kubectl` reaches that cluster |
| Both | ask the user which one to map | |

Pass the target you chose to the installer explicitly (`--docker` or `--kubernetes`) in every step
below, even when the machine seems to offer only one: then the installer never has to guess.

Where the project actually runs matters, not where the code is. If the project runs on a remote server
and you have no SSH access to it, tell the user the exact command from step 3 to run there, and stop.

## 2. Check the target (nothing is installed by this)

Run on the target (Docker host over SSH, or locally with `kubectl` pointed at the cluster):

```sh
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sh -s -- --check --docker
# or: … | sh -s -- --check --kubernetes
```

The installer prints in Russian. Read the output:

- "Проверка сервера: всё нужное есть" (everything needed is there) → install.
- "установка невозможна" (installation impossible) with reasons → fix what it names if it is yours to
  fix (e.g. start Docker, add the user to the `docker` group, free port 8090 with `--port`), otherwise
  report it to the user and stop.
- "карта будет видеть не всё" (the map will not see everything) → fine to install; tell the user what
  will be missing (a kernel without kprobes: traffic is seen, requests and their errors are not; a
  kernel older than 5.8 or without BTF: nothing between the apps is seen there, only the apps themselves).

## 3. Install

**Docker host** (needs root or the docker group; drop `sudo` if you already are root):

```sh
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sudo sh -s -- --docker --yes --bind 127.0.0.1
```

`--bind 127.0.0.1` keeps the map off the internet: on the same machine it opens at
http://127.0.0.1:8090/, from elsewhere through an SSH tunnel (step 5). Keep it by default, also on a
laptop. Leave it out only when the user asks for the map on the network (a LAN address, or a public port —
then also suggest their existing reverse proxy with HTTPS in front of it).

**Kubernetes** (needs cluster-admin rights; helm is downloaded if missing):

```sh
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sh -s -- --kubernetes --yes --expose none
```

`--expose none` keeps the map inside the cluster (open it with port-forward, step 5). If the project
already has an ingress controller and a domain, `--expose ingress=<host>` is the better choice; use
`--expose loadbalancer` or the default NodePort (30890) only if the user wants it reachable directly.

The installer prints the map's address and password at the end. Keep both for step 6.

## 4. Verify it works

Wait 2–3 minutes, then check on the target:

- Docker: `sudo /opt/vtm/vtm.sh status` — every service `running`/`healthy`. Beyla starts last (it waits
  for `beyla-config`), so its uptime is shorter: that is not a restart.
- Kubernetes: `kubectl -n vtm get pods` — all `Running`.

Then confirm the map has data. Docker (on the host):

```sh
PASS=$(sudo /opt/vtm/vtm.sh password)
curl -s -c /tmp/vtm.ck -o /dev/null -d "password=$PASS" http://127.0.0.1:8090/login
curl -s -b /tmp/vtm.ck http://127.0.0.1:8090/api/map.json > /tmp/vtm-map.json
```

Kubernetes: run `kubectl -n vtm port-forward svc/vtm-map 8090:80 &` first, take the password from step 6,
then the same two `curl` lines. Summarise the map (python3; or the same with `jq`):

```sh
python3 - <<'PY'
import json; m = json.load(open('/tmp/vtm-map.json'))
print('platform:', m.get('platform'), '| unreadable parts:', m.get('errors') or 'none')
for a in m['apps']: print('app  ', a['namespace'] + '/' + a['name'], a['role'], 'healthy' if a['healthy'] else 'BROKEN ' + a.get('problem', ''))
for l in m['links']:
    if l['kind'] == 'traffic': print('link ', l['from'], '->', l['to'])
for n in (m.get('coverage') or {}).get('notes', []): print('cannot see:', n)
PY
```

Compare the apps with the project's own services (Compose services or Deployments): each should be
there; VTM's own stack is hidden. Traffic links appear as the apps talk (a minute or two); in the first
~5 minutes one may point the wrong way; it usually settles once the listening port is seen (a link to an
address outside Docker/the cluster is directed by bytes and can stay wrong). The `cannot see` lines are what the map
itself says it misses: pass them on to the user. `servers[].ping_ok` is false unless a ping address was
configured; that is normal.

## 5. How the user opens the map

- Docker with `--bind 127.0.0.1`: `ssh -L 8090:127.0.0.1:8090 <user>@<server>`, then http://127.0.0.1:8090/
- Kubernetes with `--expose none`: `kubectl -n vtm port-forward svc/vtm-map 8090:80`, then http://127.0.0.1:8090/
- Otherwise: the address the installer printed.

## 6. Report to the user

Tell the user, briefly:

1. where VTM was installed (host or cluster) and how to open the map (step 5);
2. the password (Docker: `sudo /opt/vtm/vtm.sh password`; Kubernetes:
   `kubectl -n vtm get secret vtm-auth -o jsonpath='{.data.MAP_PASSWORD}' | base64 -d`);
3. which of their services the map found, and anything from `coverage.notes`;
4. how to update (run the install command again) and remove it (step 8).

Optionally offer to give the map readable names: on a Docker host, `/opt/vtm/map.config.json`
(`{"title": "...", "products": {"<compose project>": "Product name"}}`), then
`sudo /opt/vtm/vtm.sh up`; in Kubernetes, `--set-json 'map.config={...}'` on the helm release.

## 7. If something fails

| Symptom | Fix |
|---|---|
| `429 Too Many Requests` from Docker Hub | the installer retries; if it still fails, `docker login` on the host and run again |
| port 8090 busy | add `--port 8091` |
| `rootless` Docker | eBPF does not work there; tell the user VTM needs regular Docker |
| Kubernetes PVCs `Pending` | no default StorageClass: the installer normally detects this; rerun the installer with `--set storage.className=<class>` (or `--set storage.ephemeral=true` for data that may be lost on restart) |
| `kubectl auth can-i` failures | the user's kube context lacks cluster-admin; ask for one that has it |
| map shows the stack but not the project | the project runs elsewhere (another host/cluster/context) — install there |
| «есть и Docker, и Kubernetes: укажите --docker или --kubernetes» | pass the target you chose in step 1 |
| `sudo: not found` | you are root already: run the same command without `sudo` |
| Kubernetes pods stuck in rollout | the installer prints the pods that are not ready; `kubectl -n vtm describe pod <name>` tells why |

## 8. Remove

```sh
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sudo sh -s -- --docker --uninstall --yes
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sh -s -- --kubernetes --uninstall --yes
```

This deletes VTM's own stack and its data only. In Kubernetes the namespace is deleted only if the
installer created it; a folder `/var/lib/vtm-alloy` (Alloy's state) stays on the nodes and can be removed by
hand.

The map is plain HTTP. Tell the user so if you exposed it beyond localhost/port-forward, and suggest HTTPS
in front of it. VTM stores metrics, container logs (30 days) and request traces with paths on the target
itself; nothing is sent elsewhere.
