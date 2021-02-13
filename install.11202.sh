#!/bin/bash
# Since: January, 2021
# Author: gvenzl
# Name: install.11202.sh
# Description: Install script for Oracle DB XE 11.2.0.2
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

# Exit on errors
# Great explanation on https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

echo "BUILDER: started"

# Build mode ("SLIM", "NORMAL", "FULL")
BUILD_MODE=${1:-"NORMAL"}

echo "BUILDER: BUILD_MODE=${BUILD_MODE}"

# Set data file sizes
SYSTEM_SIZE=353
SYSAUX_SIZE=610
TEMP_SIZE=2
UNDO_SIZE=155
if [ "${BUILD_MODE}" == "FULL" ]; then
   REDO_SIZE=50
elif [ "${BUILD_MODE}" == "NORMAL" ]; then
   REDO_SIZE=20
   USERS_SIZE=10
elif [ "${BUILD_MODE}" == "SLIM" ]; then
   REDO_SIZE=10
   USERS_SIZE=2
fi;

echo "BUILDER: installing additional packages"

# Required for install procedures
microdnf -y install bc procps-ng util-linux net-tools

# Install required system packages
microdnf -y install libaio libnsl

# Install GCC and other packages for full installation
if [ "${BUILD_MODE}" == "FULL" ]; then
   microdnf -y install glibc make binutils gcc
fi;

# Fake 2 GB swap configuration
free() { echo "Swap: 0 0 2048"; }
export -f free

################################
###### Install Database ########
################################

echo "BUILDER: installing database binaries"

# Install Oracle DB binaries
rpm -iv /install/oracle-xe-11.2.0-1.0.x86_64.rpm

# Remove fake 2 GB swap configuration
unset -f cat free

# Change installation directory to /opt/oracle
# Move $ORACLE_BASE under the new $ORACLE_BASE parent directory (i.e. /opt/ for /opt/oracle)
#mv /u01/app/oracle "${ORACLE_BASE%%/oracle}"
#chown -R oracle:dba /u01
# Symlink /u01/app/oracle --> /opt/oracle
# This is so that the hard coded shared libraries paths in the binaries (sqlplus, etc.) can be resolved (check 'ldd sqlplus')
#ln -s "${ORACLE_BASE}" /u01/app/
# Replace absolute path with $ORACLE_BASE variable for /etc/init.d/oracle-xe (used to configure DB later on)
#sed -i "s|/u01/app/oracle|\${ORACLE_BASE}|g" /etc/init.d/oracle-xe
# SQL*Plus and other files (.ora, etc) don't do variable expansion, replace absolute path /u01/app/oracle with value of $ORACLE_BASE
#for file in $(grep -rIl "/u01/app/oracle" "${ORACLE_HOME}"); do
#  sed -i "s|/u01/app/oracle|${ORACLE_BASE}|g" "${file}"
#done;
# Oracle DB directories need to be recreated:
#DATA_PUMP_DIR	/u01/app/oracle/admin/XE/dpdump/
#XMLDIR	/u01/app/oracle/product/11.2.0/xe/rdbms/xml

# Remove memory_target parameter (not supported by default in containers)
sed -i "/memory_target/d" "${ORACLE_HOME}"/config/scripts/init.ora
sed -i "/memory_target/d" "${ORACLE_HOME}"/config/scripts/init"${ORACLE_SID}"Temp.ora

# Add SGA_TARGET and PGA_AGGREGATE_TARGET to pfile
sed -i "$ a sga_target=768m" "${ORACLE_HOME}"/config/scripts/init.ora
sed -i "$ a sga_target=768m" "${ORACLE_HOME}"/config/scripts/init"${ORACLE_SID}"Temp.ora
sed -i "$ a pga_aggregate_target=256m" "${ORACLE_HOME}"/config/scripts/init.ora
sed -i "$ a pga_aggregate_target=256m" "${ORACLE_HOME}"/config/scripts/init"${ORACLE_SID}"Temp.ora

# Set random password
ORACLE_PASSWORD=$(date +%s | base64 | head -c 8)
sed -i "s/###ORACLE_PASSWORD###/${ORACLE_PASSWORD}/g" /install/xe.11202.rsp

echo "BUILDER: configuring database"

# Configure  database
/etc/init.d/oracle-xe configure responseFile=/install/xe.11202.rsp

echo "BUILDER: post config database steps"

# Perform further Database setup operations
su -p oracle -c "sqlplus -s / as sysdba" << EOF
   -- Enable remote HTTP access
   EXEC DBMS_XDB.SETLISTENERLOCALACCESS(FALSE);

   -- Remove original redo logs from fast_recovery_area and create new ones
   ALTER DATABASE ADD LOGFILE GROUP 3 ('${ORACLE_BASE}/oradata/${ORACLE_SID}/redo03.log') SIZE ${REDO_SIZE}m;
   ALTER DATABASE ADD LOGFILE GROUP 4 ('${ORACLE_BASE}/oradata/${ORACLE_SID}/redo04.log') SIZE ${REDO_SIZE}m;
   ALTER SYSTEM SWITCH LOGFILE;
   ALTER SYSTEM SWITCH LOGFILE;
   ALTER SYSTEM CHECKPOINT;
   ALTER DATABASE DROP LOGFILE GROUP 1;
   ALTER DATABASE DROP LOGFILE GROUP 2;
   ALTER DATABASE ADD LOGFILE GROUP 1 ('${ORACLE_BASE}/oradata/${ORACLE_SID}/redo01.log') SIZE ${REDO_SIZE}m;
   ALTER DATABASE ADD LOGFILE GROUP 2 ('${ORACLE_BASE}/oradata/${ORACLE_SID}/redo02.log') SIZE ${REDO_SIZE}m;
   ALTER SYSTEM SWITCH LOGFILE;
   ALTER SYSTEM SWITCH LOGFILE;
   ALTER SYSTEM CHECKPOINT;
   ALTER DATABASE DROP LOGFILE GROUP 3;
   ALTER DATABASE DROP LOGFILE GROUP 4;

   -- Remove fast recovery area
   ALTER SYSTEM SET DB_RECOVERY_FILE_DEST='';
   ALTER SYSTEM SET DB_RECOVERY_FILE_DEST_SIZE=1;
   HOST rm -r "${ORACLE_BASE}"/fast_recovery_area

   -- Setup healthcheck user
   CREATE USER OPS\$ORACLE IDENTIFIED EXTERNALLY;
   GRANT CONNECT, SELECT_CATALOG_ROLE TO OPS\$ORACLE;

   exit;
EOF

# Non-managed (OMF) redo logs aren't deleted automatically (REDO GROUP 3 and 4 above)
# Need to be deleted manually

rm "${ORACLE_BASE}"/oradata/"${ORACLE_SID}"/redo03.log
rm "${ORACLE_BASE}"/oradata/"${ORACLE_SID}"/redo04.log

###################################
######## FULL INSTALL DONE ########
###################################

# If not building the FULL image, remove and shrink additional components
if [ "${BUILD_MODE}" == "NORMAL" ] || [ "${BUILD_MODE}" == "SLIM" ]; then
  su -p oracle -c "sqlplus -s / as sysdba" << EOF

     -- Disable password profile checks
     ALTER PROFILE DEFAULT LIMIT FAILED_LOGIN_ATTEMPTS UNLIMITED PASSWORD_LIFE_TIME UNLIMITED;

     -- Remove APEX
     @${ORACLE_HOME}/apex/apxremov.sql
     DROP PUBLIC SYNONYM HTMLDB_SYSTEM;
     DROP PACKAGE HTMLDB_SYSTEM;

     -- Remove HR schema
     DROP USER HR cascade;

     exit;
EOF

  #TODO
  # Uninstall components
  if [ "${BUILD_MODE}" == "SLIM" ]; then
    su -p oracle -c "sqlplus -s / as sysdba" << EOF

    -- Remove XDB
    SELECT '#TODO' FROM DUAL;
EOF
    # Spatial
    # Text
    # XDB
  fi;

  # Shrink datafiles
 
  su -p oracle -c "sqlplus -s / as sysdba" << EOF

     ---------------------------
     -- Shrink SYSAUX tablespace
     ---------------------------

     -- Create new temporary SYSAUX tablespace
     --CREATE TABLESPACE SYSAUX_TEMP DATAFILE '${ORACLE_BASE}/oradata/${ORACLE_SID}/sysaux_temp.dbf'
     --SIZE 250M AUTOEXTEND ON NEXT 1M MAXSIZE UNLIMITED;

     -- Move tables to temporary SYSAUX tablespace
     --#TODO
     --BEGIN
     --   FOR cur IN (SELECT  owner || '.' || table_name AS name FROM all_tables WHERE tablespace_name = 'SYSAUX') LOOP
     --      EXECUTE IMMEDIATE 'ALTER TABLE ' || cur.name || ' MOVE TABLESPACE SYSAUX_TEMP';
     --   END LOOP;
     --END;
     --/

     ALTER DATABASE DATAFILE '${ORACLE_BASE}/oradata/${ORACLE_SID}/sysaux.dbf' RESIZE ${SYSAUX_SIZE}M;
     ALTER DATABASE DATAFILE '${ORACLE_BASE}/oradata/${ORACLE_SID}/sysaux.dbf'
     AUTOEXTEND ON NEXT 10M MAXSIZE UNLIMITED;

     -- Shrink SYSTEM tablespace
     ALTER DATABASE DATAFILE '${ORACLE_BASE}/oradata/${ORACLE_SID}/system.dbf' RESIZE ${SYSTEM_SIZE}M;
     ALTER DATABASE DATAFILE '${ORACLE_BASE}/oradata/${ORACLE_SID}/system.dbf'
     AUTOEXTEND ON NEXT 10M MAXSIZE UNLIMITED;

     -- Shrink TEMP tablespace
     ALTER DATABASE TEMPFILE '${ORACLE_BASE}/oradata/${ORACLE_SID}/temp.dbf' RESIZE ${TEMP_SIZE}M;
     ALTER DATABASE TEMPFILE '${ORACLE_BASE}/oradata/${ORACLE_SID}/temp.dbf'
     AUTOEXTEND ON NEXT 10M MAXSIZE UNLIMITED;

     -- Shrink USERS tablespace
     ALTER DATABASE DATAFILE '${ORACLE_BASE}/oradata/${ORACLE_SID}/users.dbf' RESIZE ${USERS_SIZE}M;
     ALTER DATABASE DATAFILE '${ORACLE_BASE}/oradata/${ORACLE_SID}/users.dbf'
     AUTOEXTEND ON NEXT 10M MAXSIZE UNLIMITED;

     -- Shrink UNDO tablespace
     ALTER DATABASE DATAFILE '${ORACLE_BASE}/oradata/${ORACLE_SID}/undotbs1.dbf' RESIZE ${UNDO_SIZE}M;
     ALTER DATABASE DATAFILE '${ORACLE_BASE}/oradata/${ORACLE_SID}/undotbs1.dbf'
     AUTOEXTEND ON NEXT 10M MAXSIZE UNLIMITED;


     exit;
EOF

# create or replace directory XMLDIR as '${ORACLE_HOME}/rdbms/xml';

fi;

echo "BUILDER: graceful database shutdown"

# Shutdown database gracefully (listener is not yet running)
su -p oracle -c "sqlplus -s / as sysdba" << EOF
   -- Shutdown database gracefully
   shutdown immediate;
   exit;
EOF

############################
### Create network files ###
############################

echo "BUILDER: creating network files"

# listener.ora
echo \
"SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (SID_NAME = PLSExtProc)
      (ORACLE_HOME = ${ORACLE_HOME})
      (PROGRAM = extproc)
    )
  )

LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC_FOR_${ORACLE_SID}))
      (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
    )
  )

DEFAULT_SERVICE_LISTENER = (${ORACLE_SID})" > "${ORACLE_HOME}"/network/admin/listener.ora

# tnsnames.ora
echo \
"${ORACLE_SID} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${ORACLE_SID})
    )
  )

EXTPROC_CONNECTION_DATA =
  (DESCRIPTION =
    (ADDRESS_LIST =
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC_FOR_${ORACLE_SID}))
    )
    (CONNECT_DATA =
      (SID = PLSExtProc)
      (PRESENTATION = RO)
    )
  )
" > "${ORACLE_HOME}/network/admin/tnsnames.ora"

# sqlnet.ora
echo "NAME.DIRECTORY_PATH= (EZCONNECT, TNSNAMES)" > "${ORACLE_HOME}"/network/admin/sqlnet.ora

chown -R oracle:dba "${ORACLE_HOME}"/network/admin

####################
### bash_profile ###
####################

echo "BUILDER: creating .bash_profile"

# Create .bash_profile for oracle user
echo \
"export ORACLE_BASE=${ORACLE_BASE}
export ORACLE_HOME=\${ORACLE_BASE}/product/11.2.0/xe
export ORACLE_SID=XE
export PATH=\${PATH}:\${ORACLE_HOME}/bin:\${ORACLE_BASE}
" >> "${ORACLE_BASE}"/.bash_profile
chown oracle:dba "${ORACLE_BASE}"/.bash_profile

########################
### Install run file ###
########################

echo "BUILDER: install operational files"

# Move operational files to ${ORACLE_BASE}
mv /install/*.sh "${ORACLE_BASE}"/
mv /install/resetPassword "${ORACLE_BASE}"/

chown oracle:dba "${ORACLE_BASE}"/*.sh \
                 "${ORACLE_BASE}"/resetPassword

chmod u+x "${ORACLE_BASE}"/*.sh \
          "${ORACLE_BASE}"/resetPassword

#########################
####### Cleanup #########
#########################

echo "BUILDER: cleanup"

# Remove install directory
rm -r /install

# Cleanup XE files not needed for being in a container but were installed by the rpm
rm -r /etc/kde/xdg/menus/OracleXE
rm -r /usr/share/applications/oraclexe*
rm -r /usr/share/desktop-menu-files/oraclexe*
rm -r /usr/share/gnome/vfolders/oraclexe*
rm -r /usr/share/pixmaps/oraclexe*
/sbin/chkconfig --del oracle-xe
rm /etc/init.d/oracle-xe

# Remove SYS audit files created during install
rm "${ORACLE_BASE}"/admin/"${ORACLE_SID}"/adump/*.aud

# Remove Data Pump log file
rm "${ORACLE_BASE}"/admin/"${ORACLE_SID}"/dpdump/dp.log

# Remove diag files
rm "${ORACLE_BASE}"/diag/rdbms/xe/"${ORACLE_SID}"/lck/*
rm "${ORACLE_BASE}"/diag/rdbms/xe/"${ORACLE_SID}"/metadata/*
rm "${ORACLE_BASE}"/diag/rdbms/xe/"${ORACLE_SID}"/trace/"${ORACLE_SID}"_*
rm "${ORACLE_BASE}"/diag/tnslsnr/localhost/listener/lck/*
rm "${ORACLE_BASE}"/diag/tnslsnr/localhost/listener/metadata/*
rm -r "${ORACLE_BASE}"/oradiag_oracle/*

# Remove Oracle DB install logs
rm "${ORACLE_HOME}"/config/log/*

if [ "${BUILD_MODE}" == "NORMAL" ] || [ "${BUILD_MODE}" == "SLIM" ]; then

  # Remove APEX directory
  rm -r "${ORACLE_HOME}"/apex

  # Remove JDBC drivers
  rm -r "${ORACLE_HOME}"/jdbc
  rm -r "${ORACLE_HOME}"/jlib

  # Remove ODBC samples
  rm -r "${ORACLE_HOME}"/odbc

  # Remove components from ORACLE_HOME
  if [ "${BUILD_MODE}" == "SLIM" ]; then

    # Remove demo directory
    rm -r "${ORACLE_HOME}"/demo

    # Remove TNS samples
    rm -r "${ORACLE_HOME}"/network/admin/samples

    # Remove NLS demo
    rm -r "${ORACLE_HOME}"/nls/demo

  fi;

fi;

# Remove build packages
# Unfortunately microdnf does not automatically uninstall dependencies that have been
# installed with a package, so if you were to uninstall just util-linux, for example,
# it does not automatically also remove gzip and cracklib again.
microdnf -y remove bc libtirpc libnsl2 libfdisk libutempter gzip cracklib libpwquality \
                   pam util-linux dbus-libs dbus-tools pam libpwquality dbus-common \
                   dbus-daemon libpcap iptables-libs libseccomp kmod-libs acl \
                   device-mapper device-mapper-libs cryptsetup-libs \
                   elfutils-default-yama-scope elfutils-libs systemd-pam systemd dbus \
                   procps-ng net-tools util-linux

# Remove dnf cache
microdnf clean all
