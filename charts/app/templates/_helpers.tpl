{{/* What each size means. Teams pick a size; the numbers are the platform's call. */}}
{{- define "app.size" -}}
{{- $sizes := dict
  "small"  (dict "replicas" 1 "cpu" "50m"  "memory" "64Mi"  "memoryLimit" "128Mi")
  "medium" (dict "replicas" 2 "cpu" "100m" "memory" "128Mi" "memoryLimit" "256Mi")
  "large"  (dict "replicas" 3 "cpu" "250m" "memory" "256Mi" "memoryLimit" "512Mi")
-}}
{{- get $sizes .Values.size | toJson -}}
{{- end -}}

{{/* Public address: <name>.<stage>.<domain>, or <name>.<domain> in production. */}}
{{- define "app.host" -}}
{{- if eq .Values.platform.stage "production" -}}
{{ .Values.application.name }}.{{ .Values.platform.domain }}
{{- else -}}
{{ .Values.application.name }}.{{ .Values.platform.stage }}.{{ .Values.platform.domain }}
{{- end -}}
{{- end -}}

{{/* The namespace a service runs in: <name>-<stage>, read from the values so that rendering the chart outside a cluster answers the same as Argo CD applying it. */}}
{{- define "app.namespace" -}}
{{ .Values.application.name }}-{{ .Values.platform.stage }}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ .Values.application.name }}
back.lab/team: {{ .Values.application.team }}
back.lab/stage: {{ .Values.platform.stage }}
{{- end -}}

{{- define "app.selector" -}}
app.kubernetes.io/name: {{ .Values.application.name }}
{{- end -}}

{{/* The Secret a request's connection lands in: <name>-<kind>, or just <kind> when that's the request's name. */}}
{{- define "app.connection" -}}
{{- if eq .name .kind -}}{{ .kind }}{{- else -}}{{ .name }}-{{ .kind }}{{- end -}}
{{- end -}}
