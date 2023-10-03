{{/*
Expand the name of the chart.
*/}}
{{- define "aachart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "aachart.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "aachart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "aachart.labels" -}}
helm.sh/chart: {{ include "aachart.chart" . }}
{{ include "aachart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
{{- define "aachart.labels.ifz" -}}
helm.sh/chart: {{ include "aachart.chart" . }}
{{ include "aachart.selectorLabels.ifz" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
{{- define "aachart.labels.proc" -}}
helm.sh/chart: {{ include "aachart.chart" . }}
{{ include "aachart.selectorLabels.proc" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}


{{/*
Selector labels
*/}}
{{- define "aachart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aachart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "aachart.selectorLabels.ifz" -}}
app.kubernetes.io/name: {{ include "aachart.name" . }}-ifz
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "aachart.selectorLabels.proc" -}}
app.kubernetes.io/name: {{ include "aachart.name" . }}-proc
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "aachart.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "aachart.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Merge Values.global with Values overwriting existing values with global values
*/}}
{{- define "aachart.entorno" -}}
  {{ if .Values.global }}
      {{- mergeOverwrite .Values .Values.global | toJson -}}
  {{ end }}
{{- end -}}
