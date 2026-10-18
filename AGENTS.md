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

`--bind 127.0.0.1` (also the default) keeps the map off the network: on the same machine it opens at
http://127.0.0.1:8090/, from elsewhere through an SSH tunnel (step 5). Keep it, also on a laptop. When the
user wants the map reachable from other machines, use HTTPS instead of a plain port (section 10): `--https`
(add `--domain <name>` if a DNS name points at the server), or `--https internal` when port 443 is taken by
the project's own proxy.

**Kubernetes** (needs cluster-admin rights; helm is downloaded if missing):

```sh
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sh -s -- --kubernetes --yes --expose none
```

`--expose none` (also the default) keeps the map inside the cluster (open it with port-forward, step 5).
If the project already has an ingress controller, `--expose ingress=<host> --https` is the better choice
(TLS on the ingress; the installer uses the cluster's cert-manager ClusterIssuer when there is one), and
`--expose ingress=auto --https` names it `<controller's IP>.sslip.io` when there is no domain. Use
`--expose loadbalancer` or `--expose nodeport` (30890) only if the user wants plain HTTP directly.

On a re-run, everything set before stays (memory limits, how the map is reached, HTTPS, names, disks):
pass only what changes.

Only one VTM runs per Docker host and per cluster. If the installer says VTM already runs (another
folder or namespace), update that one with the same `--dir` / `--namespace`; do not install a second.

The installer prints how to open the map at the end. It prints the password only to a terminal; run
from a script (as you do) it prints the command that shows it instead (step 6). Never paste the password
into files you commit.

## 4. Verify it works

Wait 2–3 minutes, then check on the target with `--status` (the same installer command with `--status`
instead of `--yes`, or on a Docker host `sudo /opt/vtm/vtm.sh status`):

- every service `running`/`healthy` (Docker) or every pod `Running` (Kubernetes). Beyla starts last on a
  Docker host (it waits for `beyla-config`), so its uptime is shorter: that is not a restart;
- the memory table: no part marked «убит за нехватку памяти» (killed for lack of memory) or «близко к
  лимиту» (near its limit). If one is, follow section 11.

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
- With `--https`: the https:// address the installer printed (`--https internal`: the browser warns once
  about the certificate; that is expected).
- Otherwise: the address the installer printed.

## 6. Report to the user

Tell the user, briefly:

1. where VTM was installed (host or cluster) and how to open the map (step 5);
2. the password (Docker: `sudo /opt/vtm/vtm.sh password`; Kubernetes:
   `kubectl -n vtm get secret vtm-auth -o jsonpath='{.data.MAP_PASSWORD}' | base64 -d`);
3. which of their services the map found, and anything from `coverage.notes`;
4. whether it is HTTPS, and if not, that the password crosses the network in clear text unless they use
   the tunnel/port-forward;
5. how to update (run the install command again; settings are kept) and remove it (step 8).

Optionally offer to give the map readable names: on a Docker host, `/opt/vtm/map.config.json`
(`{"title": "...", "products": {"<compose project>": "Product name"}}`), then
`sudo /opt/vtm/vtm.sh up`; in Kubernetes, `--set-json 'map.config={...}'` on the helm release.

## 7. If something fails

| Symptom | Fix |
|---|---|
| `429 Too Many Requests` from Docker Hub | the installer retries; if it still fails, `docker login` on the host and run again |
| port 8090 busy | add `--port 8091` |
| `rootless` Docker | eBPF does not work there; tell the user VTM needs regular Docker |
| «диски … не создадутся» / «за две минуты не создались диски» (disks will not be made) | section 9 |
| «уже работает VTM» (VTM already runs: another folder or namespace) | update that one: same command with its `--dir` or `--namespace`; never a second |
| «порт 9400 … занят» (Beyla's port taken) | another Beyla or a VTM of another kind runs on the server; tell the user which program the message names |
| «HTTPS пока не отвечает с действительным сертификатом» | port 443 is closed from the internet (cloud firewall/security group) or the domain does not point at the server; check `docker logs` of the `https` container (the message gives the command); fix, then `sudo /opt/vtm/vtm.sh up` |
| «Порт 443 занят» (HTTPS port taken) | the project's proxy holds 443: `--https internal`, or behind the project's proxy (section 10) |
| a part «убит за нехватку памяти» (OOMKilled) | section 11 |
| `kubectl auth can-i` failures | the user's kube context lacks cluster-admin; ask for one that has it |
| map shows the stack but not the project | the project runs elsewhere (another host/cluster/context) — install there |
| «есть и Docker, и Kubernetes: укажите --docker или --kubernetes» | pass the target you chose in step 1 |
| `sudo: not found` | you are root already: run the same command without `sudo` |
| «namespace … уже есть и создан не VTM» | VTM goes into a namespace of its own (it is allowed privileged pods); pick a new `--namespace`, never the project's |
| Kubernetes pods stuck in rollout | the installer prints the pods that are not ready; `kubectl -n vtm describe pod <name>` tells why |

## 8. Remove

```sh
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sudo sh -s -- --docker --uninstall --yes
curl -fsSL https://raw.githubusercontent.com/snemesh/vtm-install/main/install.sh | sh -s -- --kubernetes --uninstall --yes
```

This deletes VTM's own stack and its data only. In Kubernetes the namespace is deleted only if the
installer created it; a folder `/var/lib/vtm-alloy` (Alloy's state) stays on the nodes and can be removed by
hand.

VTM stores metrics, container logs (30 days) and request traces with paths on the target itself;
nothing is sent elsewhere.

## 9. Disks (Kubernetes) {#disks}

The stores (metrics, logs, traces) need disks of a StorageClass: the cluster's default, or the one in
`--set storage.className=<class>`. Before installing, the installer checks that the class can make disks;
if it cannot, it stops before anything is installed and names three ways out. Choose with the user:

1. **Install the missing CSI driver.** Typical case: EKS, whose default class `gp2` uses the old
   `kubernetes.io/aws-ebs` plugin, which since Kubernetes 1.23 works only through the EBS CSI driver. With
   `eksctl` and the AWS CLI (cluster name `<cluster>`, account id `<account>`):

   ```sh
   eksctl utils associate-iam-oidc-provider --cluster <cluster> --approve
   eksctl create iamserviceaccount --name ebs-csi-controller-sa --namespace kube-system --cluster <cluster> \
     --role-name AmazonEKS_EBS_CSI_DriverRole --role-only \
     --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy --approve
   aws eks create-addon --cluster-name <cluster> --addon-name aws-ebs-csi-driver \
     --service-account-role-arn arn:aws:iam::<account>:role/AmazonEKS_EBS_CSI_DriverRole
   kubectl get csidriver ebs.csi.aws.com      # present: the driver is in
   ```

   Then run the installer again. These change the user's AWS account (an IAM role, an EKS add-on): get the
   user's yes first. For other clouds, the message names the driver (`pd.csi.storage.gke.io`,
   `disk.csi.azure.com`, …): install it the way that cloud documents.
2. **Another class** that makes disks: `kubectl get storageclass`, then `--set storage.className=<class>`.
3. **No disks**: `--set storage.ephemeral=true`. Fine for a trial; metrics, logs and traces are lost when
   a store's pod restarts.

If disks are still not made after install (the installer waits two minutes and prints the cluster's own
reason), remove the half-made installation (`--uninstall`) and install again with option 2 or 3: a
StatefulSet's disks cannot change in place.

## 10. HTTPS {#https}

- **Docker, Let's Encrypt**: `--https` (with `--domain <name>` when a DNS name points at the server; without
  it the name is `<IP with dashes>.sslip.io`, which leads to the server's public IP). Caddy in front of the
  map gets and renews the certificate over port 443 only (port 80 stays the project's). Needs: port 443
  free on the host and open from the internet. The map's own port then listens on 127.0.0.1 only.
- **Docker, own certificate**: `--https internal` — `https://<IP>:8443/`, encrypted, the browser warns once.
  For servers without a public IP or with 443 taken by the project's proxy.
- **Behind the project's own proxy**: install with `--bind 127.0.0.1` and add a site to their proxy that
  passes to `http://127.0.0.1:8090` with `X-Forwarded-Proto` (nginx: `proxy_set_header X-Forwarded-Proto
  $scheme;`). This edits the user's proxy configuration: ask first.
- **Kubernetes**: `--expose ingress=<host> --https` (or `ingress=auto`). With cert-manager in the cluster
  the certificate is real; without it the ingress controller serves its own (the installer says so).
- Switch off: `--https off`. On a Docker host also `sudo /opt/vtm/vtm.sh https off|auto|internal [domain]`.

## 11. Memory limits {#memory}

Every part of VTM has a memory limit, so VTM never takes memory from the user's apps. CPU is not limited.

| Part | Default | Grows with |
|---|---|---|
| beyla | 2Gi | apps and calls; ~600 MB more for a minute at start |
| tempo | 3Gi | fresh traces, searches |
| loki | 2Gi | log volume |
| victoria-metrics | 1Gi | number of series |
| telemetry-mcp | 512Mi | map size |
| telemetry-live, alloy | 256Mi | |
| map | 192Mi | |
| node-exporter, blackbox-exporter, guard, gate-http and gate-otlp (Kubernetes), https (Docker) | 64–128Mi | |

How to check and adjust, when asked to tune VTM or when step 4 shows a problem:

1. Look: `… | sh -s -- --docker --status` (or `sudo /opt/vtm/vtm.sh status`) / `… | sh -s -- --kubernetes
   --status`. Memory per part «now / limit», restarts, and the last reason. In Kubernetes the «now» needs
   metrics-server; without it, judge by restarts and `OOMKilled`.
2. Raise a limit when the part is marked «убит за нехватку памяти» (OOMKilled) or «близко к лимиту»
   (≥80 %) on two checks a few minutes apart: new limit ≈ 1.5 × the current one. Ignore Beyla in its first
   two minutes (start peak).
3. Lower a limit only when the server itself is short of memory (`free -m` / `kubectl top nodes`: less
   than ~10 % available) and a part stays far below its limit: new limit ≈ 1.3 × its peak, never below
   64Mi, Beyla never below 768Mi, Tempo and Loki never below 512Mi.
4. Apply: `… | sh -s -- --docker --limit tempo=4Gi` (Docker host, immediately and only that part:
   `sudo /opt/vtm/vtm.sh limit tempo=4g`), or `… | sh -s -- --kubernetes --limit tempo=4Gi`. Several at
   once: repeat `--limit`. Sizes: `512Mi`, `3Gi` (Docker also takes `512m`, `3g`). Limits are kept on later
   runs and updates.
5. Check again with `--status` after a few minutes, and tell the user what you changed and why.
