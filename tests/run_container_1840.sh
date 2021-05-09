#!/bin/bash
# Since: March, 2021
# Author: gvenzl
# Name: run_container_1840.sh
# Description: Run container test scripts for Oracle DB XE 18.4.0
#
# Copyright 2021 Gerald Venzl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

source ./functions.sh

#######################
###### 18c TESTS ######
#######################

#######################
##### Image tests #####
#######################

runContainerTest "18.4.0 FULL image" "1840-full" "gvenzl/oracle-xe:18.4.0-full"
runContainerTest "18 FULL image" "18-full" "gvenzl/oracle-xe:18-full"
runContainerTest "FULL image" "full" "gvenzl/oracle-xe:full"

runContainerTest "18.4.0 REGULAR image" "1840" "gvenzl/oracle-xe:18.4.0"
runContainerTest "18 REGULAR image" "18" "gvenzl/oracle-xe:18"
runContainerTest "REGULAR image" "latest" "gvenzl/oracle-xe"

#runContainerTest "18.4.0 SLIM image" "1840-slim" "gvenzl/oracle-xe:18.4.0-slim"

#################################
##### Oracle password tests #####
#################################

# Provide different password
ORA_PWD_CMD="-e ORACLE_PASSWORD=MyTestPassword"
# Tell test method not to tear down container
NO_TEAR_DOWN="true"
# Let's keep the container name in a var to keep it simple
CONTAINER_NAME="18-ora-pwd"
# Let's keep the test name in a var to keep it simple too
TEST_NAME="18 ORACLE_PASSWORD"
# This is what we want to have back from the SQL statement
EXPECTED_RESULT="OK"

# Spin up container
runContainerTest "${TEST_NAME}" "${CONTAINER_NAME}" "gvenzl/oracle-xe:18"

# Test password, if it works we will get "OK" back from the SQL statement
result=$(podman exec -i ${CONTAINER_NAME} sqlplus -s system/MyTestPassword@//localhost/XEPDB1 <<EOF
   set heading off;
   set echo off;
   set pagesize 0;
   SELECT '${EXPECTED_RESULT}' FROM dual;
   exit;
EOF
)

# Tear down the container, no longer needed
tear_down_container "${CONTAINER_NAME}"

# See whether we got "OK" back from our test
if [ "${result}" == "${EXPECTED_RESULT}" ]; then
  echo "TEST ${TEST_NAME}: OK";
  echo "";
else
  echo "TEST ${TEST_NAME}: FAILED!";
  exit 1;
fi;

# Clean up environment variables, all tests should remain self-contained
unset CONTAINER_NAME
unset NO_TEAR_DOWN
unset ORA_PWD_CMD
unset TEST_NAME

########################################
##### Oracle random password tests #####
########################################

# We want a random password for this test
ORA_PWD_CMD="-e ORACLE_RANDOM_PASSWORD=sure"
# Tell test method not to tear down container
NO_TEAR_DOWN="true"
# Let's keep the container name in a var to keep it simple
CONTAINER_NAME="18-rand-ora-pwd"
# Let's keep the test name in a var to keep it simple too
TEST_NAME="18 ORACLE_RANDOM_PASSWORD"
# This is what we want to have back from the SQL statement
EXPECTED_RESULT="OK"

# Spin up container
runContainerTest "${TEST_NAME}" "${CONTAINER_NAME}" "gvenzl/oracle-xe:18"

# Let's get the password
rand_pwd=$(podman logs ${CONTAINER_NAME} | grep "ORACLE PASSWORD FOR SYS AND SYSTEM:" | awk '{ print $7 }')

# Test the random password, if it works we will get "OK" back from the SQL statement
result=$(podman exec -i ${CONTAINER_NAME} sqlplus -s system/"${rand_pwd}"@//localhost/XEPDB1 <<EOF
   set heading off;
   set echo off;
   set pagesize 0;
   SELECT '${EXPECTED_RESULT}' FROM dual;
   exit;
EOF
)

# Tear down the container, no longer needed
tear_down_container "${CONTAINER_NAME}"

# See whether we got "OK" back from our test
if [ "${result}" == "${EXPECTED_RESULT}" ]; then
  echo "TEST ${TEST_NAME}: OK";
  echo "";
else
  echo "TEST ${TEST_NAME}: FAILED!";
  exit 1;
fi;

# Clean up environment variables, all tests should remain self-contained
unset CONTAINER_NAME
unset NO_TEAR_DOWN
unset ORA_PWD_CMD
unset TEST_NAME
