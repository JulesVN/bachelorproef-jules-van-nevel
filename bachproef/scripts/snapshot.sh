#! /bin/bash

DIR="./saves"
RUNS=${2}
OUT_DIR="./workspace/btrfs_snapshots"
RESTORE_DIR_BASE="./workspace/btrfs_restore"
CURRENT_DIR="./workspace/current_snapshot"
RESULTS_FILE="${OUT_DIR}/results.csv"
RESTORE_RESULTS_FILE="${RESTORE_DIR_BASE}/results.csv"

mkdir -p "${OUT_DIR}" "${RESTORE_DIR_BASE}"

mapfile -t SAVES < <(find "${DIR}" -mindepth 1 -maxdepth 1 -type d | sort)

INNER_FOLDER=$(find "${SAVES[0]}" -mindepth 1 -maxdepth 1 -type d | head -n1 | xargs basename)
echo "Detected inner folder: '${INNER_FOLDER}'"

TIME_TMP=$(sudo mktemp)
sudo chmod a+rw "${TIME_TMP}"

function setup_subvolume {
  if btrfs subvolume show "${CURRENT_DIR}" &>/dev/null; then
    sudo btrfs subvolume delete "${CURRENT_DIR}" >&2
  elif [[ -d "${CURRENT_DIR}" ]]; then
    rm -rf "${CURRENT_DIR}"
  fi
  mkdir -p "$(dirname "${CURRENT_DIR}")"
  sudo btrfs subvolume create "${CURRENT_DIR}" >&2
  sudo chown "${USER}:${USER}" "${CURRENT_DIR}"
}

function cleanup_snapshots {
  if [[ -d "${OUT_DIR}" ]]; then
    while IFS= read -r snap; do
      sudo btrfs subvolume delete "${snap}" >&2
    done < <(find "${OUT_DIR}" -mindepth 1 -maxdepth 1 -type d | sort)
  fi
  mkdir -p "${OUT_DIR}"
}

function run_backup {
  local run="${1}"

  cleanup_snapshots
  setup_subvolume

  local first_save=true

  for folder in "${SAVES[@]}"; do
    local save_name=$(basename "${folder}")
    local snapshot="${OUT_DIR}/${save_name}"

    if ${first_save}; then
      local level=0
      first_save=false
    else
      local level=1
    fi

    rsync -a --delete "${folder}/${INNER_FOLDER}/" "${CURRENT_DIR}/${INNER_FOLDER}/"

    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

    sudo /usr/bin/time -f "%e,%P,%M" -o "${TIME_TMP}" btrfs subvolume snapshot -r "${CURRENT_DIR}" "${snapshot}" >/dev/null

    local time_stats=$(cat "${TIME_TMP}")

    local size_original=$(du -sb "${folder}/${INNER_FOLDER}" | awk '{print $1}')

    echo "${run},btrfs_snapshot,${save_name},${level},${time_stats},${size_original}"
  done
}

function run_restore {
  local run="${1}"

  mkdir -p "${RESTORE_DIR_BASE}"

  for folder in "${SAVES[@]}"; do
    local save_name=$(basename "${folder}")
    local snapshot="${OUT_DIR}/${save_name}"
    local restore_target="${RESTORE_DIR_BASE}/${save_name}"

    if btrfs subvolume show "${restore_target}" &>/dev/null; then
      sudo btrfs subvolume delete "${restore_target}" >&2
    elif [[ -d "${restore_target}" ]]; then
      rm -rf "${restore_target}"
    fi

    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

    sudo /usr/bin/time -f "%e,%P,%M" -o "${TIME_TMP}" btrfs subvolume snapshot "${snapshot}" "${restore_target}" >/dev/null

    local time_stats=$(cat "${TIME_TMP}")

    echo "${run},btrfs_snapshot_restore,${save_name},0,${time_stats}"
  done
}

function run_backup_tests {
  rm -f "${RESULTS_FILE}"
  echo "run,label,save,level,time_s,cpu_pct,mem_kb,size_original,exclusive_size,set_shared_size" >>"${RESULTS_FILE}"

  for i in $(seq 1 "${RUNS}"); do
    echo "Started run ${i}"
    run_backup "${i}" >>"${RESULTS_FILE}"
    for folder in "${SAVES[@]}"; do
      local snapshot="${OUT_DIR}/$(basename "${folder}")"
      local exclusive_size=$(sudo btrfs filesystem du -s --raw "${snapshot}" | tail -1 | awk '{print $2}')
      local set_shared_size=$(sudo btrfs filesystem du -s --raw "${snapshot}" | tail -1 | awk '{print $3}')
      sed -i "/${i},btrfs_snapshot,$(basename "${folder}"),/s/$/,${exclusive_size},${set_shared_size}/" "${RESULTS_FILE}"
    done
  done
}

function run_restore_tests {
  mkdir -p "${RESTORE_DIR_BASE}"
  rm -f "${RESTORE_RESULTS_FILE}"
  echo "run,label,save,level,time_s,cpu_pct,mem_kb" >>"${RESTORE_RESULTS_FILE}"

  for i in $(seq 1 "${RUNS}"); do
    echo "Started run ${i}"
    run_restore "${i}" >>"${RESTORE_RESULTS_FILE}"
  done
}

trap 'sudo rm -f "${TIME_TMP}"' EXIT

function usage {
  echo "Usage: $0 {backup | restore}"
  exit 1
}

case "$1" in
backup)
  run_backup_tests
  ;;
restore)
  run_restore_tests
  ;;
*)
  echo "Error: Unknown command '$1'"
  usage
  ;;
esac
