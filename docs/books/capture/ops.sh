#!/bin/sh
# Sessions of guide/ug-ops.typ: the start messages of HTTPD and the answers of
# its console commands.  Run it after a restart of HTTPD (S HTTPD) with the four
# route lines of mvsMF, as the user MVSMF_USER that may use the console services.
#
#   MVSMF_URL=http://localhost:8080 MVSMF_USER=... MVSMF_PASS=... sh capture/ops.sh

. "$(dirname "$0")/lib.sh"

ses ug-ops/o-start.txt 'curl -s -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restconsoles/v1/log?timeRange=10m" | grep -o "HTTPD0\(00\|05\|02\|04\|36\|54\|01\)[IW][^\"]*" | tail -10'

for c in dv dc help; do
	case $c in
	dv) cmd='F HTTPD,D V' ;;
	dc) cmd='F HTTPD,D C' ;;
	help) cmd='F HTTPD,HELP' ;;
	esac
	ses ug-ops/o-$c.txt "curl -s -X PUT -u \"\$MVSMF_USER:\$MVSMF_PASS\" -H 'Content-Type: application/json' -d '{\"cmd\":\"$cmd\"}' \"\$MVSMF_URL/zosmf/restconsoles/consoles/defcn\" | grep -o 'HTTPD1[0-9][0-9][IW][^\\\\\"]*' | grep -v HTTPD100I"
done
