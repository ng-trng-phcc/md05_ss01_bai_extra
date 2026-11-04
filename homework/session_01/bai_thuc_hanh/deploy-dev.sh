#!/usr/bin/env bash
# QuickBite development deployment for the confirmed identityservice repository.
set -Eeuo pipefail

trap 'rc=$?; printf "\033[31m[FAIL] Unexpected failure at line %s (exit %s).\033[0m\n" "$LINENO" "$rc" >&2' ERR

log() { printf '[INFO] %s\n' "$*"; }
die() { printf '\033[31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run sudo ./deploy-dev.sh user inside the Ubuntu container.'
[[ $# -eq 1 && $1 == user ]] || die 'Usage: sudo ./deploy-dev.sh user (Development only).'
[[ -e /.dockerenv ]] || die 'This script is restricted to the Docker lab.'

readonly REPO=/root/workspace/identityservice
readonly REPO_URL=https://github.com/ng-trng-phcc/md04_ss13_bai_01.git
readonly DIR=/opt/quickbite/dev/user-service
readonly JAR=$DIR/user-service.jar
readonly PIDFILE=$DIR/user-service.pid
readonly LOGFILE=$DIR/application.log
readonly JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
readonly JAVA=$JAVA_HOME/bin/java
readonly PORT=8080
readonly MARKER=-Dquickbite.deployment=dev-user
readonly START_TIMEOUT=90
readonly STOP_TIMEOUT=20
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

for tool in git ss python3 runuser nohup flock curl; do
  command -v "$tool" >/dev/null || die "Missing tool: $tool"
done
[[ -x $JAVA ]] || die 'Java 21 is required by the application toolchain.'
[[ -d $REPO/.git ]] || die 'Run /lab/setup-dev.sh first.'
[[ $(git -C "$REPO" remote get-url origin) == "$REPO_URL" ]] || die 'Unexpected Git origin.'
[[ $(stat -c '%U:%G:%a' "$DIR") == user-svc:quickbite-apps:750 ]] \
  || die 'Deployment directory permissions differ; run setup-dev.sh.'
runuser -u user-svc -- test -x "$DIR" || die 'Service account cannot traverse its directory.'
exec 9>/run/lock/quickbite-dev-user.lock
flock --nonblock 9 || die 'Another development deployment is active.'
umask 027

source_env=$DIR/dev.env
[[ -f $source_env && ! -L $source_env ]] || die 'Missing development environment file.'
[[ $(stat -c '%u:%a' "$source_env") == 0:600 ]] || die 'dev.env must be root-owned mode 600.'
set -a
. "$source_env"
set +a
[[ $SERVER_PORT == "$PORT" ]] || die 'Development port must be 8080.'
[[ $SERVER_ADDRESS == 127.0.0.1 ]] || die 'Development listener must remain container-local.'

log 'Checking clean source and updating the verified default branch.'
[[ -z $(git -C "$REPO" status --porcelain) ]] || die 'Local changes present; refusing git pull.'
branch=$(git ls-remote --symref "$REPO_URL" HEAD | awk '$1=="ref:" { sub("refs/heads/", "", $2); print $2; exit }')
[[ -n $branch && $(git -C "$REPO" branch --show-current) == "$branch" ]] \
  || die 'Checkout is not the verified remote default branch.'
git -C "$REPO" pull --ff-only origin "$branch" || die 'git pull failed; existing deployment preserved.'
[[ $(git -C "$REPO" rev-parse HEAD) == $(git -C "$REPO" rev-parse FETCH_HEAD) ]] \
  || die 'Local-only commits present; refusing to deploy divergent source.'

log 'Building identityservice with Java 21: clean bootJar.'
chmod +x "$REPO/gradlew"
build_rc=0
(cd "$REPO" && ./gradlew --no-daemon --max-workers=2 clean bootJar) || build_rc=$?
if (( build_rc != 0 )); then
  die "Gradle failed (exit $build_rc); running service and deployed JAR are untouched."
fi

# Select exactly one real Boot JAR; never deploy a '*-plain.jar'.
artifacts=()
shopt -s nullglob
for candidate in "$REPO"/build/libs/*.jar; do
  [[ $candidate == *-plain.jar ]] || artifacts+=("$candidate")
done
[[ ${#artifacts[@]} -eq 1 && -s ${artifacts[0]} ]] || die 'Expected one nonempty bootJar artifact.'
python3 - "${artifacts[0]}" <<'PY'
import struct, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as jar:
    manifest = jar.read('META-INF/MANIFEST.MF').decode()
    assert 'Main-Class: org.springframework.boot.loader.launch.JarLauncher' in manifest
    assert 'Start-Class: com.example.identityservice.IdentityserviceApplication' in manifest
    bytecode = jar.read('BOOT-INF/classes/com/example/identityservice/IdentityserviceApplication.class')
    assert struct.unpack('>H', bytecode[6:8])[0] == 65, 'Expected Java 21 bytecode'
print('Verified runnable identityservice Boot JAR (Java 21).')
PY

# Record both PID and kernel start time, then validate owner/executable/argv each
# time before signalling. A reused PID or unrelated listener is never killed.
service_uid=$(id -u user-svc)
process_matches() {
  runuser -u user-svc -- python3 - "$1" "${2:-}" "$service_uid" "$JAVA" "$JAR" "$MARKER" <<'PY'
import os, sys
pid, start, uid, java, jar, marker = sys.argv[1:]
try:
    root = '/proc/' + str(int(pid))
    fields = open(root + '/stat').read().rsplit(')', 1)[1].split()
    args = open(root + '/cmdline', 'rb').read().split(b'\0')[:-1]
    args = [a.decode() for a in args]
    assert fields[0] != 'Z'
    assert not start or fields[19] == start
    assert os.stat(root).st_uid == int(uid)
    assert os.path.realpath(root + '/exe') == os.path.realpath(java)
    assert args == [java, marker, '-jar', jar]
except (OSError, ValueError, AssertionError):
    sys.exit(1)
PY
}
process_start() {
  python3 - "$1" <<'PY'
import sys
print(open('/proc/' + sys.argv[1] + '/stat').read().rsplit(')', 1)[1].split()[19])
PY
}
listeners() {
  ss -H -ltnp "sport = :$PORT"
  # Container root lacks CAP_SYS_PTRACE; query as the service account as well
  # to resolve its Java listener without adding capabilities to the container.
  runuser -u user-svc -- ss -H -ltnp "sport = :$PORT"
}
listener_is() {
  local output
  output=$(listeners)
  [[ -n $output ]] || return 1
  mapfile -t found < <(printf '%s\n' "$output" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
  [[ ${#found[@]} -eq 1 && ${found[0]} == "$1" ]]
}
old_pid=
old_start=
if [[ -e $PIDFILE ]]; then
  [[ -f $PIDFILE && ! -L $PIDFILE ]] || die 'Unexpected PID file type.'
  read -r old_pid old_start < "$PIDFILE"
  [[ $old_pid =~ ^[0-9]+$ && $old_start =~ ^[0-9]+$ ]] || die 'Invalid PID identity record.'
  if [[ -d /proc/$old_pid ]] && ! process_matches "$old_pid" "$old_start"; then
    die 'PID file points to a different process; refusing to signal it.'
  fi
  [[ -d /proc/$old_pid ]] || old_pid=
fi
port_state=$(listeners)
if [[ -n $port_state ]]; then
  [[ -n $old_pid ]] && listener_is "$old_pid" && process_matches "$old_pid" "$old_start" \
    || die 'Port 8080 belongs to an unrelated/unmanaged process; deployment aborted.'
fi

staged=$(mktemp "$DIR/.user-service.jar.XXXXXX")
cleanup() { [[ -z ${staged:-} ]] || rm -f -- "$staged"; }
trap cleanup EXIT
install -o user-svc -g quickbite-apps -m 640 "${artifacts[0]}" "$staged"
runuser -u user-svc -- test -r "$staged" || die 'Service account cannot read the staged JAR.'

if [[ -n $old_pid ]]; then
  log "Stopping verified deployment PID $old_pid with SIGTERM."
  process_matches "$old_pid" "$old_start" || die 'Process identity changed before stop.'
  kill -TERM "$old_pid"
  for ((i=0; i<STOP_TIMEOUT; i++)); do
    process_matches "$old_pid" "$old_start" || break
    sleep 1
  done
  if process_matches "$old_pid" "$old_start"; then
    log "Graceful timeout; sending SIGKILL only to verified PID $old_pid."
    kill -KILL "$old_pid"
    sleep 1
  fi
  process_matches "$old_pid" "$old_start" && die 'Old service failed to stop.'
fi
[[ -z $(listeners) ]] || die 'Port 8080 became occupied; refusing startup.'
mv -f -- "$staged" "$JAR"
staged=
rm -f -- "$PIDFILE"
[[ ! -L $LOGFILE ]] || die 'Refusing a symlinked application log.'
touch "$LOGFILE"
chown user-svc:quickbite-apps "$LOGFILE"
chmod 640 "$LOGFILE"

log 'Starting Java as user-svc using runuser and nohup.'
new_pid=$(runuser -u user-svc -- bash -c '
  cd "$1"
  nohup "$2" "$3" -jar "$4" >> "$5" 2>&1 < /dev/null &
  printf "%s\n" "$!"
' bash "$DIR" "$JAVA" "$MARKER" "$JAR" "$LOGFILE" 9>&-)
new_start=$(process_start "$new_pid")
printf '%s %s\n' "$new_pid" "$new_start" > "$PIDFILE"
chmod 600 "$PIDFILE"
sleep 1

for ((i=0; i<START_TIMEOUT; i++)); do
  process_matches "$new_pid" "$new_start" || die "Service exited; inspect $LOGFILE."
  http_code=000
  if listener_is "$new_pid"; then
    http_code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 1 --max-time 2 http://127.0.0.1:8080/ || true)
  fi
  case "$http_code" in
    2??|3??|401|403|404)
      sleep 2
      process_matches "$new_pid" "$new_start" && listener_is "$new_pid" \
        || die 'Service did not remain alive after HTTP readiness.'
      log "Development deployment ready: PID=$new_pid owner=user-svc port=8080 HTTP=$http_code"
      log "Source commit: $(git -C "$REPO" rev-parse HEAD); log: $LOGFILE"
      exit 0
      ;;
  esac
  sleep 1
done
die "Startup timed out after $START_TIMEOUT seconds; inspect $LOGFILE."
