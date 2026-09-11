{{/* What each size means: the platform's opinion, hidden from teams. */}}
{{- define "app.size" -}}
{{- $sizes := dict
  "small"  (dict "replicas" 1 "cpu" "50m"  "memory" "64Mi"  "memoryLimit" "128Mi")
  "medium" (dict "replicas" 2 "cpu" "100m" "memory" "128Mi" "memoryLimit" "256Mi")
  "large"  (dict "replicas" 3 "cpu" "250m" "memory" "256Mi" "memoryLimit" "512Mi")
-}}
{{- get $sizes .Values.size | toJson -}}
{{- end -}}

{{/* Where a public service answers: <app>.<env>.<domain>, or <app>.<domain> in prod. */}}
{{- define "app.host" -}}
{{- if eq .Values.platform.env "prod" -}}
{{ .Release.Name }}.{{ .Values.platform.domain }}
{{- else -}}
{{ .Release.Name }}.{{ .Values.platform.env }}.{{ .Values.platform.domain }}
{{- end -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
back.lab/env: {{ .Values.platform.env }}
{{- end -}}

{{- define "app.selector" -}}
app.kubernetes.io/name: {{ .Release.Name }}
{{- end -}}
