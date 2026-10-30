#!/usr/bin/env bash
# T69's CloudFront: a KeyValueStore, the CAT gate function and one distribution in front of one
# origin, built for the test and deleted after it (lab/test-69-segmented-access-and-scrambling.md).
#
#   t69-cloudfront.sh kvs                 # creates the KeyValueStore and writes the signing key
#   t69-cloudfront.sh function            # creates the function, associated with the store
#   t69-cloudfront.sh test                # test-function on DEVELOPMENT: seven cases, no deploy
#   t69-cloudfront.sh publish
#   t69-cloudfront.sh dist ORIGIN_DNS     # creates the distribution (the function's LIVE stage)
#   t69-cloudfront.sh wait | status
#   t69-cloudfront.sh down                # disables and deletes the distribution, function, store
#
# Secrets and state stay outside the repository in $P69_HOME (default ~/p69-local): origin-secret,
# sign.key (the HS256 key, hex) and cf.env. A secret never reaches a command line: each call that
# carries one reads it from a 0600 JSON file. Cache settings are the legacy kind: TTLs 0/1/60 s
# honour the origin's Cache-Control. The function runs on every viewer request, cached or not.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
P69_HOME=${P69_HOME:-$HOME/p69-local}
PORT=${PORT:-18310}
KVS_NAME=${KVS_NAME:-p69-cat}
FN_NAME=${FN_NAME:-p69-cat-gate}
KID=t69k1
STATE=$P69_HOME/cf.env
mkdir -p "$P69_HOME"
chmod 700 "$P69_HOME"
umask 077
[ -s "$P69_HOME/origin-secret" ] || openssl rand -hex 32 >"$P69_HOME/origin-secret"
[ -s "$P69_HOME/sign.key" ] || openssl rand -hex 32 >"$P69_HOME/sign.key"
touch "$STATE"
# shellcheck disable=SC1090
. "$STATE"

save() { # NAME VALUE
	grep -v "^$1=" "$STATE" >"$STATE.tmp" || true
	echo "$1=$2" >>"$STATE.tmp"
	mv "$STATE.tmp" "$STATE"
}

kvs_etag() { aws cloudfront-keyvaluestore describe-key-value-store --kvs-arn "$KVS_ARN" --query ETag --output text; }

kvs_put() { # KEY VALUE, or KEY @FILE: the CLI reads the value from a 0600 file, never from argv
	local f
	f=$(mktemp "$P69_HOME/put.XXXXXX")
	python3 - "$f" "$KVS_ARN" "$1" "$2" "$(kvs_etag)" <<-'PY'
		import json, sys
		f, arn, k, v, etag = sys.argv[1:]
		if v.startswith("@"):
		    v = open(v[1:]).read().strip()
		json.dump({"KvsARN": arn, "Key": k, "Value": v, "IfMatch": etag}, open(f, "w"))
	PY
	aws cloudfront-keyvaluestore put-key --cli-input-json "file://$f" --query ETag --output text >/dev/null
	rm -f "$f"
}

cmd_kvs() {
	if [ -z "${KVS_ARN:-}" ]; then
		KVS_ARN=$(aws cloudfront create-key-value-store --name "$KVS_NAME" --comment "T69 CAT keys (temporary)" \
			--query KeyValueStore.ARN --output text)
		save KVS_ARN "$KVS_ARN"
	fi
	for _ in $(seq 1 60); do
		[ "$(aws cloudfront describe-key-value-store --name "$KVS_NAME" --query KeyValueStore.Status --output text)" = READY ] && break
		sleep 5
	done
	kvs_put "k:$KID" "@$P69_HOME/sign.key"
	echo "kvs $KVS_NAME ready; key k:$KID written"
}

cmd_function() {
	local cfg
	cfg="{\"Comment\":\"T69 CAT gate (temporary)\",\"Runtime\":\"cloudfront-js-2.0\",\"KeyValueStoreAssociations\":{\"Quantity\":1,\"Items\":[{\"KeyValueStoreARN\":\"$KVS_ARN\"}]}}"
	if aws cloudfront describe-function --name "$FN_NAME" >/dev/null 2>&1; then
		local etag
		etag=$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)
		aws cloudfront update-function --name "$FN_NAME" --if-match "$etag" --function-config "$cfg" \
			--function-code "fileb://$HERE/t69-cat-gate.js" --query ETag --output text >/dev/null
		echo "function $FN_NAME updated"
	else
		aws cloudfront create-function --name "$FN_NAME" --function-config "$cfg" \
			--function-code "fileb://$HERE/t69-cat-gate.js" --query ETag --output text >/dev/null
		echo "function $FN_NAME created"
	fi
}

cmd_test() { # seven cases against the DEVELOPMENT stage; prints the outcome only, never the token
	local etag d
	etag=$(aws cloudfront describe-function --name "$FN_NAME" --stage DEVELOPMENT --query ETag --output text)
	d=$(mktemp -d "$P69_HOME/test.XXXXXX")
	local cat=(python3 "$HERE/t69-cat.py" mint --key-file "$P69_HOME/sign.key")
	"${cat[@]}" --out "$d/valid" 2>/dev/null
	"${cat[@]}" --flip-mac --out "$d/mac" 2>/dev/null
	"${cat[@]}" --exp "$(($(date +%s) - 10))" --out "$d/expired" 2>/dev/null
	"${cat[@]}" --catu-prefix /x/ --out "$d/uri" 2>/dev/null
	"${cat[@]}" --iss other --out "$d/iss" 2>/dev/null
	local rcti
	rcti=$(openssl rand -hex 8)
	"${cat[@]}" --cti "$rcti" --out "$d/revoked" 2>/dev/null
	kvs_put "rev:$rcti" 1
	sleep 2
	for c in valid missing mac expired uri iss revoked; do
		python3 - "$d" "$c" <<-'PY'
			import json, sys
			d, c = sys.argv[1:]
			h = {} if c == "missing" else {"cta-common-access-token": {"value": open(f"{d}/{c}").read().strip()}}
			ev = {"version": "1.0", "context": {"eventType": "viewer-request"}, "viewer": {"ip": "192.0.2.1"},
			      "request": {"method": "GET", "uri": "/e/index.m3u8", "querystring": {}, "headers": h, "cookies": {}}}
			json.dump(ev, open(f"{d}/ev-{c}.json", "w"))
		PY
		aws cloudfront test-function --name "$FN_NAME" --if-match "$etag" --stage DEVELOPMENT \
			--event-object "fileb://$d/ev-$c.json" --output json >"$d/out-$c.json"
		python3 - "$d/out-$c.json" "$c" <<-'PY'
			import json, sys
			r = json.load(open(sys.argv[1]))["TestResult"]
			err = r.get("FunctionErrorMessage")
			out = json.loads(r["FunctionOutput"]) if r.get("FunctionOutput") else {}
			resp = out.get("response") or {}
			if err:
			    got = "error: " + err
			elif resp.get("statusCode"):
			    got = f"{resp['statusCode']} {resp.get('statusDescription', '')}"
			else:
			    got = "passed to origin"
			print(f"  {sys.argv[2]:8} -> {got} (utilization {r.get('ComputeUtilization')})")
		PY
	done
	rm -rf "$d"
}

cmd_publish() {
	local etag
	etag=$(aws cloudfront describe-function --name "$FN_NAME" --stage DEVELOPMENT --query ETag --output text)
	aws cloudfront publish-function --name "$FN_NAME" --if-match "$etag" --query FunctionSummary.FunctionMetadata.Stage --output text
	save FN_ARN "$(aws cloudfront describe-function --name "$FN_NAME" --stage LIVE --query FunctionSummary.FunctionMetadata.FunctionARN --output text)"
}

cmd_dist() { # ORIGIN_DNS
	local dns=${1:?origin dns} f
	f=$(mktemp "$P69_HOME/dist.XXXXXX")
	python3 - "$f" "$dns" "$PORT" "$FN_ARN" "$P69_HOME/origin-secret" <<-'PY'
		import json, sys, time
		f, dns, port, fn, secret_file = sys.argv[1:]
		secret = open(secret_file).read().strip()
		beh = {"TargetOriginId": "origin", "ViewerProtocolPolicy": "https-only", "Compress": False,
		       "AllowedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"],
		                          "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
		       "ForwardedValues": {"QueryString": False, "Cookies": {"Forward": "none"}, "Headers": {"Quantity": 0}},
		       "MinTTL": 0, "DefaultTTL": 1, "MaxTTL": 60,
		       "FunctionAssociations": {"Quantity": 1, "Items": [{"FunctionARN": fn, "EventType": "viewer-request"}]}}
		origin = {"Id": "origin", "DomainName": dns,
		          "CustomOriginConfig": {"HTTPPort": int(port), "HTTPSPort": 443, "OriginProtocolPolicy": "http-only",
		                                 "OriginReadTimeout": 10, "OriginKeepaliveTimeout": 5,
		                                 "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}},
		          "ConnectionAttempts": 2, "ConnectionTimeout": 2,
		          "CustomHeaders": {"Quantity": 1, "Items": [{"HeaderName": "X-P69-Origin", "HeaderValue": secret}]}}
		cfg = {"CallerReference": f"t69-{int(time.time())}", "Comment": "T69 CAT gate (temporary)", "Enabled": True,
		       "PriceClass": "PriceClass_100", "HttpVersion": "http2", "IsIPV6Enabled": False,
		       "Origins": {"Quantity": 1, "Items": [origin]}, "DefaultCacheBehavior": beh,
		       "CustomErrorResponses": {"Quantity": 2, "Items": [
		           {"ErrorCode": 404, "ErrorCachingMinTTL": 1}, {"ErrorCode": 502, "ErrorCachingMinTTL": 0}]}}
		json.dump({"DistributionConfig": cfg}, open(f, "w"))
	PY
	local out
	out=$(aws cloudfront create-distribution --cli-input-json "file://$f" --query 'Distribution.[Id,DomainName]' --output text)
	rm -f "$f"
	save CF_ID "$(echo "$out" | cut -f1)"
	save CF_DOMAIN "$(echo "$out" | cut -f2)"
	echo "distribution created; state in $STATE"
}

cmd_wait() { aws cloudfront wait distribution-deployed --id "$CF_ID" && echo deployed; }
cmd_status() {
	[ -n "${CF_ID:-}" ] && aws cloudfront get-distribution --id "$CF_ID" --query 'Distribution.[Status,DistributionConfig.Enabled]' --output text
	aws cloudfront describe-function --name "$FN_NAME" --query 'FunctionSummary.FunctionMetadata.Stage' --output text 2>/dev/null || echo "no function"
	aws cloudfront describe-key-value-store --name "$KVS_NAME" --query 'KeyValueStore.Status' --output text 2>/dev/null || echo "no kvs"
}

cmd_down() {
	if [ -n "${CF_ID:-}" ]; then
		local f etag
		f=$(mktemp "$P69_HOME/down.XXXXXX")
		aws cloudfront get-distribution-config --id "$CF_ID" --output json >"$f"
		etag=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ETag"])' "$f")
		python3 - "$f" <<-'PY'
			import json, sys
			d = json.load(open(sys.argv[1]))["DistributionConfig"]
			d["Enabled"] = False
			json.dump(d, open(sys.argv[1], "w"))
		PY
		aws cloudfront update-distribution --id "$CF_ID" --if-match "$etag" --distribution-config "file://$f" \
			--query Distribution.Status --output text
		rm -f "$f"
		aws cloudfront wait distribution-deployed --id "$CF_ID"
		etag=$(aws cloudfront get-distribution --id "$CF_ID" --query ETag --output text)
		aws cloudfront delete-distribution --id "$CF_ID" --if-match "$etag"
		echo "distribution $CF_ID deleted"
		save CF_ID ""
	fi
	if aws cloudfront describe-function --name "$FN_NAME" >/dev/null 2>&1; then
		aws cloudfront delete-function --name "$FN_NAME" \
			--if-match "$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)"
		echo "function $FN_NAME deleted"
	fi
	if aws cloudfront describe-key-value-store --name "$KVS_NAME" >/dev/null 2>&1; then
		aws cloudfront delete-key-value-store --name "$KVS_NAME" \
			--if-match "$(aws cloudfront describe-key-value-store --name "$KVS_NAME" --query ETag --output text)"
		echo "kvs $KVS_NAME deleted"
		save KVS_ARN ""
	fi
}

case "${1:-}" in
kvs) cmd_kvs ;;
function) cmd_function ;;
test) cmd_test ;;
publish) cmd_publish ;;
dist) cmd_dist "${2:-}" ;;
wait) cmd_wait ;;
status) cmd_status ;;
down) cmd_down ;;
*)
	sed -n '2,16p' "$0"
	exit 1
	;;
esac
