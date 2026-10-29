#!/usr/bin/env bash
# T59's CloudFront: one distribution, one origin per pathway, built for the test and deleted after
# it (lab/test-59-segmented-1plus1-cloudfront.md).
#
#   t59-cloudfront.sh up ORIGIN_A_DNS ORIGIN_B_DNS   # creates the function and the distribution
#   t59-cloudfront.sh sync ORIGIN_A_DNS ORIGIN_B_DNS # rewrites a live one to this configuration
#   t59-cloudfront.sh wait | status
#   t59-cloudfront.sh down                           # disables, waits, deletes both
#
# Secrets and state live outside the repository: $P59_HOME/{origin-secret,viewer-key,cf.env}
# (default ~/p59-local). Cache settings are the legacy kind (the campaign's IAM user may create a
# distribution but not list cache policies): TTLs 0/1/60 s honour the origin's Cache-Control, so
# the playlist is cached 1 s and segments 60 s; errors are cached 1 s (404) and 0 s (502, 504).
# /a/* and /b/* reach one pathway each; /g/* reaches the origin group (T61): pathway A, failing
# over to B on 404 or 5xx, a refused connection or a timeout. ATTEMPTS, CONNECT_S and READ_S set
# every origin's connection attempts, connection timeout and response timeout (T59: 2, 2, 10).

set -euo pipefail
P59_HOME=${P59_HOME:-$HOME/p59-local}
PORT=${PORT:-18310}
ATTEMPTS=${ATTEMPTS:-2}
CONNECT_S=${CONNECT_S:-2}
READ_S=${READ_S:-10}
NAME=${FN_NAME:-p59-viewer-gate} # a second distribution beside the first needs its own
mkdir -p "$P59_HOME"
STATE=${CF_STATE:-$P59_HOME/cf.env}

behaviour() { # target-origin [path-pattern]
	local pp=""
	[ -n "${2:-}" ] && pp="\"PathPattern\": \"$2\","
	cat <<EOF
{ $pp "TargetOriginId": "$1", "ViewerProtocolPolicy": "https-only", "Compress": false,
  "AllowedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"],
                      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] } },
  "ForwardedValues": { "QueryString": false, "Cookies": { "Forward": "none" },
                       "Headers": { "Quantity": 0 } },
  "MinTTL": 0, "DefaultTTL": 1, "MaxTTL": 60,
  "FunctionAssociations": { "Quantity": 1, "Items": [
      { "FunctionARN": "$FN_ARN", "EventType": "viewer-request" } ] } }
EOF
}

origin() { # id dns secret
	cat <<EOF
{ "Id": "$1", "DomainName": "$2",
  "CustomOriginConfig": { "HTTPPort": $PORT, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only",
                          "OriginReadTimeout": $READ_S, "OriginKeepaliveTimeout": 5,
                          "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] } },
  "ConnectionAttempts": $ATTEMPTS, "ConnectionTimeout": $CONNECT_S,
  "CustomHeaders": { "Quantity": 1, "Items": [ { "HeaderName": "X-P59-Origin", "HeaderValue": "$3" } ] } }
EOF
}

# /h/, /y/ and /z/ alias /g/ at the origins, so that CloudFront caches the same objects apart
# (T60's follow-up); the origins serve /y/ and /z/ playlists with max-age=0.
config() { # caller-reference origin-a origin-b origin-secret
	cat <<EOF
{ "CallerReference": "$1", "Comment": "T59 two pathways (temporary)", "Enabled": true,
  "PriceClass": "PriceClass_100", "HttpVersion": "http2", "IsIPV6Enabled": false,
  "Origins": { "Quantity": 2, "Items": [ $(origin pathA "$2" "$4"), $(origin pathB "$3" "$4") ] },
  "OriginGroups": { "Quantity": 1, "Items": [ { "Id": "paths",
      "FailoverCriteria": { "StatusCodes": { "Quantity": 5, "Items": [404, 500, 502, 503, 504] } },
      "Members": { "Quantity": 2, "Items": [ { "OriginId": "pathA" }, { "OriginId": "pathB" } ] } } ] },
  "DefaultCacheBehavior": $(behaviour pathA),
  "CacheBehaviors": { "Quantity": 6, "Items": [ $(behaviour pathA "/a/*"), $(behaviour pathB "/b/*"),
      $(behaviour paths "/g/*"), $(behaviour paths "/h/*"), $(behaviour paths "/y/*"),
      $(behaviour paths "/z/*") ] },
  "CustomErrorResponses": { "Quantity": 3, "Items": [
      { "ErrorCode": 404, "ErrorCachingMinTTL": 1 },
      { "ErrorCode": 502, "ErrorCachingMinTTL": 0 },
      { "ErrorCode": 504, "ErrorCachingMinTTL": 0 } ] },
  "ViewerCertificate": { "CloudFrontDefaultCertificate": true } }
EOF
}

# Rewrite a live distribution to this script's configuration, keeping its domain and function. An
# update takes the whole configuration, defaults included, so this one is laid over the live one.
sync() {
	local a=$1 b=$2 etag ref cur cfg
	. "$STATE"
	FN_ARN=$(aws cloudfront describe-function --name "$FN_NAME" --stage LIVE \
		--query FunctionSummary.FunctionMetadata.FunctionARN --output text)
	cur=$(mktemp)
	cfg=$(mktemp)
	etag=$(aws cloudfront get-distribution-config --id "$CF_ID" --query ETag --output text)
	aws cloudfront get-distribution-config --id "$CF_ID" --query DistributionConfig >"$cur"
	ref=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["CallerReference"])' "$cur")
	config "$ref" "$a" "$b" "$(cat "$P59_HOME/origin-secret")" |
		python3 "$(dirname "$0")/t59-cf-merge.py" "$cur" >"$cfg"
	aws cloudfront update-distribution --id "$CF_ID" --if-match "$etag" --distribution-config "file://$cfg" \
		--query Distribution.Status --output text
	rm -f "$cur" "$cfg"
}

up() {
	local a=$1 b=$2 osec key fn etag cfg out
	[ -f "$P59_HOME/origin-secret" ] || openssl rand -hex 16 >"$P59_HOME/origin-secret"
	[ -f "$P59_HOME/viewer-key" ] || openssl rand -hex 16 >"$P59_HOME/viewer-key"
	osec=$(cat "$P59_HOME/origin-secret")
	key=$(cat "$P59_HOME/viewer-key")
	fn=$(mktemp)
	cat >"$fn" <<EOF
function handler(event) {
	var h = event.request.headers['x-p59-key'];
	if (!h || h.value !== '$key') {
		return { statusCode: 403, statusDescription: 'Forbidden' };
	}
	return event.request;
}
EOF
	etag=$(aws cloudfront create-function --name "$NAME" \
		--function-config '{"Comment":"T59 viewer gate","Runtime":"cloudfront-js-2.0"}' \
		--function-code "fileb://$fn" --query ETag --output text)
	FN_ARN=$(aws cloudfront publish-function --name "$NAME" --if-match "$etag" \
		--query FunctionSummary.FunctionMetadata.FunctionARN --output text)
	rm -f "$fn"
	cfg=$(mktemp)
	config "p59-$(date +%s)" "$a" "$b" "$osec" >"$cfg"
	out=$(aws cloudfront create-distribution --distribution-config "file://$cfg" \
		--query 'Distribution.[Id,DomainName]' --output text)
	rm -f "$cfg"
	read -r id dom <<<"$out"
	printf 'CF_ID=%s\nCF_DOMAIN=%s\nFN_NAME=%s\n' "$id" "$dom" "$NAME" >"$STATE"
	echo "distribution $id https://$dom (deploying)"
}

case "${1:-}" in
up) up "${2:?origin A dns}" "${3:?origin B dns}" ;;
sync) sync "${2:?origin A dns}" "${3:?origin B dns}" ;;
wait)
	. "$STATE"
	aws cloudfront wait distribution-deployed --id "$CF_ID" && echo "deployed $CF_DOMAIN"
	;;
status)
	. "$STATE"
	aws cloudfront get-distribution --id "$CF_ID" --query 'Distribution.[Status,DomainName]' --output text
	;;
down)
	. "$STATE"
	etag=$(aws cloudfront get-distribution-config --id "$CF_ID" --query ETag --output text)
	cfg=$(mktemp)
	aws cloudfront get-distribution-config --id "$CF_ID" --query DistributionConfig |
		python3 -c 'import json,sys; c=json.load(sys.stdin); c["Enabled"]=False; print(json.dumps(c))' >"$cfg"
	aws cloudfront update-distribution --id "$CF_ID" --if-match "$etag" \
		--distribution-config "file://$cfg" --query Distribution.Status --output text
	rm -f "$cfg"
	aws cloudfront wait distribution-deployed --id "$CF_ID"
	etag=$(aws cloudfront get-distribution --id "$CF_ID" --query ETag --output text)
	aws cloudfront delete-distribution --id "$CF_ID" --if-match "$etag" && echo "distribution $CF_ID deleted"
	etag=$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)
	aws cloudfront delete-function --name "$FN_NAME" --if-match "$etag" && echo "function $FN_NAME deleted"
	;;
*)
	echo "usage: t59-cloudfront.sh up A_DNS B_DNS | sync A_DNS B_DNS | wait | status | down" >&2
	exit 2
	;;
esac
