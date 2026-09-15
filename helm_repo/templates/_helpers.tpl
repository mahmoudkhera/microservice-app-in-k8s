
{{/* Release-qualified name, used for chart-scoped objects such as the test pod. */}}
{{- define "stockwatch.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}



{{/* Namespace every resource in this chart lands in. */}}
{{- define "app.namespace" -}}
{{- default .Release.Namespace .Values.namespace.name -}}
{{- end -}}

{{/* Labels shared by every object in the chart. */}}
{{- define "app.labels" -}}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}




{{/*
Pod selector labels, one define per service. A Deployment's selector is
immutable, so nothing that changes between upgrades belongs in here.
*/}}



{{- define "frontend.selectorLabels" -}}
app: {{ .Values.frontend.name }}
app.kubernetes.io/name: {{ .Release.Name}}
tier: frontend
{{- end -}}


{{- define "inventory.selectorLabels" -}}
app: {{ .Values.inventory.name }}
app.kubernetes.io/name: {{ .Values.inventory.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
tier: inventory
{{- end -}}



{{- define "notifications.selectorLabels" -}}
app: {{ .Values.notifications.name }}
app.kubernetes.io/name: {{ .Values.notifications.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
tier: notifications
{{- end -}}




{{/* Image pull policy: the per-service setting wins, else the chart default. */}}
{{- define "stockwatch.pullPolicy" -}}
{{- default .root.Values.image.pullPolicy .svc.image.pullPolicy -}}
{{- end -}}


