{{/* Resource name: the release name, e.g. "app". */}}
{{- define "app.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Selector labels: must never change after install (Deployment selectors are immutable). */}}
{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "app.labels" -}}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
Image reference: registry/repository:tag@digest. The tag is for humans; the digest decides
which bytes run. values.schema.json already rejects a missing digest or "latest".
*/}}
{{- define "app.image" -}}
{{- with .Values.image -}}
{{- printf "%s/%s:%s@%s" .registry .repository .tag .digest -}}
{{- end -}}
{{- end -}}
