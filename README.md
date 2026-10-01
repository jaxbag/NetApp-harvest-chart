# NetApp Harvest Helm chart

Production-oriented native Helm chart for NetApp Harvest. The chart installs
Harvest pollers only. It does **not** install Prometheus, Prometheus Operator,
Grafana, Alertmanager, or any CRD.

## Version baseline and upstream research

This chart deliberately targets one upstream baseline:

| Item | Pinned value |
|---|---|
| Harvest version | `24.08.0` (`v24.08.0`, commit `0cd7265`) |
| Container image | `ghcr.io/netapp/harvest:24.08.0-1` |
| Image manifest | `linux/amd64`, digest `sha256:9292d5556d8b0e78178a37fa698a48ed8f77ae1b79a33849c6398651e2afe06a` |
| Documentation | `https://netapp.github.io/harvest/24.08/` |

Findings from the tagged source and versioned documentation:

- The official image is built from
  `container/onePollerPerContainer/Dockerfile`, uses a distroless Debian 12
  runtime, has `ENTRYPOINT ["bin/poller"]`, and does not declare `USER` or a
  container `HEALTHCHECK`. Registry inspection shows that this release tag is a
  single `linux/amd64` manifest, so the default node selector prevents it from
  being scheduled to an incompatible node.
- The official container workflow creates one container per poller and invokes
  `--poller <name> --promPort <port> --config <file>`. This chart mirrors that
  model with one Deployment per `pollers` entry.
- `harvest.yml` contains `Exporters`, `Defaults`, and `Pollers`. Prometheus is a
  pull exporter and serves `/metrics`; `local_http_addr: 0.0.0.0` exposes it to
  the Kubernetes Service.
- Harvest 24.08 supports `basic_auth`, `certificate_auth`,
  `credentials_file`, and `credentials_script`. This chart uses the documented
  plaintext output mode of `credentials_script`: the password is injected from
  a Kubernetes Secret into the selected poller pod and printed only to the
  child process stdout. The username is supplied by a pod environment variable
  and expanded by Harvest's documented config expander. Neither credential
  enters the ConfigMap or container arguments.
- The collector implementations and shipped `conf/*/default.yaml` files in
  `v24.08.0` confirm the ONTAP collector subset used by this chart:
  `Zapi`, `ZapiPerf`, `Rest`, `RestPerf`, `KeyPerf`, and `Ems`. `StorageGrid`,
  `Unix`, and the internal `NodeMon` module target other poller types and are
  deliberately excluded from the schema. There is no shipped `Simple`
  collector name in this release.
- ONTAP server verification is enabled by default (`use_insecure_tls: false`).
  `ca_cert` appends a PEM CA to the system roots.
- **Harvest 24.08 limitation:** `tls_min_version` is applied in the ZAPI client,
  but the 24.08 REST transport does not enforce it. Therefore `minVersion` is
  not a minimum-TLS guarantee for `Rest`, `RestPerf`, or `KeyPerf`. This was
  corrected by Harvest `24.11.1`, where both REST and ZAPI use the centralized
  credential transport, but this chart intentionally remains on 24.08.0.
- The only documented exporter health surface is the real TCP listener and
  `/metrics`; the chart does not invent `/healthz` or `/ready`. Default probes
  use `tcpSocket` on the `metrics` port.
- Poller metrics/cache are held in memory. In foreground mode logs go to stdout.
  With autosupport disabled, the chart has no durable state requirement.
  Therefore it intentionally creates no PVC. `/tmp` is an `emptyDir` so the
  container root filesystem can remain read-only.
- The upstream image defaults to root, but the poller foreground process only
  needs read access to `/opt/harvest` for this deployment mode. The chart runs
  it as the distroless non-root UID/GID `65532`, drops all capabilities, and
  disables privilege escalation. Override the contexts only after testing a
  customized image.

Primary sources: [Kubernetes deployment][k8], [Harvest configuration][config],
[Prometheus exporter][prom], [container deployment][containers], and the
[v24.08.0 source tag][source].

[k8]: https://netapp.github.io/harvest/24.08/install/k8/
[config]: https://netapp.github.io/harvest/24.08/configure-harvest-basic/
[prom]: https://netapp.github.io/harvest/24.08/prometheus-exporter/
[containers]: https://netapp.github.io/harvest/24.08/install/containers/
[source]: https://github.com/NetApp/harvest/tree/v24.08.0

Relevant implementation references: [24.08 ZAPI TLS handling][tls-2408] and
[24.11.1 centralized credential transport][tls-2411].

[tls-2408]: https://github.com/NetApp/harvest/blob/v24.08.0/pkg/api/ontapi/zapi/client.go
[tls-2411]: https://github.com/NetApp/harvest/blob/v24.11.1/pkg/auth/auth.go

## Architecture

Each ONTAP target gets an independent single-replica Deployment. Every pod
listens on the same container port, and one selector-stable Service exposes all
pod endpoints. Prometheus Operator discovers those endpoints through one
ServiceMonitor.

```text
ONTAP cluster(s) -> Harvest poller pod(s) -> Service /metrics
                                         -> ServiceMonitor
                                         -> existing Prometheus Operator
```

The default Deployment strategy is `Recreate`. A rolling update could briefly
run two pollers against the same ONTAP target and expose duplicate series;
`Recreate` trades that overlap for a short, controlled scrape gap. The
Deployment object itself is patched, not replaced.

Short Deployment names remain readable (`<fullname>-<poller>`). When the full
logical identity would exceed 63 characters, the name is rendered as a
50-character readable prefix plus a 12-character SHA-256 suffix. The hash is
calculated from the complete fullname and complete poller name before any
truncation. Rendering also fails if two logical identities ever resolve to the
same final name.

## Install

Create externally managed Secrets first. Each Secret must contain the key named
by `passwordKey`:

```sh
kubectl -n monitoring create secret generic harvest-cluster01 \
  --from-literal=password='REDACTED'
kubectl -n monitoring create secret generic harvest-cluster02 \
  --from-literal=password='REDACTED'
kubectl -n monitoring create secret generic ontap-ca \
  --from-file=ca.crt=./ontap-ca.crt
```

Review `examples/values-ontap.yaml`, then deploy:

```sh
helm upgrade --install harvest ./harvest \
  --namespace monitoring \
  --create-namespace \
  -f ./harvest/examples/values-ontap.yaml \
  --atomic --wait --timeout 10m
```

The `configure-me` entry in the default `values.yaml` exists only so defaults
remain valid against the production schema (`pollers.minProperties: 1`). It is
a reserved render-time blocker: an unmodified install fails with a clear error.
Real values must remove it with `configure-me: null`, as both the example and
test values do. A genuinely empty final `pollers` map fails schema validation.

When an `existingSecret`, its key, or the CA Secret is absent, Kubernetes keeps
the affected pod non-ready (`CreateContainerConfigError` or volume setup error).
With the recommended `--atomic --wait`, install/upgrade fails and Helm restores
the previous release without a chart hook modifying it.

`secrets.create=false` is the production default. With `true`, the chart creates
ordinary Helm-managed Secrets named by each `auth.existingSecret`; a password is
then required in values. This stores credentials in Helm release values and the
Secrets are deleted on uninstall, so this mode is intended only for controlled
development. The chart does not adopt a Secret that already exists.

### Secret ownership migration

Changing `secrets.create` changes ownership and is not a normal in-place
configuration edit. A direct `true` → `false` switch while keeping the same
Secret name is unsupported: Helm may delete the formerly Helm-owned Secret as
it disappears from the new manifest. The reverse direction may fail because a
pre-existing external object cannot be adopted automatically.

For a controlled `true` → `false` migration:

1. Create a new externally managed Secret under a **new name** and verify its
   password key.
2. Render and review an upgrade that simultaneously sets
   `secrets.create=false` and points the poller at that new name.
3. Run the upgrade with `--atomic --wait`. The pod moves to the external Secret;
   the old chart-managed Secret may then be removed by normal Helm ownership.
4. Verify the poller before deleting any out-of-band credential backup.

For `false` → `true`, likewise choose a new unused Secret name and provide the
chart-managed password in the same reviewed upgrade. The previous external
Secret remains untouched. The chart deliberately uses no `lookup`, keep policy,
takeover annotation, hook, or patch operation for either migration.

## TLS

`ontapTLS.verify=true` produces `use_insecure_tls: false`. If
`existingCASecret` is set, its `caKey` is mounted read-only and referenced using
the documented `ca_cert` setting. The CA Secret is external: the chart never
creates, labels, patches, hooks, or deletes it. `minVersion` must not be relied
upon as a REST TLS floor on Harvest 24.08; enforce REST protocol policy at the
network/endpoint layer or upgrade Harvest in a separately reviewed change.

## ServiceMonitor CRD strategy

When `serviceMonitor.enabled=true`, the ServiceMonitor is always rendered. The
chart deliberately does not install or conditionally hide the CRD. If
`monitoring.coreos.com/v1/ServiceMonitor` is absent, Kubernetes returns a clear
"no matches for kind" error and an atomic install is rolled back. Disable the
resource explicitly when Prometheus Operator is not present. Add selector
labels required by your Prometheus instance under `serviceMonitor.labels`.

## Controlled rollouts and credential rotation

`checksum/config` is calculated from ConfigMap **data only**. A real generated
configuration change starts a controlled rollout; chart metadata, release
timestamps, and unchanged upgrades do not. No random or time-based value is
used.

For chart-managed Secrets only, `checksum/secret` changes when the configured
password/key changes. Helm cannot observe content changes in an externally
managed Secret. Such rotation alone does not roll out a Deployment and the
chart intentionally does not use `lookup`, a hook, or a dynamic checksum to
pretend otherwise. Restart explicitly through your external controller, or set
a new operator-chosen token:

```sh
helm upgrade --install harvest ./harvest \
  -n monitoring -f ./harvest/examples/values-ontap.yaml \
  --set-string rollout.restartToken='rotation-2026-10-01' \
  --atomic --wait --timeout 10m
```

## Immutable image references

`image.tag` remains supported for the existing workflow. For production
reproducibility, set `image.digest` to a reviewed `sha256:<64 hex>` value. When
non-empty, the rendered reference is `repository@digest` and the tag is ignored.
The schema rejects malformed digests. The verified manifest digest for the
default 24.08.0-1 image is recorded in the version table above.

## Lifecycle behavior

Stable selectors contain only release/name plus the poller identity. They never
contain app or chart versions. The Service does not set `clusterIP`, so Helm
does not manufacture immutable-field diffs.

| Resource | Install | Upgrade | Rollback | Uninstall | Owner |
|---|---|---|---|---|---|
| Deployment (one/poller) | CREATE | PATCH; pod rollout only on pod-template change | PATCH to prior spec/config checksum | DELETE | Helm release |
| Service | CREATE; cluster assigns ClusterIP | PATCH; no manual ClusterIP | PATCH to prior release | DELETE | Helm release |
| ConfigMap | CREATE | PATCH | PATCH to prior data | DELETE | Helm release |
| chart-managed Secret (`create=true`) | CREATE, fails on ownership conflict | PATCH | PATCH to prior Helm value | DELETE | Helm release |
| external `existingSecret` | UNTOUCHED | UNTOUCHED | UNTOUCHED; credentials are not rolled back | UNTOUCHED | external controller/operator |
| ServiceMonitor | CREATE | PATCH | PATCH | DELETE | Helm release |
| external CA Secret | UNTOUCHED | UNTOUCHED | UNTOUCHED | UNTOUCHED | external controller/operator |
| PVC | not created | not applicable | not applicable | not applicable | none |
| Hook Job | none | none | none | none | none |

Removing a poller from values deletes only that poller's Helm-owned Deployment;
its external credential Secret remains. A rollback restores the prior chart
configuration but **cannot** roll back an externally managed password or CA.
Uninstall performs no ONTAP or external-system cleanup.

### Selector and naming migration from chart 0.1.0

Chart 0.2.0 removes `nameOverride` from immutable selectors. For releases that
used the default `nameOverride: ""` (or explicitly used `harvest`), the selector
values remain `app.kubernetes.io/name=harvest` and are backward-compatible.

An existing 0.1.0 release with a different `nameOverride` has a different
immutable Deployment selector. Kubernetes will reject an in-place patch. There
is no safe template trick or hook for this. Schedule a maintenance window,
render and back up the release manifests, explicitly remove only the affected
Harvest Deployment(s), and immediately run the reviewed 0.2.0 upgrade with
`--atomic --wait`. This recreates poller Deployments and causes a scrape gap;
Services, external credential Secrets, and the CA Secret remain untouched.

The collision fix also changes any old Deployment name that was previously
truncated beyond 63 characters. Treat that case as the same controlled
recreation migration to avoid briefly running old and new pollers together.
Changing `nameOverride` or `fullnameOverride` during routine upgrades remains a
resource-identity migration and is not supported as an ordinary patch.

## Hooks audit

The chart uses no Helm hooks. Runtime resources are ordinary Helm-managed
objects and rely on Kubernetes dependency/readiness behavior. There are no
validation, restart, migration, or cleanup Jobs. Consequently there is no hook
weight, delete policy, failure path, or hook-side rollback behavior to audit.

Audit command:

```sh
rg -n 'helm\.sh/hook' harvest/templates
```

Expected result: no matches.

## Destructive-operations audit

Templates contain no shell control plane, Kubernetes client, Helm client,
delete/patch/replace API call, cleanup Job, pre/post-delete action, PVC deletion,
Secret recreation logic, or ONTAP mutation. The only shell fragment is the
read-only credential adapter that prints the pod's `HARVEST_PASSWORD` for the
documented Harvest credential interface.

```sh
rg -n 'kubectl (delete|patch|replace)|helm uninstall|rm -rf|pre-delete|post-delete|helm\.sh/hook' harvest
```

Expected result: matches only explanatory README text, never a template.

## Validation

Run all three render checks before release:

```sh
helm lint --strict ./harvest
helm lint --strict ./harvest -f ./harvest/tests/values-lint.yaml
helm template harvest ./harvest \
  -f ./harvest/tests/values-lint.yaml > /tmp/harvest-test.yaml
helm template harvest ./harvest \
  -f ./harvest/examples/values-ontap.yaml > /tmp/harvest-ontap.yaml
HELM_BIN=helm ./harvest/tests/regression.sh
```

For lifecycle review, render two value revisions and compare them. An unchanged
render must be byte-identical; a changed generated config must alter the
ConfigMap and `checksum/config`, while external Secret and CA objects remain
absent from both outputs.

### Recorded verification

Verified on 2026-10-01 with Helm `v3.19.0`:

| Check | Result |
|---|---|
| `helm lint --strict` with default, test, and example values | PASS — 1 chart, 0 failures (default lint logs the intentional `configure-me` render blocker as informational) |
| unmodified default render | expected FAIL — reserved `configure-me` blocker |
| final `pollers: {}` | expected FAIL — `minProperties: 1` |
| example `helm template` | PASS — 2 Deployments, ConfigMap, Service, ServiceMonitor |
| chart-managed Secret render | PASS — 2 ordinary Secrets, no hook annotations |
| schema negative test (`service.port=70000`) | PASS — rejected above port 65535 |
| H-01 short/63-char/shared-prefix/long-release names | PASS — all unique and ≤63 |
| H-02 selectors after image/chart/podLabels/restartToken/nameOverride changes | PASS — byte-identical |
| H-03 numeric-looking Secret names and keys | PASS — parsed as strings |
| collectors `Zapi`, `Rest`, `Zappi` | PASS, PASS, expected FAIL |
| reserved annotation/selector-label override | expected FAIL with explicit error |
| malformed `tolerations` and image digest | expected FAIL |
| v1 → v2 config change | only ConfigMap data and both `checksum/config` annotations changed |
| image-only change | only two Deployment image fields changed |
| restartToken-only change | only two PodTemplate annotations changed |
| unchanged values | byte-identical render |
| hooks audit over `templates/` | no matches |
| destructive-pattern audit over `templates/` | no matches |

The test script retains its render/diff artifacts in a temporary directory and
prints that path, making every assertion independently inspectable.
