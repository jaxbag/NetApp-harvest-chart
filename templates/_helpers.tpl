{{/* Chart name. */}}
{{- define "harvest.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Complete release-scoped identity before Kubernetes-length truncation. */}}
{{- define "harvest.fullnameRaw" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name }}
{{- end }}
{{- end }}
{{- end }}

{{/* Release-scoped Kubernetes resource name. */}}
{{- define "harvest.fullname" -}}
{{- include "harvest.fullnameRaw" . | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* A stable, DNS-safe name for one poller Deployment. */}}
{{- define "harvest.pollerFullname" -}}
{{- $base := include "harvest.fullnameRaw" .root -}}
{{- $logical := printf "%s-%s" $base .poller -}}
{{- if le (len $logical) 63 -}}
{{- $logical -}}
{{- else -}}
{{- $hash := sha256sum $logical | trunc 12 -}}
{{- $prefix := $logical | trunc 50 | trimSuffix "-" -}}
{{- printf "%s-%s" $prefix $hash -}}
{{- end -}}
{{- end }}

{{- define "harvest.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Immutable selector labels. Chart.Name and Release.Name are stable identities;
nameOverride/fullnameOverride, app version, chart version, and image are absent.
*/}}
{{- define "harvest.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end }}

{{- define "harvest.commonLabels" -}}
helm.sh/chart: {{ include "harvest.chart" . | quote }}
{{ include "harvest.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end }}

{{/* Fail rather than emit duplicate or overridden chart-owned pod metadata. */}}
{{- define "harvest.validateUserMetadata" -}}
{{- $reservedLabels := list "app.kubernetes.io/name" "app.kubernetes.io/instance" "app.kubernetes.io/component" "harvest.netapp.io/poller" -}}
{{- range $key, $_ := .Values.podLabels -}}
{{- if has $key $reservedLabels -}}
{{- fail (printf "podLabels key %q is reserved by the chart" $key) -}}
{{- end -}}
{{- end -}}
{{- $reservedAnnotations := list "checksum/config" "checksum/secret" "harvest.netapp.io/restart-token" -}}
{{- range $key, $_ := .Values.podAnnotations -}}
{{- if has $key $reservedAnnotations -}}
{{- fail (printf "podAnnotations key %q is reserved by the chart" $key) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "harvest.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end }}

{{/* The schema-valid documentation poller must never reach an installation. */}}
{{- define "harvest.validateValues" -}}
{{- if hasKey .Values.pollers "configure-me" -}}
{{- fail "replace the reserved pollers.configure-me example with at least one real poller (see examples/values-ontap.yaml)" -}}
{{- end -}}
{{- end }}

{{/* The checksum uses this data-only helper, so chart metadata changes do not restart pods. */}}
{{- define "harvest.configData" -}}
harvest.yml: |
  Tools:
    autosupport_disabled: {{ .Values.harvest.autosupportDisabled }}
  Exporters:
    prometheus:
      exporter: Prometheus
      local_http_addr: 0.0.0.0
      port: {{ .Values.service.port }}
      add_meta_tags: {{ .Values.harvest.exporter.addMetaTags }}
      sort_labels: {{ .Values.harvest.exporter.sortLabels }}
      cache_max_keep: {{ .Values.harvest.exporter.cacheMaxKeep | quote }}
  Defaults:
    collectors:
{{ toYaml .Values.harvest.collectors | indent 6 }}
    exporters:
      - prometheus
    use_insecure_tls: {{ not .Values.ontapTLS.verify }}
{{- if .Values.ontapTLS.minVersion }}
    tls_min_version: {{ .Values.ontapTLS.minVersion | quote }}
{{- end }}
{{- if and .Values.ontapTLS.verify .Values.ontapTLS.existingCASecret }}
    ca_cert: /etc/harvest/ca/{{ .Values.ontapTLS.caKey }}
{{- end }}
  Pollers:
{{- range $name, $poller := .Values.pollers }}
    {{ $name | quote }}:
      datacenter: {{ $poller.datacenter | quote }}
      addr: {{ $poller.addr | quote }}
      auth_style: basic_auth
      # The value is expanded by Harvest from this pod's environment. The
      # actual username therefore does not enter the ConfigMap.
      username: $__env{HARVEST_USERNAME}
      credentials_script:
        path: {{ printf "/etc/harvest/scripts/%s" $name | quote }}
        schedule: {{ $.Values.harvest.credentialsScript.schedule | quote }}
        timeout: {{ $.Values.harvest.credentialsScript.timeout | quote }}
      exporters:
        - prometheus
{{- end }}
{{- range $name, $_ := .Values.pollers }}
{{ $name | quote }}: |
  #!/busybox/sh
  # Harvest accepts plaintext stdout as the password for the configured username.
  printf '%s' "${HARVEST_PASSWORD}"
{{- end }}
{{- end }}
