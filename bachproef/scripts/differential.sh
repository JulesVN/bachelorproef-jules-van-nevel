#! /bin/bash

DIR="./saves"
RUNS=${2}
OUT_DIR="./workspace/differential_backup"
RESTORE_DIR_BASE="./workspace/differential_restore"
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
  local level0_snap="${snap_dir}/level0.snar"

  mkdir -p "${label_dir}" "${snap_dir}" "${CURRENT_DIR}"
  rm -rf "${label_dir:?}/"*
  rm -f "${level0_snap}"
  rm -rf "${CURRENT_DIR:?}/"*

  local first_save=true

  for folder in "${SAVES[@]}"; do
    local save_name
    save_name=$(basename "${folder}")
    local archive="${label_dir}/${save_name}.tar${extension}"

    rsync -a --delete "${folder}/" "${CURRENT_DIR}/"

    if ${first_save}; then
      local level=0
      first_save=false

      sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
      time_stats=$(/usr/bin/time -f "%e,%P,%M" \
        tar -C "${CURRENT_DIR}" ${tar_flags} "${archive}" \
        -g "${level0_snap}" \
        "${INNER_FOLDER}" 2>&1)
    else
      local level=1
      local snap_copy="${snap_dir}/diff_working.snar"
      cp "${level0_snap}" "${snap_copy}"

      sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
      time_stats=$(/usr/bin/time -f "%e,%P,%M" \
        tar -C "${CURRENT_DIR}" ${tar_flags} "${archive}" \
        -g "${snap_copy}" \
        "${INNER_FOLDER}" 2>&1)
    fi

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
  local level0_archive="${label_dir}/small_mod_1.tar${extension}"

  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  mkdir -p "${restore_target}"
  rm -rf "${restore_target:?}/"*

  local first_archive=true

  for folder in "${SAVES[@]}"; do
    local save_name
    save_name=$(basename "${folder}")
    local archive="${label_dir}/${save_name}.tar${extension}"

    if ${first_archive}; then
      local level=0
      first_archive=false

      time_stats=$(/usr/bin/time -f "%e,%P,%M" \
        tar ${tar_flags} "${archive}" \
        --incremental \
        -C "${restore_target}" 2>&1)
    else
      local level=1

      rm -rf "${restore_target:?}/"*
      sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
      time_stats=$(/usr/bin/time -f "%e,%P,%M" bash -c "
        tar ${tar_flags} '${level0_archive}' --incremental -C '${restore_target}' &&
        tar ${tar_flags} '${archive}'        --incremental -C '${restore_target}'
      " 2>&1)
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
  echo "run,label,save,level,time_s,cpu_pct,mem_kb,size_original,size_archive" \
    >>"${RESULTS_FILE}"

  for i in $(seq 1 "${RUNS}"); do
    echo "Started run ${i}"
    {
      run_backup "${i}" "uncompressed" "-cf" ""
      run_backup "${i}" "gzip" "-czf" ".gz"
      run_backup "${i}" "bzip2" "-cjf" ".bz2"
      run_backup "${i}" "xz" "-cJf" ".xz"
      run_backup "${i}" "lzma" "--lzma -cf" ".lzma"
      run_backup "${i}" "lzip" "--lzip -cf" ".lz"
      run_backup "${i}" "lzop" "--lzop -cf" ".lzo"
      run_backup "${i}" "zstd" "--zstd -cf" ".zst"
    } >>"${RESULTS_FILE}"
  done
}

function run_restore_tests {
  mkdir -p "${RESTORE_DIR_BASE}"
  rm -f "${RESTORE_RESULTS_FILE}"
  echo "run,label,save,level,time_s,cpu_pct,mem_kb,size_archive,size_restored" \
    >>"${RESTORE_RESULTS_FILE}"

  for i in $(seq 1 "${RUNS}"); do
    echo "Started run ${i}"
    {
      run_restore "${i}" "uncompressed" "-xf" ""
      run_restore "${i}" "gzip" "-xzf" ".gz"
      run_restore "${i}" "bzip2" "-xjf" ".bz2"
      run_restore "${i}" "xz" "-xJf" ".xz"
      run_restore "${i}" "lzma" "--lzma -xf" ".lzma"
      run_restore "${i}" "lzip" "--lzip -xf" ".lz"
      run_restore "${i}" "lzop" "--lzop -xf" ".lzo"
      run_restore "${i}" "zstd" "--zstd -xf" ".zst"
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
