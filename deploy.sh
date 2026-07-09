#!/usr/bin/env bash
set -euo pipefail

readonly PROG_NAME="${0##*/}"

HOST=""
PORT=22
USER="root"
DO_RESTART=0

FILES=(
	"files/etc/config/ap-isolation:/etc/config/ap-isolation:644"
	"files/etc/init.d/ap-isolation:/etc/init.d/ap-isolation:755"
	"files/etc/hotplug.d/iface/50-ap-isolation:/etc/hotplug.d/iface/50-ap-isolation:644"
	"files/usr/sbin/ap-isolation.sh:/usr/sbin/ap-isolation.sh:755"
)

usage() {
	cat <<EOF
Usage: $PROG_NAME -H <host> [-P <port>] [-u <user>] [-r]

Quick-deploy ap-isolation files to an OpenWrt router.

Options:
  -H <host>    Router hostname or IP (required)
  -P <port>    SSH port (default: 22)
  -u <user>    SSH user (default: root)
  -r           Restart / enable service after deploy
  -h           Show this help and exit
EOF
	exit 0
}

die() {
	printf "Error: %s\n" "$*" >&2
	exit 1
}

while getopts "hH:P:u:r" opt; do
	case "$opt" in
		h) usage ;;
		H) HOST="$OPTARG" ;;
		P) PORT="$OPTARG" ;;
		u) USER="$OPTARG" ;;
		r) DO_RESTART=1 ;;
		*) usage ;;
	esac
done

[ -n "$HOST" ] || die "Host is required (-H <host>)"

SSH_CMD="ssh -p ${PORT} -o ConnectTimeout=5 ${USER}@${HOST}"
SCP_CMD="scp -O -P ${PORT} -o ConnectTimeout=5"

remote_cmd() {
	$SSH_CMD "$@" 2>/dev/null
}

remote_md5() {
	remote_cmd "md5sum '$1' 2>/dev/null | cut -d' ' -f1"
}

local_md5() {
	md5sum "$1" 2>/dev/null | cut -d' ' -f1 || echo ""
}

printf "Checking connectivity to %s@%s:%d ... " "$USER" "$HOST" "$PORT"
remote_cmd "true" || die "unreachable"
printf "OK\n"

printf "Creating remote directories ... "
remote_cmd "mkdir -p /etc/config /etc/init.d /etc/hotplug.d/iface /usr/sbin"
printf "done\n"

result=()
transferred=0
skipped=0
errors=0

for entry in "${FILES[@]}"; do
	local_path="${entry%%:*}"
	rest="${entry#*:}"
	remote_path="${rest%:*}"
	mode="${rest##*:}"

	if [ -f "${local_path}.local" ]; then
		local_path="${local_path}.local"
	fi

	local_md5_val="$(local_md5 "$local_path")"
	remote_md5_val="$(remote_md5 "$remote_path")"
	local_name="${local_path#files/}"

	if [ -z "$remote_md5_val" ]; then
		if $SCP_CMD "$local_path" "${USER}@${HOST}:${remote_path}"; then
			remote_cmd "chmod $mode '$remote_path'"
			result+=("$local_name  ... new (transferred)")
			transferred=$((transferred + 1))
		else
			result+=("$local_name  ... ERROR (scp failed)")
			errors=$((errors + 1))
		fi
	elif [ "$remote_md5_val" = "$local_md5_val" ]; then
		result+=("$local_name  ... unchanged (skipped)")
		skipped=$((skipped + 1))
		remote_cmd "chmod $mode '$remote_path'" 2>/dev/null || true
	else
		if $SCP_CMD "$local_path" "${USER}@${HOST}:${remote_path}"; then
			remote_cmd "chmod $mode '$remote_path'"
			result+=("$local_name  ... updated (transferred)")
			transferred=$((transferred + 1))
		else
			result+=("$local_name  ... ERROR (scp failed)")
			errors=$((errors + 1))
		fi
	fi
done

printf "\n--- File deployment summary ---\n"
for line in "${result[@]}"; do
	printf "  %s\n" "$line"
done

printf "\nChecking /etc/sysupgrade.conf ...\n"
sysupgrade_added=0
sysupgrade_skipped=0

for entry in "${FILES[@]}"; do
	rest="${entry#*:}"
	remote_path="${rest%:*}"

	if remote_cmd "grep -qxF '$remote_path' /etc/sysupgrade.conf" 2>/dev/null; then
		printf "  %-40s already listed (skipped)\n" "$remote_path"
		sysupgrade_skipped=$((sysupgrade_skipped + 1))
	else
		remote_cmd "echo '$remote_path' >> /etc/sysupgrade.conf"
		printf "  %-40s added\n" "$remote_path"
		sysupgrade_added=$((sysupgrade_added + 1))
	fi
done

if [ "$DO_RESTART" -eq 1 ]; then
	printf "\nEnabling and restarting service ... "
	remote_cmd "/etc/init.d/ap-isolation enable && /etc/init.d/ap-isolation reload" && printf "done\n" || printf "FAILED\n"
fi

printf "\n--- Done ---\n"
printf "  %d transferred, %d skipped, %d errors\n" "$transferred" "$skipped" "$errors"
printf "  sysupgrade.conf: %d added, %d already present\n" "$sysupgrade_added" "$sysupgrade_skipped"
