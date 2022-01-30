LIB_DIR=$(dirname "${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}")

function backupApp() {
  local packageName="$1"
  local baseDestFolder="$2/$1"

  if [[ "${APK}" != 'true' ]]; then
    
    # Backup to target paths as short as possible to avoid "path too long" errors
    backupFolder "/data/data/${packageName}" "${baseDestFolder}/data/"

    backupFolder "/sdcard/Android/data/${packageName}" "${baseDestFolder}/sdcard/"
    
    # Backing up to /sdcard/data and /sdcard/media would have been more intuitive
    # But: media was added later and migrating data would be too much effort for me right now
    backupFolder "/sdcard/Android/media/${packageName}" "${baseDestFolder}/sdcard-media/"
    
    trace "Syncing Keys for app ${packageName} from ${KEYSTORE_FOLDER} to ${baseDestFolder}/keys/"
    # shellcheck disable=SC2046 
    # This might return multiple parameters that we don't want quoted here
    doSync "${KEYSTORE_FOLDER}/" "${baseDestFolder}/keys/" $(includeOnlyCurrentAppKeys "${packageName}")
  fi

  if [[ "${DATA}" != 'true' ]]; then
    # Backup all APKs from path (can be multiple for split-apks!)
    apkPath=$(dirname "$(sudo pm path "${packageName}" | head -n1 | sed 's/package://')")
    # Only sync APKs, libs, etc are extracted during install
    # shellcheck disable=SC2046 
    # This might return multiple parameters that we don't want quoted here
    doSync "$apkPath/" "$baseDestFolder/" $(includeOnlyApk)
  fi
}

function backupFolder() {
  srcFolder="$1"
  rootDestFolder="$2"
  
  if [[ -d "${srcFolder}" ]]; then
    trace "Syncing ${srcFolder} to ${rootDestFolder}"
    doSync "${srcFolder}/" "${rootDestFolder}" $(backupFolderSyncArgs)
  fi
}

function includeOnlyCurrentAppKeys() {
  packageName="$1"
  
  currentAppUserId=$(findCurrentAppUserId "${packageName}") 
  
  if [[ "${RCLONE}" == 'true' ]]; then
    # rsync rule causes error, so use '--exclude **' implied by rclone on --include. 
    # ERROR : Using --filter is recommended instead of both --include and --exclude as the order they are parsed in is indeterminate
    echo --include "*${currentAppUserId}*"
  else 
    echo  --include='*/' --include "*${currentAppUserId}*" --exclude='*'
  fi
}

function findCurrentAppUserId() {
  local packageName="$1"
  
  sudo grep "${packageName}" /data/system/packages.xml | \
        grep userId | sed 's/.*userId="\([0-9]*\).*/\1/'
}

function restoreApp() {
  local rootSrcFolder="$1"
  # For now just assume folder name = package name. Reading from apk would be more defensive... and effort.
  local packageName=${rootSrcFolder##*/}

  if [[ "${DATA}" != 'true' ]]; then
    installMultiple "${rootSrcFolder}/"
  fi

  if [[ "${APK}" != 'true' ]]; then
    local userAndGroup
    userAndGroup="$(stat -c '%U:%G' "/data/data/${packageName}")"
  
    restoreFolder "${rootSrcFolder}" "data" "/data/data" "${userAndGroup}"
  
    restoreFolder "${rootSrcFolder}" "sdcard" "/sdcard/Android/data" "${userAndGroup}"
    
    restoreFolder "${rootSrcFolder}" "sdcard-media" "/sdcard/Android/media" "${userAndGroup}"
    
    # TODO option for skipping restore?
    restoreKeys "${rootSrcFolder}" "${packageName}"
  fi
}

function restoreKeys() {
  local rootSrcFolder="$1"
  local packageName="$2"
  local keyFiles
  local tmpdir
  tmpdir="$(mktemp -d)"
  
  restoreFolder "${rootSrcFolder}" "keys" "${tmpdir}"
  # restoreFolder writes to subdir
  tmpdir=${tmpdir}/${packageName}
  
  # TODO do we need sudo here?
  oldAppUserId=$(find "${tmpdir}" -type f -printf "%f\n" | head -n1 | sed 's/\([0-9]*\).*/\1/')
  if [[ -z "${oldAppUserId}" ]]; then
    trace "No app user ID found could be parsed from files names in folder 'keys' for app ${packageName}. Skipping restoring keys" 
    return
  fi
  
  newAppUserId=$(findCurrentAppUserId "${packageName}") 
  
  if [[ "${oldAppUserId}" != "${newAppUserId}" ]]; then
    trace "renaming key files prefix (userid) from ${oldAppUserId} to ${newAppUserId}"
    rename "${oldAppUserId}" "${newAppUserId}" "${tmpdir}"/* "${tmpdir}"/.*
  fi
  
  keyFiles="$(find "${tmpdir}" -type f)"
  # Set UID and GID of current keystore folder
  sudo chown -R "$(sudo stat -c "%U:%G" "${KEYSTORE_FOLDER}")" "${tmpdir}"
  
  trace "Restoring key files for app ${packageName} to ${KEYSTORE_FOLDER}: ${keyFiles}" 
  # shellcheck disable=SC2086
  # We actually do want word splitting here
  sudo mv ${keyFiles} "${KEYSTORE_FOLDER}"
}

function restoreFolder() {
  # e.g. /folder/com.nxp.taginfolite
  # or remote:/folder/com.nxp.taginfolite
  local rootSrcFolder="$1"
  # e.g. data
  local relativeSrcFolder="$2"
  # e.g. /data/data
  local rootDestFolder="$3"
  # e.g. 'u0_a303:u0_a303'. Skipped if empty.
  local userAndGroup=''
  if (( $# >= 4 )); then userAndGroup="$4"; fi
  # e.g. com.nxp.taginfolite
  local packageName=${rootSrcFolder##*/}
  
  # e.g. /folder/com.nxp.taginfolite/data/
  local actualSrcFolder="${rootSrcFolder}/${relativeSrcFolder}"
  # e.g. /data/data/com.nxp.taginfolite
  local actualDestFolder="${rootDestFolder}/${packageName}"


  if [[ "$(checkActualSourceFolderExists "${actualSrcFolder}")" == 'true' ]]; then
    trace "Restoring data from ${actualSrcFolder} to ${actualDestFolder}"
    doSync "${actualSrcFolder}/" "${actualDestFolder}"
    if [[ -n "${userAndGroup}" ]]; then
      trace "Fixing owner/group ${userAndGroup} in ${actualDestFolder}"
      sudo chown -R "${userAndGroup}" "${actualDestFolder}"
    fi
  else
    info "Backup does not contain folder '${actualSrcFolder}'. Skipping"
  fi
  
}

function checkActualSourceFolderExists() {
  actualSrcFolder="$1"
  actualSourceFolderExists=false
  local sshCommand
  local localFolder
  
  if [[ "${actualSrcFolder}" == *:* ]] && [[ "${RCLONE}" != 'true' ]]; then
    # ssh '[ -d /a/b/c ]'
    sshCommand="$(removeDirFromSshExpression "${actualSrcFolder}")"
    localFolder="$(removeUserAndHostNameFromSshExpression "${actualSrcFolder}")"

    if sshFromEnv "${sshCommand}" "[ -d ${localFolder} ]"; then
      actualSourceFolderExists=true
    fi
  elif [[ "${RCLONE}" == 'true' ]]; then
    if rclone lsd "${actualSrcFolder}" > /dev/null 2>&1; then
      actualSourceFolderExists=true
    fi
  else
    [[ -d "${actualSrcFolder}" ]] && actualSourceFolderExists=true
  fi
  
  echo ${actualSourceFolderExists}
}

function backupFolderSyncArgs() {
  # TODO can't we find a single exclude that works with both rclone and rsync? Would increase maintainability drastically 
  if [[ "${RCLONE}" == 'true' ]]; then
    # Avoid fuss with whitespaces inside the filter rules by importing them from a file
    echo --filter-from="${LIB_DIR}/rclone-data-filter.txt"
  else 
    # Add --delete here to remove files ins dest that have been deleted 
    # This should also migrate from data/data/${packageName} to data/data
    echo --delete --exclude={/cache,/code_cache,/app_tmppccache,/no_backup,/app_pccache,*/temp,*/.thumb_cache,*/.com.google.firebase.crashlytics,*/.Fabric/}
  fi
}

function includeOnlyApk() {
  if [[ "${RCLONE}" == 'true' ]]; then
    # rclone implies '--exclude **' on include
    echo --include='*.apk'
  else 
    echo -m --include='*/' --include='*.apk' --exclude='*'
  fi
}

function doSync() {

  if [[ "${RCLONE}" == 'true' ]]; then
    doRclone "$@"
  else
    doRsync "$@"
  fi

}

function doRclone() {
  src="$1"
  dst="$2"
  additionalArgs=("$@")
  # Treat all args after src and dst as addition rsync args
  additionalArgs=${additionalArgs[@]:2}
  RSYNC_ARGS=${RSYNC_ARGS:-''}

  sudo rclone sync \
    $(rsyncExternalArgs) \
    ${additionalArgs} \
    "${src}" "${dst}"
}

function doRsync() {
  src="$1"
  dst="$2"
  additionalArgs=("$@")
  # Treat all args after src and dst as addition rsync args
  additionalArgs=${additionalArgs[@]:2}
  remoteShellArgs=''
  RSYNC_ARGS=${RSYNC_ARGS:-''}

  if [[ "${dst}" == *:* ]]; then
    # e.g. execViaSsh user@host 'mkdir -p /a/b/c'
    sshFromEnv "$(removeDirFromSshExpression "${dst}")" "mkdir -p $(removeUserAndHostNameFromSshExpression "${dst}")"
  else
    mkdir -p "${dst}"
  fi

  if [[ "${src}" == *:* ]] || [[ "${dst}" == *:* ]]; then
    setRemoteShellArgs
  fi

  sudo rsync \
    --human-readable --archive --times \
    "--rsh=${remoteShellArgs[*]}" \
    $(rsyncExternalArgs) \
    ${additionalArgs} \
    "${src}" "${dst}"
}

function sshFromEnv() {
  userAtHost="$1"
  sshCommand="$2"

  setRemoteShellArgs

  eval "${remoteShellArgs[*]} ${userAtHost} '${sshCommand}'"
}

function setRemoteShellArgs() {
  remoteShellArgs=('ssh')

  set +o nounset
  [[ -n "$SSH_PORT" ]] && remoteShellArgs+=("-p $SSH_PORT")
  [[ -n "$SSH_PK" ]] && remoteShellArgs+=("-i $SSH_PK")
  [[ -n "$SSH_HOST_FILE" ]] && remoteShellArgs+=("-o UserKnownHostsFile=$SSH_HOST_FILE")
  set -o nounset
}

function rsyncExternalArgs() {
  set +o nounset
  echo "${RSYNC_ARGS}"
  set -o nounset
}

# Example:
# user@host:/a/b/c
# to
# user@host
function removeDirFromSshExpression() {
  # shellcheck disable=SC2001
  # "Occasionally a more complex sed substitution is required."
  sed 's/\(.*\):.*/\1/' <<<"$1"
}

# Example:
# user@host:/a/b/c
# to
# /a/b/c
function removeUserAndHostNameFromSshExpression() {
  # shellcheck disable=SC2001
  # "Occasionally a more complex sed substitution is required."
  sed 's/.*:\(.*\)/\1/' <<<"$1"
}

function installMultiple() {
  # Note:
  # * A newer alternative to "pm" seems to be "pm"
  # * It prints a help dialog by just calling "pm" (--help does not work)
  local apkFolder="$1"

  if [[ "${apkFolder}" == *:* ]] || [[ "${RCLONE}" == 'true' ]]; then
    apkTmp=$(mktemp -d)
    # shellcheck disable=SC2046 
    # This might return multiple parameters that we don't want quoted here
    doSync "$apkFolder/" "$apkTmp/" $(includeOnlyApk)
    apkFolder=$apkTmp
  fi

  (
    cd "${apkFolder}"
    totalApkSize=0
    for apk in *.apk; do
      size=$(wc -c "${apk}" | awk '{print $1}')
      totalApkSize=$((totalApkSize + size))
    done

    trace "Creating install session for total APK size ${totalApkSize}"
    installCreateOutput=$(sudo pm install-create -S ${totalApkSize})
    sessionId=$(echo "${installCreateOutput}" | grep -E -o '[0-9]+')

    trace "Installing apks in session $sessionId"
    for apk in *.apk; do
      size=$(wc -c "${apk}" | awk '{print $1}')
      trace "Writing ${apk} (size ${size}) to session ${sessionId}"
      # install-write [-S BYTES] SESSION_ID SPLIT_NAME [PATH|-]
      #  Write an apk into the given install session.  If the path is '-', data will be read from stdin
      sudo pm install-write -S "${size}" "${sessionId}" "${apk}" "${apk}"
    done

    trace "Committing session ${sessionId}"
    sudo pm install-commit "${sessionId}"
  )
}

function trace() {
  if [[ "${LOG_LEVEL}" == 'TRACE' ]]; then
    __log "$*"
  fi
}

function isExcludedPackage() {
  packageName="$1"
  
  for exclude in $(echo "${EXCLUDE_PACKAGES}" | tr ";" "\n")
  do 
    # shellcheck disable=SC2053
    # We want globbing here, so DON'T quote exclude
    if [[ "${packageName}" == ${exclude} ]]; then
      info "packageName ${packageName} excluded by exclude parameter: ${exclude}"
      return 0
    fi
  done 
  
  return 1
}


function info() {
  if [[ "${LOG_LEVEL}" =~ ^(TRACE|INFO)$ ]]; then
    __log "$*"
  fi
}

function warn() {
  if [[ "${LOG_LEVEL}" =~ ^(TRACE|INFO|WARN)$ ]]; then
    __log "$*"
  fi  
}

function __log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

function enableFileLogging() {
  # Almost no android app seems to register for opening ".log" files. So use a more common ending.
  LOG_FILE=${LOG_FILE:-"$(mktemp --suffix=.txt)"}
  info "Writing output to logfile: ${LOG_FILE}"
  exec > >(tee -a ${LOG_FILE})
  exec 2> >(tee -a ${LOG_FILE} >&2)
}

function printSeconds() {
  echo "$((SECONDS / 3600))h $(((SECONDS / 60) % 60))m $((SECONDS % 60))s"
}

function init() {
  if [[ -n "${DEBUG}" ]]; then set -x; fi
  
  SECONDS=0 # Variable SECONDS will track execution time of the command
  
  LOG_LEVEL=${LOG_LEVEL:-'INFO'}
 
  # TODO Can we find out the user index for keystore folder?
  KEYSTORE_FOLDER=${KEYSTORE_FOLDER:-'/data/misc/keystore/user_0/'}

  if [[ ! "${LOG_LEVEL}" =~ ^(TRACE|INFO|WARN|OFF)$ ]]; then
    echo "WARNING: Unknown Log level '${LOG_LEVEL}'. Defaulting to INFO"
    LOG_LEVEL='INFO'
  fi

  enableFileLogging

  readArgs "$@"

  set -o errexit -o nounset -o pipefail
}

# Read know param and writes them into vars
function readArgs() {
  POSITIONAL_ARGS=()
  DATA=''
  APK=''
  RCLONE=''
  EXCLUDE_PACKAGES=''
  while [[ $# -gt 0 ]]; do
    ARG="$1"
    echo arg=$1

    case ${ARG} in
    -d | --data)
      DATA=true
      shift ;;
    -a | --apk) 
      APK=true
      shift ;;
    --rclone)
      RCLONE=true
      shift ;;
    --exclude-packages)
      EXCLUDE_PACKAGES="$2"; shift 2 ;;
    *) # Unknown or positional arg
      POSITIONAL_ARGS+=("$1")
      shift ;;
    esac
  done
}
