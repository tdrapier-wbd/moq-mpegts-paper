#!/usr/bin/env bash
# Close a standing relay to anonymous sessions. A loopback auth server (`moq auth serve`) verifies
# each session's JWT against the live feed's key; the relay asks it instead of granting "**" to
# anyone; the publisher presents a publish-only token for its own broadcast; and the host's probes
# (live-feed-status.sh, live-feed-monitor.sh) a subscribe-only one. Run as root on the host.
#
#   live-auth.sh install [--bin DIR] [--port 4440]   install, or re-install keeping the key
#   live-auth.sh token [--days 1] [--publish NAME]   a viewer's token on stdout: a credential
#   live-auth.sh uninstall                           back to the relay's open grant
#   live-auth.sh status
#
# The key is ES256, ID "live": /etc/moq/auth/live.jwk (root only) signs, and the auth server reads
# only pub/live.jwk. Install generates it once and keeps it; copying /etc/moq/auth/live.jwk and pub/
# to another host before installing there lets one token admit a viewer to either relay. The relay
# and the publisher change by drop-ins, never in their own units, so uninstall restores them. Neither
# install nor uninstall restarts anything: each prints the restart, which interrupts the live chain.
# Tokens are checked at admission only: a session outlives its token, and revoking every token takes
# a new key on every host.
#
# DESTDIR=DIR writes every file under DIR and reloads nothing, for inspecting what install writes.
set -euo pipefail

D=${DESTDIR:-}
ETC=/etc/moq/auth
UNITS=/etc/systemd/system
USR=${LIVE_USER:-ubuntu}
PROBE=/home/$USR/.moq-live/probe.jwt
ROOT=anon

die() { echo "live-auth: $*" >&2; exit 2; }
need_root() { [ -n "$D" ] || [ "$(id -u)" = 0 ] || die "run as root"; }
reload() { [ -n "$D" ] || systemctl daemon-reload; }
own() { [ -n "$D" ] || chown "$@"; }
exec_start() { grep -m1 '^ExecStart=' "$UNITS/$1" | cut -d= -f2- || true; }
relay_bin() { exec_start moq-relay.service | sed -nE 's#^(/[^ ]+)/moq-relay .*#\1#p'; }
sign() { "$BIN/moq" auth sign --key "$D$ETC/live.jwk" --root "$ROOT" "$@"; }

install_auth() {
	local port=4440 relay pub url bcast relay_auth pub_auth
	BIN=$(relay_bin)
	while [ $# -gt 0 ]; do
		case $1 in
		--bin) BIN=$2; shift 2 ;;
		--port) port=$2; shift 2 ;;
		*) die "install: unknown option $1" ;;
		esac
	done
	[ -x "$BIN/moq" ] || die "install: no moq in '$BIN'; pass --bin"
	relay=$(exec_start moq-relay.service)
	pub=$(exec_start moq-live-publisher.service)
	[[ $relay == *'--auth-public "**"'* ]] || die "install: the relay's unit does not grant --auth-public \"**\""
	url=$(sed -nE 's#.* --connect (https://[^ ]+/'"$ROOT"') .*#\1#p' <<<"$pub")
	bcast=$(sed -nE 's#.* --broadcast ([^ ]+) .*#\1#p' <<<"$pub")
	[ -n "$url" ] && [ -n "$bcast" ] || die "install: no --connect https://…/$ROOT and --broadcast in the publisher's unit"
	relay_auth=${relay/'--auth-public "**"'/--auth-url http://127.0.0.1:$port}
	pub_auth=${pub/" --connect $url "/ }
	[ "$pub_auth" != "$pub" ] || die "install: could not remove the publisher's --connect"

	mkdir -p "$D$ETC/pub"
	if [ ! -s "$D$ETC/live.jwk" ]; then
		(umask 077 && "$BIN/moq" auth generate --algorithm ES256 --id live \
			--out "$D$ETC/live.jwk" --public "$D$ETC/pub/live.jwk")
	fi
	[ -s "$D$ETC/pub/live.jwk" ] || die "install: $ETC/live.jwk has no pub/live.jwk beside it"
	chmod 0600 "$D$ETC/live.jwk"
	chmod 0644 "$D$ETC/pub/live.jwk"

	(umask 077 && printf 'MOQ_CONNECT=%s?jwt=%s\n' "$url" "$(sign --publish "$bcast/**")" >"$D$ETC/publisher.env")
	mkdir -p "$D$(dirname "$PROBE")"
	(umask 077 && sign --subscribe '**' >"$D$PROBE")
	own -R "$USR:$USR" "$D$(dirname "$PROBE")"

	mkdir -p "$D$UNITS/moq-relay.service.d" "$D$UNITS/moq-live-publisher.service.d"
	cat >"$D$UNITS/moq-auth.service" <<EOF
[Unit]
Description=Auth server for the standing relay (verifies each session's JWT, loopback only)
After=network-online.target
Before=moq-relay.service

[Service]
User=$USR
ExecStart=$BIN/moq auth serve --listen 127.0.0.1:$port --key-dir $ETC/pub
Restart=always
RestartSec=2
LogRateLimitIntervalSec=30s
LogRateLimitBurst=200

[Install]
WantedBy=multi-user.target
EOF
	cat >"$D$UNITS/moq-relay.service.d/auth.conf" <<EOF
[Unit]
After=moq-auth.service
Wants=moq-auth.service

[Service]
ExecStart=
ExecStart=$relay_auth
EOF
	cat >"$D$UNITS/moq-live-publisher.service.d/auth.conf" <<EOF
[Service]
EnvironmentFile=$ETC/publisher.env
ExecStart=
ExecStart=$pub_auth
EOF
	reload
	echo "installed for $bcast; apply with: systemctl enable --now moq-auth && systemctl restart moq-relay moq-live-publisher"
}

token() {
	local days=1 args=()
	while [ $# -gt 0 ]; do
		case $1 in
		--days) days=$2; shift 2 ;;
		--publish) args+=(--publish "$2/**"); shift 2 ;;
		*) die "token: unknown option $1" ;;
		esac
	done
	[ ${#args[@]} -gt 0 ] || args=(--subscribe '**')
	[ -r "$D$ETC/live.jwk" ] || die "token: cannot read $ETC/live.jwk (run as root)"
	BIN=$(relay_bin)
	[ -x "$BIN/moq" ] || die "token: no moq beside the relay"
	sign "${args[@]}" --expires $(($(date +%s) + days * 86400))
}

uninstall() {
	rm -rf "$UNITS/moq-relay.service.d/auth.conf" "$UNITS/moq-live-publisher.service.d/auth.conf"
	systemctl disable moq-auth 2>/dev/null || true
	systemctl daemon-reload
	echo "drop-ins removed; apply with: systemctl restart moq-relay moq-live-publisher && systemctl stop moq-auth"
}

case ${1:-} in
install) need_root; shift; install_auth "$@" ;;
token) shift; token "$@" ;;
uninstall) [ -z "$D" ] || die "uninstall acts on the host, not DESTDIR"; need_root; uninstall ;;
status) systemctl --no-pager --no-legend is-active moq-auth moq-relay moq-live-publisher ;;
*) sed -n '7,10p' "$0" >&2; exit 2 ;;
esac
