{{- define "harbor.labels" -}}
heritage: {{ .Release.Service }}
release: {{ .Release.Name }}
chart: {{ .Chart.Name }}
app: "harbor"
{{- end -}}

{{- define "harbor.matchLabels" -}}
release: {{ .Release.Name }}
app: "harbor"
{{- end -}}

{{- define "harbor.admin.password" -}}
  {{- .Values.harbor.harborAdminPassword | nospace | b64enc | quote -}}
{{- end -}}

{{- define "harbor.registry.rawPassword" -}}
  {{- .Values.harbor.registryPassword | nospace -}}
{{- end -}}

{{- define "harbor.registry.password" -}}
  {{- include "harbor.registry.rawPassword" . | nospace | b64enc | quote -}}
{{- end -}}

{{- define "harbor.database.rawPassword" -}}
  {{- .Values.harbor.databasePassword | nospace -}}
{{- end -}}

{{- define "harbor.database.escapedRawPassword" -}}
  {{- include "harbor.database.rawPassword" . | urlquery | replace "+" "%20" -}}
{{- end -}}

{{- define "harbor.database.encryptedPassword" -}}
  {{- include "harbor.database.rawPassword" . | b64enc | quote -}}
{{- end -}}

{{- define "harbor.image.sourceType" -}}
  {{- .Values.harbor.mirrorSourceType | default "quay" -}}
{{- end -}}

{{- define "harbor.image.source" -}}
  {{- if eq (include "harbor.image.sourceType" .) "quay" -}}
    {{- if .Values.harbor.enabled -}}
      {{- .Values.harbor.clusterIP -}}/quay/vessl-ai
    {{- else -}}
      quay.io/vessl-ai
    {{- end -}}
  {{- else if eq (include "harbor.image.sourceType" .) "vessl-harbor" -}}
    {{- if .Values.harbor.enabled -}}
      {{- .Values.harbor.clusterIP -}}/harbor/public
    {{- else -}}
      harbor.vessl.ai/public
    {{- end -}}
  {{- else -}}
    {{- fail "Unsupported imageSourceType" -}}
  {{- end -}}
{{- end -}}