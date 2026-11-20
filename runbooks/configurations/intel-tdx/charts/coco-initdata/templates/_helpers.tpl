{{- define "coco-initdata.vaultPrefix" -}}
{{- if eq (toString .Values.vaultTenantScoped) "true" -}}
{{- $g := .Values.global | default dict -}}
{{- $d := $g.clusterDomain | default "" -}}
{{- $label := splitList "." $d | first -}}
{{- if not $label -}}
{{- fail "coco-initdata: vaultTenantScoped=true but global.clusterDomain is empty; cannot derive the tenant vault prefix" -}}
{{- end -}}
{{- printf "secret/data/%s" $label -}}
{{- else -}}
{{- print "secret/data/hub" -}}
{{- end -}}
{{- end -}}
