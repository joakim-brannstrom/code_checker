SOURCE=$_

set -ueEo pipefail

function log() {
	printf "\e[0;34m[INF]\e[0m %s\n" "$*"
}

function logError() {
	printf "\e[0;31m[ERR]\e[0m %s\n" "$*"
}

function die() {
	logError "$SOURCE:$1 ${*:2}"
	exit 1
}

trap 'die $LINENO' ERR