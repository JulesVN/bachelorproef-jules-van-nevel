#! /bin/bash

DIR="./saves"
RUNS=${2}

OUT_DIR="./workspace/full_backup"
RESULTS_FILE="${OUT_DIR}/results.csv"
RESTORE_RESULTS_FILE="./workspace/full_restore/results.csv"

function run_backup {
  local run="${1}"
  local label="${2}"
  local tar_flags="${3}"
  local extension="${4}"

  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

  mkdir -p "${OUT_DIR}/${label}"
  rm -rf ${OUT_DIR}/${label}/*

  for folder in "${DIR}"/*; do
    archive="${OUT_DIR}/${label}/$(basename "${folder}").tar${extension}"

    time_stats=$(/usr/bin/time -f "%e,%P,%M" tar -C "${DIR}" ${tar_flags} "${archive}" "$(basename ${folder})" 2>&1)

    size_backup=$(stat --printf='%s' "${archive}")
    size_original=$(du -sb "${folder}" | awk '{print $1}')

    echo "${run},${label},$(basename "${folder}"),${time_stats},${size_original},${size_backup}"
  done
}

function run_backup_tests {
  rm -f "${RESULTS_FILE}"
  echo "run,label,save,level,time_s,cpu_pct,mem_kb,size_original,size_archive" >>"${RESULTS_FILE}"
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

function run_restore {
  local run="${1}"
  local label="${2}"
  local tar_flags="${3}"
  local extension="${4}"

  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

  RESTORE_DIR="./workspace/full_restore/${label}"
  mkdir -p "${RESTORE_DIR}"
  rm -rf ${RESTORE_DIR:?}/*

  for archive in "${OUT_DIR}/${label}"/*.tar${extension}; do
    base_name=$(basename "${archive}" .tar${extension})

    target_dir="${RESTORE_DIR}/${base_name}"
    mkdir -p "${target_dir}"

    time_stats=$(/usr/bin/time -f "%e,%P,%M" tar ${tar_flags} "${archive}" -C "${target_dir}" 2>&1)

    size_backup=$(stat --printf='%s' "${archive}")
    size_restored=$(du -sb "${target_dir}" | awk '{print $1}')

    echo "${run},${label}_restore,${base_name},${time_stats},${size_backup},${size_restored}"
  done
}

function run_restore_tests {
  rm -f "${RESTORE_RESULTS_FILE}"
  echo "run,label,save,level,time_s,cpu_pct,mem_kb,size_restored" >>"${RESTORE_RESULTS_FILE}"
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

case "${1}" in
backup)
  run_backup_tests
  ;;
restore)
  run_restore_tests
  ;;
*)
  echo "Error: Unknown command '${1}'"
  usage
  ;;
esac
