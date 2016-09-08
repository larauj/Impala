#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

set -euo pipefail
trap 'echo Error in $0 at line $LINENO: $(cd "'$PWD'" && awk "NR == $LINENO" $0)' ERR

CLUSTER_BIN=${IMPALA_HOME}/testdata/bin
HBASE_JAAS_CLIENT=${HBASE_CONF_DIR}/hbase-jaas-client.conf
HBASE_JAAS_SERVER=${HBASE_CONF_DIR}/hbase-jaas-server.conf
HBASE_LOGDIR=${IMPALA_CLUSTER_LOGS_DIR}/hbase

# Kill and clean data for a clean start.
${CLUSTER_BIN}/kill-hbase.sh > /dev/null 2>&1

# Gives HBase startup the proper environment
cat > ${HBASE_CONF_DIR}/hbase-env.sh <<EOF
#
# This file is auto-generated by run-hbase.sh.  Do not edit.
#
export JAVA_HOME=${JAVA_HOME}
export HBASE_LOG_DIR=${HBASE_LOGDIR}
export HBASE_PID_DIR=${HBASE_LOGDIR}
EOF

# Put zookeeper things in the logs/cluster/zoo directory.
# (See hbase.zookeeper.property.dataDir in hbase-site.xml)
rm -rf ${IMPALA_CLUSTER_LOGS_DIR}/zoo
mkdir -p ${IMPALA_CLUSTER_LOGS_DIR}/zoo
mkdir -p ${HBASE_LOGDIR}

if ${CLUSTER_DIR}/admin is_kerberized; then
  #
  # Making a kerberized cluster... set some more environment
  # variables and other magic.
  #
  . ${MINIKDC_ENV}

  if [ ! -f "${HBASE_JAAS_CLIENT}" ]; then
    echo "Can't find ${HBASE_JAAS_CLIENT}"
    exit 1
  fi

  if [ ! -f "${HBASE_JAAS_SERVER}" ]; then
    echo "Can't find ${HBASE_JAAS_SERVER}"
    exit 1
  fi

  # Catch the case where the /hbase directory is not owned by the
  # hbase user.  This can happen when the cluster was formed without
  # kerberos and then remade with "create-test-configuration.sh -k".
  if HBASE_LS_OUTPUT=`hadoop fs -ls -d /hbase 2>&1`; then
    if echo ${HBASE_LS_OUTPUT} | tail -n 1 | grep -q -v " hbase "; then
      # /hbase not owned by 'hbase'.  Failure.
      echo "The HDFS /hbase directory is not owned by \"hbase\"."
      echo "This can happen if the cluster was created with kerberos,"
      echo "and then switched to kerberos without a reformat."
    fi
  fi

  # These ultimately become args to java when it starts up hbase
  K1="-Djava.security.krb5.conf=${KRB5_CONFIG}"
  K2="${JAVA_KRB5_DEBUG}"
  K3="-Djava.security.auth.login.config=${HBASE_JAAS_CLIENT}"
  K4="-Djava.security.auth.login.config=${HBASE_JAAS_SERVER}"

  # Add some kerberos things...
  cat >> ${HBASE_CONF_DIR}/hbase-env.sh <<EOF
export HBASE_OPTS="${K1} ${K2} ${K3}"
export HBASE_MANAGES_ZK=true
export HBASE_ZOOKEEPER_OPTS="${K1} ${K2} ${K4}"
export HBASE_MASTER_OPTS="${K1} ${K2} ${K4}"
export HBASE_REGIONSERVER_OPTS="${K1} ${K2} ${K4}"
EOF
fi

: ${HBASE_START_RETRY_ATTEMPTS=5}

# `rm -f` hbase startup output capture so that `tee -a` below appends
# only for the lifetime of this script
rm -f ${HBASE_LOGDIR}/hbase-startup.out ${HBASE_LOGDIR}/hbase-rs-startup.out

for ((i=1; i <= HBASE_START_RETRY_ATTEMPTS; ++i)); do
  echo "HBase start attempt: ${i}/${HBASE_START_RETRY_ATTEMPTS}"

  echo "Killing any HBase processes possibly lingering from previous start attempts"
  ${IMPALA_HOME}/testdata/bin/kill-hbase.sh
  if ((i > 1)); then
    HBASE_WAIT_AFTER_KILL=$((${i} * 2))
    echo "Waiting ${HBASE_WAIT_AFTER_KILL} seconds before trying again..."
    sleep ${HBASE_WAIT_AFTER_KILL}
  fi

  if ((i < HBASE_START_RETRY_ATTEMPTS)); then
    # Here, we don't want errexit to take effect, so we use if blocks to control the flow.
    if ! ${HBASE_HOME}/bin/start-hbase.sh 2>&1 | tee -a ${HBASE_LOGDIR}/hbase-startup.out
    then
      echo "HBase Master startup failed"
    elif ! ${HBASE_HOME}/bin/local-regionservers.sh start 2 3 2>&1 | \
        tee -a ${HBASE_LOGDIR}/hbase-rs-startup.out
    then
      echo "HBase regionserver startup failed"
    else
      break
    fi
  else
    # In the last iteration, it's fine for errexit to do its thing.
    ${HBASE_HOME}/bin/start-hbase.sh 2>&1 | tee -a ${HBASE_LOGDIR}/hbase-startup.out
    ${HBASE_HOME}/bin/local-regionservers.sh start 2 3 2>&1 | \
        tee -a ${HBASE_LOGDIR}/hbase-rs-startup.out
  fi

done
${CLUSTER_BIN}/check-hbase-nodes.py
echo "HBase startup scripts succeeded"
