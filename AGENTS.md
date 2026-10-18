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
| `docker-compose.yml` / `compose.yaml`, deploy scripts that `ssh` to a host and run `docker compose` | Docker host | on that host (over SSH), or on this machine if the project runs here |
| Helm charts, k8s manifests, kustomize, `kubectl` in CI | Kubernetes | on any machine where `kubectl` reaches that cluster |
| Both | ask the user which one to map | |

Where the project actually runs matters, not where the code is. If the project runs on a remote server
and you have no SSH access to it, tell the user the exact command from step 3 to run there, and stop.

## 2. Check the target (nothing is installed by this)

Run on the target (Docker host over SSH, or locally with `kubectl` pointed at the cluster):

```sh
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sh -s -- --check
```

Add `--docker` or `--kubernetes` if both are present. Read the output:

- "установка невозможна" (installation impossible) with reasons → fix what it names if it is yours to
  fix (e.g. start Docker, add the user to the `docker` group, free port 8090 with `--port`), otherwise
  report it to the user and stop.
- "карта будет видеть не всё" (the map will not see everything) → fine to install; tell the user what
  will be missing (e.g. a kernel without kprobes: traffic is seen, requests and their errors are not).

## 3. Install

**Docker host** (needs root or the docker group; on a server use `sudo`):

```sh
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sudo sh -s -- --docker --yes --bind 127.0.0.1
```

`--bind 127.0.0.1` keeps the map off the internet; the user opens it through an SSH tunnel (step 5).
Drop it only for a local machine or a private network the user names, or if the user asks for a public
port — then also suggest putting the map behind their existing reverse proxy with HTTPS.

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

- Docker: `sudo /opt/vtm/vtm.sh status` — every service `running`/`healthy`.
- Kubernetes: `kubectl -n vtm get pods` — all `Running`.

Then confirm the map has data (Docker example; for Kubernetes port-forward first, see step 5):

```sh
PASS=$(sudo /opt/vtm/vtm.sh password)
curl -s -c /tmp/vtm.ck -o /dev/null -d "password=$PASS" http://127.0.0.1:8090/login
curl -s -b /tmp/vtm.ck http://127.0.0.1:8090/api/map.json | head -c 2000
```

The JSON should list the project's apps under `apps` and, once they talk, `traffic` links. Compare the
apps with the project's own services (Compose services or Deployments): each should be there. Read
`coverage.notes` — that is what the map says it cannot see; pass it on to the user. In the first ~5
minutes a link may point the wrong way; that settles by itself.

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
| Kubernetes PVCs `Pending` | no default StorageClass: the installer normally detects this; rerun with `--set storage.ephemeral=true` via helm, or set `storage.className` |
| `kubectl auth can-i` failures | the user's kube context lacks cluster-admin; ask for one that has it |
| map shows the stack but not the project | the project runs elsewhere (another host/cluster/context) — install there |

## 8. Remove

```sh
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sudo sh -s -- --docker --uninstall --yes
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sh -s -- --kubernetes --uninstall --yes
```

This deletes VTM's own stack and its data only.
