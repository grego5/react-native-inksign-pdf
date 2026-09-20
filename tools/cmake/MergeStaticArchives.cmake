if(NOT DEFINED OUTPUT OR NOT DEFINED AR OR NOT DEFINED RANLIB)
  message(FATAL_ERROR "OUTPUT, AR, and RANLIB are required")
endif()

set(_merge_root "${CMAKE_CURRENT_BINARY_DIR}/merge-static-archives")
file(REMOVE_RECURSE "${_merge_root}")
file(MAKE_DIRECTORY "${_merge_root}")
get_filename_component(_output_dir "${OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${_output_dir}")

set(_archives ${PRIMARY_ARCHIVES})
if(DEFINED ABSL_ARCHIVE_ROOT AND EXISTS "${ABSL_ARCHIVE_ROOT}")
  file(GLOB_RECURSE _absl_archives LIST_DIRECTORIES FALSE
    "${ABSL_ARCHIVE_ROOT}/*.a"
    "${ABSL_ARCHIVE_ROOT}/*.lib")
  list(SORT _absl_archives)
  list(APPEND _archives ${_absl_archives})
endif()
list(REMOVE_DUPLICATES _archives)
if(NOT _archives)
  message(FATAL_ERROR "No static archives were provided to merge")
endif()

set(_objects)
set(_archive_index 0)
foreach(_archive IN LISTS _archives)
  if(NOT EXISTS "${_archive}")
    message(FATAL_ERROR "Missing static archive: ${_archive}")
  endif()
  set(_extract_dir "${_merge_root}/${_archive_index}")
  file(MAKE_DIRECTORY "${_extract_dir}")
  execute_process(
    COMMAND "${AR}" x "${_archive}"
    WORKING_DIRECTORY "${_extract_dir}"
    RESULT_VARIABLE _extract_result
    OUTPUT_VARIABLE _extract_output
    ERROR_VARIABLE _extract_error)
  if(NOT _extract_result EQUAL 0)
    message(FATAL_ERROR
      "Unable to extract ${_archive}: ${_extract_error}${_extract_output}")
  endif()

  file(GLOB _members LIST_DIRECTORIES FALSE "${_extract_dir}/*")
  list(SORT _members)
  set(_member_index 0)
  foreach(_member IN LISTS _members)
    get_filename_component(_member_name "${_member}" NAME)
    set(_unique_member
      "${_extract_dir}/${_archive_index}_${_member_index}_${_member_name}")
    file(RENAME "${_member}" "${_unique_member}")
    list(APPEND _objects "${_unique_member}")
    math(EXPR _member_index "${_member_index} + 1")
  endforeach()
  math(EXPR _archive_index "${_archive_index} + 1")
endforeach()

if(NOT _objects)
  message(FATAL_ERROR "The input archives contained no object members")
endif()

file(REMOVE "${OUTPUT}")
execute_process(
  COMMAND "${AR}" qc "${OUTPUT}" ${_objects}
  RESULT_VARIABLE _archive_result
  OUTPUT_VARIABLE _archive_output
  ERROR_VARIABLE _archive_error)
if(NOT _archive_result EQUAL 0)
  message(FATAL_ERROR
    "Unable to create ${OUTPUT}: ${_archive_error}${_archive_output}")
endif()

execute_process(
  COMMAND "${RANLIB}" "${OUTPUT}"
  RESULT_VARIABLE _ranlib_result
  OUTPUT_VARIABLE _ranlib_output
  ERROR_VARIABLE _ranlib_error)
if(NOT _ranlib_result EQUAL 0)
  message(FATAL_ERROR
    "Unable to index ${OUTPUT}: ${_ranlib_error}${_ranlib_output}")
endif()

file(SIZE "${OUTPUT}" _archive_size)
file(SHA256 "${OUTPUT}" _archive_sha256)
get_filename_component(_output_json "${OUTPUT}" NAME)
if(ENABLE_PERFETTO_TRACE)
  set(_perfetto_json true)
else()
  set(_perfetto_json false)
endif()
file(WRITE "${METADATA}" "{\n")
file(APPEND "${METADATA}" "  \"format\": 1,\n")
file(APPEND "${METADATA}" "  \"archive\": \"${_output_json}\",\n")
file(APPEND "${METADATA}" "  \"abi\": \"${ABI}\",\n")
file(APPEND "${METADATA}" "  \"apiVersion\": ${API_VERSION},\n")
file(APPEND "${METADATA}" "  \"sourceRevision\": \"${SOURCE_REVISION}\",\n")
file(APPEND "${METADATA}" "  \"toolchain\": \"${TOOLCHAIN}\",\n")
file(APPEND "${METADATA}" "  \"ndkVersion\": \"${NDK_VERSION}\",\n")
file(APPEND "${METADATA}" "  \"perfettoTrace\": ${_perfetto_json},\n")
file(APPEND "${METADATA}" "  \"sizeBytes\": ${_archive_size},\n")
file(APPEND "${METADATA}" "  \"sha256\": \"${_archive_sha256}\"\n")
file(APPEND "${METADATA}" "}\n")
