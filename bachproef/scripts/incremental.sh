#! /bin/bash

DIR="./saves"
RUNS="${2}"
OUT_DIR="./workspace/incremental_backup"
RESTORE_DIR_BASE="./workspace/incremental_restore"
CURRENT_DIR="./workspace/current"
RESULTS_FILE="${OUT_DIR}/results.csv"
RESTORE_RESULTS_FILE="${RESTORE_DIR_BASE}/results.csv"

mapfile -t SAVES < <(find "${DIR}" -mindepth 1 -maxdepth 1 -type d | sort)

INNER_FOLDER=$(find "${SAVES[0]}" -mindepth 1 -maxdepth 1 -type d | head -n1 | xargs basename)
echo "Detected inner folder: '${INNER_FOLDER}'"

function run_backup {
  local run="${1}"
  local label="${2}"
  local tar_flags="${3}"
  local extension="${4}"

  local label_dir="${OUT_DIR}/${label}"
  local snap_dir="${OUT_DIR}/snapshots/${label}"
  local snapshot="${snap_dir}/backup.snar"

  mkdir -p "${label_dir}" "${snap_dir}" "${CURRENT_DIR}"
  rm -rf "${label_dir:?}/"*
  rm -f "${snapshot}"
  rm -rf "${CURRENT_DIR:?}/"*

  local first_save=true

  for folder in "${SAVES[@]}"; do
    local save_name
    save_name=$(basename "${folder}")
    local archive="${label_dir}/${save_name}.tar${extension}"

    if ${first_save}; then
      local level=0
      first_save=false
    else
      local level=1
    fi

    rsync -a --delete "${folder}/" "${CURRENT_DIR}/"

    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    time_stats=$(/usr/bin/time -f "%e,%P,%M" tar -C "${CURRENT_DIR}" ${tar_flags} "${archive}" -g "${snapshot}" "${INNER_FOLDER}" 2>&1)

    local size_archive
    size_archive=$(stat --printf='%s' "${archive}")
    local size_original
    size_original=$(du -sb "${CURRENT_DIR}/${INNER_FOLDER}" | awk '{print $1}')

    echo "${run},${label},${save_name},${level},${time_stats},${size_original},${size_archive}"
  done
}

function run_restore {
  local run="${1}"
  local label="${2}"
  local tar_flags="${3}"
  local extension="${4}"

  local label_dir="${OUT_DIR}/${label}"
  local restore_target="${RESTORE_DIR_BASE}/${label}"

  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  mkdir -p "${restore_target}"
  rm -rf "${restore_target:?}/"*

  local archives=()
  for folder in "${SAVES[@]}"; do
    archives+=("${label_dir}/$(basename "${folder}").tar${extension}")
  done

  local first_archive=true
  local save_index=0

  for folder in "${SAVES[@]}"; do
    local save_name
    save_name=$(basename "${folder}")
    local archive="${archives[$save_index]}"
    ((save_index++))

    if ${first_archive}; then
      local level=0
      first_archive=false

      time_stats=$(/usr/bin/time -f "%e,%P,%M" \
        tar ${tar_flags} "${archive}" --incremental -C "${restore_target}" 2>&1)
    else
      local level=1

      rm -rf "${restore_target:?}/"*
      sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

      local chain_cmd=""
      for ((i = 0; i <= save_index - 1; i++)); do
        chain_cmd+="tar ${tar_flags} '${archives[$i]}' --incremental -C '${restore_target}' && "
      done
      chain_cmd="${chain_cmd% && }"

      time_stats=$(/usr/bin/time -f "%e,%P,%M" bash -c "${chain_cmd}" 2>&1)
    fi

    local size_archive
    size_archive=$(stat --printf='%s' "${archive}")
    local size_restored
    size_restored=$(du -sb "${restore_target}" | awk '{print $1}')

    echo "${run},${label}_restore,${save_name},${level},${time_stats},${size_archive},${size_restored}"
  done
}

function run_backup_tests {
  mkdir -p "${OUT_DIR}"
  rm -f "${RESULTS_FILE}"
  echo "run,label,save,level,time_s,cpu_pct,mem_kb,size_original,size_archive" >>"${RESULTS_FILE}"

  for index in $(seq 1 "${RUNS}"); do
    echo "Started run ${index}"
    {
      run_backup "${index}" "uncompressed" "-cf" ""
      run_backup "${index}" "gzip" "-czf" ".gz"
      run_backup "${index}" "bzip2" "-cjf" ".bz2"
      run_backup "${index}" "xz" "-cJf" ".xz"
      run_backup "${index}" "lzma" "--lzma -cf" ".lzma"
      run_backup "${index}" "lzip" "--lzip -cf" ".lz"
      run_backup "${index}" "lzop" "--lzop -cf" ".lzo"
      run_backup "${index}" "zstd" "--zstd -cf" ".zst"
    } >>"${RESULTS_FILE}"
  done
}

function run_restore_tests {
  mkdir -p "${RESTORE_DIR_BASE}"
  rm -f "${RESTORE_RESULTS_FILE}"
  echo "run,label,save,level,time_s,cpu_pct,mem_kb,size_archive,size_restored" >>"${RESTORE_RESULTS_FILE}"

  for index in $(seq 1 "${RUNS}"); do
    echo "Started run ${index}"
    {
      run_restore "${index}" "uncompressed" "-xf" ""
      run_restore "${index}" "gzip" "-xzf" ".gz"
      run_restore "${index}" "bzip2" "-xjf" ".bz2"
      run_restore "${index}" "xz" "-xJf" ".xz"
      run_restore "${index}" "lzma" "--lzma -xf" ".lzma"
      run_restore "${index}" "lzip" "--lzip -xf" ".lz"
      run_restore "${index}" "lzop" "--lzop -xf" ".lzo"
      run_restore "${index}" "zstd" "--zstd -xf" ".zst"
    } >>"${RESTORE_RESULTS_FILE}"
  done
}

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
