#!/usr/bin/env bash
# Install the segmented lane as systemd units: the design T59–T63 measured, as services rather than
# detached rig processes. Run as root on the host it configures. It installs and reloads; it never
# enables or starts a unit, so it is safe beside running work. Start with the command it prints.
#
#   seg-units.sh origin [--secret-file F] [--port 18320] [--group 239.255.0.1:5000] [--seg-args '--pdt']
#                [--rate 6m] [--conns 4]
#   seg-units.sh token ID [--days 7] [--host HOST]     a receiver's playlist URL
#   seg-units.sh receiver a|b --url URL [--header-file F] [--dest HOST:PORT] [--pacer BIN]
#                [--release-ms N] [--align-ms N] [--netns NAME]
#   seg-units.sh merge --dest HOST:PORT        for an IRD without ST 2022-7 input
#   seg-units.sh uninstall | status
#
# Origin: seg-packager (t61-epochseg.py reading the live feed's local multicast group, which
# srt-ingest.service writes), seg-guard (t61-guard.py, which withdraws a stale playlist so a CDN's
# origin group fails over on the 404) and seg-origin (nginx). nginx answers a receiver only under a
# path token, /t/ID/EXPIRY/SIG/g/..., SIG being the MD5 of "EXPIRY ID" and the host's token secret
# (created once, kept across re-installs; replace it to revoke every token), and a CDN only on the
# origin secret it adds (--secret-file; without it, only tokens). Every client address is held to
# --conns connections and each connection to --rate bytes a second. Each unit restarts on its own;
# the guard deliberately does not depend on the packager. Receiver: seg-recv@a and seg-recv@b, one
# leg each (seg-recv-leg.sh). Their RTP is an ST 2022-7 pair an IRD can merge; seg-merge does it in
# software for one that cannot.
#
# DESTDIR=DIR writes every file under DIR, as root or not, and reloads nothing: for inspecting the
# units, or `systemd-analyze verify DIR/etc/systemd/system/seg-*.service` on a host.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
D=${DESTDIR:-}
OPT=/opt/seg
ETC=/etc/seg
VAR=/var/lib/seg
UNITS=/etc/systemd/system
USR=${SEG_USER:-ubuntu}

die() { echo "seg-units: $*" >&2; exit 2; }
need_root() { [ -n "$D" ] || [ "$(id -u)" = 0 ] || die "run as root"; }
reload() { [ -n "$D" ] || systemctl daemon-reload; }
own() { [ -n "$D" ] || chown "$@"; }
copy() { mkdir -p "$D$OPT" && install -m 0755 "$@" "$D$OPT/"; }
secret() { mkdir -p "$D$ETC" && (umask 077 && cat >"$D$ETC/$1"); }
unit() { mkdir -p "$D$UNITS" && cat >"$D$UNITS/$1"; }

origin() {
	local port=18320 group=239.255.0.1:5000 seg_args=--pdt secret_file="" rate=6m conns=4 gate tok
	while [ $# -gt 0 ]; do
		case $1 in
		--port) port=$2; shift 2 ;;
		--group) group=$2; shift 2 ;;
		--seg-args) seg_args=$2; shift 2 ;;
		--secret-file) secret_file=$2; shift 2 ;;
		--rate) rate=$2; shift 2 ;;
		--conns) conns=$2; shift 2 ;;
		*) die "origin: unknown option $1" ;;
		esac
	done
	gate="return 403;"
	if [ -n "$secret_file" ]; then
		[ -s "$secret_file" ] || die "origin: $secret_file is empty"
		gate="if (\$http_x_p59_origin != \"$(cat "$secret_file")\") { return 403; }"
	fi
	[ -s "$D$ETC/token.secret" ] || openssl rand -hex 24 | secret token.secret
	chmod 0640 "$D$ETC/token.secret"
	own "root:$USR" "$D$ETC/token.secret"
	tok=$(cat "$D$ETC/token.secret")
	[[ $tok =~ ^[0-9a-f]{32,}$ ]] || die "origin: $ETC/token.secret is not hex"
	copy "$HERE/t61-epochseg.py" "$HERE/t61-guard.py"
	mkdir -p "$D$VAR/www/g" "$D$VAR/ngx/tmp"
	own -R "$USR" "$D$VAR"
	secret origin.env <<EOF
SEG_WWW=$VAR/www
SEG_GROUP=$group
SEG_ARGS=$seg_args
SEG_STALE=4
EOF
	# The secrets are written into the configuration: nginx cannot read them from a file at request
	# time. A token's playlist names its segments relatively, so they resolve under the same token.
	secret nginx.conf <<EOF
worker_processes 2;
pid $VAR/ngx/ngx.pid;
error_log $VAR/ngx/error.log warn;
events { worker_connections 1024; }
http {
	types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
	log_format seg '\$msec \$status \$request_uri \$body_bytes_sent \$request_time \$remote_addr';
	access_log $VAR/ngx/access.log seg;
	client_body_temp_path tmp; proxy_temp_path tmp; fastcgi_temp_path tmp; uwsgi_temp_path tmp; scgi_temp_path tmp;
	sendfile on;
	keepalive_timeout 60;
	server_tokens off;
	map \$uri \$seg_cache { ~\.m3u8\$ "max-age=1"; ~\.ts\$ "max-age=60"; }
	limit_conn_zone \$binary_remote_addr zone=seg_conn:1m;
	limit_req_zone \$binary_remote_addr zone=seg_req:1m rate=20r/s;
	limit_conn_status 429;
	limit_req_status 429;
	server {
		listen $port;
		root $VAR/www;
		limit_conn seg_conn $conns;
		limit_req zone=seg_req burst=40 nodelay;
		limit_rate $rate;
		add_header Cache-Control \$seg_cache;
		location /t/ {
			location ~ "^/t/(?<rid>[A-Za-z0-9_-]{1,32})/(?<exp>[0-9]{10})/(?<sig>[A-Za-z0-9_-]{22})(?<rest>/g/[A-Za-z0-9_-]+\.(m3u8|ts))\$" {
				secure_link \$sig,\$exp;
				secure_link_md5 "\$exp \$rid $tok";
				if (\$secure_link = "") { return 403; }
				if (\$secure_link = "0") { return 410; }
				rewrite ^ \$rest break;
			}
			return 403;
		}
		location / {
			$gate
		}
	}
}
EOF
	chmod 0640 "$D$ETC/nginx.conf"
	own "root:$USR" "$D$ETC/nginx.conf"
	unit seg-packager.service <<EOF
[Unit]
Description=Segmented lane: epoch-locked packager (local multicast -> TS segments)
After=network-online.target srt-ingest.service
Wants=network-online.target

[Service]
User=$USR
EnvironmentFile=$ETC/origin.env
Nice=10
ExecStart=/usr/bin/python3 $OPT/t61-epochseg.py \${SEG_WWW}/g --group \${SEG_GROUP} \$SEG_ARGS
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
	unit seg-guard.service <<EOF
[Unit]
Description=Segmented lane: staleness guard (withdraws a playlist that stops advancing)
After=network-online.target

[Service]
User=$USR
EnvironmentFile=$ETC/origin.env
Nice=5
ExecStart=/usr/bin/python3 $OPT/t61-guard.py \${SEG_WWW}/g/index.m3u8 --stale \${SEG_STALE}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
	unit seg-origin.service <<EOF
[Unit]
Description=Segmented lane: origin (nginx, gated by path tokens and the CDN's origin header)
After=network-online.target
Wants=network-online.target

[Service]
User=$USR
Nice=10
ExecStart=/usr/sbin/nginx -p $VAR/ngx -c $ETC/nginx.conf -e $VAR/ngx/error.log -g 'daemon off;'
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
	mkdir -p "$D/etc/logrotate.d"
	cat >"$D/etc/logrotate.d/seg" <<EOF
$VAR/ngx/*.log {
	daily
	rotate 7
	compress
	missingok
	notifempty
	copytruncate
}
EOF
	reload
	echo "origin installed on port $port; start with: systemctl enable --now seg-packager seg-guard seg-origin"
}

token() {
	local rid=${1:-} days=7 host="<host>" port=18320 s exp sig
	[[ $rid =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "token: an ID of 1 to 32 letters, digits, - or _"
	shift
	while [ $# -gt 0 ]; do
		case $1 in
		--days) days=$2; shift 2 ;;
		--host) host=$2; shift 2 ;;
		--port) port=$2; shift 2 ;;
		*) die "token: unknown option $1" ;;
		esac
	done
	s=$(cat "$D$ETC/token.secret") || die "token: cannot read $ETC/token.secret"
	exp=$(($(date +%s) + days * 86400))
	sig=$(printf '%s %s %s' "$exp" "$rid" "$s" | openssl md5 -binary | openssl base64 | tr '+/' '-_' | tr -d '=')
	echo "http://$host:$port/t/$rid/$exp/$sig/g/index.m3u8"
}

receiver() {
	local leg=${1:-} url="" header_file="" dest="" pacer="" release="" align="" netns=""
	case $leg in a | b) shift ;; *) die "receiver: leg a or b" ;; esac
	while [ $# -gt 0 ]; do
		case $1 in
		--url) url=$2; shift 2 ;;
		--header-file) header_file=$2; shift 2 ;;
		--dest) dest=$2; shift 2 ;;
		--pacer) pacer=$2; shift 2 ;;
		--release-ms) release=$2; shift 2 ;;
		--align-ms) align=$2; shift 2 ;;
		--netns) netns=$2; shift 2 ;;
		*) die "receiver: unknown option $1" ;;
		esac
	done
	[ -n "$url" ] || die "receiver: --url is required"
	copy "$HERE/b8-hls-recv.py" "$HERE/seg-recv-leg.sh"
	[ -z "$pacer" ] || install -m 0755 "$pacer" "$D$OPT/mpegts-pacer"
	[ -x "$D$OPT/mpegts-pacer" ] || die "receiver: no $OPT/mpegts-pacer; pass --pacer"
	[ -n "$dest" ] || dest=127.0.0.1:$([ "$leg" = a ] && echo 5100 || echo 5200)
	{
		echo "SEG_URL=$url"
		[ -z "$header_file" ] || echo "SEG_HEADER=$(cat "$header_file")"
		echo "SEG_DEST=$dest"
		[ -z "$release" ] || echo "SEG_RELEASE_MS=$release"
		[ -z "$align" ] || echo "SEG_ALIGN_MS=$align"
	} | secret "recv-$leg.env"
	unit seg-recv@.service <<EOF
[Unit]
Description=Segmented lane: receiver leg %i (HLS fetch -> stream-clocked RTP)
After=network-online.target
Wants=network-online.target

[Service]
User=$USR
EnvironmentFile=$ETC/recv-%i.env
ExecStart=$OPT/seg-recv-leg.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
	# A leg in its own network namespace (a second interface or route): systemd joins it, so the leg
	# needs no root. /etc/netns/NAME/ files, T59's PoP pin among them, apply only under `ip netns exec`.
	rm -rf "$D$UNITS/seg-recv@$leg.service.d"
	if [ -n "$netns" ]; then
		[ -n "$D" ] || [ -e "/run/netns/$netns" ] || die "receiver: no network namespace $netns"
		mkdir -p "$D$UNITS/seg-recv@$leg.service.d"
		printf '[Service]\nNetworkNamespacePath=/run/netns/%s\n' "$netns" >"$D$UNITS/seg-recv@$leg.service.d/netns.conf"
	fi
	reload
	echo "leg $leg installed to $dest; start with: systemctl enable --now seg-recv@$leg"
}

merge() {
	[ "${1:-}" = --dest ] && [ -n "${2:-}" ] || die "merge: --dest HOST:PORT"
	copy "$HERE/p1aj-merge.py"
	unit seg-merge.service <<EOF
[Unit]
Description=Segmented lane: ST 2022-7 merge of legs a and b, for an IRD without 2022-7 input
After=network-online.target

[Service]
User=$USR
ExecStart=/bin/sh -c 'python3 $OPT/p1aj-merge.py --ports 5100 5200 | tsp -I file - -O ip $2'
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
	reload
	echo "merge installed to $2; start with: systemctl enable --now seg-merge"
}

uninstall() {
	local u
	for u in seg-packager seg-guard seg-origin seg-merge seg-recv@a seg-recv@b; do
		systemctl disable --now "$u" 2>/dev/null || true
	done
	rm -rf "$UNITS"/seg-packager.service "$UNITS"/seg-guard.service "$UNITS"/seg-origin.service \
		"$UNITS"/seg-merge.service "$UNITS"/seg-recv@.service "$UNITS"/seg-recv@?.service.d /etc/logrotate.d/seg
	systemctl daemon-reload
	echo "units removed; $OPT, $ETC and $VAR left in place"
}

case ${1:-} in
origin) need_root; shift; origin "$@" ;;
token) shift; token "$@" ;;
receiver) need_root; shift; receiver "$@" ;;
merge) need_root; shift; merge "$@" ;;
uninstall) [ -z "$D" ] || die "uninstall acts on the host, not DESTDIR"; need_root; uninstall ;;
status) systemctl --no-pager list-units 'seg-*' --all ;;
*) sed -n '6,13p' "$0" >&2; exit 2 ;;
esac
