# Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

file(GLOB TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*-test.toit")

set(TOITRUN toit.run${CMAKE_EXECUTABLE_SUFFIX} CACHE FILEPATH "The executable used to run the tests")
set(TOITPKG toit.pkg${CMAKE_EXECUTABLE_SUFFIX} CACHE FILEPATH "The executable used to install the packages")
set(TEST_TIMEOUT 40 CACHE STRING "The maximal amount of time each test is allowed to run")
set(SLOW_TEST_TIMEOUT 200 CACHE STRING "The maximal amount of time each slow test is allowed to run")

message("TPKG: ${TOITPKG}")
add_custom_target(
  "install-pkgs"
  COMMAND "${TOITPKG}" install
  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
)

include(ProcessorCount)
ProcessorCount(NUM_CPU)

add_custom_target(
  check
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} --output-on-failure -C Release
  USES_TERMINAL
)

set(TEST_PREFIX "")
include(fail.cmake OPTIONAL)

message("Failing tests: ${FAILING_TESTS}")
message("Skipped tests: ${SKIP_TESTS}")

foreach(file ${TESTS})
  set(test_name "/tests/${file}")
  if("${test_name}" IN_LIST SKIP_TESTS)
    continue()
  endif()

  add_test(
    NAME "${test_name}"
    COMMAND ${TOITRUN} "tests/${file}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/..
  )

  if ("${file}" MATCHES "slow.toit")
    set_tests_properties(${test_name} PROPERTIES TIMEOUT ${SLOW_TEST_TIMEOUT})
  else()
    set_tests_properties(${test_name} PROPERTIES TIMEOUT ${TEST_TIMEOUT})
  endif()

  if("${test_name}" IN_LIST FAILING_TESTS)
    set_tests_properties("${test_name}" PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()
